import Foundation
import Metal
import simd

struct CoveCamera {
    var eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>
    let focal: Float = 1.55
    func ray(_ uv: SIMD2<Float>, aspect: Float) -> SIMD3<Float> {
        simd_normalize(forward*focal + right*((uv.x*2-1)*aspect) + up*(1-uv.y*2))
    }
}

// Small deterministic gameplay state. Animation, petals, water and geometry
// stay on the GPU. Navigation never depends on a pixel or GPU readback.
struct CoveMotion {
    static let lanternPivot = SIMD3<Float>(-2.93,3.08,-1.35)
    static let benchApproach = SIMD2<Float>(0.38,-0.46)
    private(set) var position = SIMD3<Float>(0,0.55,1.35)
    private(set) var velocity = SIMD2<Float>.zero
    private(set) var heading: Float = 0
    private(set) var gait: Float = 0
    private(set) var seated = false
    private(set) var sitBlend: Float = 0
    private(set) var lanternAngle: Float = 0
    private(set) var lanternVelocity: Float = 0
    private(set) var freeEye = SIMD3<Float>.zero
    private(set) var freeMode = false
    private var lastAction: UInt32 = 0
    private var previousDown = false
    var speed: Float { simd_length(velocity) }
    var controlHint: String {
        if freeMode { return "Free camera · W A S D move · R / F up / down · Shift faster · C return · Right-drag look" }
        let action = seated ? "E stand" : canSit ? "E sit on bench" : "E interact"
        return "W A S D walk · Shift run · \(action) · C free camera · Right-drag orbit · Scroll zoom"
    }

    var canSit: Bool { !freeMode && simd_distance(SIMD2(position.x,position.z),Self.benchApproach)<0.85 }
    static func walkable(_ p: SIMD2<Float>) -> Bool {
        guard abs(p.x) <= 3.07, p.y >= -1.59, p.y <= 2.50 else { return false }
        // Inflate furniture by the character's 18 cm radius.
        if p.x > -0.85 && p.x < 1.61 && p.y > -1.75 && p.y < -0.62 { return false }
        if simd_distance(p,SIMD2(-2.35,-1.35)) < 0.39 { return false }
        return true
    }
    func camera(_ input: PointerState) -> CoveCamera {
        let pitch = freeMode ? min(1.45,max(-1.45,0.56+input.camera.y)) : min(1.18,max(0.12,0.56+input.camera.y))
        let yaw = 0.39+input.camera.x
        let distance = 8.4*exp(input.camera.z)
        let offset = SIMD3<Float>(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))
        let target = SIMD3<Float>(0.30+position.x*0.22,1.72,-0.05+(position.z-1.35)*0.16)
        let eye = freeMode ? freeEye : target+offset*distance
        let forward = -offset, right = simd_normalize(simd_cross(forward,SIMD3(0,1,0)))
        return CoveCamera(eye: eye,right: right,up: simd_cross(right,forward),forward: forward)
    }
    mutating func input(_ input: PointerState, aspect: Float, active: Bool) {
        if input.freeCamera != freeMode {
            let current = camera(input)
            freeEye = current.eye; freeMode = input.freeCamera; velocity = .zero
        }
        if input.actionSerial != lastAction && active && !freeMode {
            if seated {
                seated = false; position = SIMD3(Self.benchApproach.x,0.55,Self.benchApproach.y+0.10)
            } else if canSit {
                seated = true; position = SIMD3(0.38,0.45,-1.18); heading = 0; velocity = .zero
            } else if simd_distance(SIMD2(position.x,position.z),SIMD2(-2.35,-1.0)) < 1.05 {
                lanternVelocity += 1.25
            }
        }
        lastAction = input.actionSerial
        let down = input.down && input.inside
        if active && down && !previousDown {
            let c = camera(input), d = c.ray(input.position,aspect:aspect)
            let center = Self.lanternPivot-SIMD3(0,0.39,0), t = simd_dot(center-c.eye,d)
            if t>0 && simd_distance(c.eye+d*t,center)<0.38 { lanternVelocity += 1.8 }
        }
        previousDown = down
    }
    mutating func step(_ input: PointerState, wind: Float, time: Float, dt: Float) {
        let c = camera(input)
        if freeMode {
            var move = c.right*input.navigation.x+c.forward*input.navigation.z+SIMD3<Float>(0,input.navigation.y,0)
            if simd_length(move)>1 { move = simd_normalize(move) }
            freeEye += move * dt * (input.modifiers & 1 == 0 ? 2.7:5.4)
            freeEye = simd_clamp(freeEye,SIMD3(-14,0.7,-14),SIMD3(14,12,14)); velocity = .zero
        } else if !seated {
            let forward = simd_normalize(SIMD2(c.forward.x,c.forward.z)), right = SIMD2(c.right.x,c.right.z)
            var wish = right*input.navigation.x+forward*input.navigation.z
            if simd_length(wish)>1 { wish = simd_normalize(wish) }
            let running = input.modifiers & 1 != 0
            velocity += (wish*(running ? 2.6:1.25)-velocity)*(1-exp(-dt*14))
            var p = SIMD2(position.x,position.z)
            let steps = max(1,Int(ceil(simd_length(velocity)*dt/0.035)))
            let delta = velocity*dt/Float(steps)
            for _ in 0..<steps {
                if Self.walkable(p+SIMD2(delta.x,0)) { p.x += delta.x }
                if Self.walkable(p+SIMD2(0,delta.y)) { p.y += delta.y }
            }
            let travel = simd_distance(p,SIMD2(position.x,position.z))
            if travel<0.00001 && simd_length(wish)>0 { velocity *= 0.45 }
            position = SIMD3(p.x,0.55,p.y)
            if speed>0.025 {
                let target = atan2(velocity.x,velocity.y), difference = atan2(sin(target-heading),cos(target-heading))
                heading += difference*(1-exp(-dt*14))
            }
            gait = (gait+travel*9).truncatingRemainder(dividingBy:2 * .pi)
            heading = atan2(sin(heading),cos(heading))
        }
        sitBlend += ((seated ? 1:0)-sitBlend)*(1-exp(-dt*13))
        let windForce = wind*(sin(time*0.8)*0.15+sin(time*1.9)*0.05)
        lanternVelocity += (-11*lanternAngle-1.5*lanternVelocity+windForce)*dt
        lanternVelocity = min(3,max(-3,lanternVelocity)); lanternAngle += lanternVelocity*dt
        if abs(lanternAngle)>0.65 { lanternAngle = min(0.65,max(-0.65,lanternAngle)); lanternVelocity *= -0.35 }
    }
    var snapshot: [Float] { [position.x,position.y,position.z,velocity.x,velocity.y,heading,gait,sitBlend,lanternAngle,lanternVelocity] }
}

