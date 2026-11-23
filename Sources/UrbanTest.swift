import AppKit
import Metal
import CryptoKit
import simd

// Tests the actual GPU image path without an application or window.
enum UrbanTest {
    static func run() throws {
        let args=CommandLine.arguments,i=args.firstIndex(of:"--output")
        let directory=URL(fileURLWithPath:i.flatMap {args.indices.contains($0+1) ? args[$0+1]:nil} ?? "/tmp/molten-urban")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let engine=try MetalEngine();var settings=Settings(),input=PointerState(),frame:UInt32=0
        func require(_ value:Bool,_ why:String)throws{if !value{throw MoltenError.failed(why)}}
        func draw(_ dt:Float=0,width:Int=192,height:Int=144)throws{
            try autoreleasepool{
                guard let c=engine.queue.makeCommandBuffer()else{throw MoltenError.failed("No urban test command.")}
                _=try engine.encode(command:c,width:width,height:height,time:Float(engine.cinematic.urban.tick)/60+dt,dt:dt,frame:frame,settings:settings,input:input)
                c.commit();c.waitUntilCompleted();frame &+= 1
                try require(c.status == .completed && c.error == nil,"Urban GPU failure: \(String(describing:c.error))")
            }
        }
        func state()throws->[Float]{try engine.cinematic.urban.snapshot(queue:engine.queue)}
        func pixels()throws->PixelImage{try engine.readback(engine.output!)}
        func save(_ name:String)throws{try pixels().save(to:directory.appendingPathComponent(name+".png"))}
        try require(MemoryLayout<UrbanFrame>.stride==48,"Urban uniform ABI mismatch.")
        var results:[[String:Any]]=[]
        for scene in [Scene.paperCity,.glassBlocks] {
            var row:[String:Any]=["scene":scene.title,"key":scene.key]
            settings=Settings();settings.scene=scene;settings.quality=2;input=PointerState();engine.reset()
            guard let url=Bundle.main.url(forResource:UrbanEngine.resourceName(scene),withExtension:"png",subdirectory:"UrbanArtwork"),
                  let reference=NSBitmapImageRep(data:try Data(contentsOf:url))else{throw MoltenError.failed("Missing source image.")}
            row["source_sha256"]=SHA256.hash(data:try Data(contentsOf:url)).map {String(format:"%02x",$0)}.joined()
            let width=reference.pixelsWide,height=reference.pixelsHigh
            row["source_size"]=[width,height]
            let testHeight=scene == .paperCity ? 360:144
            if !args.contains("--preview-only") {
                settings.intensity=0;settings.sceneParameters = .zero
                try draw(width:width,height:height)
                let identity=[UInt8](try pixels().bytes)
                try require(reference.bitsPerSample==8 && reference.samplesPerPixel>=3 && !reference.isPlanar,"Unexpected reference encoding.")
                var errorSum=0.0,worst=0,samples=0
                for y in stride(from:3,to:height-3,by:11){for x in stride(from:3,to:width-3,by:11){
                    var sample=[Int](repeating:0,count:reference.samplesPerPixel);reference.getPixel(&sample,atX:x,y:y)
                    for channel in 0..<3 {
                        let error=abs(Int(identity[(y*width+x)*4+channel])-sample[2-channel])
                        errorSum+=Double(error);worst=max(worst,error);samples+=1
                    }
                }}
                let mean=errorSum/Double(samples)
                try require(mean<0.6 && worst<=3,"Reference fidelity failed for \(scene.title): mean \(mean), max \(worst).")
                row["source_pixel_fidelity"]=["mean_channel_error_255":mean,"max_channel_error_255":Double(worst),"samples":Double(samples)]
                try save(scene.key+"-source-fidelity")
                try draw(width:width+200,height:height);let wide=[UInt8](try pixels().bytes)
                for y in stride(from:20,to:height-20,by:31){for x in stride(from:20,to:width-20,by:29){for c in 0..<3{
                    try require(abs(Int(identity[(y*width+x)*4+c])-Int(wide[(y*(width+200)+x+100)*4+c]))<=3,"Reference aspect ratio changed.")
                }}}
                row["aspect_ratio_preserved"]=true
                settings=Settings();settings.scene=scene;settings.quality=2
                var referenceState:[Float]=[],errors:[String:Float]=[:]
                for fps in [60,30,120] {
                    engine.reset();input=PointerState();input.inside=true;input.down=true
                    input.position=scene == .paperCity ? SIMD2(0.62,0.78):SIMD2(0.67,0.48)
                    for _ in 0..<fps{try draw(1/Float(fps),height:testHeight)}
                    let q=try state();try require(engine.cinematic.urban.tick==60,"Urban motion depends on display cadence.")
                    if fps==60{referenceState=q}else{
                        let error=zip(q,referenceState).map{abs($0-$1)}.max() ?? 0
                        try require(q.count==referenceState.count && error<0.00001,"Urban cadence parity failed.");errors[String(fps)]=error
                    }
                }
                engine.reset();input=PointerState()
                for _ in 0..<60{try draw(1/60,height:testHeight)}
                try require(zip(try state(),referenceState).map{abs($0-$1)}.max()!>0.01,"Pointer did not disturb \(scene.title).")
                row["cadence_errors"]=errors;row["pointer_response"]=true
                if scene == .glassBlocks {
                    for y in 0..<UrbanEngine.grid {for seam:Float in [0.2375,0.535,0.8175]{
                        let x=Int(seam*Float(UrbanEngine.grid));try require(referenceState[(y*UrbanEngine.grid+x)*2]==0,"A ripple crossed a vertical glass joint.")
                    }}
                    for x in 0..<UrbanEngine.grid {for seam:Float in [0.290,0.694]{
                        let y=Int(seam*Float(UrbanEngine.grid));try require(referenceState[(y*UrbanEngine.grid+x)*2]==0,"A ripple crossed a horizontal glass joint.")
                    }}
                    try draw(width:width,height:height);let animated=[UInt8](try pixels().bytes)
                    for x in [285,642,981]{for y in stride(from:10,to:height-10,by:13){for c in 0..<3{
                        try require(animated[(y*width+x)*4+c]==identity[(y*width+x)*4+c],"Glass animation moved a structural joint.")
                    }}}
                    for y in [254,608]{for x in stride(from:10,to:width-10,by:13){for c in 0..<3{
                        try require(animated[(y*width+x)*4+c]==identity[(y*width+x)*4+c],"Glass animation moved a structural joint.")
                    }}}
                    row["pane_isolation_and_fixed_seams"]=true
                }
                engine.reset();input=PointerState();try draw(height:testHeight);let original=try pixels().bytes
                for _ in 0..<90{try draw(1/60,height:testHeight)}
                try require(try pixels().bytes != original,"Urban scene did not animate.")
                let frozen=try state();settings.paused=true;try draw(height:testHeight);let paused=try pixels().bytes
                try draw(1/30,height:testHeight)
                try require(try pixels().bytes==paused && state()==frozen,"Pause advanced an urban scene.")
                input.camera=SIMD4(0.4,0.2,0,0);try draw(width:213,height:161)
                for index in 0..<3{
                    settings.sceneParameters[index]=scene.controls[index].range.lowerBound;try draw(height:testHeight);let low=try pixels().bytes
                    settings.sceneParameters[index]=scene.controls[index].range.upperBound;try draw(height:testHeight)
                    try require(try pixels().bytes != low,"Urban control \(scene.controls[index].title) had no effect.")
                    try require(try state()==frozen,"Paused urban tuning advanced simulation.")
                }
                settings.intensity=0;try draw(height:testHeight);let low=try pixels().bytes
                settings.intensity=2;try draw(height:testHeight);try require(try pixels().bytes != low,"Urban primary control had no effect.")
                input.camera=SIMD4(0.6,0.6,-0.8,0);try draw(height:testHeight);let bounded=try pixels().bytes
                input.camera=SIMD4(20,20,-20,0);try draw(height:testHeight)
                try require(try pixels().bytes==bounded,"Urban camera escaped its bounded range.")
                row["pause_resize_tuning"]=true;row["bounded_camera"]=true
                settings=Settings();settings.scene=scene;settings.quality=2;input=PointerState();engine.reset();try draw(height:testHeight)
                try require(try pixels().bytes==original,"Urban reset was not exact.")
                for _ in 0..<120{try draw(1/60,height:testHeight)}
                let allocation=engine.cinematic.resourceBytes
                for _ in 0..<120{try draw(1/60,height:testHeight)}
                try require(allocation==engine.cinematic.resourceBytes && allocation<16*1024*1024,"Urban scene grew or retained unnecessary GPU storage.")
                row["stable_allocations_bytes"]=allocation;row["reset_exact"]=true
                print("PASS \(scene.title): source fidelity, aspect ratio, cadence, input, pause, tuning, bounds, reset and stable allocations")
            }
            settings=Settings();settings.scene=scene;settings.quality=2;input=PointerState();engine.reset()
            for _ in 0..<90{try draw(1/60,height:testHeight)}
            for preset in 0..<3 {settings.preset=preset;try draw(width:width,height:height);try save(scene.key+"-\(preset)")}
            settings.preset=0;try draw(width:1440,height:1000);try save(scene.key+"-wide")
            input.camera=SIMD4(0.5,-0.3,-0.18,0);input.inside=true;input.down=true;input.position=SIMD2(0.67,0.48)
            for _ in 0..<30{try draw(1/60,width:width,height:height)}
            try save(scene.key+"-interaction")
            if args.contains("--movie") {
                let mw=scene == .paperCity ? 564:960,mh=scene == .paperCity ? 1056:702
                let movie=try OffscreenMovie(url:directory.appendingPathComponent(scene.key+".mov"),width:mw,height:mh)
                settings=Settings();settings.scene=scene;settings.quality=2;input=PointerState();engine.reset()
                for n in 0..<180 {
                    try autoreleasepool {
                        let time=Float(n)/30
                        input.camera.x=time>2 ? 0.4*sin((time-2)*1.2):0
                        input.camera.y=time>2 ? -0.2*sin((time-2)*0.8):0
                        input.inside=true;input.down=time>3 && time<5
                        input.position=scene == .paperCity ? SIMD2(0.6,0.75):SIMD2(0.64+0.08*sin(time*1.5),0.47)
                        input.delta=input.down ? SIMD2(0.002,0.001):.zero
                        try draw(1/30,width:mw,height:mh);try movie.append(pixels())
                    }
                }
                try movie.finish();row["movie_frames"]=movie.frames
            }
            settings.scene = .liquid;try draw()
            try require(engine.cinematic.resourceBytes==0,"Inactive urban resources were retained.")
            row["resources_released"]=true;results.append(row)
        }
        let report:[String:Any]=["all_passed":true,"preview_only":args.contains("--preview-only"),"results":results,"device":engine.device.name]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("urban-test.json"),options:.atomic)
        print("PASS both original-image scenes and complete resource release")
    }
}
