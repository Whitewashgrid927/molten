import Foundation
import Metal
import MetalKit
import simd

struct CoveVertex {
    var position: SIMD4<Float> // xyz, material
    var normal: SIMD4<Float>   // xyz, stable variation
    var color: SIMD4<Float>    // linear color, roughness
    var rig: SIMD4<Float>      // joint origin, deformation group
}

// Original geometry; fixed topology is deformed on the GPU, then refitted for
// camera, shadow and water rays. No mesh data is copied back during display.
final class CoveWorld {
    let rest: MTLBuffer, vertices: MTLBuffer, indices: MTLBuffer
    let acceleration: MTLAccelerationStructure, scratch: MTLBuffer
    let descriptor: MTLPrimitiveAccelerationStructureDescriptor
    let materials: [MTLTexture]
    let vertexCount: Int, triangleCount: Int, blossomCount: Int
    private var built = false
    var resourceBytes: Int { rest.length + vertices.length + indices.length + acceleration.size + scratch.length + materials.reduce(0) { $0 + $1.allocatedSize } }
    init(device: MTLDevice, command: MTLCommandBuffer, quality: Int) throws {
        let mesh = CoveMeshBuilder(detail: quality); mesh.build()
        vertexCount = mesh.vertices.count; triangleCount = mesh.indices.count / 3; blossomCount = mesh.blossoms
        guard let r = device.makeBuffer(bytes: mesh.vertices, length: vertexCount * MemoryLayout<CoveVertex>.stride, options: .storageModeShared),
              let v = device.makeBuffer(length: r.length, options: .storageModePrivate),
              let i = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4, options: .storageModeShared) else {
            throw MoltenError.failed("Could not allocate Sakura Cove geometry.")
        }
        rest = r; vertices = v; indices = i
        r.label = "Cove rest mesh"; v.label = "Cove animated geometry"; i.label = "Cove triangles"
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = v; geometry.vertexStride = MemoryLayout<CoveVertex>.stride
        geometry.vertexFormat = .float3; geometry.indexBuffer = i; geometry.indexType = .uint32
        geometry.triangleCount = triangleCount; geometry.opaque = true
        descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]; descriptor.usage = [.refit]
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let a = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let s = device.makeBuffer(length: max(sizes.buildScratchBufferSize, sizes.refitScratchBufferSize), options: .storageModePrivate) else {
            throw MoltenError.failed("Could not allocate Sakura Cove ray tracing.")
        }
        acceleration = a; scratch = s
        a.label = "Cove ray tracing"; s.label = "Cove reusable refit scratch"
        let loader = MTKTextureLoader(device: device)
        var arrays: [MTLTexture] = []
        for kind in ["color", "normal", "arm"] {
            var maps: [MTLTexture] = []
            for name in ["rock_boulder_dry", "bark_willow", "river_small_rocks"] {
                guard let url = Bundle.main.url(forResource: name + "_" + kind, withExtension: "jpg", subdirectory: "RiverMaterials") else { throw MoltenError.failed("Missing cove material.") }
                maps.append(try loader.newTexture(URL: url, options: [.SRGB: kind == "color", .textureStorageMode: MTLStorageMode.private.rawValue]))
            }
            let first = maps[0]
            guard maps.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.pixelFormat == first.pixelFormat }) else { throw MoltenError.failed("Inconsistent cove materials.") }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: first.pixelFormat, width: first.width, height: first.height, mipmapped: true)
            d.textureType = .type2DArray; d.arrayLength = maps.count; d.storageMode = .private; d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d), let e = command.makeBlitCommandEncoder() else { throw MoltenError.failed("Could not upload cove materials.") }
            for (slice, map) in maps.enumerated() {
                e.copy(from: map, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: map.width, height: map.height, depth: 1), to: t, destinationSlice: slice, destinationLevel: 0, destinationOrigin: MTLOrigin())
            }
            e.generateMipmaps(for: t); e.endEncoding(); arrays.append(t)
        }
        materials = arrays
    }
    func updateAcceleration(command: MTLCommandBuffer) throws {
        guard let e = command.makeAccelerationStructureCommandEncoder() else { throw MoltenError.failed("Could not update cove geometry.") }
        if built {
            e.refit(sourceAccelerationStructure: acceleration, descriptor: descriptor, destinationAccelerationStructure: nil, scratchBuffer: scratch, scratchBufferOffset: 0)
        } else {
            e.build(accelerationStructure: acceleration, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0); built = true
        }
        e.endEncoding()
    }
}

