import Foundation
import Metal

enum WindTest {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw MoltenError.failed(message) }
  }
  static func run() throws {
    let args = CommandLine.arguments
    let index = args.firstIndex(of: "--output")
    let folder = URL(
      fileURLWithPath: index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        ?? "/tmp/molten-turbine")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let engine = try MetalEngine()
    let wind = engine.cinematic.wind
    var settings = Settings()
    var input = PointerState()
    var frame: UInt32 = 0
    settings.scene = .turbine
    settings.quality = 0
    var results: [String: Any] = [:]
    func draw(_ dt: Float = 1 / 60, width: Int = 320, height: Int = 220) throws -> Double {
      try autoreleasepool {
        guard let c = engine.queue.makeCommandBuffer() else {
          throw MoltenError.failed("No turbine test command.")
        }
        _ = try engine.encode(
          command: c, width: width, height: height, time: Float(wind.tick) / 60, dt: dt,
          frame: frame, settings: settings, input: input)
        c.commit()
        c.waitUntilCompleted()
        frame &+= 1
        try require(
          c.status == .completed && c.error == nil,
          "Turbine GPU command failed: \(String(describing:c.error))")
        return (c.gpuEndTime - c.gpuStartTime) * 1000
      }
    }
    func snapshot() throws -> [Float] { try wind.snapshot(queue: engine.queue) }
    func save(_ name: String) throws {
      try engine.readback(engine.output!).save(to: folder.appendingPathComponent(name + ".png"))
    }
    try require(
      MemoryLayout<WindFrame>.stride == 128 && MemoryLayout<WindVertex>.stride == 48,
      "Turbine shader ABI mismatch.")
    if !args.contains("--preview-only") {
      _ = try draw(0)
      let initial = try snapshot()
      var distinct = Set<SIMD3<Int>>()
      for i in stride(from: 0, to: initial.count, by: 8) {
        distinct.insert(
          SIMD3(Int(initial[i] * 1000), Int(initial[i + 1] * 1000), Int(initial[i + 2] * 1000)))
      }
      try require(distinct.count > 4000, "Particle initialization collapsed onto repeated paths.")
      results["distinct_particle_distribution"] = true
      var cadence: [[Float]] = []
      var phases: [Float] = []
      for fps in [30, 60, 120] {
        engine.reset()
        input = PointerState()
        _ = try draw(0)
        for _ in 0..<fps * 2 { _ = try draw(1 / Float(fps)) }
        cadence.append(try snapshot())
        phases.append(wind.phase)
      }
      try require(
        cadence[0] == cadence[1] && cadence[1] == cadence[2] && phases[0] == phases[2],
        "Tracer advection or rotor motion depends on frame rate.")
      let state = try snapshot()
      try require(state.allSatisfy(\.isFinite), "Non-finite wind particle state.")
      for i in stride(from: 0, to: state.count, by: 8) {
        try require(
          state[i] >= (-5.61) && state[i] <= 1.3 && abs(state[i + 1]) < 4
            && abs(state[i + 2]) < 3.3, "Tracer escaped the wake bounds.")
      }
      results["fixed_60hz_identical_at_30_60_120fps"] = true
      settings.paused = true
      _ = try draw(0)
      let frozen = try snapshot()
      let phase = wind.phase
      for _ in 0..<6 { _ = try draw(1 / 30) }
      try require(try snapshot() == frozen && wind.phase == phase, "Paused turbine kept moving.")
      input.camera.x = 0.5
      _ = try draw(0, width: 419, height: 287)
      try require(
        try snapshot() == frozen && wind.phase == phase, "Orbit or resize advanced a paused wake.")
      settings.paused = false
      input = PointerState()
      let beforeTick = wind.tick
      _ = try draw(2)
      try require(wind.tick - beforeTick <= 6, "A stalled display caused unbounded wind catch-up.")
      input.down = true
      input.inside = true
      input.modifiers = 1
      for _ in 0..<180 { _ = try draw() }
      try require(wind.rotorSpeed < 0.002, "The rotor brake did not settle.")
      input = PointerState()
      for _ in 0..<90 { _ = try draw() }
      try require(wind.rotorSpeed > 1, "Releasing the brake did not restart the rotor.")
      results["pause_orbit_resize_brake_resume_bounded_catchup"] = true
      engine.reset()
      _ = try draw(0)
      for _ in 0..<30 { _ = try draw() }
      let calm = try snapshot()
      engine.reset()
      _ = try draw(0)
      input.inside = true
      input.down = true
      input.position = SIMD2(0.55, 0.48)
      for _ in 0..<30 { _ = try draw() }
      let stirred = try snapshot()
      try require(
        zip(calm, stirred).contains { abs($0 - $1) > 0.01 },
        "Dragging did not disturb the particle wake.")
      input = PointerState()
      engine.reset()
      settings.intensity = 0.4
      _ = try draw(0)
      let slow = try snapshot()
      settings.intensity = 2
      engine.reset()
      _ = try draw(0)
      let fast = try snapshot()
      let slowVelocity = stride(from: 4, to: slow.count, by: 8).reduce(Float(0)) {
        $0 + abs(slow[$1])
      }
      let fastVelocity = stride(from: 4, to: fast.count, by: 8).reduce(Float(0)) {
        $0 + abs(fast[$1])
      }
      try require(fastVelocity > slowVelocity * 2, "Wind control did not change tracer transport.")
      settings.intensity = 1
      results["pointer_stirs_and_wind_changes_transport"] = true
      let allocated = wind.resourceBytes
      settings.intensity = 2
      settings.sceneParameters = SIMD4(2, 2, 2, 0)
      input.down = true
      input.inside = true
      for n in 0..<600 {
        input.position = SIMD2(0.5 + sin(Float(n) * 0.09) * 0.25, 0.5 + cos(Float(n) * 0.07) * 0.2)
        _ = try draw(1 / 30, width: 320, height: 220)
      }
      let stressed = try snapshot()
      try require(
        stressed.allSatisfy(\.isFinite) && wind.resourceBytes == allocated,
        "Sustained wind interaction diverged or grew allocations.")
      for i in stride(from: 0, to: stressed.count, by: 8) {
        try require(
          stressed[i] >= (-5.61) && stressed[i] <= 2.1 && abs(stressed[i + 1]) < 4
            && abs(stressed[i + 2]) < 3.3, "Stress particle escaped.")
      }
      results["twenty_seconds_max_controls_bounded_particles_and_memory"] = true
      try require(
        !FrameScheduling.shouldRun(
          visible: false, paused: false, staticScene: false, refinementPending: true,
          interacting: true, redrawPending: true),
        "Hidden window policy allowed rendering.")
      results["hidden_window_stops_rendering"] = true
      print(
        "PASS turbine mechanics: cadence, finite bounds, pause, resize, brake, release, input, wind and sustained stress"
      )
    }
    settings = Settings()
    settings.scene = .turbine
    settings.quality = 2
    input = PointerState()
    for preset in 0..<3 {
      settings.preset = preset
      engine.reset()
      for _ in 0..<100 { _ = try draw(1 / 60, width: 1440, height: 1000) }
      try save("turbine-\(preset)")
    }
    settings.preset = 0
    input.camera.x = -0.55
    input.camera.y = 0.12
    _ = try draw(0, width: 1440, height: 1000)
    try save("turbine-orbit")
    input = PointerState()
    input.down = true
    input.inside = true
    input.position = SIMD2(0.43, 0.48)
    for _ in 0..<75 { _ = try draw(1 / 60, width: 1440, height: 1000) }
    try save("turbine-disturbed")
    var performance: [[String: Any]] = []
    input = PointerState()
    for quality in 0..<4 {
      settings.quality = quality
      let (w, h) = settings.renderSize(for: CGSize(width: 1920, height: 1280))
      var times: [Double] = []
      for n in 0..<35 {
        let t = try draw(1 / 60, width: w, height: h)
        if n > 5 { times.append(t) }
      }
      times.sort()
      try require(
        wind.particleCount == WindEngine.counts[quality] && wind.resourceBytes < 160 * 1024 * 1024,
        "Quality exceeded the turbine resource budget.")
      performance.append([
        "quality": quality, "width": w, "height": h, "particles": wind.particleCount,
        "gpu_median_ms": times[times.count / 2],
        "gpu_p95_ms": times[Int(Double(times.count - 1) * 0.95)],
        "scene_resource_bytes": wind.resourceBytes,
      ])
    }
    results["performance"] = performance
    if args.contains("--movie") {
      let movie = try OffscreenMovie(
        url: folder.appendingPathComponent("turbine.mov"), width: 1200, height: 800)
      settings.quality = 2
      input = PointerState()
      engine.reset()
      for n in 0..<240 {
        input.camera.x = sin(Float(n) / 240 * Float.pi) * 0.23
        input.down = n >= 110 && n < 170
        input.inside = input.down
        input.position = SIMD2(
          0.48 + sin(Float(n) * 0.05) * 0.09, 0.47 + cos(Float(n) * 0.04) * 0.08)
        if n >= 180 && n < 225 {
          input.down = true
          input.inside = true
          input.modifiers = 1
        } else {
          input.modifiers = 0
        }
        _ = try draw(1 / 30, width: 1200, height: 800)
        try movie.append(engine.readback(engine.output!))
      }
      try movie.finish()
      results["movie_seconds"] = 8
    }
    settings.scene = .liquid
    input = PointerState()
    _ = try draw(0)
    try require(
      wind.resourceBytes == 0 && wind.particleCount == 0, "Turbine resources survived scene exit.")
    results["resources_released_on_exit"] = true
    let report: [String: Any] = [
      "all_passed": true, "preview_only": args.contains("--preview-only"),
      "device": engine.device.name, "results": results,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: folder.appendingPathComponent("turbine-test.json"), options: .atomic)
    print("PASS Prismatic Turbine: \(folder.path)")
  }
}
