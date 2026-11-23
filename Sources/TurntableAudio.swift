import AVFoundation
import Synchronization

// A bounded, immutable PCM allocation. No decoder, file access, lock or allocation
// runs on the real-time audio thread. Local files never leave this process.
final class TurntableTrack {
    static let byteLimit = 64 * 1024 * 1024
    let buffer: AVAudioPCMBuffer
    let name: String
    var sampleRate: Double { buffer.format.sampleRate }
    var channels: Int { Int(buffer.format.channelCount) }
    var count: Int { Int(buffer.frameLength) }
    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let channels = Int(file.processingFormat.channelCount)
        guard (1...2).contains(channels), file.length > 1,
              file.length <= Int64(Self.byteLimit / (channels * 2)),
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MoltenError.failed("Choose a mono or stereo track under 64 MB of decoded audio (about six minutes of stereo at 44.1 kHz).")
        }
        // AVAudioFile may return a partial buffer before EOF (including a short
        // final packet). Keep reading so the loop never silently drops the tail.
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
              let destination = pcm.int16ChannelData?[0] else { throw MoltenError.failed("Could not decode this audio format.") }
        var total = 0
        while total < Int(pcm.frameCapacity) && file.framePosition < file.length {
            try file.read(into: chunk)
            let count = min(Int(chunk.frameLength), Int(pcm.frameCapacity) - total)
            guard count > 0 else { break }
            destination.advanced(by: total * channels).update(from: chunk.int16ChannelData![0], count: count * channels)
            total += count
        }
        pcm.frameLength = AVAudioFrameCount(total)
        guard pcm.frameLength > 1, pcm.int16ChannelData != nil else { throw MoltenError.failed("This file contains no playable audio.") }
        buffer = pcm; name = url.deletingPathExtension().lastPathComponent
    }
    init(buffer: AVAudioPCMBuffer, name: String) { self.buffer = buffer; self.name = name }
    func sample(_ frame: Int, _ channel: Int) -> Float {
        Float(buffer.int16ChannelData![0][frame * channels + min(channel, channels - 1)]) / 32768
    }
}

final class TurntableSampler: @unchecked Sendable {
    let track: TurntableTrack?
    let sampleRate: Double
    // One atomic publication keeps speed and gain coherent for each audio block.
    private let controls = Atomic<UInt64>(0)
    private(set) var position: Double = 0
    private var smoothGain: Float = 0
    private var smoothRate: Float = 1
    private var noise: UInt32 = 0x548b12
    private var lowNoise: Float = 0
    init(track: TurntableTrack? = nil) { self.track = track; sampleRate = track?.sampleRate ?? 48_000; set(rate: 1, gain: 0) }
    func set(rate: Float, gain: Float) {
        let rate = min(8, max(-8, rate.isFinite ? rate : 0)), gain = min(1, max(0, gain.isFinite ? gain : 0))
        controls.store(UInt64(rate.bitPattern) | (UInt64(gain.bitPattern) << 32), ordering: .relaxed)
    }
    // Also used by the offline tests; no audio device is needed to verify scratching.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let packed = controls.load(ordering: .relaxed)
        let rate = Float(bitPattern: UInt32(truncatingIfNeeded: packed))
        let gain = Float(bitPattern: UInt32(truncatingIfNeeded: packed >> 32))
        let count = track?.count ?? 0
        for i in 0..<frames {
            smoothRate += (rate - smoothRate) * 0.006
            smoothGain += (gain - smoothGain) * 0.003
            var l: Float = 0, r: Float = 0
            if let track, count > 1 {
                let index = Int(position), next = (index + 1) % count, fraction = Float(position - Double(index))
                l = track.sample(index, 0) * (1 - fraction) + track.sample(next, 0) * fraction
                r = track.sample(index, 1) * (1 - fraction) + track.sample(next, 1) * fraction
                position += Double(smoothRate)
                if position < 0 { position += Double(count) * ceil(-position / Double(count)) }
                if position >= Double(count) { position.formTruncatingRemainder(dividingBy: Double(count)) }
            } else {
                noise = noise &* 1664525 &+ 1013904223
                let white = Float(noise >> 8) / 8388608 - 1
                lowNoise += (white - lowNoise) * 0.015
                let crackle: Float = noise & 0x3fff < 3 ? white * 0.16 : 0
                let water = sin(position * 0.00031) * sin(position * 0.000117)
                l = lowNoise * 0.14 + crackle + Float(water) * 0.004
                r = lowNoise * 0.12 - crackle * 0.6 + Float(water) * 0.004
                position += Double(abs(smoothRate)); if position > 1e8 { position -= 1e8 }
            }
            // A stationary platter is silent; the tonearm fades out at its rest.
            let amplitude = smoothGain * min(1, abs(smoothRate) * 12)
            left[i] = l * amplitude; right[i] = r * amplitude
        }
    }
}

enum TurntableAudioGraph {
    static func make(sampler: TurntableSampler) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampler.sampleRate, channels: 2) else {
            throw MoltenError.failed("Audio format is unavailable.")
        }
        let source = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let l = buffers[0].mData, let r = buffers[1].mData else { return -50 }
            sampler.render(frames: Int(frames), left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self))
            return noErr
        }
        engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
        return engine
    }
}

@MainActor final class TurntableAudio {
    private var engine: AVAudioEngine?
    private var sampler: TurntableSampler?
    private var track: TurntableTrack?
    private var generation = 0
    private(set) var enabled = false
    private(set) var running = false
    private(set) var trackName: String?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    func toggle() { enabled.toggle(); onChange?() }
    func load(_ url: URL) {
        generation += 1; let request = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try TurntableTrack(url: url) }
            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                switch result {
                case .success(let track):
                    self.stopEngine(); self.track = track; self.trackName = track.name; self.enabled = true; self.onChange?()
                case .failure(let error): self.onError?(error.localizedDescription)
                }
            }
        }
    }
    func synchronize(motion: TurntableMotion, animationSpeed: Float) {
        sampler?.set(rate: motion.velocity / 0.22 * animationSpeed, gain: motion.arm > 0.18 ? (track == nil ? 0.60 : 0.7) : 0)
    }
    func setActive(_ active: Bool) {
        guard active && enabled else {
            if running { engine?.pause(); running = false }
            return
        }
        guard !running else { return }
        do {
            if engine == nil {
                let sampler = TurntableSampler(track: track)
                self.engine = try TurntableAudioGraph.make(sampler: sampler); self.sampler = sampler
            }
            try engine?.start(); running = true
        } catch { enabled = false; stopEngine(); onError?(error.localizedDescription); onChange?() }
    }
    private func stopEngine() { engine?.stop(); engine = nil; sampler = nil; running = false }
    func release() {
        generation += 1; stopEngine(); track = nil; trackName = nil; enabled = false
    }
}
