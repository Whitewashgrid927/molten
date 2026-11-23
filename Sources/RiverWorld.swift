import Foundation
import Metal
import MetalKit
import simd

// Original deterministic geometry. Built once on entering the river, then held
// only in GPU buffers. The same triangles are used by camera and secondary rays.
struct RiverMeshVertex {
    var position: SIMD4<Float> // xyz, material (ground/stone/bark/leaf)
    var normal: SIMD4<Float>   // xyz, per-object variation
    var color: SIMD4<Float>    // linear base color, roughness
}

final class RiverWorld {
    static func smooth(_ a: Float,_ b: Float,_ x: Float) -> Float {
        let t = min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t)
    }
    static func waterLevel(_ z: Float) -> Float {
        -0.007*(z+4) + 0.10*(1-smooth(-13,-10,z)) + 0.09*(1-smooth(-3,-1,z))
    }
    static func channelWidth(_ z: Float) -> Float {
        2.08+0.31*sin(z*0.37+1.3)+0.19*sin(z*0.83)+0.10*sin(z*1.71+0.7)
    }
    static func groundHeight(x: Float,z: Float) -> Float {
        let center = 1.65*sin(z*0.17)+0.65*sin(z*0.41)
        let lateral = x-center, bank = abs(lateral)-channelWidth(z)
        let pool = 0.28+0.24*pow(0.5+0.5*sin(z*0.43+0.6),2)
        let bar = 0.17*exp(-pow((lateral-0.9*sin(z*0.31))*1.35,2))*pow(0.5+0.5*sin(z*0.77),4)
        let shingle = 0.022*sin(x*13+z*4)*sin(z*10-x*3)+0.035*sin(x*4.3+z*1.3)*sin(z*3.7)
        let bed = -pool+bar+shingle
        let shore = 0.10+0.065*sin(z*1.7+x*2.9)+0.035*sin(z*4.1-x*1.3)
        let blend = smooth(-0.48,0.20,bank)
        let hummocks = smooth(0,2,bank)*(0.22*sin(x*1.2+z*0.44)*sin(z*0.81)+0.12*sin(x*2.3-z*0.9))
        return waterLevel(z)+bed*(1-blend)+shore*blend+max(bank-0.25,0)*0.16
            + smooth(1,8,bank)*(0.45+0.25*sin(z*0.29+x*0.41))+hummocks
    }
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let acceleration: MTLAccelerationStructure
    let materials: [MTLTexture]
    let triangleCount: Int
    let treeCount: Int
    let leafCount: Int
    var resourceBytes: Int { vertices.length + indices.length + acceleration.size + materials.reduce(0) { $0+$1.allocatedSize } }

    init(device: MTLDevice, command: MTLCommandBuffer, quality: Int) throws {
        let loader = MTKTextureLoader(device: device)
        let names = ["river_small_rocks", "rock_boulder_dry", "bark_willow", "forest_floor", "mossy_rock"]
        var arrays: [MTLTexture] = []
        for kind in ["color", "normal", "arm"] {
            var maps: [MTLTexture] = []
            for name in names {
                guard let url = Bundle.main.url(forResource: name+"_"+kind,withExtension: "jpg",subdirectory: "RiverMaterials") else {
                    throw MoltenError.failed("Missing river material: \(name)/\(kind)")
                }
                maps.append(try loader.newTexture(URL: url,options: [.SRGB:kind == "color",.textureStorageMode:MTLStorageMode.private.rawValue]))
            }
            let first = maps[0]
            guard maps.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.pixelFormat == first.pixelFormat }) else {
                throw MoltenError.failed("Inconsistent river material map dimensions or formats.")
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: first.pixelFormat,width: first.width,height: first.height,mipmapped: true)
            descriptor.textureType = .type2DArray; descriptor.arrayLength = names.count
            descriptor.storageMode = .private; descriptor.usage = .shaderRead
            guard let array = device.makeTexture(descriptor: descriptor),let blit = command.makeBlitCommandEncoder() else {
                throw MoltenError.failed("Could not allocate scanned river materials.")
            }
            array.label = "River scanned \(kind) materials"
            for (slice,map) in maps.enumerated() {
                blit.copy(from: map,sourceSlice: 0,sourceLevel: 0,sourceOrigin: MTLOrigin(x:0,y:0,z:0),sourceSize: MTLSize(width:map.width,height:map.height,depth:1),to: array,destinationSlice: slice,destinationLevel: 0,destinationOrigin: MTLOrigin(x:0,y:0,z:0))
            }
            blit.generateMipmaps(for: array); blit.endEncoding(); arrays.append(array)
        }
        materials = arrays
        let mesh = RiverMeshBuilder(detail: quality)
        mesh.build()
        triangleCount = mesh.indices.count / 3; treeCount = mesh.trees; leafCount = mesh.leaves
        guard let v = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<RiverMeshVertex>.stride, options: .storageModeShared),
              let i = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4, options: .storageModeShared) else {
            throw MoltenError.failed("Could not allocate the river forest geometry.")
        }
        vertices = v; indices = i
        v.label = "River forest vertices"; i.label = "River forest indices"
        let triangles = MTLAccelerationStructureTriangleGeometryDescriptor()
        triangles.vertexBuffer = v; triangles.vertexStride = MemoryLayout<RiverMeshVertex>.stride
        triangles.vertexFormat = .float3; triangles.indexBuffer = i; triangles.indexType = .uint32
        triangles.triangleCount = triangleCount; triangles.opaque = true
        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [triangles]
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate),
              let encoder = command.makeAccelerationStructureCommandEncoder() else {
            throw MoltenError.failed("Could not build the river ray tracing structure.")
        }
        structure.label = "River forest ray tracing"
        encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        acceleration = structure
    }
}

