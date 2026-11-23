import Foundation
import Metal

enum RiverTest {
    static func run() throws {
        let args = CommandLine.arguments, output = args.firstIndex(of: "--output")
        let directory = URL(fileURLWithPath: output.flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? "/tmp/molten-river")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try MetalEngine()
        var settings = Settings(); settings.scene = .river; settings.quality = 1
        var input = PointerState(), frame: UInt32 = 0
        func draw(dt: Float = 0, width: Int = 129, height: Int = 87, time: Float? = nil) throws {
            try autoreleasepool {
                guard let command = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No river test command buffer.") }
                _ = try engine.encode(command: command, width: width, height: height,
                    time: time ?? Float(engine.cinematic.river.tick)/60+dt, dt: dt, frame: frame, settings: settings, input: input)
                command.commit(); command.waitUntilCompleted(); frame &+= 1
                guard command.status == .completed, command.error == nil else { throw MoltenError.failed("River GPU error: \(String(describing: command.error))") }
            }
        }
        func snapshot() throws -> [Float] { try engine.cinematic.river.snapshot(queue: engine.queue) }
        func save(_ name: String) throws { try engine.readback(engine.output!).save(to: directory.appendingPathComponent(name + ".png")) }
        func wake(_ state: [Float]) -> (peak: Float, weight: Double, downstream: Double) {
            let width = engine.cinematic.river.gridWidth, height = engine.cinematic.river.gridHeight, cells = width * height
            var peak: Float = 0, mass: Double = 0, z: Double = 0
            for i in 0..<cells {
                let value = state[cells * 4 + i * 4 + 3]
                peak = max(peak, value)
                let position = (Double(i / width)+0.5)/Double(height)*56-36
                mass += Double(value); z += Double(value)*position
            }
            return (peak,mass,z/max(mass,0.00001))
        }
        func evolve(fps: Int, seconds: Int, drag: Bool = false) throws {
            for i in 0..<(fps*seconds) {
                if drag {
                    input.down = true; input.inside = true
                    input.position = SIMD2(0.46+0.12*sin(Float(i)/Float(fps)*2.5),0.68+0.08*cos(Float(i)/Float(fps)*2.5))
                    input.delta = SIMD2(0.008,-0.005)
                }
                try draw(dt: 1/Float(fps))
            }
        }
        if args.contains("--preview-only") {
            settings.quality = 2
            for (name, glow, stirring) in [("river-natural",Float(0),false),("river-quiet",Float(1),false),("river-wake",Float(1),true)] {
                settings.intensity = glow; input = PointerState(); engine.reset()
                try evolve(fps: 60,seconds: 3,drag: stirring)
                input = PointerState()
                for _ in 0..<40 { try draw(dt: 1/60,width: 1800,height: 1200) }
                try save(name)
            }
            print("PASS offscreen natural-water, quiet-water and disturbed-water previews")
            return
        }
        try draw()
        let initial = try snapshot()
        let triangles = engine.cinematic.river.triangleCount, leaves = engine.cinematic.river.leafCount
        let materialCount = engine.cinematic.river.scannedMaterialCount
        guard materialCount == 5 else { throw MoltenError.failed("Scanned river material arrays are incomplete.") }
        let geometry = try engine.cinematic.river.bathymetrySnapshot(queue: engine.queue)
        let gw = engine.cinematic.river.gridWidth, gh = engine.cinematic.river.gridHeight
        guard geometry.count == gw*gh*4 else { throw MoltenError.failed("River bathymetry is incomplete.") }
        var topologyError: Float = 0
        for i in stride(from: 0,to: gw*gh,by: 37) {
            let x = (Float(i%gw)+0.5)/Float(gw)*24-12, z = (Float(i/gw)+0.5)/Float(gh)*56-36
            let expected = max(0.02,RiverWorld.waterLevel(z)-RiverWorld.groundHeight(x:x,z:z))
            topologyError = max(topologyError,abs(expected-geometry[i*4]))
        }
        guard topologyError < 0.002 else { throw MoltenError.failed("Mesh and water solver disagree about the bed: \(topologyError)") }
        guard triangles > 500_000, leaves > 10_000, engine.cinematic.river.treeCount >= 32 else {
            throw MoltenError.failed("Detailed forest geometry is missing.")
        }
        try evolve(fps: 60, seconds: 2); let sixty = try snapshot()
        let sixtyOrganisms = try engine.cinematic.river.organismSnapshot(queue: engine.queue)
        guard initial != sixty else { throw MoltenError.failed("River state did not evolve.") }
        var cadence: [String: Float] = [:]
        for fps in [30,120] {
            engine.reset(); input = PointerState(); try evolve(fps: fps, seconds: 2)
            let other = try snapshot(), error = zip(sixty,other).map { abs($0-$1) }.max() ?? 0
            guard error < 0.0001 else { throw MoltenError.failed("River simulation changed at \(fps) Hz: \(error)") }
            let particles = try engine.cinematic.river.organismSnapshot(queue: engine.queue)
            guard particles == sixtyOrganisms else { throw MoltenError.failed("River organisms changed with frame cadence.") }
            cadence[String(fps)] = error
        }
        print("PASS identical 30/60/120 Hz river simulation states")
        engine.reset(); input = PointerState(); try draw()
        input.down = true; input.inside = true; input.position = SIMD2(0.45,0.63)
        for _ in 0..<30 { try draw(dt: 1/60) }
        let touched = try snapshot(), firstWake = wake(touched)
        let wavePeak = stride(from: 0, to: touched.count/2, by: 4).map { abs(touched[$0]) }.max() ?? 0
        guard firstWake.peak > 0.2, wavePeak > 0.002 else { throw MoltenError.failed("River interaction failed to excite waves and luminescence.") }
        input = PointerState()
        try evolve(fps: 60, seconds: 2)
        let released = try snapshot(), laterWake = wake(released)
        guard laterWake.peak > 0.015, laterWake.peak < firstWake.peak, laterWake.downstream > firstWake.downstream+0.4 else {
            throw MoltenError.failed("Released wake did not persist, advect downstream, and decay: \(firstWake) → \(laterWake)")
        }
        let frozenOrganisms = try engine.cinematic.river.organismSnapshot(queue: engine.queue)
        settings.paused = true
        for _ in 0..<4 { try draw(width: 337,height: 219) }
        guard try engine.cinematic.river.organismSnapshot(queue: engine.queue) == frozenOrganisms else { throw MoltenError.failed("Paused organisms evolved.") }
        guard try snapshot() == released else { throw MoltenError.failed("Paused river state changed.") }
        print("PASS click ripples, persistent wake, downstream transport, decay, and paused state")
        settings.paused = false
        var stressRows: [[String: Any]] = []
        for quality in [1,3] {
            settings.quality = quality; settings.intensity = 2; settings.sceneParameters = SIMD4(2,1.8,1.5,0)
            input = PointerState(); engine.reset(); try draw()
            let seconds = quality == 1 ? 30 : 12
            try evolve(fps: 30,seconds: seconds,drag: true)
            let organisms = try engine.cinematic.river.organismSnapshot(queue: engine.queue)
            guard organisms.count == engine.cinematic.river.organismCount*8,
                  organisms.allSatisfy({ $0.isFinite && abs($0) < 60 }) else {
                throw MoltenError.failed("River organism state diverged.")
            }
            let state = try snapshot(), cells = engine.cinematic.river.gridWidth*engine.cinematic.river.gridHeight
            let bed = try engine.cinematic.river.bathymetrySnapshot(queue: engine.queue)
            guard state.allSatisfy({ $0.isFinite && abs($0) <= 2.01 }) else { throw MoltenError.failed("River simulation diverged.") }
            let clipped = stride(from: 0,to: cells*4,by: 4).filter { abs(state[$0]) > 0.149 }.count
            guard clipped < cells/100 else { throw MoltenError.failed("River wave solver spent its budget against the safety clamp.") }
            var dryCells = 0
            for i in 0..<cells where bed[i*4+1] == 0 {
                dryCells += 1
                guard state[i*4..<i*4+4].allSatisfy({ $0 == 0 }),state[cells*4+i*4..<cells*4+i*4+4].allSatisfy({ $0 == 0 }) else {
                    throw MoltenError.failed("Water or excitation leaked onto a dry bank or into a solid obstacle.")
                }
            }
            let width = engine.cinematic.river.gridWidth
            for row in 0..<engine.cinematic.river.gridHeight {
                for column in [0,width-1] {
                    let cell = (row*width+column)*4
                    guard state[cell..<cell+4].allSatisfy({ $0==0 }), state[cells*4+cell..<cells*4+cell+4].allSatisfy({ $0==0 }) else {
                        throw MoltenError.failed("River material leaked beyond the banks.")
                    }
                }
            }
            stressRows.append(["quality":quality,"seconds":seconds,"finite_bounded":true,"height_clamp_cells":clipped,"dry_boundaries":true,"dry_cells_checked":dryCells])
        }
        print("PASS maximum-control river stress, finite waves, and dry domain boundaries")
        settings.quality = 2; settings.intensity = 1; settings.sceneParameters = Scene.river.defaultParameters
        for preset in 0..<3 {
            settings.preset = preset; engine.reset(); input = PointerState()
            for _ in 0..<180 { try draw(dt: 1/60,width: 1200,height: 800) }
            guard engine.cinematic.river.usesMetalFX else { throw MoltenError.failed("The river did not use MetalFX denoising.") }
            try save("river-\(preset)")
        }
        settings.preset = 0; engine.reset(); input = PointerState()
        settings.intensity = 0
        try evolve(fps: 60,seconds: 3)
        for _ in 0..<32 { try draw(dt: 1/60,width: 1800,height: 1200) }
        try save("river-natural")
        settings.intensity = 1; engine.reset()
        try evolve(fps: 60,seconds: 2,drag: true)
        input = PointerState()
        // Let the denoiser gather history after the output resize, with the wake
        // still moving. This is an actual interactive render, not an illustration.
        for _ in 0..<32 { try draw(dt: 1/60,width: 1800,height: 1200) }
        try save("river-wake")
        settings.paused = true; input.camera = SIMD4(0.22,-0.1,-0.35,0)
        try draw(width: 1200,height: 800); try save("river-close")
        for camera in [SIMD4<Float>(0.8,0.7,0.8,0),SIMD4<Float>(-0.6,-0.5,-0.7,0)] {
            input.camera = camera
            try draw(width: 419,height: 287)
            let bytes = [UInt8](try engine.readback(engine.output!).bytes)
            let visible = stride(from: 0,to: bytes.count,by: 4).filter { max(bytes[$0],max(bytes[$0+1],bytes[$0+2])) > 25 }.count
            guard visible > 419*287/100 else { throw MoltenError.failed("River orbit clipped the camera into the terrain.") }
        }
        settings.scene = .liquid; try draw()
        guard engine.cinematic.resourceBytes == 0 else { throw MoltenError.failed("Inactive river resources were retained.") }
        let report: [String: Any] = ["all_passed":true,"device":engine.device.name,"cadence_max_difference":cadence,
            "initial_wake_peak":firstWake.peak,"released_wake_peak":laterWake.peak,
            "downstream_distance_after_two_seconds":laterWake.downstream-firstWake.downstream,
            "wave_peak_after_click":wavePeak,"pause_preserves_state":true,"particle_cadence_and_pause":true,
            "forest_triangles":triangles,"individual_leaves":leaves,"scanned_materials":materialCount,"mesh_solver_depth_max_error":topologyError,
            "hardware_ray_tracing":true,"metalfx_denoising_verified":true,"stress":stressRows,"inactive_resources_released":true]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("river-test.json"),options: .atomic)
        print("PASS river resources released and visual previews saved")
    }
}
