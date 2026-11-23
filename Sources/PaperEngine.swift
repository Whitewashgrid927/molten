import AppKit
import CoreText
import Metal
import simd

// Camera, optics and five small spring states. Geometry is tessellated in Metal;
// no scene graph, per-frame meshes, image captures or unbounded particles.
struct PaperFrame {
  var eye = SIMD4<Float>.zero
  var right = SIMD4<Float>.zero
  var up = SIMD4<Float>.zero
  var forward = SIMD4<Float>.zero
  var lightEye = SIMD4<Float>.zero
  var lightRight = SIMD4<Float>.zero
  var lightUp = SIMD4<Float>.zero
  var lightForward = SIMD4<Float>.zero
  var viewport = SIMD4<Float>.zero
  var controls = SIMD4<Float>.zero
  var focus = SIMD4<Float>.zero
}

enum PaperCamera {
  static func base(_ index: Int, spread: Float) -> SIMD3<Float> {
    let n = Float(index)
    return SIMD3((n - 2) * 0.22, (4 - n) * 0.30, (n - 2) * (0.46 + spread * 0.34))
  }
  static func frame(input: PointerState, width: Int, height: Int) -> PaperFrame {
    let target = SIMD3<Float>(0, 2.6, 0)
    let yaw = min(0.65, max(-0.65, input.camera.x))
    let pitch = min(0.32, max(-0.32, input.camera.y))
    var offset = SIMD3<Float>(-3.2, 3.0, 9.4) * exp(min(0.45, max(-0.42, input.camera.z)))
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
    let lightEye = SIMD3<Float>(-3.5, 8, 6)
    let lightForward = simd_normalize(SIMD3<Float>(0, 1.6, 0) - lightEye)
    let lightRight = simd_normalize(simd_cross(lightForward, SIMD3<Float>(0, 1, 0)))
    let lightUp = simd_cross(lightRight, lightForward)
    var f = PaperFrame()
    f.eye = SIMD4(eye.x, eye.y, eye.z, 0)
    f.forward = SIMD4(forward.x, forward.y, forward.z, 0)
    // Fit the portrait stack in both wide and compact Molten windows.
    f.right = SIMD4(right.x, right.y, right.z, min(3.3, 3.3 * Float(width) / Float(height) / 1.38))
    f.up = SIMD4(up.x, up.y, up.z, 0)
    f.lightEye = SIMD4(lightEye.x, lightEye.y, lightEye.z, 0)
    f.lightForward = SIMD4(lightForward.x, lightForward.y, lightForward.z, 0)
    f.lightRight = SIMD4(lightRight.x, lightRight.y, lightRight.z, 5.5)
    f.lightUp = SIMD4(lightUp.x, lightUp.y, lightUp.z, 0)
    f.viewport = SIMD4(Float(width), Float(height), 0, 0)
    return f
  }
  static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
  static func project(_ p: SIMD3<Float>, frame f: PaperFrame) -> SIMD2<Float> {
    let q = p - xyz(f.eye)
    let depth = max(0.1, simd_dot(q, xyz(f.forward)))
    return SIMD2(
      0.5 + simd_dot(q, xyz(f.right)) * f.right.w / depth * 0.5 * f.viewport.y / f.viewport.x,
      0.5 - simd_dot(q, xyz(f.up)) * f.right.w / depth * 0.5)
  }
  // Intersect the visible layered backs. The same tab profile is used by the
  // shader; a press in the white margin must never open a random folder.
  static func pick(
    _ position: SIMD2<Float>, frame f: PaperFrame, states: [SIMD4<Float>], spread: Float
  ) -> Int? {
    let xy = (position - SIMD2<Float>(repeating: 0.5)) * SIMD2(2 * f.viewport.x / f.viewport.y, -2)
    let ray = simd_normalize(xyz(f.forward) * f.right.w + xyz(f.right) * xy.x + xyz(f.up) * xy.y)
    guard abs(ray.z) > 0.05 else { return nil }
    var best: (Int, Float)?
    for i in 0..<5 {
      let base = base(i, spread: spread) + SIMD3(states[i].x, states[i].y, 0)
      let t = (base.z - f.eye.z) / ray.z
      guard t > 0 else { continue }
      let p = xyz(f.eye) + ray * t - base
      let tab = -1.05 + Float(i) * 0.07
      let bump: Float = abs(p.x - tab) < 0.62 ? 0.32 : 0
      let top: Float = 3.05 + bump
      if abs(p.x) < 2.18 && p.y > 0 && p.y < top,
        best == nil || t < best!.1
      {
        best = (i, t)
      }
    }
    return best?.0
  }
}

