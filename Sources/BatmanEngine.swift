import Foundation
import Metal
import MetalKit
import simd

struct BatmanFrame {
    var page = SIMD4<Float>.zero       // viewport-to-page scale, bounded depth shift
    var touch = SIMD4<Float>.zero      // page position, pressed, impulse
    var clock = SIMD4<Float>.zero      // simulation seconds, step, artwork dimensions
}

// The original drawing owns the appearance. A continuous displacement field
// moves its painted regions without cutting holes or inventing hidden anatomy.
final class BatmanEngine {
    static let grid = 96
    let device: MTLDevice
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private(set) var artwork: MTLTexture?
    private var masks: MTLTexture?
    private var waves: [MTLTexture] = []
    private var initialized = false, masksReady = false
    private var accumulator: Float = 0
    private(set) var tick: UInt32 = 0
    var resourceBytes: Int {
        (artwork?.allocatedSize ?? 0) + (masks?.allocatedSize ?? 0) + waves.reduce(0) { $0 + $1.allocatedSize }
    }
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["batmanMasks", "batmanInitialize", "batmanFlow", "batmanIllustration"] {
            guard let f = library.makeFunction(name: name) else { throw MoltenError.failed("Missing illustration shader: \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function: f)
        }
    }
    func reset() { initialized = false; accumulator = 0; tick = 0 }
    func releaseResources() { artwork = nil; masks = nil; waves.removeAll(); masksReady = false; reset() }
    private func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        guard let t = device.makeTexture(descriptor: d) else { throw MoltenError.failed("Could not allocate illustration state.") }
        return t
    }
    private func prepare() throws {
        guard artwork == nil else { return }
        guard let url = Bundle.main.url(forResource: "Original", withExtension: "png", subdirectory: "BatmanArtwork") else {
            throw MoltenError.failed("The original Batman artwork is missing. Reinstall Molten.")
        }
        // Retain display-encoded sRGB: stageResolve already bypasses tone
        // mapping for printed-art scenes. Do not apply a second gamma curve.
        let picture = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
            .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
        let regions = try texture(384, 480, .rgba16Float)
        let state = try (0..<2).map { _ in try texture(Self.grid, Self.grid, .rg32Float) }
        picture.label = "Unmodified original illustration"
        regions.label = "Illustration depth and painted-region masks"
        artwork = picture; masks = regions; waves = state
    }
    private func frame(_ input: PointerState, _ u: Uniforms) -> BatmanFrame {
        var f = BatmanFrame()
        let aspect = Float(artwork!.width) / Float(artwork!.height)
        let screenAspect = u.viewport.x / u.viewport.y
        let zoom = exp(min(0.8, max(-0.8, input.camera.z)))
        let scale = SIMD2(max(1, screenAspect / aspect), max(1, aspect / screenAspect)) * zoom
        f.page = SIMD4(scale.x, scale.y, min(0.6, max(-0.6, input.camera.x)) * 0.040,
                      min(0.6, max(-0.6, input.camera.y)) * 0.032)
        let point = (input.position - SIMD2(repeating: 0.5)) * scale + SIMD2(repeating: 0.5)
        let inside = input.inside && point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
        f.touch = SIMD4(point.x, point.y, input.down && inside ? 1 : 0, min(1, simd_length(input.delta) * 30))
        f.clock = SIMD4(Float(tick) / 60, 1 / 60, Float(artwork!.width), Float(artwork!.height))
        return f
    }
    private func run(_ name: String, command: MTLCommandBuffer, size: MTLSize,
                     u: Uniforms, f: BatmanFrame, textures: [MTLTexture]) throws {
        guard let e = command.makeComputeCommandEncoder(), let p = pipelines[name] else {
            throw MoltenError.failed("Could not encode \(name).")
        }
        var u = u, f = f
        e.label = name; e.setComputePipelineState(p)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setBytes(&f, length: MemoryLayout<BatmanFrame>.stride, index: 1)
        for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
        e.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e.endEncoding()
    }
    func encode(command: MTLCommandBuffer, image: MTLTexture, u: Uniforms, stage: StageUniforms,
                settings: Settings, input: PointerState, dt: Float) throws {
        try prepare()
        guard let artwork, let masks else { throw MoltenError.failed("Missing illustration textures.") }
        let grid = MTLSize(width: Self.grid, height: Self.grid, depth: 1)
        var f = frame(input, u)
        if !masksReady {
            try run("batmanMasks", command: command, size: MTLSize(width: masks.width, height: masks.height, depth: 1),
                    u: u, f: f, textures: [masks]); masksReady = true
        }
        if !initialized {
            try run("batmanInitialize", command: command, size: grid, u: u, f: f, textures: waves); initialized = true
        }
        // Reopening a window cannot run an unbounded simulation backlog.
        accumulator += settings.paused ? 0 : min(max(dt, 0), 1 / 15)
        let steps = min(4, Int((accumulator + 0.000001) * 60))
        accumulator = max(0, accumulator - Float(steps) / 60)
        for _ in 0..<steps {
            f = frame(input, u)
            try run("batmanFlow", command: command, size: grid, u: u, f: f, textures: [waves[0], waves[1], masks])
            waves.swapAt(0, 1); tick &+= 1
        }
        f = frame(input, u)
        try run("batmanIllustration", command: command, size: MTLSize(width: image.width, height: image.height, depth: 1),
                u: u, f: f, textures: [artwork, masks, waves[0], image])
    }
    // Verification only; the interactive renderer never reads GPU state back.
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let t = waves.first else { return [] }
        let row = Self.grid * 8, bytes = row * Self.grid
        guard let b = device.makeBuffer(length: bytes, options: .storageModeShared),
              let c = queue.makeCommandBuffer(), let e = c.makeBlitCommandEncoder() else {
            throw MoltenError.failed("Could not inspect illustration state.")
        }
        e.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
               sourceSize: MTLSize(width: Self.grid, height: Self.grid, depth: 1), to: b,
               destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: bytes)
        e.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        return Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: bytes / 4))
    }
}
