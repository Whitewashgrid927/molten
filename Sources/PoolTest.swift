import AVFoundation
import Foundation
import Metal
import Synchronization
import simd

enum PoolTest {
  static func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw MoltenError.failed(reason) }
  }
  static func run() throws {
    let args = CommandLine.arguments
    let index = args.firstIndex(of: "--output")
    let dir = URL(
      fileURLWithPath: index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        ?? "/tmp/molten-pool")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var results: [String: Any] = [:]
    let engine = try MetalEngine()
    let pool = engine.cinematic.pool
    var settings = Settings()
    var input = PointerState()
    var frame: UInt32 = 0
    settings.scene = .resonantGarden
    settings.quality = 2
    func draw(_ dt: Float = 1 / 60, width: Int = 480, height: Int = 320) throws -> Double {
      try autoreleasepool {
        guard let command = engine.queue.makeCommandBuffer() else {
          throw MoltenError.failed("No pool test command.")
        }
        _ = try engine.encode(
          command: command, width: width, height: height, time: pool.motion.time,
          dt: dt, frame: frame, settings: settings, input: input)
        input.poolEvents.removeAll(keepingCapacity: true)
        command.commit()
        command.waitUntilCompleted()
        frame &+= 1
        try require(
          command.status == .completed && command.error == nil,
          "Pool GPU command failed: \(String(describing: command.error))")
        return (command.gpuEndTime - command.gpuStartTime) * 1000
      }
    }
    func image() throws -> PixelImage { try engine.readback(engine.output!) }
    func save(_ name: String) throws {
      try image().save(to: dir.appendingPathComponent(name + ".png"))
    }
    func state() throws -> [Float] { try pool.snapshot(queue: engine.queue) }
    func press(_ uv: SIMD2<Float>, timestamp: Double) {
      input.position = uv
      input.inside = true
      input.down = true
      input.poolEvents = [.init(kind: .press, position: uv, timestamp: timestamp)]
    }
    func move(_ uv: SIMD2<Float>, timestamp: Double) {
      input.position = uv
      input.poolEvents = [.init(kind: .move, position: uv, timestamp: timestamp)]
    }
    func release(timestamp: Double) {
      input.down = false
      input.poolEvents = [.init(kind: .release, position: input.position, timestamp: timestamp)]
    }
    try require(
      MemoryLayout<PoolFrame>.stride == 224 && MemoryLayout<PoolImpulse>.stride == 16,
      "Pool shader ABI mismatch.")
    if !args.contains("--preview-only") {
      var local = Settings()
      local.scene = .resonantGarden
      let p = PoolSimulation()
      let uv = PoolProjection.project(p.stone, aspect: 1.5)
      var pointer = PointerState()
      pointer.position = uv
      pointer.inside = true
      pointer.poolEvents = [
        .init(kind: .press, position: uv, timestamp: 1),
        .init(kind: .release, position: uv, timestamp: 1.006),
      ]
      p.advance(input: pointer, dt: 1 / 60, aspect: 1.5, settings: local)
      try require(
        p.grabSerial == 1 && !p.held && p.airborne, "A complete tap between frames was lost.")
      pointer.poolEvents = []
      pointer.inside = false
      var contacts = p.sounds.count
      for _ in 0..<240 {
        p.advance(input: pointer, dt: 1 / 120, aspect: 1.5, settings: local)
        contacts += p.sounds.count
      }
      try require(
        p.skips == 0 && !p.airborne && abs(p.stone.y - PoolSimulation.restHeight) < 0.003
          && contacts >= 2,
        "A gentle placement did not land, sound and settle.")
      results["subframe_tap_and_gentle_placement"] = true
      func launch(_ simulation: PoolSimulation) -> PointerState {
        let start = PoolProjection.project(simulation.stone, aspect: 1.5)
        let end = start + SIMD2<Float>(0.09, -0.005)
        var q = PointerState()
        q.position = end
        q.inside = true
        q.poolEvents = [
          .init(kind: .press, position: start, timestamp: 1),
          .init(kind: .move, position: start + SIMD2(0.035, 0), timestamp: 1.02),
          .init(kind: .move, position: end, timestamp: 1.04),
          .init(kind: .release, position: end, timestamp: 1.045),
        ]
        simulation.advance(input: q, dt: 0, aspect: 1.5, settings: local)
        q.poolEvents = []
        q.inside = false
        return q
      }
      var states: [SIMD3<Float>] = []
      var skipCounts: [Int] = []
      for fps in [30, 60, 120] {
        let sim = PoolSimulation()
        let pointer = launch(sim)
        try require(
          simd_length(sim.velocity) > 1.2, "A fresh flick did not retain release velocity.")
        for _ in 0..<(fps * 2) {
          sim.advance(input: pointer, dt: 1 / Float(fps), aspect: 1.5, settings: local)
          try require(
            sim.stone.x.isFinite && sim.stone.y.isFinite && sim.stone.z.isFinite
              && simd_length(SIMD2(sim.stone.x, sim.stone.z)) < PoolProjection.radius,
            "A skipped stone escaped the pool or became invalid.")
        }
        states.append(sim.stone)
        skipCounts.append(sim.skips)
        try require(sim.skips > 0 && sim.skips <= 4, "Flicking did not produce bounded skips.")
      }
      try require(
        simd_distance(states[0], states[1]) < 0.0001
          && simd_distance(states[1], states[2]) < 0.0001,
        "Free-flight physics depends on rendering cadence.")
      results["fixed_120hz_flight_at_30_60_120fps"] = true
      results["skip_counts"] = skipCounts
      let still = PoolSimulation()
      var q = PointerState()
      q.inside = true
      q.down = true
      q.position = uv
      q.poolEvents = [
        .init(kind: .press, position: uv, timestamp: 0),
        .init(kind: .move, position: uv + SIMD2(0.10, 0), timestamp: 0.02),
      ]
      q.position += SIMD2(0.10, 0)
      still.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local)
      q.poolEvents = []
      for _ in 0..<30 { still.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local) }
      q.down = false
      q.poolEvents = [.init(kind: .release, position: q.position, timestamp: 0.55)]
      still.advance(input: q, dt: 0, aspect: 1.5, settings: local)
      try require(
        simd_length(SIMD2(still.velocity.x, still.velocity.z)) < 0.01,
        "An old movement caused an unintended throw.")
      q.poolEvents = []
      q.inside = false
      let previousTick = still.tick
      still.advance(input: q, dt: 2, aspect: 1.5, settings: local)
      try require(still.tick - previousTick <= 8, "A stalled frame caused unbounded catch-up.")
      let cancelled = PoolSimulation()
      q = PointerState()
      q.position = uv
      q.inside = true
      q.down = true
      cancelled.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local)
      try require(cancelled.held, "Center hit testing missed the visible stone.")
      q.cancelSerial = 1
      q.down = false
      cancelled.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local)
      try require(
        !cancelled.held && !cancelled.airborne && cancelled.velocity == .zero,
        "Focus cancellation launched the stone.")
      results["stationary_release_focus_cancel_bounded_catchup"] = true
      // Every visible stone must be selectable, independent and voiced differently.
      var frequencies: [Float] = []
      let garden = PoolSimulation()
      for index in 0..<3 {
        var q = PointerState()
        q.inside = true
        q.down = true
        q.position = PoolProjection.project(garden.stones[index].position, aspect: 1.5)
        q.poolEvents = [.init(kind: .press, position: q.position, timestamp: Double(index + 2))]
        garden.advance(input: q, dt: 1 / 120, aspect: 1.5, settings: local)
        try require(
          garden.held && garden.selectedStone == index,
          "Garden stone picking disagrees with its rendered position.")
        frequencies.append(garden.sounds.first?.frequency ?? 0)
        q.down = false
        q.poolEvents = [
          .init(kind: .release, position: q.position, timestamp: Double(index + 2) + 0.01)
        ]
        garden.advance(input: q, dt: 1 / 120, aspect: 1.5, settings: local)
      }
      try require(
        Set(frequencies).count == 3 && frequencies.allSatisfy { $0 > 100 },
        "The three stones do not have distinct voices.")
      q = PointerState()
      for _ in 0..<400 { garden.advance(input: q, dt: 1 / 120, aspect: 1.5, settings: local) }
      try require(
        garden.stones.allSatisfy { $0.settled && !$0.airborne },
        "A previously released stone froze when another was picked up.")
      for index in 0..<3 {
        let root = PoolProjection.plantRoots[index]
        let start = PoolProjection.project(SIMD3(root.x, 0.44, root.y), aspect: 1.5)
        q = PointerState()
        q.inside = true
        q.down = true
        q.position = start
        q.poolEvents = [.init(kind: .press, position: start, timestamp: 10)]
        garden.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local)
        try require(garden.brushingPlant == index, "A garden plant could not be touched.")
        q.position += SIMD2(0.05, -0.01)
        q.poolEvents = [.init(kind: .move, position: q.position, timestamp: 10.1)]
        garden.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local)
        q.poolEvents = []
        for _ in 0..<30 { garden.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local) }
        try require(
          simd_length(garden.plants[index].bend) > 0.1, "Brushing did not bend the plant.")
        let before = garden.plants[index].bend
        var paused = local
        paused.paused = true
        garden.advance(input: q, dt: 1 / 30, aspect: 1.5, settings: paused)
        try require(garden.plants[index].bend == before, "Pause did not freeze the leaves.")
        q.down = false
        q.poolEvents = [.init(kind: .release, position: q.position, timestamp: 10.7)]
        garden.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local)
        try require(
          !garden.sounds.isEmpty && !garden.impulses.isEmpty && garden.brushingPlant < 0,
          "Plant release did not connect its sound and river ripple.")
        q = PointerState()
        for _ in 0..<550 { garden.advance(input: q, dt: 1 / 60, aspect: 1.5, settings: local) }
        try require(
          garden.isAtRest && garden.plants.allSatisfy { $0.energy == 0 },
          "The plants kept the garden awake.")
      }
      results["three_independent_stones_distinct_voices"] = true
      results["three_plants_brush_release_sound_ripple_pause_sleep"] = true
      print(
        "PASS pool mechanics: hit test, subframe tap, gentle placement, flick/skip, cadence, stale velocity and focus cancellation"
      )

      _ = try draw(0)
      let initial = try image().bytes
      try require(
        pool.motion.isAtRest && state().allSatisfy { $0 == 0 },
        "The untouched pool did not begin at rest.")
      press(PoolProjection.project(SIMD3(0.8, 0, 0.65), aspect: 1.5), timestamp: 0.1)
      _ = try draw(0)
      release(timestamp: 0.11)
      _ = try draw(0)
      _ = try draw(1 / 120)
      try require(
        try state().contains { abs($0) > 0.0001 },
        "A tap between fixed physics steps lost its ripple.")
      engine.reset()
      input = PointerState()
      _ = try draw(0)
      results["substep_water_tap_retained"] = true
      press(PoolProjection.project(SIMD3(0.8, 0, 0.65), aspect: 1.5), timestamp: 1)
      for n in 0..<40 {
        if n > 0 { move(input.position + SIMD2(0.001, 0), timestamp: 1 + Double(n) / 60) }
        _ = try draw()
      }
      let active = try state()
      print(
        "Pool wave peak: \(active.map { abs($0) }.max() ?? 0), touching: \(pool.motion.touchingWater), flow: \(pool.motion.flow), tick: \(pool.motion.tick)"
      )
      try require(
        active.allSatisfy(\.isFinite) && active.map { abs($0) }.max()! > 0.001,
        "Water contact did not create a finite persistent wave.")
      try require(try image().bytes != initial, "Water motion was not visible.")
      release(timestamp: 2)
      _ = try draw()
      settings.paused = true
      _ = try draw(0)
      let frozen = try state()
      let frozenStone = pool.motion.stone
      let frozenTick = pool.motion.tick
      for _ in 0..<6 { _ = try draw(1 / 30) }
      try require(
        try state() == frozen && pool.motion.tick == frozenTick && pool.motion.stone == frozenStone,
        "Paused pool kept simulating.")
      settings.quality = 3
      _ = try draw(0, width: 701, height: 419)
      try require(
        try state() == frozen && pool.motion.stone == frozenStone, "Quality/resize reset the world."
      )
      settings.paused = false
      input = PointerState()
      for _ in 0..<530 { _ = try draw(1 / 60, width: 160, height: 110) }
      try require(
        pool.motion.isAtRest && state().allSatisfy { $0 == 0 },
        "Pool did not settle to an exactly flat sleeping surface.")
      let allocation = pool.resourceBytes
      for _ in 0..<80 { _ = try draw(1 / 60, width: 160, height: 110) }
      try require(
        allocation == pool.resourceBytes && allocation <= 2 * 1024 * 1024,
        "Pool simulation allocations grew or exceeded their budget.")
      for visible in [false, true] {
        for paused in [false, true] {
          for resting in [false, true] {
            let running = FrameScheduling.shouldRunPool(
              visible: visible, paused: paused, atRest: resting, redrawPending: false)
            try require(
              running == (visible && !paused && !resting), "Pool lifecycle schedule failed.")
          }
        }
      }
      try require(
        FrameScheduling.shouldRunPool(
          visible: true, paused: false, atRest: true, redrawPending: true),
        "Resting input could not wake the display.")
      results["waves_pause_quality_resize_settle"] = true
      results["simulation_bytes"] = allocation
      results["hidden_paused_and_idle_scheduling"] = true
      print(
        "PASS pool GPU: persistent water, pause, quality/resize continuity, exact sleep, bounded allocations and lifecycle policy"
      )
      let sampler = PoolSampler()
      let count = 48_000
      var left = [Float](repeating: 0, count: count)
      var right = left
      sampler.render(frames: count, left: &left, right: &right)
      try require(
        left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 },
        "Pool audio was not silent before touch.")
      sampler.enqueue(.init(strength: 0.8, pan: -0.9, frequency: 196, splash: 0.6))
      sampler.render(frames: count, left: &left, right: &right)
      let peak = (left + right).map { abs($0) }.max()!
      let le = left.reduce(Float(0)) { $0 + $1 * $1 }
      let re = right.reduce(Float(0)) { $0 + $1 * $1 }
      try require(
        left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite) && peak < 0.8 && peak > 0.02
          && le > re * 3,
        "Resonant audio had invalid samples, clipping, silence or wrong stereo position.")
      for _ in 0..<4 { sampler.render(frames: count, left: &left, right: &right) }
      try require(left.allSatisfy { abs($0) < 0.00001 }, "Audio did not decay to silence.")
      let bounded = PoolSampler()
      var accepted = 0
      for _ in 0..<300 {
        if bounded.enqueue(.init(strength: 1, pan: 0, frequency: 196, splash: 1)) { accepted += 1 }
      }
      try require(
        accepted == 64
          && !bounded.enqueue(.init(strength: .nan, pan: 0, frequency: 196, splash: 0)),
        "Audio event queue is unbounded or accepted NaN.")
      bounded.render(frames: count, left: &left, right: &right)
      try require(
        (left + right).allSatisfy { $0.isFinite && abs($0) < 1 }, "Overlapping strikes clipped.")
      // Exercise the same AVAudioSourceNode/mixer path without opening an audio device.
      let graphSampler = PoolSampler()
      let graph = try PoolAudioGraph.make(sampler: graphSampler)
      let format = AVAudioFormat(standardFormatWithSampleRate: PoolSampler.sampleRate, channels: 2)!
      try graph.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
      try graph.start()
      graphSampler.enqueue(.init(strength: 0.7, pan: 0.8, frequency: 220, splash: 0.7))
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
      var graphEnergy: Float = 0
      for _ in 0..<12 {
        let status = try graph.renderOffline(1024, to: buffer)
        try require(status == .success, "Offline native audio graph did not render.")
        for i in 0..<Int(buffer.frameLength) { graphEnergy += abs(buffer.floatChannelData![0][i]) }
      }
      graph.stop()
      try require(graphEnergy > 1, "Native audio graph produced silence.")
      results["audio_silent_until_touch_finite_panned_bounded"] = true
      results["audio_peak"] = peak
      results["audio_native_offline_graph"] = true
      print(
        "PASS pool audio: silence, resonant strike, stereo pan, finite samples, decay, queue budget and native offline graph"
      )
    }
    settings = Settings()
    settings.scene = .resonantGarden
    settings.quality = 2
    input = PointerState()
    engine.reset()
    for preset in 0..<3 {
      settings.preset = preset
      _ = try draw(0, width: 1440, height: 960)
      try save("pool-\(preset)")
    }
    settings.preset = 0
    press(PoolProjection.project(pool.motion.stone, aspect: 1.5), timestamp: 1)
    for n in 0..<30 {
      if n > 0 { move(input.position + SIMD2(0.003, -0.001), timestamp: 1 + Double(n) / 60) }
      _ = try draw(1 / 60, width: 1440, height: 960)
    }
    try save("pool-held")
    move(input.position + SIMD2(-0.045, 0.005), timestamp: 1.51)
    _ = try draw(1 / 60)
    move(input.position + SIMD2(-0.06, 0.005), timestamp: 1.53)
    _ = try draw(1 / 60)
    release(timestamp: 1.535)
    for _ in 0..<18 { _ = try draw(1 / 60, width: 1440, height: 960) }
    try save("pool-skipping")
    engine.reset()
    input = PointerState()
    let root = PoolProjection.plantRoots[0]
    press(PoolProjection.project(SIMD3(root.x, 0.44, root.y), aspect: 1.5), timestamp: 4)
    _ = try draw(1 / 60, width: 1440, height: 960)
    move(input.position + SIMD2(0.07, -0.015), timestamp: 4.1)
    for _ in 0..<30 { _ = try draw(1 / 60, width: 1440, height: 960) }
    try save("garden-brush")
    release(timestamp: 4.6)
    _ = try draw(1 / 60, width: 1440, height: 960)
    var performance: [[String: Any]] = []
    for quality in 0..<4 {
      settings.quality = quality
      let (w, h) = settings.renderSize(for: CGSize(width: 1920, height: 1280))
      var times: [Double] = []
      for n in 0..<35 {
        input.inside = true
        input.down = true
        input.position = PoolProjection.project(
          SIMD3(0.6 + Float(n) * 0.004, 0, 0.8), aspect: Float(w) / Float(h))
        let t = try draw(1 / 60, width: w, height: h)
        if n > 5 { times.append(t) }
      }
      times.sort()
      performance.append([
        "quality": quality, "width": w, "height": h, "gpu_median_ms": times[times.count / 2],
        "gpu_p95_ms": times[Int(Double(times.count - 1) * 0.95)],
        "gpu_allocated_bytes": engine.device.currentAllocatedSize,
      ])
    }
    results["performance"] = performance
    if args.contains("--movie") {
      try movie(engine: engine, directory: dir)
      results["movie_seconds"] = 12
    }
    settings.scene = .liquid
    _ = try draw(0)
    try require(pool.resourceBytes == 0, "Pool resources survived scene exit.")
    results["resources_released_on_exit"] = true
    let report: [String: Any] = [
      "all_passed": true, "preview_only": args.contains("--preview-only"),
      "device": engine.device.name, "results": results,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: dir.appendingPathComponent("pool-test.json"), options: .atomic)
    print("PASS River Garden; report: \(dir.path)")
  }

  static func movie(engine: MetalEngine, directory: URL) throws {
    let raw = directory.appendingPathComponent("pool-silent.mov")
    let wav = directory.appendingPathComponent("pool-audio.wav")
    let movie = try OffscreenMovie(url: raw, width: 1200, height: 800)
    let sampler = PoolSampler()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    var fileSettings = format.settings
    fileSettings[AVLinearPCMIsNonInterleaved] = false
    var audio: AVAudioFile? = try AVAudioFile(forWriting: wav, settings: fileSettings)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
    pcm.frameLength = 1600
    var settings = Settings()
    settings.scene = .resonantGarden
    settings.quality = 2
    var input = PointerState()
    var start = SIMD2<Float>.zero
    engine.reset()
    for n in 0..<360 {
      try autoreleasepool {
        let t = Double(n) / 30
        let motion = engine.cinematic.pool.motion
        input.poolEvents = []
        func event(_ kind: PoolPointerEvent.Kind, _ uv: SIMD2<Float>) {
          input.position = uv
          input.inside = true
          if case .press = kind { input.down = true }
          if case .release = kind { input.down = false }
          input.poolEvents.append(.init(kind: kind, position: uv, timestamp: t))
        }
        if n == 24 {
          start = PoolProjection.project(motion.stone, aspect: 1.5)
          event(.press, start)
        }
        if n > 24 && n < 63 {
          let s = Float(n - 24) / 39
          event(.move, start + SIMD2(0.14 * s, -0.045 * sin(s * Float.pi * 0.7)))
        }
        if n == 66 { event(.release, input.position) }
        if n == 110 {
          start = PoolProjection.project(motion.stone, aspect: 1.5)
          event(.press, start)
        }
        if n >= 117 && n <= 121 {
          event(.move, start + SIMD2(-Float(n - 116) * 0.033, Float(n - 116) * 0.001))
        }
        if n == 122 { event(.release, input.position) }
        if n == 186 { event(.press, PoolProjection.project(SIMD3(0.55, 0, 0.8), aspect: 1.5)) }
        if n > 186 && n < 249 {
          let s = Float(n - 186) / 62 * Float.pi * 1.6
          event(
            .move,
            PoolProjection.project(SIMD3(0.55 * cos(s), 0, 0.65 + 0.35 * sin(s)), aspect: 1.5))
        }
        if n == 249 { event(.release, input.position) }
        if n == 270 {
          let root = PoolProjection.plantRoots[0]
          start = PoolProjection.project(SIMD3(root.x, 0.44, root.y), aspect: 1.5)
          event(.press, start)
        }
        if n > 270 && n < 292 {
          event(.move, start + SIMD2(Float(n - 270) * 0.003, -Float(n - 270) * 0.0007))
        }
        if n == 292 { event(.release, input.position) }
        guard let command = engine.queue.makeCommandBuffer() else {
          throw MoltenError.failed("No pool movie command.")
        }
        let texture = try engine.encode(
          command: command, width: 1200, height: 800, time: Float(t), dt: 1 / 30,
          frame: UInt32(n), settings: settings, input: input)
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        try movie.append(engine.readback(texture))
        sampler.set(
          flow: motion.flow, pan: (motion.touchingWater ? motion.touch.x : motion.stone.x) / 2.1,
          resonance: 0.65)
        for event in motion.sounds { sampler.enqueue(event) }
        sampler.render(
          frames: 1600, left: pcm.floatChannelData![0], right: pcm.floatChannelData![1])
        try audio!.write(from: pcm)
      }
    }
    try movie.finish()
    audio = nil
    // Flush the WAV header before loading it into AVFoundation's composition.
    let destination = directory.appendingPathComponent("pool-interaction.mov")
    try mux(video: raw, audio: wav, destination: destination)
  }
  private static func mux(video: URL, audio: URL, destination: URL) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let failure = Mutex<String?>(nil)
    Task.detached {
      do {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        guard let v = try await videoAsset.loadTracks(withMediaType: .video).first,
          let a = try await audioAsset.loadTracks(withMediaType: .audio).first,
          let vt = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let at = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
          throw MoltenError.failed("Missing pool demonstration media track.")
        }
        let duration = try await videoAsset.load(.duration)
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: v, at: .zero)
        try at.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: a, at: .zero)
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.removeItem(at: destination)
        }
        guard
          let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
          throw MoltenError.failed("Cannot create the demonstration exporter.")
        }
        try await exporter.export(to: destination, as: .mov)
      } catch { failure.withLock { $0 = error.localizedDescription } }
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 60) == .success else {
      throw MoltenError.failed("Pool movie export timed out.")
    }
    if let message = failure.withLock({ $0 }) { throw MoltenError.failed(message) }
  }
}
