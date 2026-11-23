import Foundation
import Metal
import MetalFX
import simd

struct RiverFrame {
    var viewProjection = matrix_identity_float4x4
    var previousViewProjection = matrix_identity_float4x4
    var jitter = SIMD4<Float>(repeating: 0)
    var counts = SIMD4<UInt32>(repeating: 0)
}

// Active-scene-only simulation, geometry, ray tracing, and MetalFX ownership.
final class RiverEngine {
    private let device: MTLDevice
    private var compute: [String: MTLComputePipelineState] = [:]
    private let organismPipeline: MTLRenderPipelineState
    private var surface: [MTLTexture] = [], flow: [MTLTexture] = [], bloom: [MTLTexture] = []
    private var targets: [MTLTexture] = []
    private var bathymetry: MTLTexture?
    private var denoised: MTLTexture?
    private var fog: MTLTexture?
    private var exposure: MTLTexture?
    private var denoiser: MTLFXTemporalDenoisedScaler?
    private var organisms: MTLBuffer?
    private var world: RiverWorld?
    private var quality = -1
    private var initialized = false, historyValid = false
    private var accumulator: Float = 0
    private var previousDown = false, pendingImpulse = false
    private var pendingDelta = SIMD2<Float>(repeating: 0)
    private var previousVP = matrix_identity_float4x4
    private var previousTime: Float = 0
    private var previousCamera = SIMD4<Float>(repeating: 0)
    private var previousSettings: [Float] = []
    private var renderIndex: UInt32 = 0
    private var particleCount = 0
    private(set) var tick: UInt32 = 0
    private(set) var gridWidth = 0, gridHeight = 0
    private(set) var usesMetalFX = false
    var triangleCount: Int { world?.triangleCount ?? 0 }
    var leafCount: Int { world?.leafCount ?? 0 }
    var treeCount: Int { world?.treeCount ?? 0 }
    var organismCount: Int { particleCount }
    var scannedMaterialCount: Int { world?.materials.first?.arrayLength ?? 0 }
    var resourceBytes: Int {
        var bytes = (organisms?.length ?? 0) + (world?.resourceBytes ?? 0) + (denoised?.allocatedSize ?? 0)
        bytes += (bathymetry?.allocatedSize ?? 0) + (fog?.allocatedSize ?? 0) + (exposure?.allocatedSize ?? 0)
        for array in [surface,flow,bloom,targets] { for texture in array { bytes += texture.allocatedSize } }
        return bytes
    }
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard device.supportsRaytracing else { throw MoltenError.failed("The detailed river requires Metal ray tracing support.") }
        for name in ["riverFogPass", "riverFogComposite", "riverInitialize", "riverFlowStep", "riverSurfaceStep", "riverTrace", "riverCopyHDR",
                     "riverOrganismInitialize", "riverOrganismStep", "riverBloomExtract", "riverBloomHorizontal", "riverBloomComposite"] {
            guard let f = library.makeFunction(name: name) else { throw MoltenError.failed("Missing river shader: \(name)") }
            compute[name] = try device.makeComputePipelineState(function: f)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "riverOrganismVertex")
        d.fragmentFunction = library.makeFunction(name: "riverOrganismFragment")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        let color = d.colorAttachments[0]!
        color.isBlendingEnabled = true; color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .zero; color.destinationAlphaBlendFactor = .one
        organismPipeline = try device.makeRenderPipelineState(descriptor: d)
    }
    func reset() {
        initialized = false; accumulator = 0; tick = 0; renderIndex = 0
        previousDown = false; pendingImpulse = false; pendingDelta = .zero; historyValid = false
    }
    func releaseResources() {
        surface.removeAll(); flow.removeAll(); bloom.removeAll(); targets.removeAll()
        bathymetry = nil; denoised = nil; fog = nil; exposure = nil; denoiser = nil; organisms = nil; world = nil
        quality = -1; gridWidth = 0; gridHeight = 0; particleCount = 0; usesMetalFX = false; reset()
    }
    private func texture(_ width: Int, _ height: Int, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite,.renderTarget]
        guard let texture = device.makeTexture(descriptor: d) else { throw MoltenError.failed("Could not allocate river rendering state.") }
        return texture
    }
    private func prepare(_ settings: Settings, width: Int, height: Int, command: MTLCommandBuffer) throws {
        if quality != settings.quality {
            releaseResources(); quality = settings.quality
            gridWidth = [192,256,384,512][quality]; gridHeight = gridWidth*2
            bathymetry = try texture(gridWidth,gridHeight)
            surface = try (0..<2).map { _ in try texture(gridWidth,gridHeight) }
            flow = try (0..<2).map { _ in try texture(gridWidth,gridHeight) }
            particleCount = [12_288,32_768,65_536,131_072][quality]
            organisms = device.makeBuffer(length: particleCount*32,options: .storageModePrivate)
            guard organisms != nil else { throw MoltenError.failed("Could not allocate river organisms.") }
            world = try RiverWorld(device: device,command: command,quality: quality)
        }
        usesMetalFX = !settings.paused && quality >= 1 && width >= 256 && height >= 128
            && MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
        let scale: Float = usesMetalFX ? [1,1,1.5,2.0][quality] : 1
        let w = max(1,Int(Float(width)/scale)), h = max(1,Int(Float(height)/scale))
        if targets.first?.width != w || targets.first?.height != h || denoised?.width != width || denoised?.height != height {
            // HDR radiance, normalized depth, pixel motion, albedo, specular,
            // world normals, roughness, hit distance, reactivity, world distance.
            let formats: [MTLPixelFormat] = [.rgba16Float,.r32Float,.rg16Float,.rgba16Float,.rgba16Float,
                                            .rgba16Float,.r16Float,.r16Float,.r8Unorm,.r32Float]
            targets = try formats.map { try texture(w,h,format: $0) }
            denoised = try texture(width,height)
            fog = try texture(max(1,(w+3)/4),max(1,(h+3)/4))
            bloom = try (0..<2).map { _ in try texture(max(1,(width+3)/4),max(1,(height+3)/4)) }
            denoiser = nil; historyValid = false
        }
        if usesMetalFX && denoiser == nil {
            let d = MTLFXTemporalDenoisedScalerDescriptor()
            d.inputWidth = w; d.inputHeight = h; d.outputWidth = width; d.outputHeight = height
            d.colorTextureFormat = .rgba16Float; d.depthTextureFormat = .r32Float; d.motionTextureFormat = .rg16Float
            d.diffuseAlbedoTextureFormat = .rgba16Float; d.specularAlbedoTextureFormat = .rgba16Float
            d.normalTextureFormat = .rgba16Float; d.roughnessTextureFormat = .r16Float
            d.outputTextureFormat = .rgba16Float; d.isAutoExposureEnabled = false
            d.isSpecularHitDistanceTextureEnabled = true; d.specularHitDistanceTextureFormat = .r16Float
            d.isReactiveMaskTextureEnabled = true; d.reactiveMaskTextureFormat = .r8Unorm
            d.requiresSynchronousInitialization = true
            denoiser = d.makeTemporalDenoisedScaler(device: device)
            guard denoiser != nil else { throw MoltenError.failed("MetalFX could not create the river denoiser.") }
            if exposure == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,width: 1,height: 1,mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = .shaderRead
                exposure = device.makeTexture(descriptor: descriptor)
                guard let exposure else { throw MoltenError.failed("Could not allocate the river exposure hint.") }
                var value: Float16 = 1
                exposure.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &value,bytesPerRow: 2)
            }
            historyValid = false
        }
    }
    private func run(_ name: String, command: MTLCommandBuffer, width: Int, height: Int, textures: [MTLTexture], u: Uniforms, s: StageUniforms,
                     frame: RiverFrame? = nil, particles: Bool = false, rays: Bool = false) throws {
        guard let p = compute[name], let e = command.makeComputeCommandEncoder() else { throw MoltenError.failed("Could not encode \(name).") }
        var u = u, s = s
        e.label = name; e.setComputePipelineState(p)
        e.setBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
        e.setBytes(&s,length: MemoryLayout<StageUniforms>.stride,index: 1)
        for (i,t) in textures.enumerated() { e.setTexture(t,index: i) }
        if var frame {
            e.setBytes(&frame,length: MemoryLayout<RiverFrame>.stride,index: particles ? 3 : 2)
        }
        if particles { e.setBuffer(organisms,offset: 0,index: 2) }
        if rays, let world {
            e.setAccelerationStructure(world.acceleration,bufferIndex: 3)
            e.setBuffer(world.vertices,offset: 0,index: 4); e.setBuffer(world.indices,offset: 0,index: 5)
            if name == "riverTrace" { for (i,t) in world.materials.enumerated() { e.setTexture(t,index: 12+i) } }
        }
        e.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: particles ? 128 : 8,height: particles ? 1 : 8,depth: 1))
        e.endEncoding()
    }
    private func camera(_ s: StageUniforms, aspect: Float) -> (simd_float4x4,simd_float4x4) {
        let target = SIMD3<Float>(-0.2,0.05,-8)
        var offset = SIMD3<Float>(1.1,1.8,11.8)*exp(s.camera.z)
        let pitch = s.camera.y*0.65,yaw = s.camera.x
        offset = SIMD3(offset.x,cos(pitch)*offset.y-sin(pitch)*offset.z,sin(pitch)*offset.y+cos(pitch)*offset.z)
        offset = SIMD3(cos(yaw)*offset.x+sin(yaw)*offset.z,offset.y,-sin(yaw)*offset.x+cos(yaw)*offset.z)
        var eye = target+offset
        eye.y = max(eye.y,max(RiverWorld.waterLevel(eye.z)+0.60,RiverWorld.groundHeight(x: eye.x,z: eye.z)+0.38))
        let f = simd_normalize(target-eye), r = simd_normalize(simd_cross(f,SIMD3(0,1,0))), up = simd_cross(r,f)
        let view = simd_float4x4(rows: [SIMD4(r.x,r.y,r.z,-simd_dot(r,eye)),SIMD4(up.x,up.y,up.z,-simd_dot(up,eye)),SIMD4(f.x,f.y,f.z,-simd_dot(f,eye)),SIMD4(0,0,0,1)])
        let near: Float = 0.08, far: Float = 120, focal: Float = 1.85
        let projection = simd_float4x4(columns: (SIMD4(focal/aspect,0,0,0),SIMD4(0,focal,0,0),SIMD4(0,0,far/(far-near),1),SIMD4(0,0,-near*far/(far-near),0)))
        return (view,projection)
    }
    private func halton(_ index: Int,base: Int) -> Float {
        var i = index, f: Float = 1, result: Float = 0
        while i > 0 { f /= Float(base); result += f*Float(i%base); i /= base }
        return result
    }
    func encode(command: MTLCommandBuffer,image: MTLTexture,u: Uniforms,stage: StageUniforms,settings: Settings,dt: Float) throws {
        try prepare(settings,width: image.width,height: image.height,command: command)
        var s = stage
        s.simulation = SIMD4(Float(tick)/60,1/60,Float(gridWidth),Float(gridHeight))
        let (view,projection) = camera(s,aspect: Float(image.width)/Float(image.height)), vp = projection*view
        let signature = [settings.intensity,Float(settings.preset),settings.sceneParameters.x,settings.sceneParameters.y,settings.sceneParameters.z]
        if signature != previousSettings || simd_length(s.camera-previousCamera)>0.35 { historyValid = false }
        var frame = RiverFrame()
        frame.viewProjection = vp; frame.previousViewProjection = historyValid ? previousVP : vp
        let sequence = settings.paused ? Int(s.state.x) : Int(renderIndex%32)
        if usesMetalFX || s.state.y>0.5 { frame.jitter = SIMD4(halton(sequence+1,base: 2)-0.5,halton(sequence+1,base: 3)-0.5,previousTime,u.viewport.z) }
        frame.counts = SIMD4(UInt32(particleCount),settings.paused ? UInt32(s.state.x) : renderIndex,historyValid ? 0 : 1,settings.paused ? 1 : 0)
        if !initialized {
            try run("riverInitialize",command: command,width: gridWidth,height: gridHeight,textures: [surface[0],flow[0],bathymetry!],u: u,s: s)
            try run("riverOrganismInitialize",command: command,width: particleCount,height: 1,textures: [],u: u,s: s,frame: frame,particles: true)
            initialized = true
        }
        if !settings.paused {
            pendingDelta += SIMD2(u.interaction.x,u.interaction.y)
            pendingImpulse = pendingImpulse || (u.pointer.z>0.5 && !previousDown)
            accumulator += min(max(dt,0),1/15)
        } else { pendingDelta = .zero; pendingImpulse = false }
        previousDown = u.pointer.z>0.5
        let steps = settings.paused ? 0 : min(4,Int((accumulator+0.000001)*60))
        accumulator = max(0,accumulator-Float(steps)/60)
        var physics = u
        physics.interaction.x = pendingDelta.x/Float(max(steps,1)); physics.interaction.y = pendingDelta.y/Float(max(steps,1))
        physics.interaction.x *= 0.5; physics.interaction.y *= 0.5
        for step in 0..<steps {
            for substep in 0..<2 {
                s.simulation.x = Float(tick)/60+Float(substep)/120; s.simulation.y = 1/120
                s.object.w = pendingImpulse && step==0 && substep==0 ? 1 : 0
                try run("riverFlowStep",command: command,width: gridWidth,height: gridHeight,textures: [flow[0],flow[1],surface[0],bathymetry!],u: physics,s: s)
                flow.swapAt(0,1)
                try run("riverSurfaceStep",command: command,width: gridWidth,height: gridHeight,textures: [surface[0],surface[1],flow[0],bathymetry!],u: physics,s: s)
                surface.swapAt(0,1)
            }
            s.simulation.y = 1/60
            try run("riverOrganismStep",command: command,width: particleCount,height: 1,textures: [surface[0],flow[0]],u: physics,s: s,frame: frame,particles: true)
            tick &+= 1
        }
        if steps>0 { pendingDelta = .zero; pendingImpulse = false }
        s.simulation.x = Float(tick)/60; s.object.w = 0
        var renderU = u; renderU.viewport.x = Float(targets[0].width); renderU.viewport.y = Float(targets[0].height)
        try run("riverTrace",command: command,width: targets[0].width,height: targets[0].height,textures: targets+[surface[0],flow[0]],u: renderU,s: s,frame: frame,rays: true)
        if let fog {
            try run("riverFogPass",command: command,width: fog.width,height: fog.height,textures: [fog,targets[9]],u: renderU,s: s,frame: frame,rays: true)
            try run("riverFogComposite",command: command,width: targets[0].width,height: targets[0].height,textures: [targets[0],fog,targets[9]],u: renderU,s: s)
        }
        if usesMetalFX, let denoiser, let denoised {
            denoiser.colorTexture = targets[0]; denoiser.depthTexture = targets[1]; denoiser.motionTexture = targets[2]
            denoiser.diffuseAlbedoTexture = targets[3]; denoiser.specularAlbedoTexture = targets[4]
            denoiser.normalTexture = targets[5]; denoiser.roughnessTexture = targets[6]
            denoiser.specularHitDistanceTexture = targets[7]; denoiser.reactiveMaskTexture = targets[8]
            denoiser.outputTexture = denoised; denoiser.isDepthReversed = false
            denoiser.exposureTexture = exposure; denoiser.preExposure = 1
            denoiser.motionVectorScaleX = 1; denoiser.motionVectorScaleY = 1
            denoiser.jitterOffsetX = frame.jitter.x; denoiser.jitterOffsetY = frame.jitter.y
            denoiser.shouldResetHistory = !historyValid
            denoiser.worldToViewMatrix = view; denoiser.viewToClipMatrix = projection
            denoiser.encode(commandBuffer: command)
        }
        try run("riverCopyHDR",command: command,width: image.width,height: image.height,textures: [usesMetalFX ? denoised! : targets[0],image,targets[9]],u: u,s: s)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = image; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let particles = command.makeRenderCommandEncoder(descriptor: pass) else { throw MoltenError.failed("Could not draw river organisms.") }
        var u = u
        particles.label = "River organisms and spray"; particles.setRenderPipelineState(organismPipeline)
        particles.setVertexBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
        particles.setVertexBytes(&s,length: MemoryLayout<StageUniforms>.stride,index: 1)
        particles.setVertexBuffer(organisms,offset: 0,index: 2)
        particles.setVertexBytes(&frame,length: MemoryLayout<RiverFrame>.stride,index: 3)
        particles.setFragmentBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
        particles.setFragmentTexture(targets[9],index: 0)
        particles.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6,instanceCount: particleCount)
        particles.endEncoding()
        try run("riverBloomExtract",command: command,width: bloom[0].width,height: bloom[0].height,textures: [image,bloom[0]],u: u,s: s)
        try run("riverBloomHorizontal",command: command,width: bloom[0].width,height: bloom[0].height,textures: bloom,u: u,s: s)
        try run("riverBloomComposite",command: command,width: image.width,height: image.height,textures: [image,bloom[1]],u: u,s: s)
        previousVP = vp; previousTime = u.viewport.z; previousCamera = s.camera; previousSettings = signature
        historyValid = usesMetalFX; renderIndex &+= 1
    }
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let state = surface.first,let velocity = flow.first,let c = queue.makeCommandBuffer(),let e = c.makeBlitCommandEncoder() else { return [] }
        let bytes = gridWidth*gridHeight*8
        guard let result = device.makeBuffer(length: bytes*2,options: .storageModeShared) else { throw MoltenError.failed("River snapshot allocation failed.") }
        for (i,texture) in [state,velocity].enumerated() {
            e.copy(from: texture,sourceSlice: 0,sourceLevel: 0,sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),sourceSize: MTLSize(width: gridWidth,height: gridHeight,depth: 1),to: result,destinationOffset: i*bytes,destinationBytesPerRow: gridWidth*8,destinationBytesPerImage: bytes)
        }
        e.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        return UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: Float16.self),count: bytes).map(Float.init)
    }
    func organismSnapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let organisms,let command = queue.makeCommandBuffer(),let encoder = command.makeBlitCommandEncoder() else { return [] }
        guard let result = device.makeBuffer(length: organisms.length,options: .storageModeShared) else { throw MoltenError.failed("Could not read river organisms.") }
        encoder.copy(from: organisms,sourceOffset: 0,to: result,destinationOffset: 0,size: organisms.length)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        return Array(UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: Float.self),count: organisms.length/4))
    }
    func bathymetrySnapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let bathymetry,let command = queue.makeCommandBuffer(),let encoder = command.makeBlitCommandEncoder() else { return [] }
        let bytes = gridWidth*gridHeight*8
        guard let result = device.makeBuffer(length: bytes,options: .storageModeShared) else { throw MoltenError.failed("Could not read river bathymetry.") }
        encoder.copy(from: bathymetry,sourceSlice: 0,sourceLevel: 0,sourceOrigin: MTLOrigin(x:0,y:0,z:0),sourceSize: MTLSize(width:gridWidth,height:gridHeight,depth:1),to: result,destinationOffset: 0,destinationBytesPerRow: gridWidth*8,destinationBytesPerImage: bytes)
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        if let error = command.error { throw error }
        return UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: Float16.self),count: bytes/2).map(Float.init)
    }
}