struct CoveFrame {
    var eye = SIMD4<Float>.zero
    var right = SIMD4<Float>.zero
    var up = SIMD4<Float>.zero
    var forward = SIMD4<Float>.zero
    var actor = SIMD4<Float>.zero // xyz, heading
    var animation = SIMD4<Float>.zero // gait, speed, sit, lantern swing
    var touch = SIMD4<Float>.zero // world x,z, pressed, brush velocity
    var clock = SIMD4<Float>.zero // time, dt, vertices, petals
}

final class CoveEngine {
    static let petalCount = 384, grid = 256
    private let device: MTLDevice
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var world: CoveWorld?
    private var waves: [MTLTexture] = []
    private var petals: [MTLBuffer] = []
    private var initialized = false
    private var geometryReady = false
    private var accumulator: Float = 0
    private(set) var tick: UInt32 = 0
    private(set) var motion = CoveMotion()
    var triangleCount: Int { world?.triangleCount ?? 0 }
    var blossomCount: Int { world?.blossomCount ?? 0 }
    var resourceBytes: Int { (world?.resourceBytes ?? 0) + waves.reduce(0) { $0+$1.allocatedSize } + petals.reduce(0) { $0+$1.length } }
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["coveInitialize","coveWaves","covePetals","coveDeform","coveRender"] {
            guard let f = library.makeFunction(name:name) else { throw MoltenError.failed("Missing cove shader: \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function:f)
        }
    }
    func reset() { initialized = false; geometryReady = false; accumulator = 0; tick = 0; motion = CoveMotion() }
    func releaseResources() { world = nil; waves.removeAll(); petals.removeAll(); reset() }
    private func prepare(command: MTLCommandBuffer, quality: Int) throws {
        guard world == nil else { return }
        world = try CoveWorld(device: device,command: command,quality: quality)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg32Float,width:Self.grid,height:Self.grid,mipmapped:false)
        d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
        for _ in 0..<2 {
            guard let t = device.makeTexture(descriptor:d),let p = device.makeBuffer(length:Self.petalCount*32,options:.storageModePrivate) else { throw MoltenError.failed("Could not allocate cove simulation.") }
            waves.append(t); petals.append(p)
        }
    }
    private func frame(_ input: PointerState, _ u: Uniforms) -> CoveFrame {
        var f = CoveFrame(); let c = motion.camera(input)
        f.eye = SIMD4(c.eye.x,c.eye.y,c.eye.z,c.focal)
        f.right = SIMD4(c.right.x,c.right.y,c.right.z,0); f.up = SIMD4(c.up.x,c.up.y,c.up.z,0); f.forward = SIMD4(c.forward.x,c.forward.y,c.forward.z,0)
        f.actor = SIMD4(motion.position.x,motion.position.y,motion.position.z,motion.heading)
        f.animation = SIMD4(motion.gait,motion.speed,motion.sitBlend,motion.lanternAngle)
        let ray = c.ray(input.position,aspect:u.viewport.x/u.viewport.y)
        let t = ray.y < -0.001 ? (u.controls.z-c.eye.y)/ray.y : -1
        let hit = c.eye+ray*max(t,0)
        f.touch = SIMD4(hit.x,hit.z,input.down && input.inside && t>0 && t<80 ? 1:0,min(1,simd_length(input.delta)*15))
        f.clock = SIMD4(Float(tick)/60,1/60,Float(world?.vertexCount ?? 0),Float(Self.petalCount))
        return f
    }
    private func run(_ name: String, command: MTLCommandBuffer, size: MTLSize, u: Uniforms, s: StageUniforms, f: CoveFrame, textures: [MTLTexture] = [], buffers: [MTLBuffer] = []) throws {
        guard let e = command.makeComputeCommandEncoder(),let p = pipelines[name] else { throw MoltenError.failed("Could not encode \(name).") }
        var u = u, s = s, f = f
        e.label = name; e.setComputePipelineState(p)
        e.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0); e.setBytes(&s,length:MemoryLayout<StageUniforms>.stride,index:1); e.setBytes(&f,length:MemoryLayout<CoveFrame>.stride,index:2)
        for (i,t) in textures.enumerated() { e.setTexture(t,index:i) }
        for (i,b) in buffers.enumerated() { e.setBuffer(b,offset:0,index:i+3) }
        if name == "coveRender",let world {
            e.setAccelerationStructure(world.acceleration,bufferIndex:6)
            e.useResource(world.vertices,usage:.read); e.useResource(world.indices,usage:.read)
        }
        e.dispatchThreads(size,threadsPerThreadgroup:size.height==1 ? MTLSize(width:64,height:1,depth:1):MTLSize(width:8,height:8,depth:1)); e.endEncoding()
    }
    func encode(command: MTLCommandBuffer, image: MTLTexture, u: Uniforms, stage: StageUniforms, settings: Settings, input: PointerState, dt: Float) throws {
        try prepare(command:command,quality:settings.quality)
        guard let world else { throw MoltenError.failed("Missing cove world.") }
        let delta = min(max(dt,0),1/15)
        motion.input(input,aspect:u.viewport.x/u.viewport.y,active:delta>0)
        var f = frame(input,u)
        if !initialized {
            try run("coveInitialize",command:command,size:MTLSize(width:Self.grid,height:Self.grid,depth:1),u:u,s:stage,f:f,textures:waves,buffers:petals)
            initialized = true
        }
        accumulator += delta
        let steps = min(4,Int((accumulator+0.000001)*60)); accumulator = max(0,accumulator-Float(steps)/60)
        for _ in 0..<steps {
            motion.step(input,wind:u.controls.y,time:Float(tick)/60,dt:1/60)
            f = frame(input,u)
            try run("coveWaves",command:command,size:MTLSize(width:Self.grid,height:Self.grid,depth:1),u:u,s:stage,f:f,textures:waves)
            waves.swapAt(0,1)
            try run("covePetals",command:command,size:MTLSize(width:Self.petalCount,height:1,depth:1),u:u,s:stage,f:f,buffers:petals)
            petals.swapAt(0,1); tick &+= 1
        }
        f = frame(input,u)
        if !geometryReady || steps>0 {
            try run("coveDeform",command:command,size:MTLSize(width:world.vertexCount,height:1,depth:1),u:u,s:stage,f:f,buffers:[world.rest,world.vertices,petals[0]])
            try world.updateAcceleration(command:command); geometryReady = true
        }
        try run("coveRender",command:command,size:MTLSize(width:image.width,height:image.height,depth:1),u:u,s:stage,f:f,textures:[image,waves[0]]+world.materials,buffers:[world.vertices,world.indices])
    }
    // Verification-only readback. Bounded state excludes the unbounded clock.
    func snapshot(queue: MTLCommandQueue) throws -> [Float] {
        guard let w = waves.first,let p = petals.first else { return [] }
        let row = Self.grid*8, bytes = row*Self.grid
        guard let b = device.makeBuffer(length:bytes+p.length,options:.storageModeShared),let c = queue.makeCommandBuffer(),let e = c.makeBlitCommandEncoder() else { throw MoltenError.failed("Could not inspect cove state.") }
        e.copy(from:w,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:Self.grid,height:Self.grid,depth:1),to:b,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:bytes)
        e.copy(from:p,sourceOffset:0,to:b,destinationOffset:bytes,size:p.length); e.endEncoding(); c.commit(); c.waitUntilCompleted()
        if let error = c.error { throw error }
        return Array(UnsafeBufferPointer(start:b.contents().assumingMemoryBound(to:Float.self),count:b.length/4))+motion.snapshot
    }
}