private final class RiverMeshBuilder {
    var vertices: [RiverMeshVertex] = []
    var indices: [UInt32] = []
    var trees = 0, leaves = 0
    private var state: UInt64 = 0x71c852b3956a
    private let detail: Int
    init(detail: Int) { self.detail = detail }
    func random() -> Float {
        state &+= 0x9e3779b97f4a7c15
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Float((z ^ (z >> 31)) >> 40) / 16_777_216
    }
    func range(_ a: Float, _ b: Float) -> Float { a + (b-a)*random() }
    func center(_ z: Float) -> Float { 1.65*sin(z*0.17)+0.65*sin(z*0.41) }
    func width(_ z: Float) -> Float { RiverWorld.channelWidth(z) }
    func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t) }
    func ground(_ x: Float, _ z: Float) -> Float {
        RiverWorld.groundHeight(x: x,z: z)
    }
    @discardableResult func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ material: Float, _ seed: Float, _ color: SIMD3<Float>, _ roughness: Float) -> UInt32 {
        let i = UInt32(vertices.count)
        vertices.append(RiverMeshVertex(position: SIMD4(p.x,p.y,p.z,material),normal: SIMD4(n.x,n.y,n.z,seed),color: SIMD4(color.x,color.y,color.z,roughness)))
        return i
    }
    func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) { indices += [a,b,c] }
    func tube(_ points: [SIMD3<Float>], _ radii: [Float], sides: Int, seed: Float, root: Bool = false) {
        let start = UInt32(vertices.count)
        for j in points.indices {
            let tangent = simd_normalize(points[min(j+1,points.count-1)]-points[max(j-1,0)])
            let axis = abs(tangent.y) > 0.9 ? SIMD3<Float>(1,0,0) : SIMD3<Float>(0,1,0)
            let right = simd_normalize(simd_cross(tangent,axis)), up = simd_cross(right,tangent)
            for k in 0...sides {
                let angle = Float(k)/Float(sides)*2 * Float.pi
                let n = right*cos(angle)+up*sin(angle)
                let ridges = 1 + 0.045*sin(angle*5+seed*13+Float(j)*0.25)+0.035*sin(angle*9+seed*27)
                vertex(points[j]+n*radii[j]*ridges,n,2,seed,SIMD3(0.16,0.105,0.066),root ? 0.78 : 0.85)
            }
        }
        for j in 0..<points.count-1 { for k in 0..<sides {
            let a = start+UInt32(j*(sides+1)+k), b = a+UInt32(sides+1)
            tri(a,b,a+1); tri(a+1,b,b+1)
        } }
    }
    func leaf(_ p: SIMD3<Float>, direction: SIMD3<Float>, length: Float, breadth: Float, seed: Float, fern: Bool = false) {
        let d = simd_normalize(direction)
        let right = simd_normalize(simd_cross(d,abs(d.y)>0.92 ? SIMD3(1,0,0) : SIMD3(0,1,0)))
        let n = simd_normalize(simd_cross(right,d))
        let color = fern ? SIMD3<Float>(0.055,0.17,0.058) : SIMD3<Float>(0.065+seed*0.035,0.14+seed*0.08,0.048)
        let start = UInt32(vertices.count)
        // Small frond leaflets and distant canopy leaves do not need the
        // longitudinal tessellation of a close, broad leaf.
        let segments = fern || p.y>6 || abs(p.z+4)>14 || abs(p.x-center(p.z))>6 ? 2 : 4
        for j in 0...segments {
            let t = Float(j)/Float(segments), bend = -t*t*length*0.18
            let mid = p + d*(t*length)+SIMD3(0,bend,0)
            let w = pow(sin(t * .pi),0.8)*breadth
            vertex(mid-right*w-n*w*0.13,n,3,seed,color,0.34)
            vertex(mid+n*w*0.08,n,3,seed,color,0.34)
            vertex(mid+right*w-n*w*0.13,n,3,seed,color,0.34)
        }
        for j in 0..<segments { for k in 0..<2 {
            let a = start+UInt32(j*3+k), b = a+3
            tri(a,b,a+1); tri(a+1,b,b+1)
        } }
        leaves += 1
    }
    func rock(_ p: SIMD3<Float>, size: SIMD3<Float>, seed: Float, large: Bool) {
        let segments = large ? (detail == 0 ? 18 : 32) : 9, rings = large ? 20 : 6
        let start = UInt32(vertices.count)
        func shape(_ n: SIMD3<Float>) -> SIMD3<Float> {
            let broad = 1+0.12*sin(n.x*3.2+seed*19)*sin(n.z*3.8+seed*3)
            let detail = 0.026*sin(n.y*11+n.x*7+seed*21)*sin(n.z*9-seed*9)
            var point = n*size*(broad+detail)
            point.x += n.y*size.x*(seed-0.5)*0.25
            point.y = max(point.y,-size.y*0.72)
            return p+point
        }
        for j in 0...rings { for k in 0...segments {
            let phi = Float(j)/Float(rings)*Float.pi, angle = Float(k)/Float(segments)*2 * Float.pi
            let n = SIMD3<Float>(sin(phi)*cos(angle),cos(phi),sin(phi)*sin(angle))
            let axis = abs(n.y)>0.9 ? SIMD3<Float>(1,0,0) : SIMD3<Float>(0,1,0)
            let t = simd_normalize(simd_cross(n,axis)), b = simd_cross(n,t), e: Float = 0.002
            let dt = shape(simd_normalize(n+t*e))-shape(simd_normalize(n-t*e))
            let db = shape(simd_normalize(n+b*e))-shape(simd_normalize(n-b*e))
            let raw = simd_cross(dt,db)
            let normal = simd_length_squared(raw)>0.000000000001 ? simd_normalize(raw) : n
            vertex(shape(n),normal,1,seed,SIMD3(0.3,0.3,0.3),0.78)
        } }
        for j in 0..<rings { for k in 0..<segments {
            let a = start+UInt32(j*(segments+1)+k), b = a+UInt32(segments+1)
            if j > 0 { tri(a,a+1,b) }
            if j < rings-1 { tri(a+1,b+1,b) }
        } }
    }
    func tree(_ root: SIMD3<Float>, height: Float, radius: Float, seed: Float, background: Bool = false) {
        trees += 1
        var trunk: [SIMD3<Float>] = [], radii: [Float] = []
        let lean = SIMD3<Float>(sin(seed*33),0,cos(seed*17))*height*0.08
        for i in 0...16 {
            let t = Float(i)/16
            trunk.append(root+SIMD3(0,t*height,0)+lean*t*t)
            radii.append(radius*pow(max(0.01,1-t),0.7)*(1+0.75*exp(-t*22)))
        }
        tube(trunk,radii,sides: detail == 0 ? 8 : 12,seed: seed)
        for k in 0..<(background ? 0 : 3+Int(seed*3)) {
            let angle = Float(k)*2.399+seed*20, reach = radius*range(2.0,4.0)
            let d = SIMD3<Float>(cos(angle),0,sin(angle))
            var points: [SIMD3<Float>] = [], widths: [Float] = []
            for i in 0...5 {
                let t = Float(i)/5, p = root+d*t*reach
                points.append(SIMD3(p.x,ground(p.x,p.z)-0.025+(1-t)*(1-t)*radius*0.85,p.z))
                widths.append(radius*0.40*pow(1-t,1.5)+0.004)
            }
            tube(points,widths,sides: 6,seed: seed,root: true)
        }
        let branchCount = background ? 10 : detail == 0 ? 18 : 30
        for b in 0..<branchCount {
            let t = 0.32 + Float(b)/Float(branchCount)*0.61+range(-0.04,0.04)
            let angle = Float(b)*2.399+seed*37
            let d = SIMD3<Float>(cos(angle),0,sin(angle))
            let base = root+SIMD3(0,height*t,0)+lean*t*t
            let reach = height*(0.36*(1-t)+0.065)*range(0.55,1.45)
            var points: [SIMD3<Float>] = [], widths: [Float] = []
            for j in 0...5 {
                let q = Float(j)/5
                points.append(base+d*q*reach+SIMD3(0,(0.58*q-0.65*q*q)*reach,0))
                widths.append(radius*0.21*(1-q)+0.009)
            }
            tube(points,widths,sides: 5,seed: seed)
            let lateral = SIMD3<Float>(-d.z,0,d.x)
            for j in 1...5 {
                let q = Float(j)/6, pos = base+d*q*reach+SIMD3(0,(0.58*q-0.65*q*q)*reach,0)
                for sign in [Float(-1),1] {
                    let twig = simd_normalize(d*0.40+lateral*sign+SIMD3(0,0.10,0)), length = reach*(1-q)*0.48+0.12
                    tube([pos,pos+twig*length],[0.018,0.004],sides: 4,seed: seed)
                    for k in 0..<(background ? 3 : 6) {
                        let f = Float(k)/Float(background ? 3 : 6)
                        let leafPos = pos+twig*length*f
                        leaf(leafPos,direction: simd_normalize(twig*0.55+d*(k%2==0 ? 1 : -1)+SIMD3(0,range(-0.2,0.5),0)),
                             length: range(0.16,0.32),breadth: range(0.055,0.11),seed: random())
                    }
                }
            }
        }
    }
    func build() {
        vertices.reserveCapacity(600_000); indices.reserveCapacity(2_000_000)
        let nx = detail == 0 ? 120 : 220, nz = detail == 0 ? 240 : 480
        for z in 0...nz { for x in 0...nx {
            let q = Float(x)/Float(nx)*2-1, pz = -75+Float(z)/Float(nz)*100, e: Float = 0.025
            let px = center(pz)+(q<0 ? -1 : 1)*20*pow(abs(q),1.5)
            let n = simd_normalize(SIMD3(ground(px-e,pz)-ground(px+e,pz),2*e,ground(px,pz-e)-ground(px,pz+e)))
            vertex(SIMD3(px,ground(px,pz),pz),n,0,0,SIMD3(0.105,0.095,0.064),0.84)
        } }
        for z in 0..<nz { for x in 0..<nx {
            let a = UInt32(z*(nx+1)+x), b = a+UInt32(nx+1)
            tri(a,b,a+1); tri(a+1,b,b+1)
        } }
        // The four main boulders match the simulation's obstacle positions.
        for (z,offset,radius) in [(Float(-3),Float(0.7),Float(0.72)),(5,-0.8,0.56),(-11,-0.6,0.52),(-19,0.7,0.66)] {
            rock(SIMD3(center(z)+offset,RiverWorld.waterLevel(z)-0.04,z),size: SIMD3(radius,radius*0.66,radius*0.9),seed: random(),large: true)
        }
        for i in 0..<(detail == 0 ? 700 : 2400) {
            let z = range(-46,16), x = center(z)+range(-1,1)*(width(z)+2.5)
            let large = i < 72, size = large ? range(0.23,0.70) : range(0.025,0.13)
            let y = ground(x,z)+size*0.25
            rock(SIMD3(x,y,z),size: SIMD3(size,size*range(0.45,0.85),size*range(0.7,1.4)),seed: random(),large: large)
        }
        // Irregular banks leave the river corridor and the moonlit bend open.
        for i in 0..<(detail == 0 ? 32 : 48) {
            let z = range(-48,15), side: Float = i%2 == 0 ? -1 : 1
            let x = center(z)+side*(width(z)+range(1.8,9.0))
            let h = range(6,13), radius = range(0.15,0.36)
            tree(SIMD3(x,ground(x,z),z),height: h,radius: radius,seed: random())
        }
        // A second, less expensive layer closes the forest beyond the near banks.
        for i in 0..<(detail == 0 ? 40 : 90) {
            let z = range(-70,15), side: Float = i%2==0 ? -1 : 1
            let x = center(z)+side*(width(z)+range(6,18))
            tree(SIMD3(x,ground(x,z),z),height: range(8,16),radius: range(0.12,0.26),seed: random(),background: true)
        }
        // Low shrubs and tufted sedges interrupt the bare banks and soften the
        // transition from wet shingle to the forest floor.
        for i in 0..<(detail == 0 ? 800 : 2800) {
            let z = range(-48,15), side: Float = i%2==0 ? -1 : 1
            let x = center(z)+side*(width(z)+range(0.05,10.0)), p = SIMD3(x,ground(x,z),z)
            let shrub = i%3==0, height = shrub ? range(0.25,0.85) : range(0.16,0.50)
            for j in 0..<(shrub ? 16 : 8) {
                let a = Float(j)*2.399+Float(i)
                let direction = simd_normalize(SIMD3<Float>(cos(a)*0.6,range(0.25,1.2),sin(a)*0.6))
                let position = p+SIMD3(cos(a),0,sin(a))*range(0.01,0.12)
                leaf(position,direction: direction,length: height*range(0.7,1.2),breadth: shrub ? 0.04 : 0.008,seed: random(),fern: true)
            }
        }
        // A fallen trunk, exposed branches, and riverbank ferns give the foreground scale.
        let start = SIMD3<Float>(-3.9,0.35,-6.2), end = SIMD3<Float>(0.5,0.10,-9.8)
        var log: [SIMD3<Float>] = []
        for i in 0...9 { let t = Float(i)/9; log.append(start*(1-t)+end*t+SIMD3(0,sin(t * .pi)*0.18,0)) }
        tube(log,(0...9).map { 0.30-Float($0)*0.014 },sides: 16,seed: 0.42,root: true)
        for i in 1...5 {
            let p = log[i], d = SIMD3<Float>(range(-0.7,0.7),range(0.2,0.8),range(-0.6,0.6))
            tube([p,p+d*0.6,p+d],[0.09,0.05,0.015],sides: 6,seed: 0.42)
        }
        for i in 0..<(detail == 0 ? 95 : 250) {
            let z = range(-36,13), sign: Float = i%2==0 ? -1 : 1
            let x = center(z)+sign*(width(z)+range(0.08,1.8)), p = SIMD3(x,ground(x,z),z)
            let height = range(0.35,0.85)
            for frond in 0..<7 {
                let a = Float(frond)*2.399+Float(i), d = SIMD3<Float>(cos(a),0,sin(a))
                for j in 1...10 {
                    let t = Float(j)/11, pos = p+d*t*height+SIMD3(0,sin(t * .pi*0.8)*height*0.8,0)
                    let lateral = SIMD3<Float>(-d.z,0.1,d.x)
                    for s in [Float(-1),1] {
                        leaf(pos,direction: lateral*s+d*0.55,length: height*(1-t)*0.32+0.025,breadth: height*0.025,seed: random(),fern: true)
                    }
                }
            }
        }
        for i in 0..<(detail == 0 ? 220 : 900) {
            let z = range(-33,12), side: Float = i%2==0 ? -1 : 1
            let x = center(z)+side*(width(z)+range(0.08,3.5)), a = range(0,2 * .pi)
            let first = vertices.count
            leaf(SIMD3(x,ground(x,z)+0.016,z),direction: SIMD3(cos(a),range(-0.06,0.12),sin(a)),length: range(0.06,0.16),breadth: range(0.025,0.05),seed: random())
            for index in first..<vertices.count {
                vertices[index].position.w = 4
                vertices[index].color = SIMD4(0.12,0.065,0.022,0.9)
            }
            if i%15==0 {
                let p = SIMD3(x,ground(x,z)+0.02,z), d = SIMD3<Float>(cos(a)*0.45,0,sin(a)*0.45)
                tube([p,p+d*0.5,p+d],[0.015,0.011,0.003],sides: 5,seed: random())
            }
        }
    }
}
