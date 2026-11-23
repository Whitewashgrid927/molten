import AVFoundation
import Synchronization
import simd

private struct PoolVoice {
  var first = SIMD4<Float>.zero
  var second = SIMD4<Float>.zero
  var coefficient = SIMD4<Float>.zero
  var decaySquared = SIMD4<Float>.zero
  var left: Float = 0
  var right: Float = 0
  var splash: Float = 0
  var remaining = 0
}

// Main-thread producer, audio-thread consumer. A bounded SPSC queue, fixed voices,
// no locks, allocations, files, model inference or Metal work on the audio thread.
final class PoolSampler: @unchecked Sendable {
  static let sampleRate: Double = 48_000
  private static let capacity: UInt32 = 64
  private let readIndex = Atomic<UInt32>(0)
  private let writeIndex = Atomic<UInt32>(0)
  private let control = Atomic<UInt64>(0)
  private let resonance = Atomic<UInt32>(Float(0.65).bitPattern)
  private let events: UnsafeMutablePointer<PoolSoundEvent>
  private let voices: UnsafeMutablePointer<PoolVoice>
  private var nextVoice = 0
  private var seed: UInt32 = 0x517c_c1b7
  private var low: Float = 0
  private var mid: Float = 0
  private var smoothFlow: Float = 0
  private var smoothPan: Float = 0
  init() {
    events = .allocate(capacity: Int(Self.capacity))
    events.initialize(
      repeating: PoolSoundEvent(strength: 0, pan: 0, frequency: 196, splash: 0),
      count: Int(Self.capacity))
    voices = .allocate(capacity: 8)
    voices.initialize(repeating: PoolVoice(), count: 8)
  }
  deinit {
    events.deinitialize(count: Int(Self.capacity))
    events.deallocate()
    voices.deinitialize(count: 8)
    voices.deallocate()
  }
  @discardableResult func enqueue(_ event: PoolSoundEvent) -> Bool {
    guard event.strength.isFinite, event.pan.isFinite, event.frequency.isFinite,
      event.splash.isFinite
    else { return false }
    let w = writeIndex.load(ordering: .relaxed)
    let r = readIndex.load(ordering: .acquiring)
    guard w &- r < Self.capacity else { return false }
    events[Int(w % Self.capacity)] = PoolSoundEvent(
      strength: min(1, max(0, event.strength)),
      pan: min(1, max(-1, event.pan)), frequency: min(1800, max(70, event.frequency)),
      splash: min(1, max(0, event.splash)))
    writeIndex.store(w &+ 1, ordering: .releasing)
    return true
  }
  func set(flow: Float, pan: Float, resonance value: Float) {
    let f = flow.isFinite ? min(1, max(0, flow)) : 0
    let p = pan.isFinite ? min(1, max(-1, pan)) : 0
    control.store(UInt64(f.bitPattern) | (UInt64(p.bitPattern) << 32), ordering: .relaxed)
    resonance.store(
      (value.isFinite ? min(1, max(0, value)) : Float(0.65)).bitPattern, ordering: .relaxed)
  }
  private func strike(_ event: PoolSoundEvent, resonance: Float) {
    let bands = SIMD4<Float>(1, 2.756, 5.404, 8.933)
    let amplitudes = SIMD4<Float>(0.21, 0.105, 0.044, 0.019) * event.strength
    let duration = SIMD4<Float>(0.55 + resonance * 1.2, 0.27 + resonance * 0.45, 0.15, 0.07)
    var v = PoolVoice()
    for j in 0..<4 {
      let angle = 2 * Float.pi * event.frequency * bands[j] / Float(Self.sampleRate)
      let decay = exp(-1 / (duration[j] * Float(Self.sampleRate)))
      v.first[j] = amplitudes[j] * sin(angle)
      v.coefficient[j] = 2 * decay * cos(angle)
      v.decaySquared[j] = decay * decay
    }
    v.left = sqrt((1 - event.pan * 0.88) * 0.5)
    v.right = sqrt((1 + event.pan * 0.88) * 0.5)
    v.splash = event.strength * event.splash * 0.34
    v.remaining = Int(Self.sampleRate * 3.4)
    voices[nextVoice] = v
    nextVoice = (nextVoice + 1) % 8
  }
  func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
    let packed = control.load(ordering: .relaxed)
    let flow = Float(bitPattern: UInt32(truncatingIfNeeded: packed))
    let pan = Float(bitPattern: UInt32(truncatingIfNeeded: packed >> 32))
    let ring = Float(bitPattern: resonance.load(ordering: .relaxed))
    var r = readIndex.load(ordering: .relaxed)
    let w = writeIndex.load(ordering: .acquiring)
    while r != w {
      strike(events[Int(r % Self.capacity)], resonance: ring)
      r &+= 1
    }
    readIndex.store(r, ordering: .releasing)
    for i in 0..<frames {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      let white = Float(seed >> 8) / 8_388_608 - 1
      low += (white - low) * 0.025
      mid += (white - mid) * 0.21
      smoothFlow += (flow - smoothFlow) * 0.0014
      smoothPan += (pan - smoothPan) * 0.001
      let water = (mid - low) * smoothFlow * 0.15
      var l = water * sqrt((1 - smoothPan * 0.75) * 0.5)
      var rr = water * sqrt((1 + smoothPan * 0.75) * 0.5)
      for j in 0..<8 where voices[j].remaining > 0 {
        let next =
          voices[j].coefficient * voices[j].first - voices[j].decaySquared * voices[j].second
        voices[j].second = voices[j].first
        voices[j].first = next
        let fade = min(1, Float(voices[j].remaining) / 240)
        let tone = (next.x + next.y + next.z + next.w + (mid - low) * voices[j].splash) * fade
        l += tone * voices[j].left
        rr += tone * voices[j].right
        voices[j].splash *= 0.99945
        voices[j].remaining -= 1
      }
      left[i] = l / (1 + abs(l) * 0.7)
      right[i] = rr / (1 + abs(rr) * 0.7)
    }
  }
}

