import Foundation
import Metal
import simd

enum CoveTest {
    static func run() throws {
        let args = CommandLine.arguments
        let i = args.firstIndex(of:"--output")
        let directory = URL(fileURLWithPath:i.flatMap { args.indices.contains($0+1) ? args[$0+1]:nil } ?? "/tmp/molten-cove")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let engine = try MetalEngine()
        var settings = Settings(), input = PointerState(), frame: UInt32 = 0
        settings.scene = .cove; settings.quality = 2
        func draw(dt: Float = 0, width: Int = 160, height: Int = 100) throws {
            try autoreleasepool {
                guard let c = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No cove test command.") }
                _ = try engine.encode(command:c,width:width,height:height,time:Float(engine.cinematic.cove.tick)/60+dt,dt:dt,frame:frame,settings:settings,input:input)
                c.commit(); c.waitUntilCompleted(); frame &+= 1
                guard c.status == .completed,c.error == nil else { throw MoltenError.failed("Cove GPU failure: \(String(describing:c.error))") }
            }
        }
        func image(_ name: String) throws { try engine.readback(engine.output!).save(to:directory.appendingPathComponent(name+".png")) }
        var results: [String:Any] = [:]
        guard MemoryLayout<CoveVertex>.stride == 64,MemoryLayout<CoveFrame>.stride == 128 else { throw MoltenError.failed("Cove GPU ABI mismatch.") }
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw MoltenError.failed(message) } }
        func snapshot() throws -> [Float] { try engine.cinematic.cove.snapshot(queue:engine.queue) }
        func toward(_ target: SIMD2<Float>) {
            let model = engine.cinematic.cove.motion, c = model.camera(input)
            let offset = target-SIMD2(model.position.x,model.position.z)
            let direction = simd_length(offset)>0.001 ? simd_normalize(offset):.zero
            let forward = simd_normalize(SIMD2(c.forward.x,c.forward.z)), right = SIMD2(c.right.x,c.right.z)
            input.navigation = SIMD3(simd_dot(direction,right),0,simd_dot(direction,forward))
        }
        func navigate(_ target: SIMD2<Float>, frames: Int = 300) throws {
            for _ in 0..<frames {
                let p = engine.cinematic.cove.motion.position
                if simd_distance(SIMD2(p.x,p.z),target)<0.08 { break }
                toward(target); try draw(dt:1/60)
            }
            input.navigation = .zero
            for _ in 0..<15 { try draw(dt:1/60) }
        }
        func project(_ point: SIMD3<Float>, aspect: Float = 1.6) -> SIMD2<Float> {
            let c = engine.cinematic.cove.motion.camera(input), p = point-c.eye
            let depth = simd_dot(p,c.forward)/c.focal
            return SIMD2(0.5+simd_dot(p,c.right)/depth/aspect*0.5,0.5-simd_dot(p,c.up)/depth*0.5)
        }
        if !args.contains("--preview-only") {
            var state60: [Float] = [], errors: [String:Float] = [:]
            for fps in [60,30,120] {
                settings = Settings(); settings.scene = .cove; settings.quality = 1; engine.reset(); input = PointerState()
                input.navigation = SIMD3(0.3,0,-0.4); input.down = true; input.inside = true; input.position = SIMD2(0.83,0.72)
                for _ in 0..<fps { try draw(dt:1/Float(fps)) }
                let state = try snapshot()
                if fps==60 { state60 = state }
                else {
                    let error = zip(state,state60).map { abs($0-$1) }.max() ?? 0
                    try require(state.count==state60.count && error<0.00001,"Cove depends on frame cadence: \(error)")
                    errors[String(fps)] = error
                }
            }
            let waveFloats = CoveEngine.grid*CoveEngine.grid*2
            let wavePeak = stride(from:0,to:waveFloats,by:2).map { abs(state60[$0]) }.max() ?? 0
            try require(wavePeak>0.001,"Water interaction did not leave a persistent disturbance.")
            results["cadence_errors"] = errors; results["wave_peak"] = wavePeak
            print("PASS 30/60/120 Hz gameplay, water and petal parity; persistent water disturbance")

            settings = Settings(); settings.scene = .cove; settings.quality = 2; engine.reset(); input = PointerState()
            try draw(dt:1/60)
            let start = engine.cinematic.cove.motion.position
            toward(SIMD2(2.8,1.35)); for _ in 0..<30 { try draw(dt:1/60) }
            let walked = simd_distance(start,engine.cinematic.cove.motion.position)
            engine.reset(); input = PointerState(); try draw(dt:1/60); toward(SIMD2(2.8,1.35)); input.modifiers = 1
            for _ in 0..<30 { try draw(dt:1/60) }
            let ran = simd_distance(start,engine.cinematic.cove.motion.position)
            try require(walked>0.35 && ran>walked*1.8,"Walking/running speeds are incorrect.")
            input.modifiers = 0; input.navigation = .zero
            for _ in 0..<60 { try draw(dt:1/60) }
            try require(engine.cinematic.cove.motion.speed<0.001,"Character did not stop after key release.")
            for target in [SIMD2<Float>(8,1.4),SIMD2(-8,1.4),SIMD2(-2,8),SIMD2(-2,-8),SIMD2(0.3,-1.4)] {
                for _ in 0..<180 {
                    toward(target); input.modifiers = 1; try draw(dt:1/60)
                    let p = engine.cinematic.cove.motion.position
                    try require(CoveMotion.walkable(SIMD2(p.x,p.z)),"Character crossed the sea edge, wall or furniture.")
                }
            }
            results["walk_distance_half_second"] = walked; results["run_distance_half_second"] = ran
            results["collision_and_key_release"] = true
            print("PASS camera-relative walking, faster running, key release and sustained collision pressure")

            engine.reset(); input = PointerState(); try draw(dt:1/60)
            try navigate(CoveMotion.benchApproach)
            try require(engine.cinematic.cove.motion.canSit,"Bench cannot be approached.")
            input.actionSerial &+= 1; for _ in 0..<45 { try draw(dt:1/60) }
            try require(engine.cinematic.cove.motion.seated && engine.cinematic.cove.motion.sitBlend>0.99,"Bench interaction did not sit.")
            try draw(width:1800,height:1200); try image("cove-seated")
            let sitting = engine.cinematic.cove.motion.position
            input.navigation = SIMD3(1,0,1)
            for _ in 0..<30 { try draw(dt:1/60) }
            try require(engine.cinematic.cove.motion.position==sitting,"Seated character walked through the bench.")
            input.navigation = .zero; input.actionSerial &+= 1; for _ in 0..<30 { try draw(dt:1/60) }
            try require(!engine.cinematic.cove.motion.seated && engine.cinematic.cove.motion.sitBlend<0.01,"Stand interaction failed.")
            let standing = engine.cinematic.cove.motion.position
            try require(CoveMotion.walkable(SIMD2(standing.x,standing.z)),"Standing placed character inside furniture.")
            results["sit_stand_and_safe_exit"] = true
            print("PASS walk to bench, sit, seated movement lock, stand and safe exit")

            input.freeCamera = true; try draw(dt:1/60)
            let oldEye = engine.cinematic.cove.motion.camera(input).eye
            input.navigation = SIMD3(0.3,0.4,0.5)
            for _ in 0..<45 { try draw(dt:1/60) }
            try require(simd_distance(oldEye,engine.cinematic.cove.motion.camera(input).eye)>0.5 && engine.cinematic.cove.motion.position==standing,"Free camera moved the character or failed to fly.")
            try draw(width:1800,height:1200); try image("cove-free-camera")
            input.camera.y = -1.35; try draw()
            try require(engine.cinematic.cove.motion.camera(input).forward.y>0.6,"Free camera cannot look upwards.")
            input.camera.y = 0

            input.freeCamera = false; input.navigation = .zero; try draw(dt:1/60)
            try require(!engine.cinematic.cove.motion.freeMode,"Returning to player failed.")
            results["free_camera_preserves_character"] = true
            print("PASS free flight, vertical movement and return to character")

            engine.reset(); input = PointerState(); try draw(dt:1/60)
            input.position = project(CoveMotion.lanternPivot-SIMD3(0,0.39,0)); input.down = true; input.inside = true
            try draw(dt:1/60); input.down = false
            for _ in 0..<12 { try draw(dt:1/60) }
            let swing = abs(engine.cinematic.cove.motion.lanternAngle)
            try require(swing>0.15,"Clicking the lantern did not impart a swing.")
            results["lantern_click_swing_radians"] = swing
            settings.paused = true
            let before = try snapshot()
            input.navigation = SIMD3(1,0,1); input.actionSerial &+= 1
            for _ in 0..<5 { try draw(width:333,height:219) }
            try require(try snapshot()==before,"Paused gameplay or GPU state changed.")
            input.navigation = .zero; input.actionSerial = 0; settings.paused = false
            settings.intensity = 2; settings.sceneParameters = SIMD4(24,1.8,0.35,0)
            for n in 0..<900 {
                input.navigation = SIMD3(sin(Float(n)*0.035),0,cos(Float(n)*0.035)); input.modifiers = 1
                input.down = n<360; input.position = SIMD2(0.78+0.10*sin(Float(n)*0.05),0.73)
                try draw(dt:1/30)
            }
            let state = try snapshot()
            try require(state.allSatisfy { $0.isFinite && abs($0)<20 },"Cove state diverged during stress.")
            for j in stride(from:waveFloats,to:waveFloats+CoveEngine.petalCount*8,by:8) {
                try require(abs(state[j])<=9.01 && abs(state[j+2])<=9.01 && state[j+1] >= -0.2 && state[j+1]<5.5,"A petal escaped its simulation domain.")
            }
            results["pause_preserves_state"] = true; results["maximum_controls_stress_seconds"] = 30; results["bounded_gpu_state"] = true
            print("PASS lantern swing, paused state and 30 seconds of maximum controls, moving player and held input")
        }
        for preset in 0..<3 {
            settings = Settings(); settings.scene = .cove; settings.quality = 2; settings.preset = preset; engine.reset(); input = PointerState()
            for _ in 0..<90 { try draw(dt:1/60) }
            try draw(width:1800,height:1200); try image("cove-\(preset)")
            print("PASS rendered \(settings.scene.presets[preset]): \(engine.cinematic.cove.triangleCount) triangles, \(engine.cinematic.cove.blossomCount) blossoms")
        }
        results["triangles"] = engine.cinematic.cove.triangleCount; results["blossoms"] = engine.cinematic.cove.blossomCount
        results["active_gpu_resources_mb"] = Double(engine.cinematic.resourceBytes)/1048576
        settings.scene = .liquid; try draw()
        try require(engine.cinematic.cove.resourceBytes==0 && engine.cinematic.resourceBytes==0,"Inactive cove resources leaked.")
        results["inactive_resources_released"] = true
        let report: [String:Any] = ["all_passed":true,"preview_only":args.contains("--preview-only"),"results":results]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("cove-test.json"))
    }
}
