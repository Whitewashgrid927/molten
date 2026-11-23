import Foundation
import Metal

enum StabilityTest {
    static func run() throws {
        let args = CommandLine.arguments
        let i = args.firstIndex(of: "--output")
        let directory = URL(fileURLWithPath: i.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                            ?? "/tmp/molten-stability", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try MetalEngine()
        var results: [[String: Any]] = []
        func draw(_ settings: Settings, frame: Int, dt: Float, input: PointerState = PointerState()) throws {
            try autoreleasepool {
                guard let command = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No GPU command buffer.") }
                _ = try engine.encode(command: command, width: 701, height: 509, time: Float(frame) * dt,
                                      dt: dt, frame: UInt32(frame), settings: settings, input: input)
                command.commit()
                command.waitUntilCompleted()
                if let error = command.error { throw error }
                guard command.status == .completed else { throw MoltenError.failed("Incomplete stability frame.") }
            }
        }
        for scene in [Scene.ocean, .terrain, .crystals, .patterns] {
            var settings = Settings()
            settings.scene = scene
            settings.quality = 2
            engine.reset()
            try draw(settings, frame: 0, dt: 0)
            let initial = try engine.simulationSnapshot()
            for frame in 0..<900 {
                var input = PointerState()
                if frame < 240 {
                    input.inside = true
                    input.down = true
                    input.position = SIMD2(0.5 + 0.23 * sin(Float(frame) * 0.021), 0.5 + 0.19 * cos(Float(frame) * 0.016))
                    input.delta = SIMD2(0.004, -0.003)
                }
                try draw(settings, frame: frame, dt: 1.0 / 30, input: input)
            }
            let advanced = try engine.simulationSnapshot()
            guard advanced != initial else { throw MoltenError.failed("\(scene.title) did not evolve.") }
            var minimum = Float.greatestFiniteMagnitude, maximum = -Float.greatestFiniteMagnitude
            var changed = 0, solid = 0
            for (index, sample) in advanced.enumerated() {
                for channel in 0..<4 {
                    guard sample[channel].isFinite, abs(sample[channel]) < 10 else {
                        throw MoltenError.failed("\(scene.title) simulation diverged.")
                    }
                    minimum = min(minimum, sample[channel]); maximum = max(maximum, sample[channel])
                }
                if abs(sample.x - initial[index].x) > 0.00001 { changed += 1 }
                if sample.x >= 1 { solid += 1 }
            }
            guard changed > advanced.count / 100 else { throw MoltenError.failed("\(scene.title) evolution was negligible.") }
            if scene == .crystals {
                let seedCount = initial.filter { $0.x >= 1 }.count
                guard solid > seedCount * 2, solid < advanced.count * 9 / 10 else {
                    throw MoltenError.failed("Crystal growth stalled or filled the grid too quickly.")
                }
            }
            if scene == .terrain {
                let eroded = zip(initial, advanced).filter { $0.x - $1.x > 0.0001 }.count
                guard eroded > 100 else { throw MoltenError.failed("Rain did not erode terrain.") }
            }
            guard let output = engine.output else { throw MoltenError.failed("Missing stability image.") }
            try engine.readback(output).save(to: directory.appendingPathComponent("\(scene.key)-30-seconds.png"))
            for frame in 0..<4 { try draw(settings, frame: frame, dt: 0) }
            guard try engine.simulationSnapshot() == advanced else { throw MoltenError.failed("\(scene.title) changed while paused.") }
            // Pure autonomous evolution should agree across refresh rates.
            // Rain uses continuous-time noise, so terrain is checked for bounded
            // evolution above instead of requiring identical time samples.
            if scene != .terrain {
                engine.reset()
                for frame in 0..<30 { try draw(settings, frame: frame, dt: 1.0 / 30) }
                let at30 = try engine.simulationSnapshot()
                engine.reset()
                for frame in 0..<120 { try draw(settings, frame: frame, dt: 1.0 / 120) }
                guard try engine.simulationSnapshot() == at30 else {
                    throw MoltenError.failed("\(scene.title) evolution depends on refresh rate.")
                }
            }
            results.append(["scene": scene.title, "simulated_seconds": 30, "min": minimum, "max": maximum,
                            "changed_cells": changed, "total_cells": advanced.count, "paused_state_unchanged": true])
            print("PASS \(scene.title): 30 simulated seconds, finite state, sustained interaction, pause and timing checks")
        }
        var settings = Settings()
        settings.scene = .liquid
        try draw(settings, frame: 0, dt: 0)
        guard try engine.simulationSnapshot().isEmpty else { throw MoltenError.failed("Inactive simulation memory was retained.") }
        let report: [String: Any] = ["all_passed": true, "results": results, "inactive_simulation_released": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("stability.json"), options: .atomic)
    }
}
