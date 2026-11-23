import Foundation
import Metal

enum Benchmark {
    static func run() throws {
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let outputURL = URL(fileURLWithPath: argument("--output") ?? "/tmp/molten-benchmark.json")
        let frames = max(12, min(Int(argument("--frames") ?? "") ?? 36, 300))
        let drag = arguments.contains("--drag")
        var input = PointerState()
        if drag { input.inside = true; input.down = true; input.position = SIMD2(0.5, 0.5) }
        let engine = try MetalEngine()
        let sizes: [(Int, Int)] = arguments.contains("--fullscreen") ? [(3024, 1898)] : [(1840, 1340)]
        let selectedScenes: [Scene] = argument("--scene").flatMap { name in
            Scene.allCases.first { $0.title.lowercased() == name.lowercased() || $0.key == name.lowercased() }.map { [$0] }
        } ?? Scene.allCases
        let scenes = arguments.contains("--cinematic-scenes") ? selectedScenes.filter { $0.isCinematic } : arguments.contains("--new-scenes") ? selectedScenes.filter { $0.rawValue >= 4 } : selectedScenes
        let cases: [(Scene, Int)] = scenes.flatMap { scene in
            (arguments.contains("--all-presets") ? [0, 1, 2] : [0]).map { (scene, $0) }
        }
        let qualities = argument("--quality").flatMap { name in
            ["eco", "balanced", "high", "cinematic"].firstIndex(of: name.lowercased()).map { [$0] }
        } ?? [1, 2, 0]
        let maxControls = arguments.contains("--max-controls")
        var results: [[String: Any]] = []
        var frame: UInt32 = 0
        for (drawableWidth, drawableHeight) in sizes {
            for (scene, preset) in cases {
                // Interleave repeated measurements to reveal GPU clock / load variance.
                for run in 0..<2 {
                    for quality in qualities {
                        var settings = Settings()
                        settings.scene = scene
                        settings.preset = preset
                        settings.quality = quality
                        if maxControls {
                            settings.intensity = 2
                            settings.speed = 2
                            for (index, control) in scene.controls.enumerated() { settings.sceneParameters[index] = control.range.upperBound }
                        }
                        let (width, height) = settings.renderSize(for: CGSize(width: drawableWidth, height: drawableHeight))
                        let stages: [(String, ParticleWork)] = scene == .particles && !drag
                            ? [("full", .all), ("simulation", .simulation), ("raster", .raster)] : [("full", .all)]
                        engine.reset()
                        var benchmarkInput = input
                        if scene == .river && drag {
                            benchmarkInput.position = SIMD2(0.45, 0.63)
                            benchmarkInput.delta = SIMD2(0.008, -0.005)
                        }
                        if scene == .batman && drag {
                            // Touch the painted cape inside the fitted portrait.
                            let pageWidth = (Float(963) / 1200) / (Float(width) / Float(height))
                            benchmarkInput.position = SIMD2(0.5 + 0.28 * pageWidth, 0.47)
                            benchmarkInput.delta = SIMD2(0.006, 0.002)
                            benchmarkInput.camera = SIMD4(0.4, 0.2, 0, 0)
                        }
                        if scene == .paperCity && drag {
                            let pageWidth = (Float(564) / 1055) / (Float(width) / Float(height))
                            benchmarkInput.position = SIMD2(0.5 + 0.12 * pageWidth, 0.78)
                            benchmarkInput.delta = SIMD2(0.006, 0.003)
                            benchmarkInput.camera = SIMD4(0.5, -0.3, 0, 0)
                        }
                        if (scene == .glassBlocks || scene == .blockGlass) && drag {
                            let pageWidth = (Float(1200) / 877) / (Float(width) / Float(height))
                            benchmarkInput.position = SIMD2(0.5 + 0.17 * min(1, pageWidth), 0.48)
                            benchmarkInput.delta = SIMD2(0.008, -0.005)
                            benchmarkInput.camera = SIMD4(0.5, -0.3, 0, 0)
                        }
                        // Static low-detail scenes normally settle and stop.
                        // Keep the interactive path active to measure real work.
                        if scene.isStatic && quality < 3 { benchmarkInput.orbiting = true }
                        for (label, stage) in stages {
                            var gpu: [Double] = []
                            var cpu: [Double] = []
                            let warmup = drag ? 240 : 8
                            for index in 0..<(frames + warmup) {
                                try autoreleasepool {
                                    guard let command = engine.queue.makeCommandBuffer() else {
                                        throw MoltenError.failed("No benchmark command buffer.")
                                    }
                                    if scene == .cove && drag {
                                        benchmarkInput.navigation = SIMD3(sin(Float(index)*0.035),0,cos(Float(index)*0.035))
                                        benchmarkInput.modifiers = 1
                                        benchmarkInput.position = SIMD2(0.75+0.08*sin(Float(index)*0.02),0.65)
                                        benchmarkInput.delta = SIMD2(0.005,0.002)
                                    }
                                    let start = ProcessInfo.processInfo.systemUptime
                                    _ = try engine.encode(command: command, width: width, height: height,
                                                          time: Float(frame) / 60 * settings.speed, dt: settings.speed / 60, frame: frame,
                                                          settings: settings, input: benchmarkInput, particleWork: stage)
                                    let encodeMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                    command.commit()
                                    command.waitUntilCompleted()
                                    guard command.status == .completed, command.error == nil else {
                                        throw MoltenError.failed("Benchmark GPU error: \(command.error?.localizedDescription ?? "unknown")")
                                    }
                                    if index >= warmup {
                                        gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000)
                                        cpu.append(encodeMS)
                                    }
                                    frame &+= 1
                                }
                            }
                            gpu.sort()
                            let row: [String: Any] = [
                                "scene": scene.title, "quality": ["Eco", "Balanced", "High", "Cinematic"][quality],
                                "preset": scene.presets[preset], "max_controls": maxControls,
                                "dragging": drag,
                                "stage": scene == .nativeGlass ? "backdrop_only_excludes_native_compositor" : label, "run": run, "frames": frames,
                                "drawable_width": drawableWidth, "drawable_height": drawableHeight,
                                "render_width": width, "render_height": height,
                                "particles": scene == .particles ? settings.particleCount : 0,
                                "gpu_median_ms": gpu[gpu.count / 2], "gpu_p95_ms": gpu[min(gpu.count - 1, Int(Double(gpu.count) * 0.95))],
                                "cpu_encode_mean_ms": cpu.reduce(0, +) / Double(cpu.count),
                                "gpu_allocated_mb": Double(engine.device.currentAllocatedSize) / 1048576
                            ]
                            results.append(row)
                            print("\(scene.title) / \(row["quality"]!) / \(label): \(String(format: "%.3f", gpu[gpu.count / 2])) ms GPU")
                        }
                    }
                }
            }
        }
        let report: [String: Any] = [
            "device": engine.device.name, "results": results,
            "scope": "Offscreen GPU timings; excludes presentation, display scheduling and other apps. No frame-rate or battery-runtime claim."
        ]
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL, options: .atomic)
    }
}
