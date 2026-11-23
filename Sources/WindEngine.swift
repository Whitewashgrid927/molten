import Foundation
import Metal
import simd

struct WindFrame {
  var eye = SIMD4<Float>.zero
  var right = SIMD4<Float>.zero
  var up = SIMD4<Float>.zero
  var forward = SIMD4<Float>.zero
  var state = SIMD4<Float>.zero  // seconds, fixed step, rotor phase, count
  var wind = SIMD4<Float>.zero  // axial speed, actual rotor speed, turbulence, density
  var pointer = SIMD4<Float>.zero
  var viewport = SIMD4<Float>.zero
}
struct WindVertex {
  var position: SIMD4<Float>
  var normal: SIMD4<Float>
  var color: SIMD4<Float>
}

enum WindCamera {
  static func frame(input: PointerState, width: Int, height: Int) -> WindFrame {
    let target = SIMD3<Float>(-1.20, 0.25, 0)
    let yaw = input.camera.x
    let pitch = min(0.85, max(-0.70, input.camera.y))
    var offset = SIMD3<Float>(7.5, 1.8, 6.5) * exp(min(0.65, max(-0.65, input.camera.z)))
    offset = SIMD3(
      offset.x, cos(pitch) * offset.y - sin(pitch) * offset.z,
      sin(pitch) * offset.y + cos(pitch) * offset.z)
    offset = SIMD3(
      cos(yaw) * offset.x + sin(yaw) * offset.z, offset.y,
      -sin(yaw) * offset.x + cos(yaw) * offset.z)
    let eye = target + offset
    let forward = simd_normalize(-offset)
    let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
    let up = simd_cross(right, forward)
    var f = WindFrame()
    f.eye = SIMD4(eye.x, eye.y, eye.z, 0)
    f.right = SIMD4(right.x, right.y, right.z, 2.65)
    f.up = SIMD4(up.x, up.y, up.z, 0)
    f.forward = SIMD4(forward.x, forward.y, forward.z, 0)
    f.viewport = SIMD4(Float(width), Float(height), 0, 0)
    let xy =
      (input.position - SIMD2<Float>(repeating: 0.5))
      * SIMD2<Float>(2 * Float(width) / Float(height), -2)
    let ray = simd_normalize(forward * 2.65 + right * xy.x + up * xy.y)
    // Cursor disturbance lies in the camera-facing plane through the hub.
    let hub = SIMD3<Float>(1.25, 0.45, 0)
    let distance = simd_dot(hub - eye, forward) / max(0.1, simd_dot(ray, forward))
    let p = eye + ray * distance
    f.pointer = SIMD4(p.x, p.y, p.z, input.down && input.inside && input.modifiers & 1 == 0 ? 1 : 0)
    return f
  }
}

