import Foundation
import Metal
import AVFoundation

enum AtelierTest {
    static func run() throws {
        let args = CommandLine.arguments
        let i = args.firstIndex(of: "--output")
        let directory = URL(fileURLWithPath: i.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "/tmp/molten-atelier")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try MetalEngine()
        var settings = Settings(), input = PointerState(), frame: UInt32 = 0
        func draw(dt: Float = 0, width: Int = 127, height: Int = 83) throws {
            try autoreleasepool {
                guard let c = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No atelier test command.") }
                _ = try engine.encode(command: c, width: width, height: height,
                    time: Float(engine.cinematic.atelier.tick) / 60 + dt, dt: dt, frame: frame, settings: settings, input: input)
                c.commit(); c.waitUntilCompleted(); frame &+= 1
                guard c.status == .completed, c.error == nil else { throw MoltenError.failed("Atelier GPU failure: \(String(describing: c.error))") }
            }
        }
        func snapshot() throws -> [Float] { try engine.cinematic.atelier.snapshot(queue: engine.queue) }
        func image(_ name: String) throws -> Data {
            let pixels = try engine.readback(engine.output!)
            try pixels.save(to: directory.appendingPathComponent(name + ".png")); return pixels.bytes
        }
        var results: [String: Any] = [:]
        if !args.contains("--preview-only") {
            // Verify the actual state, including equal step counts at 30/60/120 Hz.
            for scene in [Scene.koi, .portal] {
                settings.scene = scene; settings.quality = 1; input = PointerState(); engine.reset()
                input.down = true; input.inside = true; input.modifiers = 1; input.position = SIMD2(0.65,0.52)
                func evolve(_ fps: Int) throws -> [Float] {
                    for _ in 0..<fps { try draw(dt: 1 / Float(fps)) }
                    return try snapshot()
                }
                let sixty = try evolve(60)
                var errors: [String: Float] = [:]
                for fps in [30,120] {
                    engine.reset(); let other = try evolve(fps)
                    let error = zip(sixty,other).map { abs($0 - $1) }.max() ?? 0
                    guard error < 0.00001 else { throw MoltenError.failed("\(scene.title) depends on display cadence: \(error).") }
                    errors[String(fps)] = error
                }
                let waveCount = AtelierEngine.grid * AtelierEngine.grid * 4
                let peak = stride(from: 0, to: waveCount, by: 4).map { abs(sixty[$0]) }.max() ?? 0
                guard peak > 0.01 else { throw MoltenError.failed("\(scene.title) brush failed to create a persistent wake.") }
                input = PointerState(); settings.paused = true
                let before = try snapshot()
                for _ in 0..<5 { try draw(width: 333, height: 219) }
                guard try snapshot() == before else { throw MoltenError.failed("Paused atelier state changed.") }
                settings.paused = false; settings.intensity = 2
                for (i, control) in scene.controls.enumerated() { settings.sceneParameters[i] = control.range.upperBound }
                for n in 0..<600 {
                    input.down = true; input.inside = true
                    input.position = SIMD2(0.5 + 0.2 * sin(Float(n) * 0.09), 0.5 + 0.16 * cos(Float(n) * 0.09))
                    try draw(dt: 1 / 30)
                }
                let state = try snapshot()
                guard state.allSatisfy({ $0.isFinite && abs($0) < 20 }) else { throw MoltenError.failed("Unbounded atelier state.") }
                if scene == .koi {
                    for offset in stride(from: waveCount, to: state.count, by: 8) {
                        let radius = hypot(state[offset],state[offset + 1])
                        guard radius <= 0.801 && radius >= 0.309 else { throw MoltenError.failed("A koi escaped its pond or crossed the spindle.") }
                    }
                }
                results[scene.key] = ["cadence_errors": errors, "wake_peak": peak, "pause_preserves_state": true, "stress_seconds": 20, "finite_state": true]
                print("PASS \(scene.title): 30/60/120 Hz parity, persistent waves, pause, 20-second stress, bounded state")
            }

            // Hit testing uses the same aspect-correct coordinate map as the shader.
            var motion = TurntableMotion(), pointer = PointerState()
            pointer.inside = true
            func point(_ p: SIMD2<Float>, down: Bool) {
                pointer.position = p / SIMD2<Float>(4.65,3.1) + SIMD2(repeating: 0.5); pointer.down = down
                motion.update(input: pointer, aspect: 1.5, dt: 1 / 60)
            }
            point(SIMD2(0.7,0),down:true)
            point(SIMD2(0.65,0.25),down:true)
            guard motion.velocity > 1, motion.dragging else { throw MoltenError.failed("Record did not follow a forward scratch.") }
            point(SIMD2(0.7,-0.05),down:true)
            guard motion.velocity < -1 else { throw MoltenError.failed("Record did not reverse.") }
            point(SIMD2(0.7,-0.05),down:false)
            let released = motion.velocity
            for _ in 0..<60 { motion.update(input:pointer,aspect:1.5,dt:1/60) }
            guard motion.velocity > released, motion.velocity < 0.22 else { throw MoltenError.failed("Record inertia failed.") }
            point(SIMD2(-1.24,-0.40),down:true); point(SIMD2(-1.24,-0.40),down:false)
            guard motion.speed > 1.99 else { throw MoltenError.failed("On-scene speed fader failed.") }
            point(motion.armTip,down:true); point(SIMD2(1.13,0.53),down:true); point(SIMD2(1.13,0.53),down:false)
            guard motion.arm < 0.01 else { throw MoltenError.failed("Tonearm did not lift.") }
            point(SIMD2(-1.24,0.66),down:true); point(SIMD2(-1.24,0.66),down:false)
            guard motion.speed == 0 else { throw MoltenError.failed("Motor switch failed.") }
            results["turntable_mechanics"] = ["forward_and_reverse":true,"inertia":true,"speed_fader":true,"tonearm":true,"motor_switch":true]
            print("PASS forward/reverse scratching, inertia, speed fader, tonearm, motor switch")

            results["audio"] = try audio(directory: directory)
            for scene in Scene.allCases {
                for paused in [false,true] {
                    guard !FrameScheduling.shouldPlayAudio(visible: false,paused: paused,scene: scene),
                          !FrameScheduling.shouldPlayAudio(visible: true,paused: true,scene: scene) else {
                        throw MoltenError.failed("Hidden or paused scenes can play audio.")
                    }
                    if scene != .koi { guard !FrameScheduling.shouldPlayAudio(visible:true,paused:paused,scene:scene) else { throw MoltenError.failed("Audio leaked into another scene.") } }
                }
            }
            results["hidden_paused_other_scene_audio_stops"] = true
        }
        // Large actual renders, including a genuinely different camera and next world.
        for scene in [Scene.koi,.portal] {
            settings = Settings(); settings.scene = scene; settings.quality = 2; input = PointerState(); engine.reset()
            for _ in 0..<180 { try draw(dt:1/60) }
            try draw(width:1800,height:1200); let original = try image(scene.key + "-hero")
            if scene == .portal {
                input.camera.x = 0.48; input.camera.y = -0.12
                try draw(width:1800,height:1200); let orbit = try image("portal-orbit")
                guard orbit != original else { throw MoltenError.failed("Portal orbit did not reveal depth.") }
                input.camera = SIMD4(0,0,0,5.5)
                try draw(width:1800,height:1200); _ = try image("portal-approach")
                input.camera.w = 12
                try draw(width:1800,height:1200); let next = try image("portal-next-world")
                guard next != original else { throw MoltenError.failed("Portal did not lead to another world.") }
            } else {
                input.down = true; input.inside = true; input.position = SIMD2(0.65,0.55); input.modifiers = 1
                for _ in 0..<30 { try draw(dt:1/60) }
                try draw(width:1800,height:1200); _ = try image("koi-stirred")
            }
        }
        settings.scene = .liquid; try draw()
        guard engine.cinematic.atelier.resourceBytes == 0, engine.cinematic.resourceBytes == 0 else { throw MoltenError.failed("Inactive atelier resources leaked.") }
        results["inactive_resources_released"] = true
        let report: [String:Any] = ["all_passed":true,"preview_only":args.contains("--preview-only"),"device":engine.device.name,"results":results]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("atelier-test.json"),options:.atomic)
        print("PASS rendered previews, portal orbit/traversal, and inactive resource release")
    }
    private static func audio(directory: URL) throws -> [String:Any] {
        let format = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:44_100,channels:2,interleaved:true)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:44_100)!
        buffer.frameLength = 44_100
        for i in 0..<44_100 {
            buffer.int16ChannelData![0][i*2] = Int16(sin(Double(i)*0.0627)*16_000)
            buffer.int16ChannelData![0][i*2+1] = Int16(sin(Double(i)*0.0413)*12_000)
        }
        let url = directory.appendingPathComponent("synthetic-audio-fixture.wav")
        do {
            let file = try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatInt16,interleaved:true)
            try file.write(from:buffer)
            file.close()
        }
        defer { try? FileManager.default.removeItem(at:url) }
        let track = try TurntableTrack(url:url), sampler = TurntableSampler(track:track)
        guard track.count == 44_100 && track.channels == 2 else { throw MoltenError.failed("Local audio decoding failed: \(track.count) frames, \(track.channels) channels.") }
        var left = [Float](repeating:0,count:4096), right = left
        func render() { left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in sampler.render(frames:4096,left:l.baseAddress!,right:r.baseAddress!) } } }
        sampler.set(rate:1,gain:0.7); render()
        guard left.contains(where:{abs($0)>0.1}), left != right else { throw MoltenError.failed("Stereo playback was silent or collapsed.") }
        let forward = sampler.position
        sampler.set(rate:-1,gain:0.7); render()
        guard sampler.position < forward else { throw MoltenError.failed("Reverse audio scratching failed.") }
        for rate in [Float(-8),0,0.01,8] {
            sampler.set(rate:rate,gain:0.7)
            for _ in 0..<10 { render() }
            guard left.allSatisfy({$0.isFinite && abs($0)<=1}), sampler.position>=0 && sampler.position<Double(track.count) else { throw MoltenError.failed("Audio loop escaped its PCM allocation.") }
        }
        sampler.set(rate:1,gain:0); render(); render()
        guard left.map(abs).max()! < 0.00001 else { throw MoltenError.failed("Lifted tonearm did not fade to silence.") }
        // Exercise the production AVAudioSourceNode graph in offline mode. No
        // hardware output device is started and no sound is played to the user.
        let graph = try TurntableAudioGraph.make(sampler:sampler)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate:44_100,channels:2)!
        try graph.enableManualRenderingMode(.offline,format:outputFormat,maximumFrameCount:512)
        let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:512)!
        sampler.set(rate:1,gain:0.7); try graph.start()
        defer { graph.stop() }
        var audible = false
        for _ in 0..<16 {
            let status = try graph.renderOffline(512,to:output)
            guard status == .success else { throw MoltenError.failed("Offline AVAudioEngine rendering failed: \(status.rawValue)") }
            audible = audible || UnsafeBufferPointer(start:output.floatChannelData![0],count:Int(output.frameLength)).contains(where:{abs($0)>0.01})
        }
        guard audible else { throw MoltenError.failed("Production audio graph was silent.") }
        graph.pause(); guard !graph.isRunning else { throw MoltenError.failed("Audio graph did not stop on pause.") }
        print("PASS local PCM decode, stereo playback, reverse scratching, bounded loops, mute fade, and offline AVAudioEngine graph")
        return ["local_decode":true,"stereo":true,"reverse":true,"rates_tested":[-8,0,0.01,8],"mute_fade":true,"offline_engine":true,"engine_pause":true,"hardware_audio_output":false,"decoded_track_limit_bytes":TurntableTrack.byteLimit]
    }
}
