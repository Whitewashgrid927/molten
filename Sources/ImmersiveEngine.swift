import AppKit
import Metal
import simd

// Card typography is generated once. Reef state stays on the GPU, with a
// bounded 60 Hz solver and instanced geometry rather than per-pixel fish loops.
final class ImmersiveEngine {
    private let device: MTLDevice
    private var compute: [String: MTLComputePipelineState] = [:]
    private var render: [String: MTLRenderPipelineState] = [:]
    private let opaqueDepth: MTLDepthStencilState
    private let transparentDepth: MTLDepthStencilState
    private var scene: Scene?
    private var quality = -1
    private var atlas: MTLTexture?
    private var flow: [MTLTexture] = []
    private var actors: [MTLBuffer] = []
    private var plankton: [MTLBuffer] = []
    private var depth: MTLTexture?
    private var seabed: MTLTexture?
    private var initialized = false
    private var accumulator: Float = 0
    private(set) var tick: UInt32 = 0
    private(set) var fishCount = 0
    private(set) var planktonCount = 0
    static let jellyCount = 12
    private var lightPosition = SIMD2<Float>(-0.45, 0.55)
    var resourceBytes: Int {
        [atlas, depth, seabed].compactMap { $0 }.reduce(0) { $0 + $1.allocatedSize }
        + flow.reduce(0) { $0 + $1.allocatedSize }
        + (actors + plankton).reduce(0) { $0 + $1.length }
    }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["cardRender", "reefInitialize", "reefFlowInitialize", "reefFlowStep", "reefActorsStep", "reefPlanktonStep", "reefBackground"] {
            guard let f = library.makeFunction(name: name) else { throw MoltenError.failed("Missing immersive shader: \(name)") }
            compute[name] = try device.makeComputePipelineState(function: f)
        }
        for (vertex, fragment, transparent) in [
            ("reefFishVertex", "reefSolidFragment", false),
            ("reefKelpVertex", "reefSolidFragment", false),
            ("reefCoralVertex", "reefSolidFragment", false),
            ("reefPolypVertex", "reefSolidFragment", false),
            ("reefJellyVertex", "reefJellyFragment", true),
            ("reefTentacleVertex", "reefJellyFragment", true),
            ("reefPlanktonVertex", "reefPlanktonFragment", true)
        ] {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.depthAttachmentPixelFormat = .depth32Float
            if transparent {
                let color = d.colorAttachments[0]!
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .zero
                color.destinationAlphaBlendFactor = .one
            }
            render[vertex] = try device.makeRenderPipelineState(descriptor: d)
        }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less; d.isDepthWriteEnabled = true
        guard let opaque = device.makeDepthStencilState(descriptor: d) else { throw MoltenError.failed("No reef depth state.") }
        opaqueDepth = opaque
        d.isDepthWriteEnabled = false
        guard let transparent = device.makeDepthStencilState(descriptor: d) else { throw MoltenError.failed("No transparent depth state.") }
        transparentDepth = transparent
    }

    func reset() { initialized = false; accumulator = 0; tick = 0; lightPosition = SIMD2(-0.45, 0.55) }
    func releaseResources() {
        atlas = nil; flow.removeAll(); actors.removeAll(); plankton.removeAll()
        depth = nil; seabed = nil; scene = nil; quality = -1; fishCount = 0; planktonCount = 0
        reset()
    }
    private func texture(_ width: Int, _ height: Int, depth: Int = 1, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = depth > 1 ? .type3D : .type2D
        d.width = width; d.height = height; d.depth = depth; d.pixelFormat = format
        d.storageMode = .private
        d.usage = format == .depth32Float ? [.renderTarget] : [.shaderRead, .shaderWrite]
        guard let t = device.makeTexture(descriptor: d) else { throw MoltenError.failed("Could not allocate immersive texture.") }
        return t
    }
    private func buffer(_ count: Int) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: count * 32, options: .storageModePrivate) else { throw MoltenError.failed("Could not allocate reef organisms.") }
        return b
    }
    private func makeAtlas() throws -> MTLTexture {
        let width = 1024, height = 768
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw MoltenError.failed("Could not create card lettering.")
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        func text(_ value: String, y: CGFloat, size: CGFloat, x: CGFloat = 0, serif: Bool = false, tracking: CGFloat = 0) {
            let font = serif ? NSFont(name: "Baskerville", size: size) ?? NSFont.systemFont(ofSize: size)
                : NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: tracking]
            let string = value as NSString, w = string.size(withAttributes: attributes).width
            string.draw(at: NSPoint(x: x + (512 - w) / 2, y: y), withAttributes: attributes)
        }
        text("M O L T E N   /   A R C A N A", y: 699, size: 10)
        text("OBSIDIAN", y: 146, size: 43, serif: true, tracking: 5)
        text("THE MIDNIGHT EMPRESS", y: 124, size: 10, tracking: 1.5)
        text("NO. 018     ·     FIRST EDITION", y: 59, size: 9, tracking: 0.4)
        text("M O L T E N", y: 668, size: 21, x: 512, serif: true)
        text("A R C A N A", y: 625, size: 11, x: 512)
        text("THE NIGHT COLLECTION", y: 155, size: 11, x: 512, tracking: 1)
        text("XVIII  /  MMXXVI", y: 115, size: 11, x: 512)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { throw MoltenError.failed("Card lettering is unavailable.") }
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in gray.indices { gray[i] = data[i * 4] }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { throw MoltenError.failed("Could not upload card lettering.") }
        gray.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        return t
    }
    private func prepare(_ settings: Settings, width: Int, height: Int) throws {
        if scene != settings.scene || quality != settings.quality {
            releaseResources(); scene = settings.scene; quality = settings.quality
            if scene == .holographic { atlas = try makeAtlas() }
            else {
                fishCount = [192, 384, 640, 960][quality]
                planktonCount = [2048, 4096, 8192, 12288][quality]
                actors = try (0..<2).map { _ in try buffer(fishCount + Self.jellyCount) }
                plankton = try (0..<2).map { _ in try buffer(planktonCount) }
                flow = try (0..<2).map { _ in try texture(32, 24, depth: 32) }
            }
        }
        if scene == .reef && (depth?.width != width || depth?.height != height) {
            depth = try texture(width, height, format: .depth32Float)
            seabed = try texture(width, height, format: .r32Float)
        }
    }
    private func run(_ name: String, command: MTLCommandBuffer, size: MTLSize, u: Uniforms, s: StageUniforms,
                     textures: [MTLTexture] = [], buffers: [MTLBuffer] = []) throws {
        guard let pipeline = compute[name], let e = command.makeComputeCommandEncoder() else { throw MoltenError.failed("Could not encode \(name).") }
        var u = u, s = s
        e.label = name; e.setComputePipelineState(pipeline)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setBytes(&s, length: MemoryLayout<StageUniforms>.stride, index: 1)
        for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
        for (i, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: i + 2) }
        let group = size.depth > 1 ? MTLSize(width: 4, height: 4, depth: 4) : size.height == 1
            ? MTLSize(width: 128, height: 1, depth: 1) : MTLSize(width: 8, height: 8, depth: 1)
        e.dispatchThreads(size, threadsPerThreadgroup: group); e.endEncoding()
    }
    func encode(command: MTLCommandBuffer, image: MTLTexture, u: Uniforms, stage: StageUniforms, settings: Settings, dt: Float) throws {
        try prepare(settings, width: image.width, height: image.height)
        var s = stage
        let pixels = MTLSize(width: image.width, height: image.height, depth: 1)
        if settings.scene == .holographic, let atlas {
            if u.pointer.z > 0.5 && UInt32(s.state.z) & 1 != 0 { lightPosition = (SIMD2(u.pointer.x, u.pointer.y) - 0.5) * SIMD2(2, -2) }
            s.light = SIMD4(lightPosition.x, lightPosition.y, 0, 0)
            try run("cardRender", command: command, size: pixels, u: u, s: s, textures: [image, atlas])
            return
        }
        guard let seabed, let depth else { throw MoltenError.failed("Missing reef targets.") }
        let cube = MTLSize(width: 32, height: 24, depth: 32)
        let population = MTLSize(width: planktonCount, height: 1, depth: 1)
        s.simulation = SIMD4(Float(tick) / 60, 1 / 60, Float(fishCount), Float(planktonCount))
        if !initialized {
            try run("reefInitialize", command: command, size: population, u: u, s: s, buffers: [actors[0], plankton[0]])
            try run("reefFlowInitialize", command: command, size: cube, u: u, s: s, textures: [flow[0]])
            initialized = true
        }
        accumulator += min(max(dt, 0), 1 / 15)
        let steps = min(4, Int((accumulator + 0.000001) * 60))
        accumulator = max(0, accumulator - Float(steps) / 60)
        // Pointer displacement is consumed once per frame, independent of how
        // many fixed physics ticks this frame needs.
        var physics = u
        physics.interaction /= Float(max(steps, 1))
        for _ in 0..<steps {
            s.simulation.x = Float(tick) / 60
            try run("reefFlowStep", command: command, size: cube, u: physics, s: s, textures: flow)
            flow.swapAt(0, 1)
            try run("reefActorsStep", command: command, size: MTLSize(width: fishCount + Self.jellyCount, height: 1, depth: 1), u: physics, s: s,
                    textures: [flow[0]], buffers: actors)
            try run("reefPlanktonStep", command: command, size: population, u: physics, s: s, textures: [flow[0]], buffers: plankton)
            actors.swapAt(0, 1); plankton.swapAt(0, 1); tick &+= 1
        }
        s.simulation.x = Float(tick) / 60
        try run("reefBackground", command: command, size: pixels, u: u, s: s, textures: [image, seabed, flow[0]])
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = image; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { throw MoltenError.failed("Could not draw reef geometry.") }
        var u = u
        e.label = "Reef organisms and vegetation"
        e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setVertexBytes(&s, length: MemoryLayout<StageUniforms>.stride, index: 1)
        e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setFragmentBytes(&s, length: MemoryLayout<StageUniforms>.stride, index: 1)
        e.setVertexBuffer(actors[0], offset: 0, index: 2)
        e.setVertexTexture(flow[0], index: 0); e.setFragmentTexture(seabed, index: 0)
        e.setCullMode(.none)
        func draw(_ shader: String, vertices: Int, instances: Int, transparent: Bool = false) {
            e.setRenderPipelineState(render[shader]!)
            e.setDepthStencilState(transparent ? transparentDepth : opaqueDepth)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices, instanceCount: instances)
        }
        draw("reefKelpVertex", vertices: 24 * 6, instances: 56 * 7)
        draw("reefCoralVertex", vertices: 12 * 4 * 6, instances: 36 * 15)
        draw("reefPolypVertex", vertices: 12 * 8 * 6, instances: 180)
        draw("reefFishVertex", vertices: 12 * 8 * 6 + 12, instances: fishCount)
        draw("reefJellyVertex", vertices: 32 * 14 * 6, instances: Self.jellyCount, transparent: true)
        draw("reefTentacleVertex", vertices: 24 * 6, instances: Self.jellyCount * 10, transparent: true)
        e.setVertexBuffer(plankton[0], offset: 0, index: 2)
        draw("reefPlanktonVertex", vertices: 6, instances: planktonCount, transparent: true)
        e.endEncoding()
    }

    // Test-only readback. The live renderer never maps simulation state to CPU.
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let source = actors.first, let particles = plankton.first, let current = flow.first,
              let c = queue.makeCommandBuffer(), let b = c.makeBlitCommandEncoder() else { return [] }
        let flowBytes = current.width * current.height * current.depth * 8
        guard let result = device.makeBuffer(length: source.length + particles.length + flowBytes, options: .storageModeShared) else {
            throw MoltenError.failed("Reef snapshot allocation failed.")
        }
        b.copy(from: source, sourceOffset: 0, to: result, destinationOffset: 0, size: source.length)
        b.copy(from: particles, sourceOffset: 0, to: result, destinationOffset: source.length, size: particles.length)
        b.copy(from: current, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: current.width, height: current.height, depth: current.depth), to: result,
            destinationOffset: source.length + particles.length, destinationBytesPerRow: current.width * 8,
            destinationBytesPerImage: current.width * current.height * 8)
        b.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        let count = (source.length + particles.length) / 4
        var values = Array(UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: Float.self), count: count))
        values += UnsafeBufferPointer(start: result.contents().advanced(by: count * 4).assumingMemoryBound(to: Float16.self), count: flowBytes / 2).map(Float.init)
        return values
    }
}