final class WindEngine {
  let device: MTLDevice
  private let compute: [String: MTLComputePipelineState]
  private let solid: MTLRenderPipelineState, cloud: MTLRenderPipelineState
  private let solidDepth: MTLDepthStencilState, cloudDepth: MTLDepthStencilState
  private var particles: MTLBuffer?, mesh: MTLBuffer?
  private var color: MTLTexture?, depth: MTLTexture?
  private var vertexCount = 0
  private(set) var particleCount = 0
  private(set) var tick: UInt32 = 0
  private(set) var phase: Float = 0.35
  private(set) var rotorSpeed: Float = 0
  private var accumulator: Float = 0
  private var initialized = false
  var resourceBytes: Int {
    (particles?.length ?? 0) + (mesh?.length ?? 0) + (color?.allocatedSize ?? 0)
      + (depth?.allocatedSize ?? 0)
  }
  static let counts = [120_000, 300_000, 900_000, 1_400_000]
  init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    var pipelines: [String: MTLComputePipelineState] = [:]
    for name in ["windInitialize", "windStep", "windResolve"] {
      guard let function = library.makeFunction(name: name) else {
        throw MoltenError.failed("Missing turbine shader: \(name)")
      }
      pipelines[name] = try device.makeComputePipelineState(function: function)
    }
    compute = pipelines
    func pipeline(_ vertex: String, _ fragment: String, blend: Bool) throws
      -> MTLRenderPipelineState
    {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = library.makeFunction(name: vertex)
      d.fragmentFunction = library.makeFunction(name: fragment)
      d.colorAttachments[0].pixelFormat = .rgba16Float
      d.depthAttachmentPixelFormat = .depth32Float
      if blend {
        let c = d.colorAttachments[0]!
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .zero
        c.destinationAlphaBlendFactor = .one
      }
      return try device.makeRenderPipelineState(descriptor: d)
    }
    solid = try pipeline("windSolidVertex", "windSolidFragment", blend: false)
    cloud = try pipeline("windParticleVertex", "windParticleFragment", blend: true)
    let d = MTLDepthStencilDescriptor()
    d.depthCompareFunction = .less
    d.isDepthWriteEnabled = true
    guard let a = device.makeDepthStencilState(descriptor: d) else {
      throw MoltenError.failed("Missing turbine depth state.")
    }
    solidDepth = a
    d.isDepthWriteEnabled = false
    guard let b = device.makeDepthStencilState(descriptor: d) else {
      throw MoltenError.failed("Missing particle depth state.")
    }
    cloudDepth = b
  }
  func reset() {
    tick = 0
    phase = 0.35
    rotorSpeed = 0
    accumulator = 0
    initialized = false
  }
  func releaseResources() {
    particles = nil
    mesh = nil
    color = nil
    depth = nil
    particleCount = 0
    vertexCount = 0
    reset()
  }
  private func prepare(width: Int, height: Int, quality: Int) throws {
    let count = Self.counts[quality]
    if particleCount != count {
      guard let b = device.makeBuffer(length: count * 32, options: .storageModePrivate) else {
        throw MoltenError.failed("Cannot allocate wind particles.")
      }
      b.label = "Turbine: fixed tracer population"
      particles = b
      particleCount = count
      initialized = false
    }
    if mesh == nil {
      let vertices = Self.geometry()
      guard
        let b = device.makeBuffer(
          bytes: vertices, length: vertices.count * MemoryLayout<WindVertex>.stride,
          options: .storageModeShared)
      else { throw MoltenError.failed("Cannot allocate turbine mesh.") }
      mesh = b
      vertexCount = vertices.count
      b.label = "Turbine: tower, nacelle, hub and three airfoils"
    }
    if color?.width != width || color?.height != height {
      func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private
        d.usage = format == .depth32Float ? [.renderTarget] : [.renderTarget, .shaderRead]
        guard let t = device.makeTexture(descriptor: d) else {
          throw MoltenError.failed("Cannot allocate turbine render target.")
        }
        return t
      }
      color = try texture(.rgba16Float)
      depth = try texture(.depth32Float)
    }
  }
  private func run(
    _ name: String, command: MTLCommandBuffer, f: WindFrame, output: MTLTexture? = nil
  ) throws {
    guard let p = compute[name], let e = command.makeComputeCommandEncoder() else {
      throw MoltenError.failed("Cannot encode turbine work.")
    }
    var f = f
    e.label = name
    e.setComputePipelineState(p)
    e.setBytes(&f, length: MemoryLayout<WindFrame>.stride, index: 0)
    e.setBuffer(particles, offset: 0, index: 1)
    if let output {
      e.setTexture(color, index: 0)
      e.setTexture(output, index: 1)
      e.dispatchThreads(
        MTLSize(width: output.width, height: output.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    } else {
      e.dispatchThreads(
        MTLSize(width: particleCount, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }
    e.endEncoding()
  }
  func encode(
    command: MTLCommandBuffer, output: MTLTexture, u: Uniforms, settings: Settings,
    input: PointerState, dt: Float
  ) throws {
    try prepare(width: output.width, height: output.height, quality: settings.quality)
    var f = WindCamera.frame(input: input, width: output.width, height: output.height)
    f.viewport.z = Float(settings.quality)
    f.viewport.w = Float(settings.preset)
    f.wind = SIMD4(
      settings.intensity * 1.65, rotorSpeed, settings.sceneParameters.y, settings.sceneParameters.z)
    f.state = SIMD4(Float(tick) / 60, 1 / 60, phase, Float(particleCount))
    if !initialized {
      rotorSpeed = settings.sceneParameters.x * 2
      f.wind.y = rotorSpeed
      try run("windInitialize", command: command, f: f)
      initialized = true
    }
    if !settings.paused {
      accumulator += min(0.1, max(0, dt.isFinite ? dt : 0))
      let steps = min(6, Int((accumulator + 0.000001) * 60))
      accumulator = max(0, accumulator - Float(steps) / 60)
      for _ in 0..<steps {
        let target: Float =
          input.down && input.modifiers & 1 != 0 ? 0 : settings.sceneParameters.x * 2
        rotorSpeed += (target - rotorSpeed) * (1 - exp(-Float(1.0 / 60) * 4))
        phase = (phase + rotorSpeed / 60).truncatingRemainder(dividingBy: 2 * Float.pi)
        tick &+= 1
        f.state.x = Float(tick) / 60
        f.state.z = phase
        f.wind.y = rotorSpeed
        try run("windStep", command: command, f: f)
      }
    }
    f.state.z = phase
    f.wind.y = rotorSpeed
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = color
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: 0.0015, green: 0.003, blue: 0.022, alpha: 1)
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    pass.depthAttachment.clearDepth = 1
    guard let e = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw MoltenError.failed("Cannot render turbine.")
    }
    e.label = "Turbine mesh and depth-tested flow particles"
    e.setCullMode(.none)
    e.setVertexBytes(&f, length: MemoryLayout<WindFrame>.stride, index: 0)
    e.setFragmentBytes(&f, length: MemoryLayout<WindFrame>.stride, index: 0)
    e.setRenderPipelineState(solid)
    e.setDepthStencilState(solidDepth)
    e.setVertexBuffer(mesh, offset: 0, index: 1)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    e.setRenderPipelineState(cloud)
    e.setDepthStencilState(cloudDepth)
    e.setVertexBuffer(particles, offset: 0, index: 1)
    e.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
    e.endEncoding()
    try run("windResolve", command: command, f: f, output: output)
  }
  // Tests only; no synchronous readback occurs in the interactive app.
  func snapshot(queue: MTLCommandQueue) throws -> [Float] {
    guard let particles else { return [] }
    let bytes = min(particles.length, 4096 * 32)
    guard let b = device.makeBuffer(length: bytes, options: .storageModeShared),
      let c = queue.makeCommandBuffer(),
      let e = c.makeBlitCommandEncoder()
    else { throw MoltenError.failed("Cannot inspect turbine state.") }
    e.copy(from: particles, sourceOffset: 0, to: b, destinationOffset: 0, size: bytes)
    e.endEncoding()
    c.commit()
    c.waitUntilCompleted()
    if let error = c.error { throw error }
    return Array(
      UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: bytes / 4)
    )
  }
  private static func geometry() -> [WindVertex] {
    var vertices: [WindVertex] = []
    func triangle(
      _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ na: SIMD3<Float>,
      _ nb: SIMD3<Float>, _ nc: SIMD3<Float>, rotor: Bool = false, tone: Float = 1
    ) {
      for (p, n) in [(a, na), (b, nb), (c, nc)] {
        vertices.append(
          .init(
            position: SIMD4(p.x, p.y, p.z, rotor ? 1 : 0), normal: SIMD4(n.x, n.y, n.z, 0),
            color: SIMD4(0.35 * tone, 0.40 * tone, 0.44 * tone, 1)))
      }
    }
    func cylinder(
      _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float, rotor: Bool = false,
      tone: Float = 1
    ) {
      let axis = simd_normalize(b - a)
      let side = simd_normalize(
        simd_cross(axis, abs(axis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)))
      let other = simd_cross(axis, side)
      let slope = (ra - rb) / simd_length(b - a)
      for j in 0..<40 {
        let u = Float(j) / 40 * 2 * Float.pi
        let v = Float(j + 1) / 40 * 2 * Float.pi
        let n0 = side * cos(u) + other * sin(u)
        let n1 = side * cos(v) + other * sin(v)
        let p0 = a + n0 * ra
        let p1 = a + n1 * ra
        let q0 = b + n0 * rb
        let q1 = b + n1 * rb
        let s0 = simd_normalize(n0 + axis * slope)
        let s1 = simd_normalize(n1 + axis * slope)
        triangle(p0, p1, q1, s0, s1, s1, rotor: rotor, tone: tone)
        triangle(p0, q1, q0, s0, s1, s0, rotor: rotor, tone: tone)
        triangle(a, p1, p0, -axis, -axis, -axis, rotor: rotor, tone: tone)
        triangle(b, q0, q1, axis, axis, axis, rotor: rotor, tone: tone)
      }
    }
    let hub = SIMD3<Float>(1.25, 0.45, 0)
    cylinder(SIMD3(0.98, -2.35, 0), SIMD3(0.98, 0.43, 0), 0.125, 0.075)
    cylinder(SIMD3(0.65, 0.45, 0), SIMD3(1.25, 0.45, 0), 0.13, 0.18, tone: 0.86)
    cylinder(hub, hub + SIMD3(0.24, 0, 0), 0.19, 0.035, rotor: true, tone: 1.08)
    let radii: [Float] = [0.14, 0.30, 0.55, 0.85, 1.18, 1.50, 1.78, 1.96]
    let chords: [Float] = [0.06, 0.15, 0.21, 0.205, 0.16, 0.115, 0.062, 0.008]
    for blade in 0..<3 {
      let angle = Float(blade) * 2 * Float.pi / 3
      func point(_ ring: Int, _ j: Int) -> (SIMD3<Float>, SIMD3<Float>) {
        let theta = Float(j) / 20 * 2 * Float.pi
        let r = radii[ring]
        let chord = chords[ring]
        let twist = 0.40 - r * 0.21
        let thickness = max(0.006, 0.045 * (1 - r / 2.3))
        let x = sin(theta) * thickness
        let z = cos(theta) * chord + 0.035 * r * r
        var p = SIMD3<Float>(x * cos(twist) + z * sin(twist), r, -x * sin(twist) + z * cos(twist))
        var n = simd_normalize(
          SIMD3<Float>(sin(theta) / thickness, 0, cos(theta) / max(0.01, chord)))
        n = SIMD3(n.x * cos(twist) + n.z * sin(twist), n.y, -n.x * sin(twist) + n.z * cos(twist))
        p = SIMD3(p.x, p.y * cos(angle) - p.z * sin(angle), p.y * sin(angle) + p.z * cos(angle))
        n = SIMD3(n.x, n.y * cos(angle) - n.z * sin(angle), n.y * sin(angle) + n.z * cos(angle))
        return (p + hub, n)
      }
      for ring in 0..<(radii.count - 1) {
        for j in 0..<20 {
          let a = point(ring, j)
          let b = point(ring, j + 1)
          let c = point(ring + 1, j + 1)
          let d = point(ring + 1, j)
          triangle(a.0, b.0, c.0, a.1, b.1, c.1, rotor: true)
          triangle(a.0, c.0, d.0, a.1, c.1, d.1, rotor: true)
        }
      }
    }
    return vertices
  }
}
