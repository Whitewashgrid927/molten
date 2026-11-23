import Foundation
import Metal

enum SelfTest {
    static func run() throws {
        let outputIndex = CommandLine.arguments.firstIndex(of: "--output")
        let directory: URL
        if let index = outputIndex, CommandLine.arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Molten-verification", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date()
        let engine = try MetalEngine()
        print("Device: \(engine.device.name); ray tracing: \(engine.device.supportsRaytracing)")
        guard MemoryLayout<Uniforms>.stride == 96 else { throw MoltenError.failed("Shader uniform ABI mismatch.") }
        var results: [[String: Any]] = []
        func render(_ settings: Settings, time: Float, frame: UInt32, input: PointerState = PointerState(),
                    width: Int = 640, height: Int = 440) throws -> (PixelImage, Double) {
            return try autoreleasepool {
                guard let command = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No command buffer.") }
                let texture = try engine.encode(command: command, width: width, height: height, time: time,
                                                dt: settings.paused ? 0 : 1.0 / 60, frame: frame, settings: settings, input: input)
                command.commit()
                command.waitUntilCompleted()
                guard command.status == .completed, command.error == nil else {
                    throw MoltenError.failed("GPU failed: \(command.error?.localizedDescription ?? "unknown error")")
                }
                return (try engine.readback(texture), (command.gpuEndTime - command.gpuStartTime) * 1000)
            }
        }
        func fingerprint(_ image: PixelImage) -> UInt64 {
            image.bytes.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        func validate(_ image: PixelImage) throws {
            var minValue = 255, maxValue = 0, bright = 0
            image.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for index in stride(from: 0, to: bytes.count, by: 4) {
                    let value = max(Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
                    minValue = min(minValue, value); maxValue = max(maxValue, value)
                    if value > 45 { bright += 1 }
                }
            }
            guard maxValue - minValue > 40, bright > image.width * image.height / 100 else {
                throw MoltenError.failed("The shader produced a blank or nearly uniform image.")
            }
        }
        // Native glass is composited by SwiftUI, outside this Metal readback.
        // NativeGlassTest covers its controls, lifecycle and backdrop separately.
        let selected = Scene.allCases.filter { $0 != .nativeGlass && (!CommandLine.arguments.contains("--cinematic-scenes") || $0.isCinematic) }
        for scene in selected {
            var settings = Settings()
            settings.scene = scene
            var fingerprints: Set<UInt64> = []
            for preset in 0..<3 {
                settings.preset = preset
                engine.reset()
                var last: PixelImage?
                var gpu: [Double] = []
                let frameCount = scene == .patterns || scene == .crystals ? 180 : scene.hasSimulation ? 100 : 18
                for frame in 0..<frameCount {
                    let (image, duration) = try render(settings, time: Float(frame) / 60, frame: UInt32(frame))
                    last = image
                    if frame > 3 { gpu.append(duration) }
                }
                guard let image = last else { throw MoltenError.failed("No image.") }
                try validate(image)
                fingerprints.insert(fingerprint(image))
                try image.save(to: directory.appendingPathComponent("\(scene.key)-\(preset).png"))
                results.append(["scene": scene.title, "preset": settings.scene.presets[preset],
                                "gpu_ms": gpu.reduce(0, +) / Double(gpu.count), "width": image.width, "height": image.height])
                print("PASS \(scene.title) / \(scene.presets[preset])")
            }
            guard fingerprints.count == 3 else { throw MoltenError.failed("\(scene.title) presets did not change the image.") }
            // Same initial state and time: the pointer alone must affect output.
            settings.preset = 0
            engine.reset()
            let baseline = try render(settings, time: 2, frame: 0).0
            engine.reset()
            var input = PointerState()
            input.inside = true; input.down = true
            input.position = SIMD2(0.67, 0.48); input.delta = SIMD2(0.09, 0.02)
            if scene == .spectral {
                var grab = input; grab.position = SIMD2(0.5, 0.5)
                _ = try render(settings, time: 2, frame: 0, input: grab)
            }
            if scene == .holographic { input.camera.x = 0.35; input.camera.y = 0.15 }
            if scene == .river { input.position = SIMD2(0.45, 0.62) }
            if scene == .resonantGarden {
                input.position = PoolProjection.project(engine.cinematic.pool.motion.stone, aspect: 640.0 / 440)
            }
            let touched = try render(settings, time: 2, frame: 0, input: input).0
            guard fingerprint(baseline) != fingerprint(touched) else { throw MoltenError.failed("\(scene.title) pointer input had no effect.") }
            if scene.isStatic { input.position.x += 0.1; if scene == .holographic { input.camera.x += 0.15 } }
            let advanced = try render(settings, time: 4, frame: 2, input: input).0
            guard fingerprint(advanced) != fingerprint(touched) else { throw MoltenError.failed("\(scene.title) did not animate.") }
            for quality in 0..<4 {
                settings.quality = quality
                let image = try render(settings, time: 3, frame: 1, width: 333, height: 217).0
                try validate(image)
            }
            if scene == .particles || (scene.rawValue >= Scene.ferrofluid.rawValue && !scene.isStatic) {
                // Every frame must clear its accumulation. Paused redraws should
                // neither brighten the image nor depend on atomic execution order.
                settings.paused = true
                settings.quality = 2
                engine.reset()
                let first = try render(settings, time: 2, frame: 0, width: 701, height: 509).0
                for index in 1...4 {
                    let repeated = try render(settings, time: 2, frame: UInt32(index), width: 701, height: 509).0
                    guard fingerprint(first) == fingerprint(repeated) else {
                        throw MoltenError.failed("\(scene.title) evolved during a paused redraw.")
                    }
                }
                print("PASS \(scene.title) deterministic paused redraws")
            }
            settings.paused = false
            // Verify every visible tuning control changes actual shader output.
            for (index, definition) in scene.controls.enumerated() {
                if scene == .resonantGarden && index == 0 {
                    // Resonance is an audio control; verify the audible decay.
                    func tailEnergy(_ resonance: Float) -> Float {
                        let sampler = PoolSampler()
                        sampler.set(flow: 0, pan: 0, resonance: resonance)
                        sampler.enqueue(.init(strength: 0.8, pan: 0, frequency: 196, splash: 0))
                        var l = [Float](repeating: 0, count: 48_000), r = l
                        sampler.render(frames: l.count, left: &l, right: &r)
                        sampler.render(frames: l.count, left: &l, right: &r)
                        return l.reduce(0) { $0 + $1*$1 }
                    }
                    guard tailEnergy(1) > tailEnergy(0) * 3 else { throw MoltenError.failed("Pool resonance did not change audible decay.") }
                    continue
                }
                settings.sceneParameters = scene.defaultParameters
                engine.reset()
                func controlImage(_ value: Settings) throws -> PixelImage {
                    var viewpoint = PointerState()
                    // Illustration depth is visible when the view shifts.
                    if scene == .batman && index == 1 { viewpoint.camera.x = 0.3 }
                    var image = try render(value, time: 2, frame: 0, input: viewpoint).0
                    if scene.isCinematic && scene.hasSimulation {
                        // Force controls influence transported material on later
                        // physics steps; a one-frame assertion would miss this.
                        for frame in 1..<24 { image = try render(value, time: 2 + Float(frame) / 60, frame: UInt32(frame), input: viewpoint).0 }
                    }
                    return image
                }
                let initial = try controlImage(settings)
                settings.sceneParameters[index] = definition.range.upperBound
                engine.reset()
                let adjusted = try controlImage(settings)
                guard fingerprint(initial) != fingerprint(adjusted) else {
                    throw MoltenError.failed("\(scene.title) / \(definition.title) control had no effect.")
                }
            }
            print("PASS \(scene.title) interaction, animation, resize, all detail levels")
        }
        // Rapid scene changes exercise resource teardown and acceleration rebuilds.
        for index in 0..<(Scene.allCases.count * 3) {
            var settings = Settings()
            settings.scene = Scene.allCases[index % Scene.allCases.count]
            _ = try render(settings, time: Float(index) * 0.1, frame: 0, width: 320, height: 240)
        }
        let report: [String: Any] = [
            "device": engine.device.name, "hardware_ray_tracing": engine.device.supportsRaytracing,
            "uniform_stride": MemoryLayout<Uniforms>.stride, "results": results,
            "elapsed_seconds": Date().timeIntervalSince(start),
            "gpu_allocated_mb_at_end": Double(engine.device.currentAllocatedSize) / 1048576,
            "all_passed": true
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("self-test.json"), options: .atomic)
        print("PASS rapid scene changes. All GPU checks passed. \(directory.path)")
    }
}
