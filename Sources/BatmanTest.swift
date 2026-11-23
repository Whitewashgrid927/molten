import AppKit
import Metal
import simd
import CryptoKit
import AVFoundation

// Offscreen visual and functional checks; no NSApplication or visible window.
enum BatmanTest {
    static func run() throws {
        let args = CommandLine.arguments, i = args.firstIndex(of: "--output")
        let directory = URL(fileURLWithPath: i.flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? "/tmp/molten-batman")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try MetalEngine()
        var settings = Settings(), input = PointerState(), frame: UInt32 = 0
        settings.scene = .batman; settings.quality = 2
        func require(_ b: Bool, _ why: String) throws { if !b { throw MoltenError.failed(why) } }
        func draw(_ dt: Float = 0, width: Int = 193, height: Int = 240) throws {
            try autoreleasepool {
                guard let c = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No illustration test command.") }
                _ = try engine.encode(command: c, width: width, height: height, time: Float(engine.cinematic.batman.tick)/60+dt,
                                      dt: dt, frame: frame, settings: settings, input: input)
                c.commit(); c.waitUntilCompleted(); frame &+= 1
                try require(c.status == .completed && c.error == nil, "Illustration GPU failure: \(String(describing:c.error))")
            }
        }
        func state() throws -> [Float] { try engine.cinematic.batman.snapshot(queue: engine.queue) }
        func pixels() throws -> PixelImage { try engine.readback(engine.output!) }
        func image(_ name: String) throws { try pixels().save(to: directory.appendingPathComponent(name+".png")) }
        var results: [String: Any] = [:]
        try require(MemoryLayout<BatmanFrame>.stride == 48, "Illustration GPU ABI mismatch.")
        guard let url = Bundle.main.url(forResource: "Original", withExtension: "png", subdirectory: "BatmanArtwork"),
              let reference = NSBitmapImageRep(data: try Data(contentsOf: url)) else { throw MoltenError.failed("Missing original artwork.") }
        results["artwork_sha256"] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        results["artwork_size"] = [reference.pixelsWide, reference.pixelsHigh]
        if !args.contains("--preview-only") {
            // Independent image decoder verifies orientation, channel order,
            // color space and a native-size zero-motion view of the source.
            settings.intensity = 0; settings.sceneParameters = .zero; engine.reset()
            try draw(width: reference.pixelsWide, height: reference.pixelsHigh)
            let identity = try pixels(), bytes = [UInt8](identity.bytes)
            var totalError = 0.0, worst = 0, count = 0
            try require(reference.bitsPerSample == 8 && reference.samplesPerPixel >= 3 && !reference.isPlanar,
                        "Unexpected source image encoding.")
            for y in stride(from: 3, to: reference.pixelsHigh-3, by: 11) {
                for x in stride(from: 3, to: reference.pixelsWide-3, by: 11) {
                    // Compare the file's encoded sRGB samples directly.
                    // colorAt() would assign a calibrated NSColor space and
                    // introduce an unrelated second conversion.
                    var sample = [Int](repeating: 0, count: reference.samplesPerPixel)
                    reference.getPixel(&sample, atX: x, y: y)
                    let expected = [sample[2], sample[1], sample[0]]
                    let offset = (y*identity.width+x)*4
                    for channel in 0..<3 {
                        let error = abs(Int(bytes[offset+channel])-expected[channel])
                        totalError += Double(error); worst = max(worst,error); count += 1
                    }
                    try require(bytes[offset+3] == 255,"Artwork contains invalid output alpha.")
                }
            }
            let meanError = totalError/Double(count)
            try require(meanError < 0.6 && worst <= 3, "Original artwork changed colors or orientation: mean \(meanError), max \(worst).")
            results["source_pixel_fidelity"] = ["mean_channel_error_255":meanError,"max_channel_error_255":Double(worst),"samples":Double(count)]
            try image("batman-source-fidelity")
            try draw(width: 1925, height: 1200)
            let wide = [UInt8](try pixels().bytes)
            for y in stride(from: 120, to: 1100, by: 37) {
                for x in stride(from: 100, to: 860, by: 31) {
                    for channel in 0..<3 {
                        try require(abs(Int(wide[(y*1925+x+481)*4+channel])-Int(bytes[(y*963+x)*4+channel])) <= 3,
                                    "Wide windows stretched the original artwork.")
                    }
                }
            }
            results["aspect_ratio_preserved"] = true
            print("PASS source color/orientation fidelity and undistorted wide-window framing")
            settings = Settings(); settings.scene = .batman; settings.quality = 2
            var referenceState: [Float] = [], errors: [String:Float] = [:]
            for fps in [60,30,120] {
                engine.reset(); input = PointerState(); input.inside = true; input.down = true; input.position = SIMD2(0.78,0.47)
                for _ in 0..<fps { try draw(1/Float(fps)) }
                let q = try state()
                try require(engine.cinematic.batman.tick == 60,"Animation depends on display cadence.")
                if fps == 60 { referenceState = q } else {
                    let error = zip(q,referenceState).map { abs($0-$1) }.max() ?? 0
                    try require(q.count == referenceState.count && error < 0.00001,"Pointer response depends on display cadence.")
                    errors[String(fps)] = error
                }
            }
            engine.reset(); input = PointerState()
            for _ in 0..<60 { try draw(1/60) }
            let breeze = try state()
            try require(zip(breeze,referenceState).map { abs($0-$1) }.max()! > 0.01,"Pointer did not affect the painted cape.")
            for x in 0..<BatmanEngine.grid { try require(referenceState[x*2] == 0,"Page edge moved.") }
            results["cadence_errors"] = errors; results["pointer_response"] = true; results["page_edges_pinned"] = true
            print("PASS fixed 60 Hz motion, stable page edges and persistent cape interaction")
            engine.reset(); input = PointerState(); try draw(); let original = try pixels().bytes
            for _ in 0..<90 { try draw(1/60) }
            try require(try pixels().bytes != original,"The illustration did not animate.")
            let frozen = try state(); settings.paused = true; try draw(); let paused = try pixels().bytes
            try draw(1/30); try require(try pixels().bytes == paused && state() == frozen,"Pause advanced the artwork.")
            input.camera = SIMD4(0.3,0.2,0,0)
            try draw(width: 211,height: 263)
            for control in 0..<3 {
                settings.sceneParameters[control] = Scene.batman.controls[control].range.lowerBound
                try draw(); let low = try pixels().bytes
                settings.sceneParameters[control] = Scene.batman.controls[control].range.upperBound
                try draw(); try require(try pixels().bytes != low,"Paused illustration control \(control) had no effect.")
                try require(try state() == frozen,"Paused controls advanced the simulation.")
            }
            settings.intensity = 0; try draw(); let calm = try pixels().bytes
            settings.intensity = 2; try draw(); try require(try pixels().bytes != calm,"Paused wind tuning had no effect.")
            input.camera = SIMD4(0.6,0.6,-0.8,0); try draw(); let bounded = try pixels().bytes
            input.camera = SIMD4(20,20,-20,0); try draw()
            try require(try pixels().bytes == bounded,"Camera exceeded the finite artwork bounds.")
            results["pause_resize_tuning"] = true; results["bounded_camera"] = true
            settings = Settings(); settings.scene = .batman; settings.quality = 2; input = PointerState(); engine.reset(); try draw()
            try require(try pixels().bytes == original,"Reset did not restore the original frame.")
            for _ in 0..<180 { try draw(1/60) }
            let resources = engine.cinematic.resourceBytes
            for _ in 0..<120 { try draw(1/60) }
            try require(engine.cinematic.resourceBytes == resources,"Illustration allocations grew.")
            try require(resources < 16*1024*1024,"Illustration retained unnecessary 3D render resources.")
            results["stable_allocations_bytes"] = resources; results["reset_exact"] = true
            print("PASS frozen pause, immediate controls, bounded depth camera, exact reset and constant allocations")
        }
        settings = Settings(); settings.scene = .batman; settings.quality = 2; engine.reset(); input = PointerState()
        for _ in 0..<90 { try draw(1/60) }
        for preset in 0..<3 { settings.preset = preset; try draw(width:1440,height:1080); try image("batman-\(preset)") }
        settings.preset = 0; try draw(width:963,height:1200); try image("batman-portrait")
        input.camera = SIMD4(0.55,-0.3,0,0); try draw(width:1200,height:1000); try image("batman-depth")
        input.camera = SIMD4(0,0,-0.4,0); try draw(width:963,height:1200); try image("batman-detail")
        if args.contains("--movie") {
            let movieURL = directory.appendingPathComponent("batman-living-artwork.mov")
            try? FileManager.default.removeItem(at: movieURL)
            let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
            let movieWidth = 720, movieHeight = 898
            let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: movieWidth, AVVideoHeightKey: movieHeight,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30]
            ])
            track.expectsMediaDataInRealTime = false
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: movieWidth, kCVPixelBufferHeightKey as String: movieHeight
            ])
            writer.add(track); try require(writer.startWriting(),"Cannot start offscreen movie.")
            writer.startSession(atSourceTime: .zero)
            settings = Settings(); settings.scene = .batman; settings.quality = 2; input = PointerState(); engine.reset()
            for n in 0..<180 {
                try autoreleasepool {
                    let t = Float(n)/30
                    input.camera.x = t>2 ? 0.4*sin((t-2)*1.2) : 0
                    input.inside = true; input.down = t>4 && t<5; input.position = SIMD2(0.78,0.47)
                    try draw(1/30,width:movieWidth,height:movieHeight)
                    let frame = try pixels(); var pixelBuffer: CVPixelBuffer?
                    guard let pool = adapter.pixelBufferPool else { throw MoltenError.failed("No movie pixel pool.") }
                    try require(CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixelBuffer) == kCVReturnSuccess,"Movie allocation failed.")
                    guard let buffer = pixelBuffer else { throw MoltenError.failed("Missing movie pixel buffer.") }
                    CVPixelBufferLockBaseAddress(buffer,[])
                    let row = CVPixelBufferGetBytesPerRow(buffer), base = CVPixelBufferGetBaseAddress(buffer)!
                    frame.bytes.withUnsafeBytes { bytes in
                        for y in 0..<movieHeight { base.advanced(by:y*row).copyMemory(from:bytes.baseAddress!.advanced(by:y*movieWidth*4),byteCount:movieWidth*4) }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer,[])
                    let deadline = Date().addingTimeInterval(10)
                    while !track.isReadyForMoreMediaData && writer.status == .writing && Date()<deadline { Thread.sleep(forTimeInterval:0.003) }
                    try require(track.isReadyForMoreMediaData && adapter.append(buffer,withPresentationTime:CMTime(value:Int64(n),timescale:30)),"Movie encoding failed.")
                }
            }
            track.markAsFinished(); let done = DispatchSemaphore(value:0)
            writer.finishWriting { done.signal() }
            try require(done.wait(timeout:.now()+30) == .success && writer.status == .completed,"Movie did not finish.")
            results["movie_frames"] = 180
        }
        settings.scene = .liquid; try draw()
        try require(engine.cinematic.resourceBytes == 0,"Inactive illustration resources were retained.")
        results["resources_released"] = true
        let report: [String:Any] = ["all_passed":true,"preview_only":args.contains("--preview-only"),"device":engine.device.name,"results":results]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("batman-test.json"),options:.atomic)
        print("PASS original-art previews and complete scene resource release")
    }
}
