import Foundation
import ImageIO
import Metal
import simd

struct GlassEffectFrame {
    var page = SIMD4<Float>.zero
    var touch = SIMD4<Float>.zero
    var optics = SIMD4<Float>.zero
    var clock = SIMD4<Float>.zero
}

// The source is decoded only on import/entry, with orientation and sRGB conversion.
// No original-resolution CPU bitmap, image cache, or per-frame readback is retained.
enum GlassImageLoader {
    static let maximumDimension = 2048
    static func decode(_ url: URL) throws -> CGImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 32768, h <= 32768, Int64(w)*Int64(h) <= 200_000_000 else {
            throw MoltenError.failed("Choose a readable image up to 200 megapixels for the glass.")
        }
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maximumDimension,
            kCGImageSourceShouldCacheImmediately:true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary),
              let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw MoltenError.failed("This image could not be decoded for the glass.")
        }
        context.setFillColor(CGColor(srgbRed:0.9,green:0.92,blue:0.93,alpha:1))
        context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let result = context.makeImage() else {throw MoltenError.failed("Could not prepare the image.")}
        return result
    }
}

final class GlassEffectEngine {
    static let grid = 256
    let device: MTLDevice
    private let pipelines: [String:MTLComputePipelineState]
    private(set) var artwork: MTLTexture?
    private var waves: [MTLTexture] = []
    private var initialized = false
    private var accumulator: Float = 0
    private var columns = 0, rows = 0
    private(set) var tick: UInt32 = 0
    private(set) var sourceURL: URL?
    private(set) var revision: UInt32 = 0
    var resourceBytes: Int {(artwork?.allocatedSize ?? 0)+waves.reduce(0){$0+$1.allocatedSize}}
    static var defaultURL: URL? {Bundle.main.url(forResource:"Default",withExtension:"png",subdirectory:"GlassEffect")}
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device=device
        var p: [String:MTLComputePipelineState]=[:]
        for name in ["blockInitialize","blockFlow","blockRender"] {
            guard let f=library.makeFunction(name:name) else {throw MoltenError.failed("Missing glass filter: \(name)")}
            p[name]=try device.makeComputePipelineState(function:f)
        }
        pipelines=p
    }
    private func load(_ url:URL)throws->MTLTexture {
        let image=try GlassImageLoader.decode(url)
        // Upload known sRGB BGRA bytes explicitly. The display-space shader
        // consumes these bytes directly, without another image-loader conversion.
        guard let provider=image.dataProvider,let data=provider.data else {throw MoltenError.failed("Missing decoded image bytes.")}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:image.width,height:image.height,mipmapped:true)
        d.storageMode = .private;d.usage = .shaderRead
        let row=(image.width*4+255) & ~255
        guard let texture=device.makeTexture(descriptor:d),
              let staging=device.makeBuffer(length:row*image.height,options:.storageModeShared),
              let queue=device.makeCommandQueue(),let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder(),
              let bytes=CFDataGetBytePtr(data) else {throw MoltenError.failed("Could not upload the glass image.")}
        for y in 0..<image.height {staging.contents().advanced(by:y*row).copyMemory(from:bytes.advanced(by:y*image.bytesPerRow),byteCount:image.width*4)}
        blit.copy(from:staging,sourceOffset:0,sourceBytesPerRow:row,sourceBytesPerImage:row*image.height,
                  sourceSize:MTLSize(width:image.width,height:image.height,depth:1),to:texture,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin())
        blit.generateMipmaps(for:texture);blit.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed, command.error == nil else {throw command.error ?? MoltenError.failed("Glass image upload failed.")}
        texture.label="Glass background, bounded to 2048 pixels"
        return texture
    }
    // Decode before replacing anything. An invalid drop leaves the current picture intact.
    func setImage(_ url:URL?)throws {
        guard let selected=url ?? Self.defaultURL else {throw MoltenError.failed("Missing glass background.")}
        let texture=try load(selected)
        artwork=texture;sourceURL=url;revision &+= 1;reset()
    }
    func reset(){initialized=false;accumulator=0;tick=0}
    func releaseResources(){artwork=nil;waves.removeAll();columns=0;rows=0;reset()}
    private func prepare()throws {
        if artwork==nil {
            if let url=sourceURL,let texture=try? load(url){artwork=texture}
            else {try setImage(nil)}
        }
        if waves.isEmpty {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg32Float,width:Self.grid,height:Self.grid,mipmapped:false)
            d.storageMode = .private;d.usage=[.shaderRead,.shaderWrite]
            waves=try (0..<2).map{_ in
                guard let t=device.makeTexture(descriptor:d) else {throw MoltenError.failed("Cannot allocate glass ripples.")};return t
            }
        }
    }
    private func run(_ name:String,command:MTLCommandBuffer,width:Int,height:Int,u:Uniforms,f:GlassEffectFrame,textures:[MTLTexture])throws {
        guard let p=pipelines[name],let e=command.makeComputeCommandEncoder()else{throw MoltenError.failed("Cannot encode \(name).")}
        var u=u,f=f;e.label=name;e.setComputePipelineState(p)
        e.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0);e.setBytes(&f,length:MemoryLayout<GlassEffectFrame>.stride,index:1)
        for (i,t) in textures.enumerated(){e.setTexture(t,index:i)}
        e.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1));e.endEncoding()
    }
    func encode(command:MTLCommandBuffer,image:MTLTexture,u:Uniforms,settings:Settings,input:PointerState,dt:Float)throws {
        try prepare();guard let artwork else{throw MoltenError.failed("Missing glass source.")}
        let aspect=Float(artwork.width)/Float(artwork.height),screen=u.viewport.x/u.viewport.y
        let newColumns=Int(min(8,max(2,settings.sceneParameters.z.rounded())))
        let newRows=max(2,min(12,Int((Float(newColumns)/aspect).rounded())))
        if columns != newColumns || rows != newRows {columns=newColumns;rows=newRows;reset()}
        let scale=SIMD2(max(1,screen/aspect),max(1,aspect/screen))*exp(min(0.8,max(-0.8,input.camera.z)))
        let point=(input.position-SIMD2(repeating:0.5))*scale+SIMD2(repeating:0.5)
        var f=GlassEffectFrame()
        f.page=SIMD4(scale.x,scale.y,min(0.6,max(-0.6,input.camera.x)),min(0.6,max(-0.6,input.camera.y)))
        f.touch=SIMD4(point.x,point.y,input.inside && input.down && point.x>=0 && point.x<=1 && point.y>=0 && point.y<=1 ? 1:0,min(1,simd_length(input.delta)*30))
        f.optics=SIMD4(Float(columns),Float(rows),Float(artwork.width),Float(artwork.height))
        f.clock=SIMD4(Float(tick)/60,1/60,Float(revision),0)
        if !initialized{try run("blockInitialize",command:command,width:Self.grid,height:Self.grid,u:u,f:f,textures:waves);initialized=true}
        accumulator += settings.paused ? 0:min(max(0,dt),1/15)
        let steps=min(4,Int((accumulator+0.000001)*60));accumulator=max(0,accumulator-Float(steps)/60)
        for _ in 0..<steps {
            f.clock.x=Float(tick)/60
            try run("blockFlow",command:command,width:Self.grid,height:Self.grid,u:u,f:f,textures:[waves[0],waves[1]])
            waves.swapAt(0,1);tick &+= 1
        }
        f.clock.x=Float(tick)/60
        try run("blockRender",command:command,width:image.width,height:image.height,u:u,f:f,textures:[artwork,waves[0],image])
    }
    func snapshot(queue:MTLCommandQueue)throws->[Float] {
        guard let texture=waves.first else{return []}
        let row=Self.grid*8,bytes=row*Self.grid
        guard let b=device.makeBuffer(length:bytes,options:.storageModeShared),let c=queue.makeCommandBuffer(),let e=c.makeBlitCommandEncoder()else{throw MoltenError.failed("Cannot inspect glass state.")}
        e.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:Self.grid,height:Self.grid,depth:1),to:b,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:bytes)
        e.endEncoding();c.commit();c.waitUntilCompleted();if let error=c.error{throw error}
        return Array(UnsafeBufferPointer(start:b.contents().assumingMemoryBound(to:Float.self),count:bytes/4))
    }
}
