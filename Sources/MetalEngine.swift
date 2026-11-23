import AppKit
import Metal
import MetalKit
import simd

enum MoltenError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

struct PointerState {
    var position = SIMD2<Float>(0.5, 0.5)
    var delta = SIMD2<Float>(0, 0)
    var down = false
    var inside = false
    var camera = SIMD4<Float>(repeating: 0)
    var eye = SIMD3<Float>(repeating: 0)
    var navigation = SIMD3<Float>(repeating: 0)
    var orbiting = false
    var modifiers: UInt32 = 0
    var actionPosition = SIMD2<Float>(0.5, 0.5)
    var actionSerial: UInt32 = 0
    var freeCamera = false
    var cancelSerial: UInt32 = 0
    var poolEvents: [PoolPointerEvent] = []
}

enum ParticleWork { case all, simulation, raster }

private struct NativeBackdropFrame: Equatable {
    let width: Int, height: Int, preset: Int
    let drift: Float, time: Float
}

// Six 16-byte vectors, identically laid out in Swift and Metal.
struct Uniforms {
    var viewport: SIMD4<Float>
    var pointer: SIMD4<Float>
    var parameters: SIMD4<Float>
    var options: SIMD4<UInt32>
    var interaction: SIMD4<Float>
    var controls: SIMD4<Float>
    init(width: Int, height: Int, time: Float, dt: Float, frame: UInt32,
         settings: Settings, input: PointerState) {
        viewport = SIMD4(Float(width), Float(height), time, dt)
        pointer = SIMD4(input.position.x, input.position.y, input.down ? 1 : 0, input.inside ? 1 : 0)
        parameters = SIMD4(settings.intensity, settings.speed, 1.15, Float(settings.preset))
        options = SIMD4(UInt32(settings.scene.rawValue), frame, UInt32(settings.particleCount), UInt32(settings.quality))
        interaction = SIMD4(input.delta.x, input.delta.y, 0, 0)
        controls = settings.sceneParameters
    }
}

struct PixelImage {
    let width: Int
    let height: Int
    let bytes: Data
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    func save(to url: URL) throws {
        guard let image = cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw MoltenError.failed("Could not encode the image.")
        }
        try png.write(to: url, options: .atomic)
    }
}

