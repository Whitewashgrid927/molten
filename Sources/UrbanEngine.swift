import Foundation
import Metal
import MetalKit
import simd

struct UrbanFrame {
    var page = SIMD4<Float>.zero
    var touch = SIMD4<Float>.zero
    var clock = SIMD4<Float>.zero
}

// Two image-based scenes share one owner. Only the selected reference, mask and
// wave pair exist; there are no HDR histories, ray structures or per-frame loads.
final class UrbanEngine {
    static let grid = 192
    let device: MTLDevice
    private var compute: [String: MTLComputePipelineState] = [:]
    private let traffic: MTLRenderPipelineState
    private let trafficPass = MTLRenderPassDescriptor()
    private(set) var artwork: MTLTexture?
    private var mask: MTLTexture?
    private var waves: [MTLTexture] = []
    private var scene: Scene?
    private var initialized = false, maskReady = false
    private var accumulator: Float = 0
    private(set) var tick: UInt32 = 0
    var resourceBytes: Int { (artwork?.allocatedSize ?? 0) + (mask?.allocatedSize ?? 0) + waves.reduce(0) { $0 + $1.allocatedSize } }
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["urbanMasks", "urbanInitialize", "urbanFlow", "urbanRender"] {
            guard let function = library.makeFunction(name: name) else { throw MoltenError.failed("Missing urban shader: \(name)") }
            compute[name] = try device.makeComputePipelineState(function: function)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "urbanCarVertex")
        d.fragmentFunction = library.makeFunction(name: "urbanCarFragment")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm; a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.sourceAlphaBlendFactor = .zero; a.destinationAlphaBlendFactor = .one
        traffic = try device.makeRenderPipelineState(descriptor: d)
        trafficPass.colorAttachments[0].loadAction = .load
        trafficPass.colorAttachments[0].storeAction = .store
    }
    static func resourceName(_ scene: Scene) -> String { scene == .paperCity ? "PaperCity" : "GlassBlocks" }
    func reset() { initialized = false; tick = 0; accumulator = 0 }
    func releaseResources() {
        trafficPass.colorAttachments[0].texture = nil
        artwork = nil; mask = nil; waves.removeAll(); scene = nil; maskReady = false; reset()
    }
    private func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        guard let t = device.makeTexture(descriptor: d) else { throw MoltenError.failed("Could not allocate urban scene state.") }
        return t
    }
    private func prepare(_ selected: Scene) throws {
        guard scene != selected else { return }
        releaseResources()
        guard let url = Bundle.main.url(forResource: Self.resourceName(selected), withExtension: "png", subdirectory: "UrbanArtwork") else {
            throw MoltenError.failed("The original urban artwork is missing. Reinstall Molten.")
        }
        let image = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
            .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
        let factor = 512 / Float(max(image.width, image.height))
        let regions = try texture(max(1,Int(Float(image.width)*factor)),max(1,Int(Float(image.height)*factor)),.rgba16Float)
        let state = try (0..<2).map { _ in try texture(Self.grid,Self.grid,.rg32Float) }
        image.label = "Original \(selected.title) reference"
        regions.label = "Urban depth and pane boundaries"
        artwork = image; mask = regions; waves = state; scene = selected
    }
    private func frame(_ input: PointerState, _ u: Uniforms) -> UrbanFrame {
        var f = UrbanFrame()
        guard let artwork else { return f }
        let aspect = Float(artwork.width)/Float(artwork.height), screen = u.viewport.x/u.viewport.y
        let scale = SIMD2(max(1,screen/aspect),max(1,aspect/screen))*exp(min(0.8,max(-0.8,input.camera.z)))
        f.page = SIMD4(scale.x,scale.y,min(0.6,max(-0.6,input.camera.x)),min(0.6,max(-0.6,input.camera.y)))
        let point = (input.position-SIMD2(repeating:0.5))*scale+SIMD2(repeating:0.5)
        let inside = input.inside && point.x>=0 && point.y>=0 && point.x<=1 && point.y<=1
        f.touch = SIMD4(point.x,point.y,inside && input.down ? 1:0,min(1,simd_length(input.delta)*30))
        f.clock = SIMD4(Float(tick)/60,1/60,Float(artwork.width),Float(artwork.height))
        return f
    }
    private func run(_ name: String, command: MTLCommandBuffer, size: MTLSize, u: Uniforms, f: UrbanFrame, textures: [MTLTexture]) throws {
        guard let p = compute[name], let e = command.makeComputeCommandEncoder() else { throw MoltenError.failed("Cannot encode \(name).") }
        var u=u, f=f
        e.label = name; e.setComputePipelineState(p)
        e.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
        e.setBytes(&f,length:MemoryLayout<UrbanFrame>.stride,index:1)
        for (i,t) in textures.enumerated() { e.setTexture(t,index:i) }
        e.dispatchThreads(size,threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)); e.endEncoding()
    }
    func encode(command: MTLCommandBuffer, image: MTLTexture, u: Uniforms, settings: Settings, input: PointerState, dt: Float) throws {
        try prepare(settings.scene)
        guard let artwork, let mask else { throw MoltenError.failed("Urban image resources were not prepared.") }
        let grid = MTLSize(width:Self.grid,height:Self.grid,depth:1)
        var f = frame(input,u)
        if !maskReady {
            try run("urbanMasks",command:command,size:MTLSize(width:mask.width,height:mask.height,depth:1),u:u,f:f,textures:[artwork,mask]); maskReady=true
        }
        if !initialized { try run("urbanInitialize",command:command,size:grid,u:u,f:f,textures:waves); initialized=true }
        accumulator += settings.paused ? 0 : min(max(dt,0),1/15)
        let steps = min(4,Int((accumulator+0.000001)*60))
        accumulator = max(0,accumulator-Float(steps)/60)
        for _ in 0..<steps {
            f = frame(input,u)
            try run("urbanFlow",command:command,size:grid,u:u,f:f,textures:[waves[0],waves[1],mask])
            waves.swapAt(0,1); tick &+= 1
        }
        f = frame(input,u)
        try run("urbanRender",command:command,size:MTLSize(width:image.width,height:image.height,depth:1),u:u,f:f,textures:[artwork,mask,waves[0],image])
        if settings.scene == .paperCity && settings.sceneParameters.x > 0 {
            trafficPass.colorAttachments[0].texture = image
            defer { trafficPass.colorAttachments[0].texture = nil }
            guard let e = command.makeRenderCommandEncoder(descriptor:trafficPass) else { throw MoltenError.failed("Could not render city traffic.") }
            var u=u
            e.label = "Small ink traffic along drawn streets"; e.setRenderPipelineState(traffic)
            e.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
            e.setVertexBytes(&f,length:MemoryLayout<UrbanFrame>.stride,index:1)
            e.setVertexTexture(mask,index:0);e.setVertexTexture(waves[0],index:1)
            e.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:36)
            e.endEncoding()
        }
    }
    // Verification-only state inspection. The interactive path has no readback.
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let t = waves.first else { return [] }
        let row=Self.grid*8, bytes=row*Self.grid
        guard let b=device.makeBuffer(length:bytes,options:.storageModeShared),let c=queue.makeCommandBuffer(),let e=c.makeBlitCommandEncoder() else {
            throw MoltenError.failed("Could not inspect urban state.")
        }
        e.copy(from:t,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:Self.grid,height:Self.grid,depth:1),to:b,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:bytes)
        e.endEncoding();c.commit();c.waitUntilCompleted();if let error=c.error{throw error}
        return Array(UnsafeBufferPointer(start:b.contents().assumingMemoryBound(to:Float.self),count:bytes/4))
    }
}
