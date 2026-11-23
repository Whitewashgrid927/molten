import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import simd

enum GlassEffectTest {
    static func run()throws {
        let args=CommandLine.arguments,i=args.firstIndex(of:"--output")
        let dir=URL(fileURLWithPath:i.flatMap{args.indices.contains($0+1) ? args[$0+1]:nil} ?? "/tmp/molten-glass-effect")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let engine=try MetalEngine();let glass=engine.cinematic.glassEffect
        var settings=Settings(),input=PointerState(),frame:UInt32=0
        settings.scene = .blockGlass;settings.quality=2
        func require(_ value:Bool,_ why:String)throws{if !value{throw MoltenError.failed(why)}}
        func draw(_ dt:Float=0,width:Int=360,height:Int=240)throws {
            try autoreleasepool {
                guard let c=engine.queue.makeCommandBuffer()else{throw MoltenError.failed("No glass test command.")}
                _=try engine.encode(command:c,width:width,height:height,time:Float(glass.tick)/60+dt,dt:dt,frame:frame,settings:settings,input:input)
                c.commit();c.waitUntilCompleted();frame &+= 1
                try require(c.status == .completed && c.error==nil,"Glass GPU failed: \(String(describing:c.error))")
            }
        }
        func pixels()throws->PixelImage{try engine.readback(engine.output!)}
        func save(_ name:String)throws{try pixels().save(to:dir.appendingPathComponent(name+".png"))}
        func state()throws->[Float]{try glass.snapshot(queue:engine.queue)}
        var result:[String:Any]=[:]
        try require(MemoryLayout<GlassEffectFrame>.stride==64,"Glass frame ABI mismatch.")
        guard let original=GlassEffectEngine.defaultURL else{throw MoltenError.failed("Missing glass default image.")}
        result["default_source_sha256"]=SHA256.hash(data:try Data(contentsOf:original)).map{String(format:"%02x",$0)}.joined()
        if !args.contains("--preview-only") {
            // Zero refraction is a true bypass. Check encoded RGB against an independent decoder.
            settings.intensity=0
            let decoded=try GlassImageLoader.decode(original),ref=NSBitmapImageRep(data:try Data(contentsOf:original))!
            try draw(width:decoded.width,height:decoded.height);let bypass=[UInt8](try pixels().bytes)
            var total=0,worst=0,count=0
            for y in stride(from:3,to:decoded.height-3,by:19){for x in stride(from:3,to:decoded.width-3,by:19){
                var sample=[Int](repeating:0,count:ref.samplesPerPixel);ref.getPixel(&sample,atX:x,y:y)
                for c in 0..<3{let error=abs(Int(bypass[(y*decoded.width+x)*4+c])-sample[2-c]);total+=error;worst=max(worst,error);count+=1}
            }}
            try require(worst<=3,"Glass bypass changed source orientation/color: \(worst).")
            result["bypass_mean_error_255"]=Double(total)/Double(count);result["bypass_max_error_255"]=worst
            try save("glass-effect-before")
            settings.intensity=1;engine.reset();try draw(width:1200,height:800)
            let joints=[UInt8](try pixels().bytes)
            for _ in 0..<60{try draw(1/60,width:1200,height:800)}
            let moved=[UInt8](try pixels().bytes)
            for x in [300,600,900]{for y in stride(from:20,to:780,by:31){for c in 0..<3{
                try require(joints[(y*1200+x)*4+c]==moved[(y*1200+x)*4+c] && moved[(y*1200+x)*4+c]<12,"Generated glass joints moved or vanished.")
            }}}
            result["generated_joints_stay_fixed"]=true
            var baseline:[Float]=[],errors:[String:Float]=[:]
            for fps in [60,30,120] {
                engine.reset();input=PointerState();input.inside=true;input.down=true;input.position=SIMD2(0.125,Float(1)/6)
                for _ in 0..<fps{try draw(1/Float(fps))}
                let q=try state();try require(glass.tick==60,"Glass speed depends on display cadence.")
                if fps==60{baseline=q}else{let e=zip(q,baseline).map{abs($0-$1)}.max()!;errors[String(fps)]=e;try require(e<0.00001,"Glass cadence parity failed.")}
            }
            try require(baseline.map{abs($0)}.max()!>0.01,"Touch did not inject a glass ripple.")
            for y in 0..<GlassEffectEngine.grid {for x in 0..<GlassEffectEngine.grid {
                if Int((Float(x)+0.5)/256*4) != 0 || Int((Float(y)+0.5)/256*3) != 0 {
                    try require(baseline[(y*256+x)*2]==0 && baseline[(y*256+x)*2+1]==0,"Ripple leaked into another glass block.")
                }
            }}
            result["cadence_errors"]=errors;result["touch_isolated_to_one_pane"]=true
            settings.paused=true;input=PointerState();try draw();let frozen=try state(),still=try pixels().bytes
            try draw(1/30);try require(try state()==frozen && pixels().bytes==still,"Paused glass evolved.")
            input.camera=SIMD4(0.4,-0.3,-0.2,0);try draw(width:417,height:283)
            try require(try state()==frozen && pixels().bytes != still,"Paused glass camera failed.")
            for index in 0..<2 {
                settings.sceneParameters[index]=Scene.blockGlass.controls[index].range.lowerBound;try draw();let low=try pixels().bytes
                settings.sceneParameters[index]=Scene.blockGlass.controls[index].range.upperBound;try draw()
                try require(try pixels().bytes != low && state()==frozen,"Glass material control did not redraw without advancing time.")
            }
            settings.sceneParameters.z=8;try draw();try require(try state().allSatisfy{$0==0},"Changing block layout retained old ripples.")
            result["pause_tuning_resize_layout"]=true
            input.camera=SIMD4(0.6,0.6,-0.8,0);try draw();let bounded=try pixels().bytes
            input.camera=SIMD4(20,20,-20,0);try draw();try require(try pixels().bytes==bounded,"Glass camera bounds failed.")
            result["bounded_camera"]=true
            // Create small synthetic images for the actual import path, with a known orientation.
            let fixture=dir.appendingPathComponent("import-fixture.png")
            func makeImage(_ width:Int,_ height:Int)throws->CGImage {
                guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw MoltenError.failed("Fixture context failed.")}
                c.setFillColor(CGColor(srgbRed:0.1,green:0.2,blue:0.9,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
                c.setFillColor(CGColor(srgbRed:0.9,green:0.15,blue:0.1,alpha:1));c.fill(CGRect(x:0,y:height/2,width:width/2,height:height-height/2))
                return c.makeImage()!
            }
            func writeImage(_ image:CGImage,_ url:URL,orientation:Int=1,type:CFString=UTType.png.identifier as CFString)throws {
                guard let dest=CGImageDestinationCreateWithURL(url as CFURL,type,1,nil)else{throw MoltenError.failed("Fixture writer failed.")}
                CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:orientation] as CFDictionary)
                try require(CGImageDestinationFinalize(dest),"Fixture encoding failed.")
            }
            try writeImage(makeImage(128,96),fixture)
            settings=Settings();settings.scene = .blockGlass;settings.quality=2;input=PointerState();engine.reset()
            try glass.setImage(fixture);try draw(width:128,height:96)
            try require(glass.artwork?.width==128 && glass.artwork?.height==96,"Imported picture was not used.")
            let revision=glass.revision,texture=glass.artwork
            do{try glass.setImage(dir.appendingPathComponent("does-not-exist.png"));throw MoltenError.failed("Invalid image accepted.")}
            catch{try require(glass.revision==revision && glass.artwork === texture,"Invalid import replaced the current image.")}
            let rotated=dir.appendingPathComponent("rotated-fixture.jpg")
            try writeImage(makeImage(128,96),rotated,orientation:6,type:UTType.jpeg.identifier as CFString)
            let r=try GlassImageLoader.decode(rotated),bitmap=NSBitmapImageRep(cgImage:r)
            try require(r.width==96 && r.height==128,"EXIF orientation was ignored.")
            let corner=bitmap.colorAt(x:80,y:16)!.usingColorSpace(.sRGB)!
            try require(corner.redComponent>0.7 && corner.blueComponent<0.32,"EXIF rotation placed the corner incorrectly.")
            let large=dir.appendingPathComponent("large-fixture.png");try writeImage(makeImage(4096,32),large)
            let small=try GlassImageLoader.decode(large);try require(small.width==2048 && small.height==16,"Import was not downsampled before texture creation.")
            settings.scene = .liquid;try draw();try require(glass.resourceBytes==0,"Glass import resources survived scene exit.")
            settings.scene = .blockGlass;try draw();try require(glass.sourceURL==fixture && glass.artwork?.width==128,"Chosen image was lost on scene reentry.")
            settings.scene = .liquid;try draw();try FileManager.default.removeItem(at:fixture)
            settings.scene = .blockGlass;try draw();try require(glass.sourceURL==nil && glass.artwork?.width==decoded.width,"Missing import did not recover to the bundled image.")
            try glass.setImage(nil);engine.reset();try draw();let initial=try pixels().bytes
            for _ in 0..<120{try draw(1/60)}
            let allocation=glass.resourceBytes
            for _ in 0..<120{try draw(1/60)}
            try require(allocation==glass.resourceBytes && allocation<32*1024*1024,"Glass resources grew or exceeded budget.")
            engine.reset();try draw();try require(try pixels().bytes==initial,"Glass reset did not restore its initial state.")
            result["image_import_orientation_downsample"]=true;result["failed_import_preserves_image"]=true
            result["scene_reentry_and_missing_file_recovery"]=true;result["stable_allocations_bytes"]=allocation;result["reset_exact"]=true
            print("PASS glass filter: bypass fidelity, fixed joints, isolated ripples, cadence, pause, controls, image import, orientation, bounds and resource lifetime")
        }
        settings=Settings();settings.scene = .blockGlass;settings.quality=2;input=PointerState();try glass.setImage(nil);engine.reset()
        for _ in 0..<90{try draw(1/60)}
        for preset in 0..<3 {settings.preset=preset;try draw(width:1440,height:960);try save("glass-effect-\(preset)")}
        settings.preset=0;input.camera=SIMD4(0.45,-0.3,0,0);input.inside=true;input.down=true;input.position=SIMD2(0.64,0.49)
        for _ in 0..<30{try draw(1/60,width:1440,height:960)}
        try save("glass-effect-interaction")
        if args.contains("--movie") {
            let movie=try OffscreenMovie(url:dir.appendingPathComponent("glass-effect.mov"),width:1200,height:800)
            settings=Settings();settings.scene = .blockGlass;settings.quality=2;input=PointerState();engine.reset()
            for n in 0..<180 {
                try autoreleasepool {
                    let t=Float(n)/30
                    settings.intensity=min(1,max(0,t-0.6)/0.9)
                    input.camera=SIMD4(t>2 ? 0.45*sin((t-2)*1.1):0,t>2 ? -0.3*sin((t-2)*0.8):0,0,0)
                    input.down=t>1 && t<4.7;input.inside=true;input.position=SIMD2(0.63+0.045*sin(t*2),0.48+0.04*cos(t*2));input.delta=SIMD2(0.003,0.002)
                    try draw(1/30,width:1200,height:800);try movie.append(pixels())
                }
            }
            try movie.finish();result["movie_frames"]=movie.frames
        }
        settings.scene = .liquid;try draw();try require(glass.resourceBytes==0,"Inactive glass resources retained.");result["resources_released"]=true
        let report:[String:Any]=["all_passed":true,"preview_only":args.contains("--preview-only"),"device":engine.device.name,"results":result]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("glass-effect-test.json"),options:.atomic)
        print("PASS glass effect and complete resource release")
    }
}