private final class CoveMeshBuilder {
    var vertices: [CoveVertex] = [], indices: [UInt32] = []
    var blossoms = 0
    let detail: Int
    var state: UInt64 = 0x6847c9e123
    var part: Float = 0, anchor = SIMD3<Float>.zero
    init(detail: Int) { self.detail = detail }
    func random() -> Float {
        state &+= 0x9e3779b97f4a7c15; var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Float((z ^ (z >> 31)) >> 40) / 16_777_216
    }
    func range(_ a: Float, _ b: Float) -> Float { a + (b-a) * random() }
    func direction() -> SIMD3<Float> { let a = range(0, 2 * .pi), y = range(-1,1), r = sqrt(1-y*y); return SIMD3(r*cos(a),y,r*sin(a)) }
    @discardableResult func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ color: SIMD3<Float>, _ material: Float, _ seed: Float, _ rough: Float = 0.7) -> UInt32 {
        let id = UInt32(vertices.count)
        vertices.append(CoveVertex(position: SIMD4(p.x,p.y,p.z,material), normal: SIMD4(n.x,n.y,n.z,seed), color: SIMD4(color.x,color.y,color.z,rough), rig: SIMD4(anchor.x,anchor.y,anchor.z,part)))
        return id
    }
    func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) { indices += [a,b,c] }
    func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ color: SIMD3<Float>, _ mat: Float, seed: Float = 0) {
        let n = simd_normalize(simd_cross(b-a,c-a)), s = UInt32(vertices.count)
        for p in [a,b,c,d] { vertex(p,n,color,mat,seed) }; tri(s,s+1,s+2); tri(s,s+2,s+3)
    }
    func box(_ center: SIMD3<Float>, _ size: SIMD3<Float>, _ color: SIMD3<Float>, _ mat: Float, bevel: Float = 0.015, seed: Float = 0) {
        let h = size * 0.5, b = min(bevel, min(h.x,min(h.y,h.z))*0.8)
        for face in 0..<6 {
            let axis = face / 2, sign: Float = face % 2 == 0 ? -1 : 1
            let u = (axis+1)%3, v = (axis+2)%3, start = UInt32(vertices.count)
            let us = [-h[u],-h[u]+b,h[u]-b,h[u]], vs = [-h[v],-h[v]+b,h[v]-b,h[v]]
            for y in 0..<4 { for x in 0..<4 {
                var p = SIMD3<Float>.zero; p[axis] = h[axis]*sign; p[u] = us[x]; p[v] = vs[y]
                let inner = simd_clamp(p,-h+SIMD3(repeating:b),h-SIMD3(repeating:b))
                let n = simd_normalize(p-inner); p = inner+n*b
                vertex(center+p,n,color,mat,seed)
            } }
            for y in 0..<3 { for x in 0..<3 {
                let a = start+UInt32(y*4+x), c = a+4
                tri(a,c,a+1); tri(a+1,c,c+1)
            } }
        }
    }
    func ellipsoid(_ p: SIMD3<Float>, _ radius: SIMD3<Float>, _ color: SIMD3<Float>, _ mat: Float, seed: Float = 0, sides: Int = 12, rings: Int = 8, rock: Bool = false) {
        let start = UInt32(vertices.count)
        func shape(_ n: SIMD3<Float>) -> SIMD3<Float> {
            let f: Float = rock ? 1 + 0.10*sin(n.x*5+seed*13)*sin(n.z*4+seed*8)+0.04*sin(n.y*13+n.x*7+seed*21) : 1
            return p+n*radius*f
        }
        for j in 0...rings { for k in 0...sides {
            let phi = Float(j)/Float(rings) * .pi, theta = Float(k)/Float(sides)*2 * .pi
            let n = SIMD3<Float>(sin(phi)*cos(theta),cos(phi),sin(phi)*sin(theta))
            vertex(shape(n),simd_normalize(n/radius),color,mat,seed)
        } }
        for j in 0..<rings { for k in 0..<sides {
            let a = start+UInt32(j*(sides+1)+k), b = a+UInt32(sides+1)
            tri(a,b,a+1); tri(a+1,b,b+1)
        } }
    }
    func tube(_ points: [SIMD3<Float>], _ radii: [Float], _ color: SIMD3<Float>, _ mat: Float, seed: Float = 0, sides: Int = 8) {
        let start = UInt32(vertices.count)
        for j in points.indices {
            let tangent = simd_normalize(points[min(j+1,points.count-1)]-points[max(j-1,0)])
            let right = simd_normalize(simd_cross(tangent,abs(tangent.y)>0.95 ? SIMD3(1,0,0):SIMD3(0,1,0)))
            let up = simd_cross(right,tangent)
            for k in 0...sides {
                let angle = Float(k)/Float(sides)*2 * .pi, n = right*cos(angle)+up*sin(angle)
                vertex(points[j]+n*radii[j],n,color,mat,seed)
            }
        }
        for j in 0..<points.count-1 { for k in 0..<sides {
            let a = start+UInt32(j*(sides+1)+k), b = a+UInt32(sides+1)
            tri(a,b,a+1); tri(a+1,b,b+1)
        } }
    }
    func flower(_ p: SIMD3<Float>, _ n: SIMD3<Float>, size: Float, seed: Float) {
        let axis = simd_normalize(simd_cross(n,abs(n.y)>0.9 ? SIMD3(1,0,0):SIMD3(0,1,0))), up = simd_cross(axis,n)
        let pink = SIMD3<Float>(0.92,0.24+seed*0.26,0.40+seed*0.25)
        for k in 0..<5 {
            let a = Float(k)*2 * .pi/5+seed*6, d = axis*cos(a)+up*sin(a), r = simd_cross(d,n)
            let middle = p + d * (size * 0.65) + n * (size * 0.16)
            let lateral = r * (size * 0.40)
            quad(p,middle+lateral,p+d*size,middle-lateral,pink,5,seed:seed)
        }
        blossoms += 1
    }
    func build() {
        // Low, uneven seabed; true submerged geometry and emergent tidal rocks.
        let side = 76, half: Float = 17
        let start = UInt32(vertices.count)
        for j in 0...side { for i in 0...side {
            let x = (Float(i)/Float(side)*2-1)*half, z = (Float(j)/Float(side)*2-1)*half
            let y = -0.72-0.022*(x*x+z*z)+0.11*sin(x*1.2)*sin(z*1.3)
            vertex(SIMD3(x,y,z),simd_normalize(SIMD3(0.044*x-0.132*cos(x*1.2)*sin(z*1.3),1,0.044*z-0.143*sin(x*1.2)*cos(z*1.3))),SIMD3(0.4,0.32,0.21),0,0)
        } }
        for j in 0..<side { for i in 0..<side { let a = start+UInt32(j*(side+1)+i), b = a+UInt32(side+1); tri(a,b,a+1); tri(a+1,b,b+1) } }
        let stone = SIMD3<Float>(0.55,0.48,0.33)
        box(SIMD3(0,-0.01,0.15),SIMD3(6.5,0.98,5.4),stone,1,bevel:0.11)
        for side in 0..<4 { for n in 0..<18 {
            let f = Float(n)/17, along = -3.25+f*6.5
            let p: SIMD3<Float> = side<2 ? SIMD3(along,0.13+range(-0.08,0.06),side==0 ? 2.83 : -2.52) : SIMD3(side==2 ? -3.30:3.30,0.09+range(-0.1,0.08),-2.5+f*5.3)
            ellipsoid(p,SIMD3(range(0.27,0.48),range(0.30,0.46),range(0.29,0.48)),stone,1,seed:random(),rock:true)
        } }
        for row in 0..<14 { for col in 0..<10 {
            let x: Float = -3.04+Float(col)*0.64+(row%2==0 ? 0 : 0.32)
            if x>3.15 { continue }
            let z: Float = -2.28+Float(row)*0.37, seed = random()
            let width: Float = x>2.9 ? 0.30:0.615
            box(SIMD3(x,0.49+range(-0.006,0.006),z),SIMD3(width,0.12,0.347),SIMD3(0.59+seed*0.18,0.53+seed*0.16,0.39+seed*0.17),2,bevel:0.017,seed:seed)
        } }
        // Broken plaster reveals brick at corners; separate capstones cast shadows.
        box(SIMD3(0.0,1.36,-1.97),SIMD3(5.7,1.62,0.24),SIMD3(0.27,0.56,0.63),3,bevel:0.035)
        for k in 0..<11 { box(SIMD3(-2.62+Float(k)*0.525,2.22,-1.97),SIMD3(0.50,0.17,0.38),SIMD3(0.38,0.22,0.10),2,bevel:0.022,seed:random()) }
        for row in 0..<7 { for side in [-1,1] {
            box(SIMD3(Float(side)*(row%2==0 ? 2.77:2.69),0.68+Float(row)*0.22,-1.95),SIMD3(row%2==0 ? 0.34:0.50,0.20,0.33),SIMD3(0.48,0.26,0.12),2,bevel:0.014,seed:random())
        } }
        // Bench: individual slats, legs, and curved armrests.
        let wood = SIMD3<Float>(0.22,0.043,0.026), iron = SIMD3<Float>(0.021,0.027,0.028)
        for x: Float in [-0.50,1.25] {
            for z: Float in [-1.48,-0.90] { box(SIMD3(x,0.78,z),SIMD3(0.055,0.47,0.065),iron,6,bevel:0.008) }
            box(SIMD3(x,1.17,-1.53),SIMD3(0.06,0.84,0.065),iron,6,bevel:0.008)
            tube([SIMD3(x,0.98,-0.87),SIMD3(x,1.20,-0.89),SIMD3(x,1.24,-1.28),SIMD3(x,1.10,-1.52)],[0.027,0.027,0.027,0.027],iron,6)
        }
        for i in 0..<4 { box(SIMD3(0.38,0.99,-1.43+Float(i)*0.16),SIMD3(2.0,0.055,0.145),wood,4,bevel:0.008,seed:random()) }
        for i in 0..<3 { box(SIMD3(0.38,1.20+Float(i)*0.15,-1.52),SIMD3(2.0,0.12,0.065),wood,4,bevel:0.008,seed:random()) }
        // Lantern on its own swinging assembly.
        box(SIMD3(-2.35,0.72,-1.35),SIMD3(0.37,0.35,0.37),stone,1,bevel:0.035)
        box(SIMD3(-2.35,1.99,-1.35),SIMD3(0.13,2.55,0.13),SIMD3(0.07,0.035,0.019),4)
        box(SIMD3(-2.65,3.14,-1.35),SIMD3(0.78,0.11,0.12),SIMD3(0.09,0.05,0.025),4)
        tube([SIMD3(-2.35,2.68,-1.35),SIMD3(-2.85,3.10,-1.35)],[0.045,0.045],wood,4)
        part = 9; anchor = CoveMotion.lanternPivot
        tube([anchor,anchor-SIMD3(0,0.16,0)],[0.018,0.018],iron,6)
        let lp = anchor-SIMD3(0,0.39,0)
        box(lp,SIMD3(0.24,0.34,0.24),SIMD3(1,0.64,0.18),7,bevel:0.008)
        for x: Float in [-0.14,0.14] { for z: Float in [-0.14,0.14] { box(lp+SIMD3(x,0,z),SIMD3(0.025,0.40,0.025),iron,6,bevel:0.004) } }
        box(lp-SIMD3(0,0.22,0),SIMD3(0.34,0.055,0.34),iron,6)
        tube([lp+SIMD3(0,0.18,0),lp+SIMD3(0,0.39,0)],[0.25,0.015],iron,6,sides:4)
        part = 0; anchor = .zero
        for _ in 0..<65 {
            let p = SIMD3<Float>(range(-8,8),range(-0.7,-0.1),range(-7,8))
            if abs(p.x)<3.8 && p.z > -2.8 && p.z<3.3 { continue }
            let size = range(0.18,0.9)
            ellipsoid(p,SIMD3(size,range(0.18,0.55),size*range(0.7,1.4)),stone,1,seed:random(),rock:true)
        }
        // Grass grows mostly in paving joints and exposed margins.
        for _ in 0..<410 {
            let row = Int(range(0,14)), x = range(-3.1,3.1), z = -2.46+Float(row)*0.37
            if abs(x)<2.4 && z < 1.9 && random()<0.78 { continue }
            let p = SIMD3<Float>(x,0.54,z), h = range(0.04,0.16), color = SIMD3<Float>(0.055,0.11+random()*0.08,0.025)
            for k in 0..<3 { let a = Float(k)*2.1, d = SIMD3<Float>(cos(a)*0.022,0,sin(a)*0.022); quad(p-d,p+d,p+SIMD3(0.02,h,0.01),p+SIMD3(0.02,h,0.01),color,8,seed:random()) }
        }
        tree(); character()
        // Petals share the geometry acceleration structure, including reflections.
        for i in 0..<CoveEngine.petalCount {
            part = Float(100+i); anchor = .zero
            quad(SIMD3(-0.018,0,0),SIMD3(0,-0.006,0.032),SIMD3(0.018,0,0),SIMD3(0,0,-0.025),SIMD3(0.96,0.48,0.62),5,seed:random())
        }
        part = 0
    }
    func tree() {
        let root = SIMD3<Float>(1.85,0.45,-2.18), bark = SIMD3<Float>(0.16,0.09,0.06)
        part = 10
        tube([root,root+SIMD3(-0.13,0.9,0.04),root+SIMD3(-0.02,1.8,-0.1),root+SIMD3(-0.38,2.6,0.08)],[0.27,0.22,0.15,0.07],bark,9,seed:0.45,sides:16)
        for i in 0..<14 {
            let a = Float(i)*2.399, radius = range(0.9,1.9), h = range(2.5,3.5)
            let end = root+SIMD3(cos(a)*radius,h,sin(a)*radius*0.75)
            let joint = root+SIMD3(-0.1,1.4+Float(i%4)*0.22,0)
            let mid = simd_mix(joint,end,SIMD3(repeating:0.60))+SIMD3(0,0.22,0)
            tube([joint,mid,end],[0.10,0.05,0.008],bark,9,seed:random(),sides:9)
            for j in 0..<3 {
                let tip = end+SIMD3(range(-0.55,0.55),range(-0.15,0.55),range(-0.48,0.48))
                tube([mid,simd_mix(mid,tip,SIMD3(repeating:0.65)),tip],[0.035,0.016,0.003],bark,9,seed:random(),sides:6)
                let count = detail == 0 ? 64 : 125
                for _ in 0..<count {
                    let d = direction(), p = tip + d*SIMD3<Float>(0.57,0.36,0.48)*pow(random(),0.45)
                    flower(p,d,size:range(0.041,0.067),seed:random())
                    if j==0 && random()<0.35 {
                        let c = SIMD3<Float>(0.07,0.17,0.045), t = direction()*0.08
                        quad(p-t,p+SIMD3(0.025,0.01,0),p+t,p-SIMD3(0.025,0.01,0),c,8,seed:random())
                    }
                }
            }
        }
        part = 0
    }
    func character() {
        let cloth = SIMD3<Float>(0.027,0.045,0.068), skin = SIMD3<Float>(0.70,0.43,0.29), hair = SIMD3<Float>(0.045,0.020,0.014), hat = SIMD3<Float>(0.76,0.67,0.46)
        part = 1; anchor = .zero
        ellipsoid(SIMD3(0,0.77,0),SIMD3(0.15,0.23,0.105),cloth,10,sides:20,rings:12)
        tube([SIMD3(0,0.87,0),SIMD3(0,0.96,0)],[0.055,0.055],skin,11)
        ellipsoid(SIMD3(0,1.04,0),SIMD3(0.115,0.14,0.10),skin,11,sides:20,rings:16)
        ellipsoid(SIMD3(0,1.08,-0.035),SIMD3(0.12,0.14,0.095),hair,4,sides:20)
        ellipsoid(SIMD3(0,0.96,-0.085),SIMD3(0.12,0.16,0.055),hair,4)
        for x: Float in [-0.04,0.04] { ellipsoid(SIMD3(x,1.04,0.093),SIMD3(0.009,0.013,0.007),hair,6,sides:8,rings:6) }
        ellipsoid(SIMD3(0,1.005,0.104),SIMD3(0.016,0.023,0.016),skin,11,sides:10)
        ellipsoid(SIMD3(0,1.155,0),SIMD3(0.30,0.018,0.265),hat,12,sides:36,rings:8)
        ellipsoid(SIMD3(0,1.205,0),SIMD3(0.16,0.10,0.14),hat,12,sides:28,rings:10)
        tube([SIMD3(0,1.157,0),SIMD3(0,1.19,0)],[0.157,0.158],SIMD3(0.11,0.08,0.055),4,sides:28)
        part = 8; anchor = SIMD3(0,0.57,0)
        tube([SIMD3(0,0.61,0),SIMD3(0,0.47,0),SIMD3(0,0.28,0)],[0.135,0.18,0.25],cloth,10,sides:32)
        for side: Float in [-1,1] {
            let x = side*0.085
            part = side<0 ? 2:4; anchor = SIMD3(x,0.54,0)
            tube([anchor,SIMD3(x,0.31,0)],[0.052,0.038],skin,11,sides:12)
            part = side<0 ? 3:5
            tube([SIMD3(x,0.31,0),SIMD3(x,0.10,0)],[0.038,0.027],skin,11,sides:12)
            ellipsoid(SIMD3(x,0.055,0.035),SIMD3(0.052,0.048,0.10),SIMD3(0.09,0.045,0.025),4,sides:12)
            part = side<0 ? 6:7; anchor = SIMD3(side*0.145,0.84,0)
            tube([anchor,SIMD3(side*0.20,0.64,0),SIMD3(side*0.20,0.49,0.03)],[0.065,0.038,0.027],cloth,10,sides:12)
            ellipsoid(SIMD3(side*0.20,0.475,0.03),SIMD3(0.032,0.047,0.025),skin,11,sides:10)
        }
        part = 0; anchor = .zero
    }
}