enum PoolAudioGraph {
  static func make(sampler: PoolSampler) throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    guard
      let format = AVAudioFormat(standardFormatWithSampleRate: PoolSampler.sampleRate, channels: 2)
    else {
      throw MoltenError.failed("The pool audio format is unavailable.")
    }
    let node = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(list)
      guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else {
        return -50
      }
      sampler.render(
        frames: Int(frames), left: left.assumingMemoryBound(to: Float.self),
        right: right.assumingMemoryBound(to: Float.self))
      return noErr
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    return engine
  }
}

@MainActor final class PoolAudio {
  private var engine: AVAudioEngine?
  private var sampler: PoolSampler?
  private var active = false
  private var lastSound: Double = 0
  private(set) var enabled = true
  var running: Bool { engine?.isRunning ?? false }
  var onChange: (() -> Void)?
  var onError: ((String) -> Void)?
  func toggle() {
    enabled.toggle()
    if !enabled { stop() }
    onChange?()
  }
  func setActive(_ value: Bool) {
    active = value
    if !value { stop() }
  }
  func synchronize(motion: PoolSimulation, settings: Settings) {
    guard active && enabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if !motion.sounds.isEmpty || motion.flow > 0.002 { lastSound = now }
    if now - lastSound > 3.5 {
      stop()
      return
    }
    do {
      if engine == nil {
        let sampler = PoolSampler()
        let graph = try PoolAudioGraph.make(sampler: sampler)
        self.sampler = sampler
        self.engine = graph
        try graph.start()
      }
      let pan = motion.touchingWater ? motion.touch.x / 2.1 : motion.stone.x / 2.1
      sampler?.set(flow: motion.flow, pan: pan, resonance: settings.sceneParameters.x)
      for var event in motion.sounds {
        event.frequency *= [Float(1), 0.75, 1.125][settings.preset]
        sampler?.enqueue(event)
      }
    } catch {
      enabled = false
      stop()
      onError?(error.localizedDescription)
      onChange?()
    }
  }
  private func stop() {
    engine?.stop()
    engine = nil
    sampler = nil
  }
  func release() {
    active = false
    lastSound = 0
    stop()
  }
}
