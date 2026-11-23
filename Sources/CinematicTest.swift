import Foundation
import Metal

// Offscreen integration tests exercise the real renderer and solver state.
// They never create an NSApplication, window, display link, or polling timer.
enum CinematicTest {
    static func run() throws {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        let directory = URL(fileURLWithPath: argument("--output") ?? "/tmp/molten-cinematic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try MetalEngine()
        let scenes = Scene.allCases.filter { $0.isCinematic && (argument("--scene") == nil || $0.key == argument("--scene")) }
        var results: [[String: Any]] = []
        func draw(_ settings: Settings, time: Float, dt: Float, frame: Int, input: PointerState = PointerState(),
                  width: Int = 900, height: Int = 600) throws -> Double {
            try autoreleasepool {
                guard let c = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No test command buffer.") }
                _ = try engine.encode(command: c, width: width, height: height, time: time, dt: dt,
                                      frame: UInt32(frame), settings: settings, input: input)
                c.commit(); c.waitUntilCompleted()
                if let error = c.error { throw error }
                guard c.status == .completed else { throw MoltenError.failed("Incomplete cinematic frame.") }
                return (c.gpuEndTime - c.gpuStartTime) * 1000
            }
        }
        func pixels() throws -> PixelImage {
            guard let output = engine.output else { throw MoltenError.failed("No cinematic output.") }
            return try engine.readback(output)
        }
        func save(_ name: String) throws { try pixels().save(to: directory.appendingPathComponent(name + ".png")) }
        func validate(_ image: PixelImage) throws {
            let bytes = [UInt8](image.bytes)
            var visible = 0, low = 255, high = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let light = max(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
                low = min(low, light); high = max(high, light)
                if light > 35 { visible += 1 }
                guard bytes[i + 3] == 255 else { throw MoltenError.failed("Invalid alpha in cinematic output.") }
            }
            guard high - low > 40, visible > image.width * image.height / 80 else { throw MoltenError.failed("Empty cinematic image.") }
        }
        for scene in scenes {
            var settings = Settings(); settings.scene = scene; settings.quality = 2
            for preset in 0..<3 {
                settings.preset = preset; engine.reset()
                var times: [Double] = []
                let frames = scene.hasSimulation ? 90 : 1
                for frame in 0..<frames {
                    times.append(try draw(settings, time: Float(frame) / 60, dt: 1 / 60, frame: frame))
                }
                try validate(pixels()); try save("\(scene.key)-\(preset)")
                times.sort()
                results.append(["scene": scene.title, "preset": scene.presets[preset], "gpu_median_ms": times[times.count / 2],
                                "active_scene_mb": Double(engine.cinematic.resourceBytes) / 1048576])
                print("PASS \(scene.title) / \(scene.presets[preset]): \(String(format: "%.2f", times[times.count / 2])) ms GPU")
            }
        }
        if !args.contains("--preview-only") {
            for scene in scenes {
                var settings = Settings(); settings.scene = scene; settings.quality = 3; settings.paused = true
                engine.reset()
                var input = PointerState()
                var early: [UInt8] = [], middle: [UInt8] = []
                let sampleLimit = scene.rendersDirectly ? 1 : CinematicEngine.sampleLimit
                for frame in 0..<sampleLimit {
                    _ = try draw(settings, time: 1, dt: 0, frame: frame, width: 417, height: 283)
                    if frame == 7 { early = [UInt8](try pixels().bytes) }
                    if frame == 31 { middle = [UInt8](try pixels().bytes) }
                }
                guard engine.cinematic.converged, engine.cinematic.samples == sampleLimit else { throw MoltenError.failed("Cinematic convergence never stopped.") }
                let countBefore = engine.cinematic.renderedSamples
                _ = try draw(settings, time: 1, dt: 0, frame: 128, width: 417, height: 283)
                guard engine.cinematic.renderedSamples == countBefore else { throw MoltenError.failed("A converged still image kept rendering.") }
                let final = [UInt8](try pixels().bytes)
                func error(_ image: [UInt8]) -> Double {
                    zip(image, final).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(final.count)
                }
                if scene == .spectral {
                    guard error(middle) < error(early) else { throw MoltenError.failed("Spectral accumulation did not converge.") }
                }
                try save("\(scene.key)-cinematic-\(sampleLimit)")
                let frozen = try engine.cinematic.snapshot(queue: engine.queue)
                input.camera.x = 0.3
                if scene == .resonantGarden { input.camera.z = 0.2 }
                _ = try draw(settings, time: 1, dt: 0, frame: 129, input: input, width: 417, height: 283)
                guard engine.cinematic.samples == 1 else { throw MoltenError.failed("Camera change retained stale history.") }
                guard [UInt8](try pixels().bytes) != final else { throw MoltenError.failed("The camera did not change the image.") }
                if scene == .stormPlanet {
                    input.camera.z = -6
                    _ = try draw(settings, time: 1, dt: 0, frame: 129, input: input, width: 900, height: 600)
                    try save("storm-planet-atmosphere"); try validate(pixels())
                } else if scene == .fractal {
                    input.eye = SIMD3(0, 0, 2.5)
                    _ = try draw(settings, time: 1, dt: 0, frame: 129, input: input, width: 900, height: 600)
                    try validate(pixels()); try save("fractal-flight")
                }
                _ = try draw(settings, time: 1, dt: 0, frame: 130, input: input, width: 419, height: 287)
                guard engine.cinematic.samples == 1 else { throw MoltenError.failed("Resize retained stale history.") }
                settings.intensity = 1.7
                _ = try draw(settings, time: 1, dt: 0, frame: 131, input: input, width: 419, height: 287)
                guard engine.cinematic.samples == 1 else { throw MoltenError.failed("Controls retained stale history.") }
                guard try engine.cinematic.snapshot(queue: engine.queue) == frozen else { throw MoltenError.failed("Paused 3D state evolved.") }
                print("PASS \(scene.title): \(sampleLimit) samples, camera/control/resize invalidation, frozen simulation")
                if scene.hasSimulation {
                    settings.quality = 1; settings.paused = false
                    settings.sceneParameters = scene.defaultParameters; settings.intensity = 2
                    for (index, control) in scene.controls.enumerated() { settings.sceneParameters[index] = control.range.upperBound }
                    engine.reset()
                    _ = try draw(settings, time: 0, dt: 0, frame: 0, width: 97, height: 65)
                    let initial = try engine.cinematic.snapshot(queue: engine.queue)
                    var peakOccupancy = 0
                    var poolWasDisturbed = false
                    for frame in 0..<900 {
                        var interaction = PointerState()
                        if frame < 360 {
                            interaction.down = true; interaction.inside = true
                            interaction.position = SIMD2(0.5 + 0.2 * sin(Float(frame) * 0.07), 0.5 + 0.1 * cos(Float(frame) * 0.05))
                            interaction.modifiers = frame < 180 ? 0 : 1
                        }
                        _ = try draw(settings, time: Float(frame) / 30, dt: 1 / 30, frame: frame, input: interaction, width: 97, height: 65)
                        if scene == .resonantGarden && frame == 180 {
                            poolWasDisturbed = try engine.cinematic.snapshot(queue: engine.queue) != initial
                        }
                        if scene == .fluidTank && frame % 30 == 0 {
                            peakOccupancy = max(peakOccupancy, try engine.cinematic.gridOccupancy(queue: engine.queue))
                        }
                    }
                    guard peakOccupancy <= CinematicEngine.cellCapacity else { throw MoltenError.failed("Liquid neighbor grid overflow: \(peakOccupancy)") }
                    let state = try engine.cinematic.snapshot(queue: engine.queue)
                    let evolved = scene == .resonantGarden ? poolWasDisturbed && engine.cinematic.pool.motion.isAtRest : state != initial
                    guard evolved, state.allSatisfy({ $0.isFinite && abs($0) < 20 }) else {
                        throw MoltenError.failed("\(scene.title) diverged or stopped evolving.")
                    }
                    if scene == .fluidTank {
                        var active = 0
                        for i in stride(from: 0, to: state.count, by: 16) where state[i + 3] > 0.5 {
                            active += 1
                            guard abs(state[i]) <= 0.976, state[i + 1] >= 0.024, state[i + 1] <= 1.976,
                                  abs(state[i + 2]) <= 0.976 else { throw MoltenError.failed("Liquid particle escaped the tank.") }
                        }
                        guard active > 10368 else { throw MoltenError.failed("Pouring did not add liquid particles.") }
                    } else if scene == .combustion {
                        let hot = stride(from: 0, to: state.count, by: 4).filter { state[$0 + 1] > 0.1 }.count
                        guard hot > 100 else { throw MoltenError.failed("Combustion extinguished unexpectedly.") }
                    }
                    settings.paused = true
                    for frame in 0..<3 { _ = try draw(settings, time: 30, dt: 0, frame: frame, width: 900, height: 600) }
                    guard try engine.cinematic.snapshot(queue: engine.queue) == state else { throw MoltenError.failed("Stress state changed during pause.") }
                    try save("\(scene.key)-30-seconds")
                    results.append(["scene": scene.title, "simulated_seconds": 30, "finite_state": true, "pause_preserves_state": true, "maximum_controls": true, "peak_grid_occupancy": peakOccupancy])
                    print("PASS \(scene.title): 30 seconds with sustained interaction and maximum controls; finite bounded state")
                }
            }
            var settings = Settings(); settings.scene = .liquid
            _ = try draw(settings, time: 0, dt: 0, frame: 0, width: 127, height: 83)
            guard engine.cinematic.resourceBytes == 0 else { throw MoltenError.failed("Inactive cinematic resources were retained.") }
            print("PASS cinematic resources released on scene switch")
        }
        let report: [String: Any] = ["all_passed": true, "preview_only": args.contains("--preview-only"),
                                     "results": results, "device": engine.device.name]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("cinematic-test.json"), options: .atomic)
    }
}
