import Foundation
import Metal
import simd

struct PoolFrame {
  var stone = SIMD4<Float>.zero
  var shape = SIMD4<Float>.zero
  var motion = SIMD4<Float>.zero
  var touch = SIMD4<Float>.zero
  var state = SIMD4<Float>.zero
  var view = SIMD4<Float>.zero
  var impact = SIMD4<Float>.zero
  var velocity = SIMD4<Float>.zero
  var stone1 = SIMD4<Float>.zero
  var stone2 = SIMD4<Float>.zero
  var plant0 = SIMD4<Float>.zero
  var plant1 = SIMD4<Float>.zero
  var plant2 = SIMD4<Float>.zero
  var selection = SIMD4<Float>.zero
}

final class PoolEngine {
  static let grid = 256
  let device: MTLDevice
  let motion = PoolSimulation()
  private let pipelines: [String: MTLComputePipelineState]
  private var waves: [MTLTexture] = []
  private var pendingImpulses: [PoolImpulse] = []
  private var initialized = false
  private var wasResting = true
  var resourceBytes: Int { waves.reduce(0) { $0 + $1.allocatedSize } }
  init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    var result: [String: MTLComputePipelineState] = [:]
    for name in ["poolInitialize", "poolStep", "poolRender"] {
      guard let f = library.makeFunction(name: name) else {
        throw MoltenError.failed("Missing pool shader: \(name)")
      }
      result[name] = try device.makeComputePipelineState(function: f)
    }
    pipelines = result
  }
  func reset() {
    motion.reset()
    pendingImpulses.removeAll(keepingCapacity: true)
    initialized = false
    wasResting = true
  }
  func releaseResources() {
    waves.removeAll()
    reset()
  }
  private func run(
    _ name: String, command: MTLCommandBuffer, size: MTLSize,
    u: Uniforms, f: PoolFrame, textures: [MTLTexture], impulses: [PoolImpulse] = []
  ) throws {
    guard let p = pipelines[name], let e = command.makeComputeCommandEncoder() else {
      throw MoltenError.failed("Could not encode the pool.")
    }
    var u = u
    var f = f
    e.label = name
    e.setComputePipelineState(p)
    e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    e.setBytes(&f, length: MemoryLayout<PoolFrame>.stride, index: 1)
    if impulses.isEmpty {
      var empty = SIMD4<Float>.zero
      e.setBytes(&empty, length: 16, index: 2)
    } else {
      impulses.withUnsafeBytes { e.setBytes($0.baseAddress!, length: $0.count, index: 2) }
    }
    var count = UInt32(impulses.count)
    e.setBytes(&count, length: 4, index: 3)
    for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
    e.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    e.endEncoding()
  }
  func encode(
    command: MTLCommandBuffer, image: MTLTexture, u: Uniforms,
    settings: Settings, input: PointerState, dt: Float
  ) throws {
    if waves.isEmpty {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rg32Float,
        width: Self.grid, height: Self.grid, mipmapped: false)
      d.storageMode = .private
      d.usage = [.shaderRead, .shaderWrite]
      waves = try (0..<2).map { _ in
        guard let t = device.makeTexture(descriptor: d) else {
          throw MoltenError.failed("Could not allocate pool ripples.")
        }
        t.label = "River Garden: bounded 256-square wave field"
        return t
      }
    }
    let steps = motion.advance(
      input: input, dt: dt, aspect: u.viewport.x / u.viewport.y, settings: settings)
    // A contact can arrive before the next fixed physics tick, especially at
    // slow animation speeds. Keep its wave impulse until a step consumes it.
    pendingImpulses.append(contentsOf: motion.impulses.prefix(max(0, 32 - pendingImpulses.count)))
    var f = PoolFrame()
    func stone(_ i: Int) -> SIMD4<Float> {
      let p = motion.stones[i].position
      return SIMD4(p.x, p.y, p.z, motion.stones[i].wetness)
    }
    func plant(_ i: Int) -> SIMD4<Float> {
      let p = motion.plants[i]
      return SIMD4(p.bend.x, p.bend.y, p.velocity.x, p.velocity.y)
    }
    f.stone = stone(0)
    f.stone1 = stone(1)
    f.stone2 = stone(2)
    f.plant0 = plant(0)
    f.plant1 = plant(1)
    f.plant2 = plant(2)
    f.selection = SIMD4(
      Float(motion.selectedStone), Float(motion.hoveredStone), Float(motion.hoveredPlant),
      Float(motion.brushingPlant))
    f.shape = SIMD4(0.34, 0.20, 0.27, motion.wetness)
    f.motion = SIMD4(motion.tilt.x, motion.tilt.y, motion.hover, Float(motion.skips))
    f.touch = SIMD4(motion.touch.x, motion.touch.y, motion.touchingWater ? 1 : 0, motion.flow)
    f.state = SIMD4(motion.time, motion.activity, motion.held ? 1 : 0, motion.airborne ? 1 : 0)
    f.view = SIMD4(u.viewport.x / u.viewport.y, min(0.35, max(-0.3, input.camera.z)), 0, 0)
    f.impact = motion.impact
    f.velocity = SIMD4(motion.velocity.x, motion.velocity.y, motion.velocity.z, 0)
    let grid = MTLSize(width: Self.grid, height: Self.grid, depth: 1)
    if !initialized || (motion.isAtRest && !wasResting) {
      try run("poolInitialize", command: command, size: grid, u: u, f: f, textures: waves)
      initialized = true
    }
    // No accumulation targets or CPU readbacks. Sleeping water is exactly flat.
    if !motion.isAtRest && !settings.paused {
      for step in 0..<steps {
        try run(
          "poolStep", command: command, size: grid, u: u, f: f,
          textures: waves, impulses: step == 0 ? pendingImpulses : [])
        waves.swapAt(0, 1)
      }
      if steps > 0 { pendingImpulses.removeAll(keepingCapacity: true) }
    }
    wasResting = motion.isAtRest
    try run(
      "poolRender", command: command,
      size: MTLSize(width: image.width, height: image.height, depth: 1),
      u: u, f: f, textures: [waves[0], image])
  }
  // Verification only; never used by the interactive/audio path.
  func snapshot(queue: MTLCommandQueue) throws -> [Float] {
    guard let t = waves.first else { return [] }
    let row = Self.grid * 8
    let bytes = row * Self.grid
    guard let b = device.makeBuffer(length: bytes, options: .storageModeShared),
      let c = queue.makeCommandBuffer(), let e = c.makeBlitCommandEncoder()
    else {
      throw MoltenError.failed("Could not inspect pool state.")
    }
    e.copy(
      from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
      sourceSize: MTLSize(width: Self.grid, height: Self.grid, depth: 1), to: b,
      destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: bytes)
    e.endEncoding()
    c.commit()
    c.waitUntilCompleted()
    if let error = c.error { throw error }
    return Array(
      UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: bytes / 4)
    )
  }
}
