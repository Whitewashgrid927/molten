import Foundation
import Metal
import simd

struct AtelierUniforms {
    var record = SIMD4<Float>(0, 0.22, 1, 1) // angle, angular velocity, speed, tonearm engagement
    var touch = SIMD4<Float>(0, 0, 0, 0) // design coordinates, brush, dragging record
    var clock = SIMD4<Float>(0, 1 / 60, 7, 0)
}

// Mechanical input is tiny CPU state, shared with audio without a GPU readback.
// Fish, wakes and transported ink live entirely in private GPU storage.
struct TurntableMotion {
    private(set) var angle: Float = 0
    private(set) var velocity: Float = 0.22
    private(set) var speed: Float = 1
    private(set) var arm: Float = 1
    private(set) var dragging = false
    private var selection = 0
    private var previousDown = false
    private var previousAngle: Float = 0
    static let pivot = SIMD2<Float>(1.13, -0.86)
    var armTip: SIMD2<Float> { Self.pivot + SIMD2(-0.34 * arm, 1.39) }
    static func point(_ input: PointerState, aspect: Float) -> SIMD2<Float> {
        var p = (input.position - SIMD2<Float>(repeating: 0.5)) * SIMD2(aspect, 1) * 3.1
        p *= exp(input.camera.z)
        p.y /= max(0.5, cos(input.camera.y * 0.5))
        let a = input.camera.x * 0.12
        p = SIMD2(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y)
        return p
    }
    mutating func update(input: PointerState, aspect: Float, dt: Float) {
        let p = Self.point(input, aspect: aspect)
        let down = input.down && input.inside
        if down && !previousDown {
            if simd_distance(p, armTip) < 0.15 || simd_distance(p, Self.pivot) < 0.13 { selection = 3 }
            else if abs(p.x + 1.24) < 0.11 && abs(p.y) < 0.47 { selection = 2 }
            else if simd_distance(p, SIMD2(-1.24, 0.66)) < 0.095 { selection = 4; speed = speed > 0 ? 0 : 1 }
            else if simd_length(p) < 0.98 && input.modifiers & 1 == 0 { selection = 1 }
            else { selection = 0 }
            previousAngle = atan2(p.y, p.x)
        }
        dragging = down && selection == 1
        if down && selection == 2 { speed = min(2, max(0, (0.40 - p.y) / 0.8 * 2)) }
        if down && selection == 3 { arm = min(1, max(0, (Self.pivot.x - p.x) / 0.34)) }
        if dragging {
            let next = atan2(p.y, p.x)
            let delta = atan2(sin(next - previousAngle), cos(next - previousAngle))
            angle += delta
            if dt > 0 { velocity = min(8, max(-8, delta / max(dt, 1 / 240))) }
            previousAngle = next
        } else if dt > 0 {
            // Exact exponential relaxation keeps the coast independent of frame rate.
            let target = 0.22 * speed, damping: Float = 1.35
            let decay = exp(-damping * dt)
            angle += target * dt + (velocity - target) * (1 - decay) / damping
            velocity = target + (velocity - target) * decay
        }
        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        previousDown = down
        if !down { selection = 0 }
    }
}

