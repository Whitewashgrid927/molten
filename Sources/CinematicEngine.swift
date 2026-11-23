import Foundation
import Metal
import simd

// A separate, active-scene-only resource owner. Large simulations stay on the
// GPU; small interaction models submit bounded state and camera uniforms.
struct StageUniforms {
    var camera = SIMD4<Float>(repeating: 0)
    var eye = SIMD4<Float>(repeating: 0)
    var object = SIMD4<Float>(repeating: 0)
    var light = SIMD4<Float>(-1.3, 3.2, 1.1, 0)
    var metal = SIMD4<Float>(0.95, 0.42, 0.38, 0)
    var state = SIMD4<Float>(repeating: 0)
    var simulation = SIMD4<Float>(repeating: 0)
}

final class CinematicEngine {
    let device: MTLDevice
    let immersive: ImmersiveEngine
    let river: RiverEngine
    let atelier: AtelierEngine
    let cove: CoveEngine
    let batman: BatmanEngine
    let urban: UrbanEngine
    let glassEffect: GlassEffectEngine
    let pool: PoolEngine
    let paper: PaperEngine
    let wind: WindEngine
    private let pipelines: [String: MTLComputePipelineState]
    private var scene: Scene?
    private var quality = -1
    private var images: [MTLTexture] = []
    private var volumes: [MTLTexture] = []
    private var buffers: [MTLBuffer] = []
    private var initialized = false
    private var accumulator: Float = 0
    private var tick: UInt32 = 0
    private var signature: [Float] = []
    private var previousDown = false
    private var object = SIMD4<Float>(repeating: 0)
    private var light = SIMD4<Float>(-1.3, 3.2, 1.1, 0)
    private var metal = SIMD4<Float>(0.95, 0.42, 0.38, 0)
    private var grabOffset = SIMD3<Float>(repeating: 0)
    private(set) var samples = 0
    private(set) var renderedSamples = 0
    static let sampleLimit = 128
    static let liquidParticles = 16_384
    static let hashSide = 20
    static let cellCapacity = 96
    private(set) var volumeSide = 0
    var resourceBytes: Int {
        paper.resourceBytes + wind.resourceBytes + pool.resourceBytes + glassEffect.resourceBytes + urban.resourceBytes + batman.resourceBytes + cove.resourceBytes + atelier.resourceBytes + river.resourceBytes + immersive.resourceBytes + images.reduce(0) { $0 + $1.allocatedSize } + volumes.reduce(0) { $0 + $1.allocatedSize }
            + buffers.reduce(0) { $0 + $1.length }
    }
    var targetSamples: Int {
        if scene?.rendersDirectly == true { return 1 }
        return scene?.isStatic == true && quality >= 0 ? [8, 16, 32, 128][quality] : Self.sampleLimit
    }
    var converged: Bool { samples >= targetSamples }
    func invalidateHistory() { samples = 0; signature.removeAll() }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        self.immersive = try ImmersiveEngine(device: device, library: library)
        self.river = try RiverEngine(device: device, library: library)
        self.atelier = try AtelierEngine(device: device, library: library)
        self.cove = try CoveEngine(device: device, library: library)
        self.batman = try BatmanEngine(device: device, library: library)
        self.urban = try UrbanEngine(device: device, library: library)
        self.glassEffect = try GlassEffectEngine(device: device, library: library)
        self.pool = try PoolEngine(device: device, library: library)
        self.paper = try PaperEngine(device: device, library: library)
        self.wind = try WindEngine(device: device, library: library)
        var result: [String: MTLComputePipelineState] = [:]
        for name in ["stageResolve", "spectralPhotons", "spectralRender", "photonResolve",
                     "tankInitialize", "tankPredict", "tankGrid", "tankLambda", "tankCorrect", "tankApply",
                     "tankFinish", "tankSplat", "tankField", "tankBody", "tankRender",
                     "fireInitialize", "fireAdvect", "fireCurl", "fireForce", "fireDivergence",
                     "firePressure", "fireProject", "fireRender", "planetRender", "fractalRender"] {
            guard let function = library.makeFunction(name: name) else { throw MoltenError.failed("Missing cinematic shader: \(name)") }
            result[name] = try device.makeComputePipelineState(function: function)
        }
        pipelines = result
    }

    func reset() {
        immersive.reset()
        river.reset()
        atelier.reset()
        cove.reset()
        batman.reset()
        urban.reset()
        glassEffect.reset()
        pool.reset()
        paper.reset()
        wind.reset()
        initialized = false
        accumulator = 0
        tick = 0
        signature.removeAll()
        samples = 0
        previousDown = false
        object = scene == .combustion ? SIMD4(0.18, 1.05, 0, 0) : .zero
        light = SIMD4(-1.3, 3.2, 1.1, 0)
        metal = SIMD4(0.95, 0.42, 0.38, 0)
    }
    func releaseResources() {
        immersive.releaseResources()
        river.releaseResources()
        atelier.releaseResources()
        cove.releaseResources()
        batman.releaseResources()
        urban.releaseResources()
        glassEffect.releaseResources()
        pool.releaseResources()
        paper.releaseResources()
        wind.releaseResources()
        images.removeAll(); volumes.removeAll(); buffers.removeAll()
        scene = nil; quality = -1; volumeSide = 0
        reset()
    }
    private func texture(width: Int, height: Int, depth: Int = 1, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = depth > 1 ? .type3D : .type2D
        d.pixelFormat = format; d.width = width; d.height = height; d.depth = depth
        d.storageMode = .private; d.usage = depth > 1 ? [.shaderRead, .shaderWrite] : [.shaderRead, .shaderWrite, .renderTarget]
        guard let t = device.makeTexture(descriptor: d) else { throw MoltenError.failed("Could not allocate a cinematic texture.") }
        return t
    }
    private func buffer(_ length: Int) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: length, options: .storageModePrivate) else {
            throw MoltenError.failed("Could not allocate cinematic simulation storage.")
        }
        return b
    }
    private func prepare(settings: Settings, width: Int, height: Int) throws {
        // Quality changes adjust pixels without resetting a stone mid-gesture.
        if scene == settings.scene && (scene == .resonantGarden || scene == .paperFolders) { quality = settings.quality }
        if scene != settings.scene || quality != settings.quality {
            releaseResources()
            scene = settings.scene; quality = settings.quality
            switch settings.scene {
            case .spectral:
                buffers = [try buffer(512 * 512 * 3 * 4)]
                volumes = [try texture(width: 512, height: 512)]
            case .fluidTank:
                volumeSide = [48, 64, 80, 96][quality]
                let n = Self.liquidParticles, cells = Self.hashSide * Self.hashSide * Self.hashSide
                buffers = [try buffer(n * 64), try buffer(n * 64), try buffer(cells * 4),
                           try buffer(cells * Self.cellCapacity * 4), try buffer(n * 4), try buffer(n * 16),
                           try buffer(volumeSide * volumeSide * volumeSide * 4), try buffer(32)]
                volumes = [try texture(width: volumeSide, height: volumeSide, depth: volumeSide, format: .r16Float)]
            case .combustion:
                object = SIMD4(0.18, 1.05, 0, 0)
                volumeSide = [40, 48, 64, 72][quality]
                for index in 0..<8 {
                    volumes.append(try texture(width: volumeSide, height: volumeSide, depth: volumeSide,
                                               format: (4...6).contains(index) ? .r16Float : .rgba16Float))
                }
            default: break
            }
        }
        // A photographed illustration needs neither ray accumulation nor HDR
        // history targets. It writes the display texture directly.
        if !settings.scene.rendersDirectly && (images.first?.width != width || images.first?.height != height) {
            images = try (0..<3).map { _ in try texture(width: width, height: height) }
            samples = 0; signature.removeAll()
        }
    }
    private func run(_ name: String, command: MTLCommandBuffer, size: MTLSize,
                     textures: [MTLTexture] = [], buffers: [MTLBuffer] = [], u: Uniforms, s: StageUniforms) throws {
        guard let p = pipelines[name], let e = command.makeComputeCommandEncoder() else { throw MoltenError.failed("Could not encode \(name).") }
        var u = u, s = s
        e.label = name; e.setComputePipelineState(p)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setBytes(&s, length: MemoryLayout<StageUniforms>.stride, index: 1)
        for (index, t) in textures.enumerated() { e.setTexture(t, index: index) }
        for (index, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: index + 2) }
        let group = size.depth > 1 ? MTLSize(width: 4, height: 4, depth: 4)
            : size.height == 1 ? MTLSize(width: 128, height: 1, depth: 1) : MTLSize(width: 8, height: 8, depth: 1)
        e.dispatchThreads(size, threadsPerThreadgroup: group)
        e.endEncoding()
    }
    private func clear(_ buffers: [MTLBuffer], command: MTLCommandBuffer) throws {
        guard let e = command.makeBlitCommandEncoder() else { throw MoltenError.failed("Could not clear cinematic storage.") }
        for b in buffers { e.fill(buffer: b, range: 0..<b.length, value: 0) }
        e.endEncoding()
    }

    // Same orbit camera and plane intersection as stageCamera in Cinematic.metal.
    private func pointerOnPlane(_ input: PointerState, aspect: Float, y: Float, fire: Bool = false) -> SIMD3<Float> {
        let target = SIMD3<Float>(0, fire ? 1 : 0.65, 0)
        var offset = (fire ? SIMD3<Float>(2.4, 0.95, 4) : SIMD3<Float>(0, 1.65, 4.8)) * exp(input.camera.z)
        let pitch = input.camera.y, yaw = input.camera.x
        offset = SIMD3(offset.x, cos(pitch) * offset.y - sin(pitch) * offset.z, sin(pitch) * offset.y + cos(pitch) * offset.z)
        offset = SIMD3(cos(yaw) * offset.x + sin(yaw) * offset.z, offset.y, -sin(yaw) * offset.x + cos(yaw) * offset.z)
        let origin = target + offset
        let f = simd_normalize(target - origin), r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        let up = simd_cross(r, f)
        let xy = (input.position - SIMD2<Float>(repeating: 0.5)) * SIMD2(2 * aspect, -2)
        let ray = simd_normalize(f * 2.2 + r * xy.x + up * xy.y)
        guard abs(ray.y) > 0.01 else { return SIMD3(0, y, 0) }
        let distance = (y - origin.y) / ray.y
        guard distance > 0, distance < 30 else { return SIMD3(0, y, 0) }
        let hit = origin + ray * distance
        return SIMD3(min(2, max(-2, hit.x)), y, min(2, max(-2, hit.z)))
    }

    func encode(command: MTLCommandBuffer, output: MTLTexture, uniforms: Uniforms,
                settings: Settings, input: PointerState, dt: Float) throws {
        let width = output.width, height = output.height
        try prepare(settings: settings, width: width, height: height)
        if settings.scene == .spectral && input.down {
            let isLight = input.modifiers & 1 != 0, isMetal = input.modifiers & 2 != 0
            let plane: Float = isLight ? 1.8 : isMetal ? 0.42 : 0.65
            let hit = pointerOnPlane(input, aspect: Float(width) / Float(height), y: plane)
            let selected = isLight ? light : isMetal ? metal : object
            if !previousDown { grabOffset = SIMD3(selected.x, selected.y, selected.z) - hit }
            let p = hit + grabOffset
            if isLight { light.x = p.x; light.z = p.z }
            else if isMetal { metal.x = p.x; metal.z = p.z }
            else { object.x = p.x; object.z = p.z }
        }
        previousDown = input.down
        if settings.scene == .combustion && input.down && input.modifiers & 1 != 0 {
            let p = pointerOnPlane(input, aspect: Float(width) / Float(height), y: 1.05, fire: true)
            object = SIMD4(min(0.7, max(-0.7, p.x)), p.y, min(0.7, max(-0.7, p.z)), 0)
        }
        if settings.scene == .stormPlanet && input.down { light.w = (input.position.x - 0.5) * 6.28 }
        var u = uniforms
        if settings.scene.isStatic { u.viewport.z = 0 }
        var s = StageUniforms()
        s.camera = input.camera; s.eye = SIMD4(input.eye.x, input.eye.y, input.eye.z, 0)
        s.object = object; s.light = light; s.metal = metal
        s.state.z = Float(input.modifiers)
        s.simulation = SIMD4(Float(tick) / 120, 1 / 120, Float(Self.liquidParticles), Float(volumeSide))
        // Stochastic refinement is valid only for the exact same scene state.
        // Animated frames always begin a new history; pause enables refinement.
        let nextSignature: [Float] = [Float(width), Float(height), Float(settings.scene.rawValue), Float(settings.preset),
            Float(settings.quality), settings.intensity, settings.sceneParameters.x, settings.sceneParameters.y, settings.sceneParameters.z,
            input.camera.x, input.camera.y, input.camera.z, input.camera.w, input.eye.x, input.eye.y, input.eye.z,
            object.x, object.z, light.x, light.z, light.w, metal.x, metal.z, u.viewport.z,
            input.down ? input.position.x : 0, input.down ? input.position.y : 0,
            input.down ? 1 : 0, Float(input.modifiers), Float(tick), Float(input.actionSerial), input.freeCamera ? 1 : 0]
        if signature != nextSignature { samples = 0; signature = nextSignature }
        let progressive = (settings.scene.isStatic || (settings.quality == 3 && settings.paused)) && !input.down && !input.orbiting
        if !progressive { samples = 0 }
        if progressive && converged { return }
        s.state.x = Float(samples)
        s.state.y = progressive ? 1 : 0
        // Input motion uses fewer ray steps, but returns to full detail on release.
        s.state.w = input.down || input.orbiting ? 1 : 0
        let pixels = MTLSize(width: width, height: height, depth: 1)
        let cube = MTLSize(width: volumeSide, height: volumeSide, depth: volumeSide)
        let particles = MTLSize(width: Self.liquidParticles, height: 1, depth: 1)
        switch settings.scene {
        case .spectral:
            try clear(buffers, command: command)
            try run("spectralPhotons", command: command, size: MTLSize(width: 131_072, height: 1, depth: 1), buffers: buffers, u: u, s: s)
            try run("photonResolve", command: command, size: MTLSize(width: 512, height: 512, depth: 1), textures: volumes, buffers: buffers, u: u, s: s)
            try run("spectralRender", command: command, size: pixels, textures: [images[0], volumes[0]], u: u, s: s)
        case .fluidTank:
            if !initialized {
                try clear([buffers[6], buffers[7]], command: command)
                try run("tankInitialize", command: command, size: particles, buffers: [buffers[0], buffers[7]], u: u, s: s)
                try run("tankSplat", command: command, size: particles, buffers: [buffers[0], buffers[6]], u: u, s: s)
                try run("tankField", command: command, size: cube, textures: volumes, buffers: [buffers[6]], u: u, s: s)
            }
            accumulator += min(max(dt, 0), 1 / 15)
            let steps = min(8, Int((accumulator + 0.000001) * 120))
            accumulator = max(0, accumulator - Float(steps) / 120)
            for _ in 0..<steps {
                s.simulation.x = Float(tick) / 120
                try run("tankBody", command: command, size: MTLSize(width: 1, height: 1, depth: 1), textures: volumes, buffers: [buffers[7]], u: u, s: s)
                try run("tankPredict", command: command, size: particles, buffers: [buffers[0], buffers[7]], u: u, s: s)
                for _ in 0..<3 {
                    try clear([buffers[2]], command: command)
                    try run("tankGrid", command: command, size: particles, buffers: [buffers[0], buffers[2], buffers[3]], u: u, s: s)
                    try run("tankLambda", command: command, size: particles, buffers: [buffers[0], buffers[2], buffers[3], buffers[4]], u: u, s: s)
                    try run("tankCorrect", command: command, size: particles, buffers: [buffers[0], buffers[2], buffers[3], buffers[4], buffers[5], buffers[7]], u: u, s: s)
                    try run("tankApply", command: command, size: particles, buffers: [buffers[0], buffers[5]], u: u, s: s)
                }
                try run("tankFinish", command: command, size: particles, buffers: [buffers[0], buffers[1], buffers[2], buffers[3]], u: u, s: s)
                buffers.swapAt(0, 1)
                tick &+= 1
            }
            if !initialized || steps > 0 {
                try clear([buffers[6]], command: command)
                try run("tankSplat", command: command, size: particles, buffers: [buffers[0], buffers[6]], u: u, s: s)
                try run("tankField", command: command, size: cube, textures: volumes, buffers: [buffers[6]], u: u, s: s)
            }
            try run("tankRender", command: command, size: pixels, textures: [images[0], volumes[0]], buffers: [buffers[7]], u: u, s: s)
        case .combustion:
            if !initialized {
                try run("fireInitialize", command: command, size: cube, textures: [volumes[0], volumes[2], volumes[5], volumes[6]], u: u, s: s)
            }
            accumulator += min(max(dt, 0), 1 / 15)
            let steps = min(4, Int((accumulator + 0.000001) * 60))
            accumulator = max(0, accumulator - Float(steps) / 60)
            for _ in 0..<steps {
                s.simulation.x = Float(tick) / 60; s.simulation.y = 1 / 60
                try run("fireAdvect", command: command, size: cube, textures: [volumes[0], volumes[2], volumes[1], volumes[3]], u: u, s: s)
                try run("fireCurl", command: command, size: cube, textures: [volumes[1], volumes[7]], u: u, s: s)
                try run("fireForce", command: command, size: cube, textures: [volumes[1], volumes[3], volumes[7], volumes[0]], u: u, s: s)
                try run("fireDivergence", command: command, size: cube, textures: [volumes[0], volumes[4], volumes[5]], u: u, s: s)
                for iteration in 0..<(quality >= 2 ? 18 : 12) {
                    let a = iteration % 2 == 0 ? 5 : 6, b = iteration % 2 == 0 ? 6 : 5
                    try run("firePressure", command: command, size: cube, textures: [volumes[a], volumes[4], volumes[b]], u: u, s: s)
                }
                try run("fireProject", command: command, size: cube, textures: [volumes[0], volumes[5], volumes[1]], u: u, s: s)
                volumes.swapAt(0, 1); volumes.swapAt(2, 3)
                tick &+= 1
            }
            try run("fireRender", command: command, size: pixels, textures: [images[0], volumes[2]], u: u, s: s)
        case .stormPlanet:
            try run("planetRender", command: command, size: pixels, textures: [images[0]], u: u, s: s)
        case .fractal:
            try run("fractalRender", command: command, size: pixels, textures: [images[0]], u: u, s: s)
        case .holographic, .reef:
            try immersive.encode(command: command, image: images[0], u: u, stage: s, settings: settings, dt: dt)
        case .river:
            try river.encode(command: command, image: images[0], u: u, stage: s, settings: settings, dt: dt)
        case .koi, .portal:
            try atelier.encode(command: command, image: images[0], u: u, stage: s, settings: settings, input: input, dt: dt)
        case .batman:
            try batman.encode(command: command, image: output, u: u, stage: s, settings: settings, input: input, dt: dt)
        case .blockGlass:
            try glassEffect.encode(command: command, image: output, u: u, settings: settings, input: input, dt: dt)
        case .paperFolders:
            try paper.encode(command: command, output: output, settings: settings, input: input, dt: dt)
        case .turbine:
            try wind.encode(command: command, output: output, u: u, settings: settings, input: input, dt: dt)
        case .resonantGarden:
            try pool.encode(command: command, image: output, u: u, settings: settings, input: input, dt: dt)
        case .paperCity, .glassBlocks:
            try urban.encode(command: command, image: output, u: u, settings: settings, input: input, dt: dt)
        case .cove:
            try cove.encode(command: command, image: images[0], u: u, stage: s, settings: settings, input: input, dt: dt)
        default: break
        }
        initialized = true
        if !settings.scene.rendersDirectly {
            try run("stageResolve", command: command, size: pixels, textures: [images[0], images[1], images[2], output], u: u, s: s)
            images.swapAt(1, 2)
        }
        renderedSamples += 1
        samples = progressive ? min(samples + 1, targetSamples) : 0
    }

    func gridOccupancy(queue: MTLCommandQueue) throws -> Int {
        guard scene == .fluidTank, buffers.count > 2 else { return 0 }
        let source = buffers[2]
        guard let result = device.makeBuffer(length: source.length, options: .storageModeShared),
              let c = queue.makeCommandBuffer(), let b = c.makeBlitCommandEncoder() else { throw MoltenError.failed("Grid inspection failed.") }
        b.copy(from: source, sourceOffset: 0, to: result, destinationOffset: 0, size: source.length)
        b.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        return Int(UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: UInt32.self), count: source.length / 4).max() ?? 0)
    }

    // Explicit headless inspection; never called by the interactive render loop.
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let scene else { return [] }
        if scene == .reef { return try immersive.snapshot(queue: queue) }
        if scene == .river { return try river.snapshot(queue: queue) }
        if scene == .koi || scene == .portal { return try atelier.snapshot(queue: queue) }
        if scene == .cove { return try cove.snapshot(queue: queue) }
        if scene == .batman { return try batman.snapshot(queue: queue) }
        if scene == .blockGlass { return try glassEffect.snapshot(queue: queue) }
        if scene == .resonantGarden { return try pool.snapshot(queue: queue) }
        if scene == .paperFolders { return paper.motion.snapshot }
        if scene == .turbine { return try wind.snapshot(queue: queue) }
        if scene == .paperCity || scene == .glassBlocks { return try urban.snapshot(queue: queue) }
        if scene == .fluidTank, let source = buffers.first {
            guard let result = device.makeBuffer(length: source.length, options: .storageModeShared),
                  let c = queue.makeCommandBuffer(), let b = c.makeBlitCommandEncoder() else { throw MoltenError.failed("Snapshot allocation failed.") }
            b.copy(from: source, sourceOffset: 0, to: result, destinationOffset: 0, size: source.length)
            b.endEncoding(); c.commit(); c.waitUntilCompleted()
            if let error = c.error { throw error }
            return Array(UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: Float.self), count: source.length / 4))
        }
        guard scene == .combustion else { return [] }
        let t = volumes[2], row = t.width * 8, plane = t.width * t.height * 8
        guard let result = device.makeBuffer(length: plane * t.depth, options: .storageModeShared),
              let c = queue.makeCommandBuffer(), let b = c.makeBlitCommandEncoder() else { throw MoltenError.failed("Snapshot allocation failed.") }
        b.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
               sourceSize: MTLSize(width: t.width, height: t.height, depth: t.depth), to: result,
               destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: plane)
        b.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        return UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: Float16.self), count: plane * t.depth / 2).map(Float.init)
    }
}