struct PaperMotion {
  private(set) var states = [SIMD4<Float>](repeating: .zero, count: 5)  // x, lift, open, lean
  private var velocities = [SIMD4<Float>](repeating: .zero, count: 5)
  private(set) var selected: Int? = nil
  private(set) var hovered: Int? = nil
  private(set) var focusIndex: Float = 3
  private(set) var tick: UInt32 = 0
  private var accumulator: Float = 0
  private var previousDown = false
  private var actionSerial: UInt32 = 0
  private var cancelSerial: UInt32 = 0
  private var grabStart = SIMD2<Float>.zero
  private var grabbing = false
  mutating func update(
    input: PointerState, dt: Float, paused: Bool, frame: PaperFrame, spread: Float
  ) {
    // Pause freezes physical state even when the camera/optics are adjusted.
    if paused {
      previousDown = input.down
      actionSerial = input.actionSerial
      return
    }
    hovered =
      input.inside && !input.orbiting
      ? PaperCamera.pick(input.position, frame: frame, states: states, spread: spread) : nil
    if input.cancelSerial != cancelSerial {
      grabbing = false
      cancelSerial = input.cancelSerial
    }
    let queuedPress = input.actionSerial != actionSerial
    if queuedPress || (input.down && !previousDown) {
      let p = queuedPress ? input.actionPosition : input.position
      if input.inside, let hit = PaperCamera.pick(p, frame: frame, states: states, spread: spread) {
        selected = selected == hit ? nil : hit
        grabbing = selected != nil && input.down
        grabStart = p
      } else {
        selected = nil
        grabbing = false
      }
    }
    actionSerial = input.actionSerial
    previousDown = input.down
    if !input.down { grabbing = false }
    accumulator += min(0.1, max(0, dt.isFinite ? dt : 0))
    let steps = min(12, Int((accumulator + 0.000001) * 120))
    accumulator = max(0, accumulator - Float(steps) / 120)
    for _ in 0..<steps {
      tick &+= 1
      focusIndex += (Float(selected ?? hovered ?? 3) - focusIndex) * (1 - exp(-Float(7.0 / 120)))
      for i in 0..<5 {
        let active = selected == i
        var target = SIMD4<Float>(0, active ? 0.4 : hovered == i ? 0.065 : 0, active ? 1 : 0, 0)
        if active && grabbing {
          let d = input.position - grabStart
          target.x = min(0.6, max(-0.6, d.x * 3.5))
          target.y += min(0.7, max(-0.2, -d.y * 3))
          target.w = min(0.38, max(-0.38, d.x * 2))
        }
        // Damped fixed-step springs preserve the weight of card stock.
        velocities[i] += ((target - states[i]) * 90 - velocities[i] * 16) / 120
        states[i] += velocities[i] / 120
      }
    }
  }
  var snapshot: [Float] {
    states.flatMap { [$0.x, $0.y, $0.z, $0.w] }
      + velocities.flatMap { [$0.x, $0.y, $0.z, $0.w] }
      + [sin(Float(tick) / 120), cos(Float(tick) / 120), focusIndex]
  }
}