final class AtelierEngine {
    private let device: MTLDevice
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var scene: Scene?
    private var waves: [MTLTexture] = []
    private var fish: [MTLBuffer] = []
    private var initialized = false
    private var accumulator: Float = 0
    private(set) var tick: UInt32 = 0
    private(set) var motion = TurntableMotion()
    static let fishCount = 7
    static let grid = 256
    var resourceBytes: Int { waves.reduce(0) { $0 + $1.allocatedSize } + fish.reduce(0) { $0 + $1.length } }
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["atelierInitialize", "atelierWaves", "koiStep", "koiRender", "portalRender"] {
            guard let f = library.makeFunction(name: name) else { throw MoltenError.failed("Missing atelier shader: \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function: f)
        }
    }
    func reset() { initialized = false; accumulator = 0; tick = 0; motion = TurntableMotion() }
    func releaseResources() { waves.removeAll(); fish.removeAll(); scene = nil; reset() }
    private func prepare(_ next: Scene) throws {
        guard scene != next else { return }
        releaseResources(); scene = next
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Self.grid, height: Self.grid, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        for _ in 0..<2 {
            guard let t = device.makeTexture(descriptor: d),
                  let b = device.makeBuffer(length: Self.fishCount * 32, options: .storageModePrivate) else {
                throw MoltenError.failed("Could not allocate atelier state.")
            }
            waves.append(t); fish.append(b)
        }
    }
    private func run(_ name: String, command: MTLCommandBuffer, size: MTLSize,
                     textures: [MTLTexture], buffers: [MTLBuffer], u: Uniforms, s: StageUniforms, a: AtelierUniforms) throws {
        guard let e = command.makeComputeCommandEncoder(), let p = pipelines[name] else { throw MoltenError.failed("Could not encode \(name).") }
        var u = u, s = s, a = a
        e.label = name; e.setComputePipelineState(p)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setBytes(&s, length: MemoryLayout<StageUniforms>.stride, index: 1)
        e.setBytes(&a, length: MemoryLayout<AtelierUniforms>.stride, index: 2)
        for (i, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: 3 + i) }
        for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
        e.dispatchThreads(size, threadsPerThreadgroup: size.height == 1 ? MTLSize(width: 8, height: 1, depth: 1) : MTLSize(width: 8, height: 8, depth: 1))
        e.endEncoding()
    }
    func encode(command: MTLCommandBuffer, image: MTLTexture, u: Uniforms, stage: StageUniforms,
                settings: Settings, input: PointerState, dt: Float) throws {
        try prepare(settings.scene)
        let delta = min(max(dt, 0), 1 / 15)
        if settings.scene == .koi { motion.update(input: input, aspect: u.viewport.x / u.viewport.y, dt: delta) }
        var a = AtelierUniforms()
        a.record = SIMD4(motion.angle, motion.velocity, motion.speed, motion.arm)
        let p = settings.scene == .koi ? TurntableMotion.point(input, aspect: u.viewport.x / u.viewport.y) : (input.position - SIMD2(repeating: 0.5)) * 2
        a.touch = SIMD4(p.x, p.y, input.down && input.inside ? 1 : 0, motion.dragging ? 1 : 0)
        let grid = MTLSize(width: Self.grid, height: Self.grid, depth: 1)
        if !initialized {
            try run("atelierInitialize", command: command, size: grid, textures: waves, buffers: fish, u: u, s: stage, a: a)
            initialized = true
        }
        accumulator += delta
        let steps = min(4, Int((accumulator + 0.000001) * 60))
        accumulator = max(0, accumulator - Float(steps) / 60)
        for _ in 0..<steps {
            a.clock.x = Float(tick) / 60
            try run("atelierWaves", command: command, size: grid, textures: waves, buffers: fish, u: u, s: stage, a: a)
            waves.swapAt(0, 1)
            if settings.scene == .koi {
                try run("koiStep", command: command, size: MTLSize(width: Self.fishCount, height: 1, depth: 1), textures: waves, buffers: fish, u: u, s: stage, a: a)
                fish.swapAt(0, 1)
            }
            tick &+= 1
        }
        a.clock.x = Float(tick) / 60
        try run(settings.scene == .koi ? "koiRender" : "portalRender", command: command,
                size: MTLSize(width: image.width, height: image.height, depth: 1),
                textures: [image, waves[0]], buffers: [fish[0]], u: u, s: stage, a: a)
    }
    // Readbacks exist only for headless validation, never the display/audio loop.
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let texture = waves.first, let actors = fish.first else { return [] }
        let row = Self.grid * 16, textureBytes = row * Self.grid
        guard let b = device.makeBuffer(length: textureBytes + actors.length, options: .storageModeShared),
              let c = queue.makeCommandBuffer(), let e = c.makeBlitCommandEncoder() else { throw MoltenError.failed("Atelier snapshot failed.") }
        e.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
               sourceSize: MTLSize(width: Self.grid, height: Self.grid, depth: 1), to: b,
               destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: textureBytes)
        e.copy(from: actors, sourceOffset: 0, to: b, destinationOffset: textureBytes, size: actors.length)
        e.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        return Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: b.length / 4))
    }
}
