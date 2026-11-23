import Foundation
import Metal

enum PaperTest {
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw MoltenError.failed(message) }
  }
  static func run() throws {
    let args = CommandLine.arguments
    let index = args.firstIndex(of: "--output")
    let directory = URL(
      fileURLWithPath: index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        ?? "/tmp/molten-paper")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let engine = try MetalEngine()
    let paper = engine.cinematic.paper
    var settings = Settings()
    settings.scene = .paperFolders
    settings.quality = 0
    var input = PointerState()
    var frame: UInt32 = 0
    var results: [String: Any] = [:]
    func draw(_ dt: Float = 1 / 60, width: Int = 360, height: Int = 240) throws -> Double {
      try autoreleasepool {
        guard let c = engine.queue.makeCommandBuffer() else {
          throw MoltenError.failed("Cannot make paper test command.")
        }
        _ = try engine.encode(
          command: c, width: width, height: height, time: Float(paper.motion.tick) / 120,
          dt: dt, frame: frame, settings: settings, input: input)
        c.commit()
        c.waitUntilCompleted()
        frame &+= 1
        try require(
          c.status == .completed && c.error == nil,
          "Paper GPU failure: \(String(describing:c.error))")
        return (c.gpuEndTime - c.gpuStartTime) * 1000
      }
    }
    func image() throws -> PixelImage { try engine.readback(engine.output!) }
    func save(_ name: String) throws {
      try image().save(to: directory.appendingPathComponent(name + ".png"))
    }
    try require(MemoryLayout<PaperFrame>.stride == 176, "Paper Swift/Metal ABI mismatch.")
    if !args.contains("--preview-only") {
      let pickFrame = PaperCamera.frame(input: PointerState(), width: 1600, height: 1000)
      let resting = PaperMotion()
      for i in 0..<5 {
        let tab = PaperCamera.base(i, spread: 1) + SIMD3<Float>(-1.05 + Float(i) * 0.07, 3.18, 0)
        let location = PaperCamera.project(tab, frame: pickFrame)
        try require(
          PaperCamera.pick(location, frame: pickFrame, states: resting.states, spread: 1) == i,
          "Visible folder tab could not be selected: \(i)")
      }
      results["all_five_visible_tabs_pick_correct_folder"] = true
      // Real spring trajectories must not change with display refresh rate.
      var trajectories: [[Float]] = []
      for fps in [30, 60, 120] {
        engine.reset()
        input = PointerState()
        input.inside = true
        input.down = true
        input.position = SIMD2(0.60, 0.58)
        for _ in 0..<fps { _ = try draw(1 / Float(fps)) }
        try require(paper.motion.selected != nil, "Click did not select a folder.")
        input.position += SIMD2(0.09, -0.08)
        for _ in 0..<fps { _ = try draw(1 / Float(fps)) }
        trajectories.append(paper.motion.snapshot)
      }
      try require(
        trajectories[0] == trajectories[1] && trajectories[1] == trajectories[2],
        "Paper springs depend on display cadence.")
      results["identical_springs_at_30_60_120hz"] = true
      settings.paused = true
      let frozen = paper.motion.snapshot
      for _ in 0..<5 { _ = try draw(1 / 30) }
      input.camera.x = 0.35
      _ = try draw(1 / 30, width: 419, height: 281)
      try require(
        paper.motion.snapshot == frozen, "Paused paper changed during redraw/orbit/resize.")
      settings.paused = false
      input = PointerState()
      let tick = paper.motion.tick
      _ = try draw(10)
      try require(paper.motion.tick - tick <= 12, "Paper catch-up was unbounded.")
      results["pause_resize_orbit_and_bounded_catchup"] = true
      // Quick press+release is carried by a serial and captured press point.
      engine.reset()
      input = PointerState()
      _ = try draw(0)
      input.inside = true
      input.actionSerial = 1
      input.actionPosition = SIMD2(0.60, 0.58)
      _ = try draw()
      try require(
        paper.motion.selected != nil && !input.down, "Quick click was lost between render frames.")
      for _ in 0..<90 { _ = try draw() }
      let selected = paper.motion.selected!
      try require(
        paper.motion.states[selected].z > 0.99, "Folder failed to open after a quick click.")
      input.actionSerial = 2
      _ = try draw()
      try require(paper.motion.selected == nil, "Clicking an open folder did not close it.")
      input.actionSerial = 3
      input.actionPosition = SIMD2(0.01, 0.01)
      _ = try draw()
      try require(paper.motion.selected == nil, "Clicking the margin selected hidden geometry.")
      input = PointerState()
      for _ in 0..<240 { _ = try draw() }
      try require(
        paper.motion.states.allSatisfy {
          abs($0.x) < 0.0001 && abs($0.y) < 0.0001 && abs($0.z) < 0.0001 && abs($0.w) < 0.0001
        }, "Closed folders did not settle.")
      results["quick_click_open_outside_close_settle"] = true
      // Cancellation releases the drag; later pointer motion cannot pull it.
      input.inside = true
      input.down = true
      input.position = SIMD2(0.60, 0.58)
      for _ in 0..<30 { _ = try draw() }
      input.cancelSerial &+= 1
      input.down = false
      input.position = SIMD2(0.95, 0.05)
      for _ in 0..<120 { _ = try draw() }
      try require(
        paper.motion.states.allSatisfy { abs($0.x) < 0.001 && abs($0.w) < 0.001 },
        "Focus loss retained a paper drag.")
      results["focus_loss_releases_drag"] = true
      let beforeQuality = paper.motion.snapshot
      settings.paused = true
      settings.quality = 2
      _ = try draw(0, width: 360, height: 240)
      try require(
        paper.motion.snapshot == beforeQuality, "Quality change reset the opened paper state.")
      settings.quality = 0
      _ = try draw(0)
      settings.paused = false
      results["quality_preserves_folder_state"] = true
      let bytes = paper.resourceBytes
      settings.intensity = 2
      settings.sceneParameters = SIMD4(2, 1.5, 1.5, 0)
      for n in 0..<600 {
        input.down = n % 90 < 65
        input.inside = true
        input.position = SIMD2(0.5 + sin(Float(n) * 0.07) * 0.3, 0.5 + cos(Float(n) * 0.05) * 0.3)
        _ = try draw(1 / 30)
      }
      try require(
        paper.motion.snapshot.allSatisfy { $0.isFinite && abs($0) < 20 }
          && paper.resourceBytes == bytes,
        "Sustained interaction diverged or grew paper allocations.")
      try require(
        !FrameScheduling.shouldRun(
          visible: false, paused: false, staticScene: false, refinementPending: true,
          interacting: true, redrawPending: true), "Hidden paper scene schedules rendering.")
      results["twenty_seconds_max_controls_constant_memory_and_hidden_policy"] = true
      print(
        "PASS paper interaction: cadence, quick clicks, opening, closing, focus loss, pause, bounds and memory"
      )
    }
    settings = Settings()
    settings.scene = .paperFolders
    settings.quality = 2
    input = PointerState()
    for preset in 0..<3 {
      settings.preset = preset
      engine.reset()
      for _ in 0..<80 { _ = try draw(1 / 60, width: 1600, height: 1000) }
      try save("paper-\(preset)")
    }
    settings.preset = 0
    engine.reset()
    input = PointerState()
    input.down = true
    input.inside = true
    input.position = SIMD2(0.60, 0.58)
    for _ in 0..<80 { _ = try draw(1 / 60, width: 1600, height: 1000) }
    input.position += SIMD2(0.08, -0.06)
    for _ in 0..<45 { _ = try draw(1 / 60, width: 1600, height: 1000) }
    try save("paper-open")
    input = PointerState()
    input.camera.x = -0.30
    input.camera.y = 0.10
    _ = try draw(0, width: 1600, height: 1000)
    try save("paper-orbit")
    var performance: [[String: Any]] = []
    input = PointerState()
    for quality in 0..<4 {
      settings.quality = quality
      let (w, h) = settings.renderSize(for: CGSize(width: 1920, height: 1200))
      var times: [Double] = []
      for n in 0..<40 {
        let t = try draw(1 / 60, width: w, height: h)
        if n > 5 { times.append(t) }
      }
      times.sort()
      try require(
        paper.resourceBytes < 100 * 1024 * 1024, "Paper scene exceeded its resource budget.")
      performance.append([
        "quality": quality, "width": w, "height": h, "gpu_median_ms": times[times.count / 2],
        "gpu_p95_ms": times[Int(Double(times.count - 1) * 0.95)],
        "scene_resource_bytes": paper.resourceBytes,
      ])
    }
    results["performance"] = performance
    if args.contains("--movie") {
      settings.quality = 2
      input = PointerState()
      engine.reset()
      let movie = try OffscreenMovie(
        url: directory.appendingPathComponent("paper.mov"), width: 1280, height: 800)
      for n in 0..<270 {
        input.camera.x = sin(Float(n) / 270 * Float.pi * 2) * 0.16
        input.inside = n >= 45 && n < 195
        input.down = n >= 60 && n < 150
        input.position = SIMD2(
          0.6 + (n > 60 ? sin(min(1, Float(n - 60) / 90) * Float.pi) * 0.09 : 0),
          0.58 - (n > 60 ? sin(min(1, Float(n - 60) / 90) * Float.pi) * 0.09 : 0))
        if n == 195 {
          input.actionSerial = 1
          input.actionPosition = SIMD2(0.01, 0.01)
          input.inside = true
        }
        _ = try draw(1 / 30, width: 1280, height: 800)
        try movie.append(image())
      }
      try movie.finish()
      results["movie_frames"] = movie.frames
    }
    settings.scene = .liquid
    input = PointerState()
    _ = try draw(0)
    try require(paper.resourceBytes == 0, "Paper textures were retained after scene exit.")
    results["resources_released_on_exit"] = true
    let report: [String: Any] = [
      "all_passed": true, "preview_only": args.contains("--preview-only"),
      "device": engine.device.name, "results": results,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("paper-test.json"), options: .atomic)
    print("PASS Paper Reverie: \(directory.path)")
  }
}