final class MetalEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let presentPipeline: MTLRenderPipelineState
    private var compute: [String: MTLComputePipelineState] = [:]
    private(set) var output: MTLTexture?
    private var currentScene: Scene?
    private var fluid: [MTLTexture] = []
    private var fluidWidth = 0, fluidHeight = 0
    private var fluidInitialized = false
    private var particleBuffer: MTLBuffer?
    private var particleAccumulation: MTLBuffer?
    private var particleCapacity = 0
    private var particlesInitialized = false
    private var accelerationStructure: MTLAccelerationStructure?
    private var simulation: [MTLTexture] = []
    private var simulationInitialized = false
    private var simulationTime: Float = 0
    private var magnetPosition: SIMD2<Float>?
    private(set) var nativeGlassBackdrop: MTLTexture?
    private var nativeGlassPreset: Int?
    private var nativeBackdropFrame: NativeBackdropFrame?
    private(set) var cinematic: CinematicEngine!

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw MoltenError.failed("Molten needs a Mac with Metal support.")
        }
        self.device = device
        self.queue = queue
        guard let path = Bundle.main.url(forResource: "Shaders", withExtension: "metal") else {
            throw MoltenError.failed("The shader resource is missing. Rebuild or reinstall Molten.")
        }
        guard let scenesPath = Bundle.main.url(forResource: "Scenes", withExtension: "metal") else {
            throw MoltenError.failed("The scene shader resource is missing.")
        }
        guard let cinematicPath = Bundle.main.url(forResource: "Cinematic", withExtension: "metal") else {
            throw MoltenError.failed("The cinematic shader resource is missing.")
        }
        guard let immersivePath = Bundle.main.url(forResource: "Immersive", withExtension: "metal") else {
            throw MoltenError.failed("The immersive shader resource is missing.")
        }
        guard let riverPath = Bundle.main.url(forResource: "River", withExtension: "metal") else {
            throw MoltenError.failed("The river shader resource is missing.")
        }
        guard let riverWorldPath = Bundle.main.url(forResource: "RiverWorld", withExtension: "metal") else { throw MoltenError.failed("Missing detailed river shader.") }
        guard let atelierPath = Bundle.main.url(forResource: "Atelier", withExtension: "metal") else { throw MoltenError.failed("Missing atelier shaders.") }
        guard let batmanPath = Bundle.main.url(forResource: "Batman", withExtension: "metal") else { throw MoltenError.failed("Missing Batman shaders.") }
        guard let urbanPath = Bundle.main.url(forResource: "Urban", withExtension: "metal") else { throw MoltenError.failed("Missing urban shaders.") }
        guard let covePath = Bundle.main.url(forResource: "Cove", withExtension: "metal") else { throw MoltenError.failed("Missing cove shaders.") }
        guard let glassEffectPath = Bundle.main.url(forResource: "GlassEffect", withExtension: "metal") else { throw MoltenError.failed("Missing glass effect shaders.") }
        guard let poolPath = Bundle.main.url(forResource: "Pool", withExtension: "metal") else { throw MoltenError.failed("Missing pool shaders.") }
        guard let paperPath = Bundle.main.url(forResource: "Paper", withExtension: "metal") else { throw MoltenError.failed("Missing paper shaders.") }
        guard let windPath = Bundle.main.url(forResource: "Wind", withExtension: "metal") else { throw MoltenError.failed("Missing turbine shaders.") }
        guard let nativeGlassPath = Bundle.main.url(forResource: "NativeGlass", withExtension: "metal") else { throw MoltenError.failed("Missing native glass backdrop.") }
        let source = try String(contentsOf: path, encoding: .utf8) + "\n" + String(contentsOf: scenesPath, encoding: .utf8)
            + "\n" + String(contentsOf: cinematicPath, encoding: .utf8)
            + "\n" + String(contentsOf: immersivePath, encoding: .utf8)
            + "\n" + String(contentsOf: riverPath, encoding: .utf8)
            + "\n" + String(contentsOf: riverWorldPath, encoding: .utf8)
            + "\n" + String(contentsOf: atelierPath, encoding: .utf8)
            + "\n" + String(contentsOf: covePath, encoding: .utf8)
            + "\n" + String(contentsOf: batmanPath, encoding: .utf8)
            + "\n" + String(contentsOf: urbanPath, encoding: .utf8)
            + "\n" + String(contentsOf: glassEffectPath, encoding: .utf8)
            + "\n" + String(contentsOf: poolPath, encoding: .utf8)
            + "\n" + String(contentsOf: windPath, encoding: .utf8)
            + "\n" + String(contentsOf: paperPath, encoding: .utf8)
            + "\n" + String(contentsOf: nativeGlassPath, encoding: .utf8)
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let library = try device.makeLibrary(source: source, options: options)
        cinematic = try CinematicEngine(device: device, library: library)
        func renderPipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        presentPipeline = try renderPipeline("presentFragment")
        for name in ["liquid", "velocityAdvect", "fluidCurl", "fluidVorticity", "fluidDivergence", "fluidPressure", "fluidProject",
                     "dyeAdvect", "inkRender", "clearTexture", "particleInitialize", "particleUpdate",
                     "particleSplat", "particleResolve", "glass", "ferrofluid", "blackHole", "aurora", "membranes",
                     "oceanInitialize", "oceanStep", "oceanRender",
                     "terrainInitialize", "terrainFlux", "terrainStep", "terrainRender",
                     "crystalInitialize", "crystalStep", "crystalRender",
                     "patternInitialize", "patternStep", "patternRender", "nativeGlassBackdrop"] {
            guard let function = library.makeFunction(name: name) else {
                throw MoltenError.failed("Missing shader: \(name)")
            }
            compute[name] = try device.makeComputePipelineState(function: function)
        }
    }

    func reset() {
        fluidInitialized = false
        particlesInitialized = false
        simulationInitialized = false
        simulationTime = 0
        magnetPosition = nil
        nativeBackdropFrame = nil
        cinematic?.reset()
    }

    private func texture(_ width: Int, _ height: Int, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MoltenError.failed("The GPU could not allocate a \(width) × \(height) texture.")
        }
        return texture
    }

    private func dispatch(_ name: String, command: MTLCommandBuffer, width: Int, height: Int,
                          textures: [MTLTexture] = [], uniforms: Uniforms? = nil) throws {
        guard let pipeline = compute[name], let encoder = command.makeComputeCommandEncoder() else {
            throw MoltenError.failed("Could not start \(name).")
        }
        encoder.label = name
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if var uniforms {
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private func prepare(scene: Scene, width: Int, height: Int, settings: Settings) throws {
        if output?.width != width || output?.height != height {
            output = try texture(width, height, format: .bgra8Unorm)
            output?.label = "Scene color"
            nativeBackdropFrame = nil
        }
        if currentScene != scene {
            // Keep only the active simulation's resources. Command buffers retain
            // resources until outstanding GPU work has finished.
            fluid.removeAll()
            particleBuffer = nil
            particleAccumulation = nil
            accelerationStructure = nil
            simulation.removeAll()
            nativeGlassBackdrop = nil
            nativeGlassPreset = nil
            cinematic.releaseResources()
            particleCapacity = 0
            fluidWidth = 0
            fluidHeight = 0
            currentScene = scene
            reset()
        }
        if scene == .nativeGlass {
            let selected = min(2, max(0, settings.preset))
            if nativeGlassPreset != selected || nativeGlassBackdrop == nil {
                let name = ["MistyLake", "RollingHills", "QuietCoast"][selected]
                guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "NativeGlassLandscapes") else {
                    throw MoltenError.failed("The landscape background is missing. Reinstall Molten.")
                }
                // Keep display-encoded colors: this path presents directly into
                // bgra8Unorm. Only the selected photograph is retained.
                let landscape = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
                    .SRGB: false, .generateMipmaps: false, .origin: MTKTextureLoader.Origin.topLeft,
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
                ])
                landscape.label = "Liquid Glass / \(settings.scene.presets[selected])"
                nativeGlassBackdrop = landscape
                nativeGlassPreset = selected
                nativeBackdropFrame = nil
            }
        } else if scene == .ink {
            let longest = [256, 512, 768, 768][settings.quality]
            let scale = Float(longest) / Float(max(width, height))
            let w = max(32, Int(Float(width) * scale)), h = max(32, Int(Float(height) * scale))
            if fluidWidth != w || fluidHeight != h {
                fluid = try (0..<8).map { try texture(w, h, format: (2...4).contains($0) || $0 == 7 ? .r16Float : .rgba16Float) }
                fluidWidth = w
                fluidHeight = h
                fluidInitialized = false
            }
        } else if scene == .particles {
            if particleCapacity != settings.particleCount {
                particleBuffer = device.makeBuffer(length: settings.particleCount * 32, options: .storageModePrivate)
                guard particleBuffer != nil else { throw MoltenError.failed("Could not allocate particles.") }
                particleCapacity = settings.particleCount
                particlesInitialized = false
            }
            let accumulationSize = width * height * 3 * MemoryLayout<UInt32>.stride
            if particleAccumulation?.length != accumulationSize {
                particleAccumulation = device.makeBuffer(length: accumulationSize, options: .storageModePrivate)
                guard particleAccumulation != nil else { throw MoltenError.failed("Could not allocate particle color storage.") }
                particleAccumulation?.label = "Particle RGB accumulation"
            }
        } else if scene == .glass, accelerationStructure == nil {
            try buildGlassGeometry()
        } else if [.ocean, .terrain, .crystals, .patterns].contains(scene) {
            // Simulation resolution is independent of Retina display resolution.
            // A fixed grid keeps physical scale and growth rates stable on resize.
            let side = scene == .terrain ? 256 : 384
            if simulation.first?.width != side {
                simulation = try (0..<(scene == .terrain ? 3 : 2)).map { _ in
                    try texture(side, side, format: .rgba32Float)
                }
                simulationInitialized = false
                simulationTime = 0
            }
        }
    }

    func encode(command: MTLCommandBuffer, width: Int, height: Int, time: Float, dt: Float,
                frame: UInt32, settings: Settings, input: PointerState,
                particleWork: ParticleWork = .all) throws -> MTLTexture {
        try prepare(scene: settings.scene, width: width, height: height, settings: settings)
        guard let output else { throw MoltenError.failed("No output texture.") }
        var u = Uniforms(width: width, height: height, time: time, dt: dt, frame: frame, settings: settings, input: input)
        switch settings.scene {
        case .nativeGlass:
            guard let landscape = nativeGlassBackdrop else { throw MoltenError.failed("No landscape background.") }
            let drift = settings.reduceNativeMotion ? Float(0) : max(0, settings.sceneParameters.z)
            let next = NativeBackdropFrame(width: width, height: height, preset: settings.preset,
                drift: drift, time: drift > 0 ? time : 0)
            if nativeBackdropFrame != next {
                u.controls.z = drift
                try dispatch("nativeGlassBackdrop", command: command, width: width, height: height, textures: [output, landscape], uniforms: u)
                // The queue is serial; subsequent presentation/physics frames
                // can reuse a still backdrop without another image pass.
                nativeBackdropFrame = next
            }
        case .liquid:
            try dispatch("liquid", command: command, width: width, height: height, textures: [output], uniforms: u)
        case .ink:
            if !fluidInitialized {
                for texture in fluid {
                    try dispatch("clearTexture", command: command, width: fluidWidth, height: fluidHeight, textures: [texture])
                }
                u.options.y = 0
                fluidInitialized = true
            }
            try dispatch("velocityAdvect", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[0], fluid[1]], uniforms: u)
            try dispatch("fluidCurl", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[1], fluid[7]])
            try dispatch("fluidVorticity", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[1], fluid[7], fluid[0]], uniforms: u)
            try dispatch("fluidDivergence", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[0], fluid[2]])
            // Jacobi iterations alternate pressure targets; an even count leaves
            // the solution in texture 3. Each pass has its own encoder boundary.
            for iteration in 0..<(settings.quality >= 2 ? 24 : 16) {
                let a = iteration % 2 == 0 ? 3 : 4, b = iteration % 2 == 0 ? 4 : 3
                try dispatch("fluidPressure", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[a], fluid[2], fluid[b]])
            }
            try dispatch("fluidProject", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[0], fluid[3], fluid[1]])
            try dispatch("dyeAdvect", command: command, width: fluidWidth, height: fluidHeight, textures: [fluid[5], fluid[1], fluid[6]], uniforms: u)
            try dispatch("inkRender", command: command, width: width, height: height, textures: [fluid[6], output], uniforms: u)
            fluid.swapAt(5, 6)
            fluid.swapAt(0, 1)
        case .particles:
            guard let buffer = particleBuffer else { throw MoltenError.failed("Particle storage is unavailable.") }
            var kernels = particlesInitialized ? [] : ["particleInitialize"]
            if particleWork != .raster { kernels.append("particleUpdate") }
            for name in kernels {
                guard let pipeline = compute[name], let encoder = command.makeComputeCommandEncoder() else {
                    throw MoltenError.failed("Could not start the particle simulation.")
                }
                encoder.label = name
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.dispatchThreads(MTLSize(width: settings.particleCount, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                encoder.endEncoding()
            }
            particlesInitialized = true
            if particleWork == .simulation { return output }
            guard let accumulation = particleAccumulation, let clear = command.makeBlitCommandEncoder() else {
                throw MoltenError.failed("Could not clear particle color storage.")
            }
            clear.fill(buffer: accumulation, range: 0..<accumulation.length, value: 0)
            clear.endEncoding()
            for name in ["particleSplat", "particleResolve"] {
                guard let pipeline = compute[name], let encoder = command.makeComputeCommandEncoder() else {
                    throw MoltenError.failed("Could not draw particles.")
                }
                encoder.label = name
                encoder.setComputePipelineState(pipeline)
                encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                if name == "particleSplat" {
                    encoder.setBuffer(buffer, offset: 0, index: 0)
                    encoder.setBuffer(accumulation, offset: 0, index: 2)
                    encoder.dispatchThreads(MTLSize(width: settings.particleCount, height: 1, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                } else {
                    encoder.setBuffer(accumulation, offset: 0, index: 0)
                    encoder.setTexture(output, index: 0)
                    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
                }
                encoder.endEncoding()
            }
        case .glass:
            guard let structure = accelerationStructure, let pipeline = compute["glass"],
                  let encoder = command.makeComputeCommandEncoder() else { throw MoltenError.failed("Ray tracing is unavailable.") }
            encoder.label = "Glass · hardware ray tracing"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(output, index: 0)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setAccelerationStructure(structure, bufferIndex: 1)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding()
        case .ferrofluid, .blackHole, .aurora, .membranes:
            if settings.scene == .ferrofluid {
                if input.inside {
                    let previous = magnetPosition ?? input.position
                    let blend: Float = dt == 0 ? 1 : 1 - exp(-dt / (0.03 + settings.sceneParameters.y * 0.1))
                    let position = previous + (input.position - previous) * blend
                    magnetPosition = position
                    u.pointer.x = position.x
                    u.pointer.y = position.y
                } else { magnetPosition = nil }
            }
            let name = settings.scene == .blackHole ? "blackHole" : settings.scene.key
            try dispatch(name, command: command, width: width, height: height, textures: [output], uniforms: u)
        case .ocean, .terrain, .crystals, .patterns:
            let prefix: String
            switch settings.scene {
            case .ocean: prefix = "ocean"
            case .terrain: prefix = "terrain"
            case .crystals: prefix = "crystal"
            default: prefix = "pattern"
            }
            let side = simulation[0].width
            if !simulationInitialized {
                try dispatch(prefix + "Initialize", command: command, width: side, height: side,
                             textures: [simulation[0]], uniforms: u)
                simulationInitialized = true
            }
            // Fixed simulation ticks give 30/60/120 fps the same evolution rate.
            // Bound catch-up work; paused redraws do not evolve simulation state.
            let rate: Float = settings.scene == .ocean ? 120 : settings.scene == .terrain ? 60 : 240
            simulationTime += min(max(dt, 0), 0.1)
            let ticks = min(24, Int((simulationTime + 0.000001) * rate))
            simulationTime = max(0, simulationTime - Float(ticks) / rate)
            for _ in 0..<ticks {
                var stepUniforms = u
                stepUniforms.viewport.w = 1 / rate
                // Pointer delta describes one displayed frame, not every
                // simulation substep. Preserve its total impulse at each cap.
                stepUniforms.interaction.x /= Float(max(ticks, 1))
                stepUniforms.interaction.y /= Float(max(ticks, 1))
                if settings.scene == .terrain {
                    try dispatch("terrainFlux", command: command, width: side, height: side,
                                 textures: [simulation[0], simulation[2]], uniforms: stepUniforms)
                    try dispatch("terrainStep", command: command, width: side, height: side,
                                 textures: [simulation[0], simulation[2], simulation[1]], uniforms: stepUniforms)
                } else {
                    try dispatch(prefix + "Step", command: command, width: side, height: side,
                                 textures: [simulation[0], simulation[1]], uniforms: stepUniforms)
                }
                simulation.swapAt(0, 1)
            }
            try dispatch(prefix + "Render", command: command, width: width, height: height,
                         textures: [simulation[0], output], uniforms: u)
        case .spectral, .fluidTank, .combustion, .stormPlanet, .fractal, .holographic, .reef, .river, .koi, .portal, .cove, .batman, .paperCity, .glassBlocks, .blockGlass, .resonantGarden, .turbine, .paperFolders:
            try cinematic.encode(command: command, output: output, uniforms: u, settings: settings, input: input, dt: dt)
        }
        return output
    }

    private func buildGlassGeometry() throws {
        guard device.supportsRaytracing else { throw MoltenError.failed("This Mac does not support Metal ray tracing.") }
        let centers: [SIMD3<Float>] = [SIMD3(-0.71, 0.05, 0), SIMD3(0.77, 0.37, -0.48), SIMD3(0.51, -0.65, 0.39)]
        let radii: [Float] = [0.86, 0.69, 0.47]
        var vertices: [SIMD4<Float>] = []
        vertices.reserveCapacity(3 * 3968 * 3)
        for sphere in 0..<3 {
            func point(_ latitude: Int, _ longitude: Int) -> SIMD4<Float> {
                let theta = Float(latitude) / 32 * .pi
                let phi = Float(longitude) / 64 * 2 * .pi
                let p = centers[sphere] + radii[sphere] * SIMD3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                return SIMD4(p.x, p.y, p.z, 1)
            }
            for latitude in 0..<32 {
                for longitude in 0..<64 {
                    let a = point(latitude, longitude), b = point(latitude + 1, longitude)
                    let c = point(latitude + 1, longitude + 1), d = point(latitude, longitude + 1)
                    if latitude != 0 { vertices += [a, b, d] }
                    if latitude != 31 { vertices += [d, b, c] }
                }
            }
        }
        guard vertices.count == 3 * 3968 * 3,
              let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
            throw MoltenError.failed("Could not create ray tracing geometry.")
        }
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = buffer
        geometry.vertexStride = MemoryLayout<SIMD4<Float>>.stride
        geometry.vertexFormat = .float3
        geometry.triangleCount = vertices.count / 3
        geometry.opaque = true
        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate),
              let command = queue.makeCommandBuffer(), let encoder = command.makeAccelerationStructureCommandEncoder() else {
            throw MoltenError.failed("Could not allocate the ray tracing structure.")
        }
        encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        accelerationStructure = structure
    }

    func readback(_ texture: MTLTexture) throws -> PixelImage {
        let rowBytes = ((texture.width * 4 + 255) / 256) * 256
        guard let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw MoltenError.failed("Could not read the rendered image.")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = Data(capacity: texture.width * texture.height * 4)
        for y in 0..<texture.height {
            bytes.append(buffer.contents().advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self), count: texture.width * 4)
        }
        return PixelImage(width: texture.width, height: texture.height, bytes: bytes)
    }

    // Used only by the headless stability suite; normal rendering never reads
    // simulation state back to the CPU.
    func simulationSnapshot() throws -> [SIMD4<Float>] {
        guard let texture = simulation.first else { return [] }
        let rowBytes = texture.width * MemoryLayout<SIMD4<Float>>.stride
        guard let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw MoltenError.failed("Could not inspect simulation state.")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self),
                                         count: texture.width * texture.height))
    }
}