final class PaperEngine {
  let device: MTLDevice
  private let surface: MTLRenderPipelineState, shadowPipeline: MTLRenderPipelineState
  private let depthState: MTLDepthStencilState, resolve: MTLComputePipelineState
  private var color: MTLTexture?, depth: MTLTexture?, shadow: MTLTexture?, labels: MTLTexture?
  private(set) var motion = PaperMotion()
  var resourceBytes: Int {
    [color, depth, shadow, labels].compactMap { $0 }.reduce(0) { $0 + $1.allocatedSize }
  }
  init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "paperVertex")
    d.fragmentFunction = library.makeFunction(name: "paperFragment")
    d.colorAttachments[0].pixelFormat = .rgba16Float
    d.depthAttachmentPixelFormat = .depth32Float
    surface = try device.makeRenderPipelineState(descriptor: d)
    let s = MTLRenderPipelineDescriptor()
    s.vertexFunction = library.makeFunction(name: "paperShadowVertex")
    s.depthAttachmentPixelFormat = .depth32Float
    shadowPipeline = try device.makeRenderPipelineState(descriptor: s)
    let depthDescription = MTLDepthStencilDescriptor()
    depthDescription.depthCompareFunction = .lessEqual
    depthDescription.isDepthWriteEnabled = true
    guard let ds = device.makeDepthStencilState(descriptor: depthDescription),
      let fn = library.makeFunction(name: "paperResolve")
    else { throw MoltenError.failed("Missing paper rendering functions.") }
    depthState = ds
    resolve = try device.makeComputePipelineState(function: fn)
  }
  func reset() { motion = PaperMotion() }
  func releaseResources() {
    color = nil
    depth = nil
    shadow = nil
    labels = nil
    reset()
  }
  private func texture(
    _ format: MTLPixelFormat, _ width: Int, _ height: Int, mipmapped: Bool = false
  ) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: mipmapped)
    d.usage = [.shaderRead, .renderTarget]
    d.storageMode = .private
    guard let t = device.makeTexture(descriptor: d) else {
      throw MoltenError.failed("Cannot allocate paper render target.")
    }
    return t
  }
  private func prepare(width: Int, height: Int, quality: Int) throws {
    if color?.width != width || color?.height != height {
      color = try texture(.rgba16Float, width, height, mipmapped: true)
      depth = try texture(.depth32Float, width, height)
    }
    let side = [512, 1024, 1536, 2048][quality]
    if shadow?.width != side { shadow = try texture(.depth32Float, side, side) }
    if labels == nil { labels = try labelAtlas() }
  }
  private func labelAtlas() throws -> MTLTexture {
    let width = 256
    let rowHeight = 64
    let height = rowHeight * 5
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    try rgba.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw MoltenError.failed("Cannot create paper labels.") }
      for (i, text) in ["assets", "ideas", "docs", "tests", "old"].enumerated() {
        let line = CTLineCreateWithAttributedString(
          NSAttributedString(
            string: text,
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: 32, weight: .medium),
              .foregroundColor: NSColor.white, .kern: 4,
            ]))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(
          x: (Double(width) - w) / 2, y: Double(height - (i + 1) * rowHeight + 20))
        CTLineDraw(line, context)
      }
    }
    var mask = [UInt8](repeating: 0, count: width * height)
    for i in mask.indices { mask[i] = rgba[i * 4 + 3] }
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
    d.storageMode = .shared
    d.usage = .shaderRead
    guard let t = device.makeTexture(descriptor: d) else {
      throw MoltenError.failed("Cannot upload paper labels.")
    }
    mask.withUnsafeBytes {
      t.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: width)
    }
    return t
  }
  func encode(
    command: MTLCommandBuffer, output: MTLTexture, settings: Settings, input: PointerState,
    dt: Float
  ) throws {
    try prepare(width: output.width, height: output.height, quality: settings.quality)
    var f = PaperCamera.frame(input: input, width: output.width, height: output.height)
    motion.update(
      input: input, dt: dt, paused: settings.paused, frame: f, spread: settings.intensity)
    f.viewport.z = Float(motion.tick) / 120
    f.viewport.w = Float(settings.preset)
    f.controls = SIMD4(
      settings.intensity, settings.sceneParameters.x, settings.sceneParameters.y,
      settings.sceneParameters.z)
    let focusIndex = min(4, max(0, motion.focusIndex))
    let low = Int(floor(focusIndex))
    let high = min(4, low + 1)
    let blend = focusIndex - Float(low)
    let a =
      PaperCamera.base(low, spread: settings.intensity)
      + SIMD3<Float>(
        -1.05 + Float(low) * 0.07 + motion.states[low].x, 3.18 + motion.states[low].y, 0)
    let b =
      PaperCamera.base(high, spread: settings.intensity)
      + SIMD3<Float>(
        -1.05 + Float(high) * 0.07 + motion.states[high].x, 3.18 + motion.states[high].y, 0)
    let p = a + (b - a) * blend
    f.focus = SIMD4(
      simd_dot(p - PaperCamera.xyz(f.eye), PaperCamera.xyz(f.forward)), Float(settings.quality),
      focusIndex, 0)
    var states = motion.states
    let pass = MTLRenderPassDescriptor()
    pass.depthAttachment.texture = shadow
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .store
    pass.depthAttachment.clearDepth = 1
    guard let shadowEncoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw MoltenError.failed("Cannot encode paper shadows.")
    }
    shadowEncoder.label = "Curved paper soft shadows"
    shadowEncoder.setRenderPipelineState(shadowPipeline)
    shadowEncoder.setDepthStencilState(depthState)
    shadowEncoder.setCullMode(.none)
    shadowEncoder.setDepthBias(0.001, slopeScale: 1.5, clamp: 0.01)
    shadowEncoder.setVertexBytes(&f, length: MemoryLayout<PaperFrame>.stride, index: 0)
    shadowEncoder.setVertexBytes(
      &states, length: states.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
    shadowEncoder.drawPrimitives(
      type: .triangle, vertexStart: 0, vertexCount: 96 * 24 * 6, instanceCount: 25)
    shadowEncoder.endEncoding()
    pass.depthAttachment.texture = depth
    pass.depthAttachment.storeAction = .dontCare
    pass.colorAttachments[0].texture = color
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: 0.975, green: 0.967, blue: 0.95, alpha: 30)
    guard let e = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw MoltenError.failed("Cannot render paper folders.")
    }
    e.label = "Pastel card stock, tabs and fluttering notes"
    e.setRenderPipelineState(surface)
    e.setDepthStencilState(depthState)
    e.setCullMode(.none)
    e.setVertexBytes(&f, length: MemoryLayout<PaperFrame>.stride, index: 0)
    e.setVertexBytes(&states, length: states.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
    e.setFragmentBytes(&f, length: MemoryLayout<PaperFrame>.stride, index: 0)
    e.setFragmentTexture(shadow, index: 0)
    e.setFragmentTexture(labels, index: 1)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 96 * 24 * 6, instanceCount: 25)
    e.endEncoding()
    guard let mips = command.makeBlitCommandEncoder(), let color else {
      throw MoltenError.failed("Cannot filter paper focus.")
    }
    mips.label = "Bounded paper blur pyramid"
    mips.generateMipmaps(for: color)
    mips.endEncoding()
    guard let post = command.makeComputeCommandEncoder() else {
      throw MoltenError.failed("Cannot resolve paper optics.")
    }
    post.label = "Paper depth of field and soft white falloff"
    post.setComputePipelineState(resolve)
    post.setBytes(&f, length: MemoryLayout<PaperFrame>.stride, index: 0)
    post.setTexture(color, index: 0)
    post.setTexture(output, index: 1)
    post.dispatchThreads(
      MTLSize(width: output.width, height: output.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    post.endEncoding()
  }
}
