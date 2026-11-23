import Foundation
import Metal

enum ImmersiveTest {
    static func run() throws {
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--output")
        let directory = URL(fileURLWithPath: index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "/tmp/molten-immersive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try MetalEngine()
        var settings = Settings(), input = PointerState()
        var frame: UInt32 = 0
        func draw(time: Float = 1, dt: Float = 0, width: Int = 900, height: Int = 700) throws {
            try autoreleasepool {
                guard let c = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No immersive test command buffer.") }
                _ = try engine.encode(command: c, width: width, height: height, time: time, dt: dt, frame: frame, settings: settings, input: input)
                c.commit(); c.waitUntilCompleted(); frame &+= 1
                guard c.status == .completed, c.error == nil else { throw MoltenError.failed("Immersive GPU failure: \(String(describing: c.error))") }
            }
        }
        func pixels() throws -> PixelImage { try engine.readback(engine.output!) }
        func save(_ name: String) throws { try pixels().save(to: directory.appendingPathComponent(name + ".png")) }
        func changed(_ a: Data, _ b: Data) -> Int { zip(a, b).filter { abs(Int($0) - Int($1)) > 6 }.count }
        var report: [String: Any] = ["device": engine.device.name]
        settings.scene = .holographic; settings.quality = 2
        // Inspect the face, a foil-catching tilt, reverse, light motion, and
        // all four pixel budgets with real shader output.
        for _ in 0..<32 { try draw() }; let face = try pixels().bytes; try save("card-obsidian")
        input.camera = SIMD4(0.42, -0.17, -0.05, 0)
        for _ in 0..<32 { try draw() }; let tilted = try pixels().bytes; try save("card-tilted")
        guard changed(face, tilted) > 15_000 else { throw MoltenError.failed("Card tilt did not change material or perspective.") }
        input.camera.x = .pi
        for _ in 0..<32 { try draw() }; let back = try pixels().bytes; try save("card-reverse")
        guard changed(face, back) > 15_000 else { throw MoltenError.failed("Card reverse is not distinct.") }
        input = PointerState(); input.down = true; input.modifiers = 1; input.position = SIMD2(0.83, 0.18)
        try draw(); let light = try pixels().bytes
        guard changed(face, light) > 3000 else { throw MoltenError.failed("Dragging the light did not affect the card.") }
        input.down = false; input.modifiers = 0
        try draw(); let releasedLight = try pixels().bytes
        engine.reset(); try draw(); let resetLight = try pixels().bytes
        guard changed(releasedLight, resetLight) > 3000 else { throw MoltenError.failed("Light placement was not retained on release.") }
        for quality in 0..<4 {
            settings.quality = quality; engine.reset()
            for _ in 0..<[8,16,32,128][quality] { try draw(width: 347, height: 291) }
            guard engine.cinematic.converged else { throw MoltenError.failed("Card did not settle at quality \(quality).") }
            let submitted = engine.cinematic.renderedSamples
            try draw(width: 347, height: 291)
            guard engine.cinematic.renderedSamples == submitted else { throw MoltenError.failed("Settled card kept submitting render passes.") }
        }
        report["card"] = ["tilt_changes_material": true, "distinct_reverse": true, "light_persists": true,
                          "all_quality_levels_converge_and_rest": true]
        print("PASS card tilt, reverse, persistent light, 8/16/32/128 samples, and no work after convergence")

        settings.scene = .reef; settings.quality = 1; input = PointerState(); engine.reset()
        try draw(time: 0, width: 97, height: 65)
        let fish = engine.cinematic.immersive.fishCount, plankton = engine.cinematic.immersive.planktonCount
        let actorFloats = (fish + ImmersiveEngine.jellyCount) * 8
        let particleEnd = actorFloats + plankton * 8
        let initial = try engine.cinematic.snapshot(queue: engine.queue)
        func evolve(_ fps: Int, seconds: Int = 1, interaction: Bool = false) throws -> [Float] {
            for frame in 0..<(fps * seconds) {
                input.down = interaction; input.inside = interaction
                input.position = SIMD2(0.5 + 0.2 * sin(Float(frame) / Float(fps) * 3), 0.52 + 0.12 * cos(Float(frame) / Float(fps) * 3))
                input.delta = interaction ? SIMD2(0.008, -0.005) : .zero
                try draw(time: Float(frame + 1) / Float(fps), dt: 1 / Float(fps), width: 97, height: 65)
            }
            return try engine.cinematic.snapshot(queue: engine.queue)
        }
        let sixty = try evolve(60)
        engine.reset(); input = PointerState()
        let thirty = try evolve(30)
        let cadenceError = zip(sixty, thirty).map { abs($0 - $1) }.max() ?? 0
        guard cadenceError < 0.0001 else { throw MoltenError.failed("Reef simulation depends on display cadence: \(cadenceError)") }
        engine.reset(); input = PointerState()
        let stirred = try evolve(60, seconds: 2, interaction: true)
        let peakWake = stride(from: particleEnd + 3, to: stirred.count, by: 4).map { stirred[$0] }.max() ?? 0
        let glowing = stride(from: actorFloats + 7, to: particleEnd, by: 8).filter { stirred[$0] > 0.1 }.count
        guard peakWake > 0.2, glowing > 10 else { throw MoltenError.failed("Current brush did not excite plankton or persist in the water.") }
        settings.paused = true; input = PointerState()
        try draw(time: 2); try save("reef-stirred")
        for _ in 0..<4 { try draw(time: 2) }
        guard try engine.cinematic.snapshot(queue: engine.queue) == stirred else { throw MoltenError.failed("Paused reef state changed.") }
        settings.paused = false
        settings.sceneParameters = SIMD4(2,1,1.5,0); settings.intensity = 2
        engine.reset(); input = PointerState()
        let stress = try evolve(30, seconds: 30, interaction: true)
        guard stress != initial, stress.allSatisfy({ $0.isFinite && abs($0) < 20 }) else { throw MoltenError.failed("Reef stress produced invalid or stationary state.") }
        for i in stride(from: 0, to: particleEnd, by: 8) {
            guard abs(stress[i]) <= 7.001, stress[i+1] >= -0.001, stress[i+1] <= 6.001, abs(stress[i+2]) <= 7.001 else {
                throw MoltenError.failed("An organism escaped the simulation domain.")
            }
        }
        input = PointerState(); settings.sceneParameters = Scene.reef.defaultParameters; settings.intensity = 1
        try draw(time: 30); try save("reef-stress")
        // Schooling must change trajectories, not only a color/visual uniform.
        settings.sceneParameters.y = 0; engine.reset(); let loose = try evolve(60, seconds: 2)
        settings.sceneParameters.y = 1; engine.reset(); let cohesive = try evolve(60, seconds: 2)
        let behavior = zip(loose.prefix(fish * 8), cohesive.prefix(fish * 8)).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(fish * 8)
        guard behavior > 0.01 else { throw MoltenError.failed("Schooling control did not affect fish trajectories.") }
        report["reef"] = ["simulated_stress_seconds": 30, "finite_and_bounded": true, "peak_current_wake": peakWake,
                          "excited_plankton": glowing, "cadence_max_difference": cadenceError,
                          "schooling_mean_state_difference": behavior, "pause_preserves_state": true]
        print("PASS reef fixed cadence, persistent current wakes, \(glowing) excited plankton, schooling, pause, and 30-second maximum-control stress")

        // Final presentation images use deterministic initial conditions.
        settings.quality = 2; settings.sceneParameters = Scene.reef.defaultParameters
        for preset in 0..<3 {
            settings.preset = preset; input = PointerState(); engine.reset()
            for frame in 0..<120 { try draw(time: Float(frame)/60, dt: 1/60, width: 1200, height: 850) }
            try save("reef-\(preset)")
        }
        settings.paused = true; input.camera = SIMD4(0.32, 0.12, -0.4, 0)
        try draw(time: 2, width: 1200, height: 850); try save("reef-close")
        settings.scene = .liquid
        try draw(width: 97, height: 65)
        guard engine.cinematic.resourceBytes == 0 else { throw MoltenError.failed("Inactive immersive resources were retained.") }
        report["inactive_resources_released"] = true; report["all_passed"] = true
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("immersive-test.json"), options: .atomic)
        print("PASS inactive resources released; immersive checks completed")
    }
}
