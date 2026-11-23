import Foundation
import simd

struct PoolPointerEvent {
  enum Kind { case press, move, release, cancel }
  var kind: Kind
  var position: SIMD2<Float>
  var timestamp: Double
}
struct PoolImpulse { var value: SIMD4<Float> }
struct PoolSoundEvent {
  var strength: Float
  var pan: Float
  var frequency: Float
  var splash: Float
}

// Keep the camera and bank functions identical to Pool.metal.
enum PoolProjection {
  static let eye = SIMD3<Float>(0, 4.5, 4), right = SIMD3<Float>(1, 0, 0)
  static let forward = simd_normalize(-eye)
  static let up = simd_cross(right, forward)
  static let radii = SIMD3<Float>(0.34, 0.20, 0.27)
  static let radius: Float = 2.08
  static let plantRoots = [
    SIMD2<Float>(-1.20, 0.14), SIMD2<Float>(1.27, -0.45), SIMD2<Float>(-1.32, -1.20),
  ]
  static func riverCenter(_ z: Float) -> Float { 0.30 * sin(z * 1.4) - 0.10 }
  static func riverWidth(_ z: Float) -> Float { 0.90 + 0.12 * cos(z * 2) }
  static func waterDistance(_ p: SIMD2<Float>) -> Float {
    max(abs(p.x - riverCenter(p.y)) - riverWidth(p.y), simd_length(p) - radius)
  }
  static func bounded(_ p: SIMD2<Float>, margin: Float = 0.36) -> SIMD2<Float> {
    let z = min(radius - margin, max(-radius + margin, p.y))
    let disk = sqrt(max(0, pow(radius - margin, 2) - z * z))
    let lo = max(-disk, riverCenter(z) - riverWidth(z) + margin)
    let hi = min(disk, riverCenter(z) + riverWidth(z) - margin)
    return SIMD2(min(max(lo, hi), max(min(lo, hi), p.x)), z)
  }
  static func ray(_ uv: SIMD2<Float>, aspect: Float, zoom: Float) -> SIMD3<Float> {
    let xy = (uv + SIMD2<Float>(0, 0.075) - SIMD2<Float>(repeating: 0.5)) * SIMD2(2 * aspect, -2)
    return simd_normalize(forward * (2.15 * exp(-zoom)) + right * xy.x + up * xy.y)
  }
  static func plane(_ uv: SIMD2<Float>, aspect: Float, zoom: Float, y: Float = 0) -> SIMD2<Float> {
    let rd = ray(uv, aspect: aspect, zoom: zoom)
    guard rd.y < -0.05 else { return SIMD2(20, 20) }
    let p = eye + rd * ((y - eye.y) / rd.y)
    return SIMD2(p.x, p.z)
  }
  static func project(_ p: SIMD3<Float>, aspect: Float, zoom: Float = 0) -> SIMD2<Float> {
    let q = p - eye
    let d = simd_dot(q, forward)
    let focal: Float = 2.15 * exp(-zoom)
    return SIMD2(
      0.5 + simd_dot(q, right) * focal / (2 * aspect * d), 0.425 - simd_dot(q, up) * focal / (2 * d)
    )
  }
  static func hit(
    _ uv: SIMD2<Float>, center: SIMD3<Float>, shape: SIMD3<Float>, aspect: Float, zoom: Float
  ) -> Float {
    let o = (eye - center) / shape
    let d = ray(uv, aspect: aspect, zoom: zoom) / shape
    let a = simd_dot(d, d)
    let b = simd_dot(o, d)
    let c = simd_dot(o, o) - 1
    let h = b * b - a * c
    guard h >= 0 else { return .infinity }
    let t = (-b - sqrt(h)) / a
    return t > 0 ? t : .infinity
  }
  static func hitsStone(_ uv: SIMD2<Float>, center: SIMD3<Float>, aspect: Float, zoom: Float)
    -> Bool
  {
    hit(uv, center: center, shape: radii, aspect: aspect, zoom: zoom).isFinite
  }
}
struct GardenStone {
  var position: SIMD3<Float>
  var velocity = SIMD3<Float>.zero, tilt = SIMD2<Float>.zero
  var wetness: Float = 1, cooldown: Float = 0
  var skips = 0, airborne = false, settled = true
}
struct GardenPlant {
  var bend = SIMD2<Float>.zero, velocity = SIMD2<Float>.zero
  var energy: Float { simd_length(bend) + simd_length(velocity) }
}

// All mechanics run at 120 Hz. No interactive GPU readbacks or growing state.
final class PoolSimulation {
  static let step: Float = 1 / 120, restHeight: Float = 0.065
  static let pitches: [Float] = [196, 246.942, 293.665]
  private static var initialStones: [GardenStone] {
    [
      GardenStone(position: SIMD3(-0.35, restHeight, 0.18)),
      GardenStone(position: SIMD3(0.12, restHeight, -0.87)),
      GardenStone(position: SIMD3(0.30, restHeight, 1.14)),
    ]
  }
  private(set) var stones = initialStones
  private(set) var plants = [GardenPlant](repeating: GardenPlant(), count: 3)
  private(set) var selectedStone = 0, hoveredStone = -1, hoveredPlant = -1, brushingPlant = -1
  var stone: SIMD3<Float> { stones[selectedStone].position }
  var velocity: SIMD3<Float> { stones[selectedStone].velocity }
  var tilt: SIMD2<Float> { stones[selectedStone].tilt }
  var airborne: Bool { stones[selectedStone].airborne }
  var skips: Int { stones[selectedStone].skips }
  var wetness: Float { stones[selectedStone].wetness }
  private(set) var hover: Float = 0, hoverTarget: Float = 0
  private(set) var held = false, touchingWater = false
  private(set) var flow: Float = 0, activity: Float = 0
  private(set) var touch = SIMD2<Float>.zero
  private(set) var tick: UInt32 = 0, grabSerial: UInt32 = 0, contactSerial: UInt32 = 0
  private(set) var impact = SIMD4<Float>(0, 0, -100, 0)
  private(set) var impulses: [PoolImpulse] = [], sounds: [PoolSoundEvent] = []
  private var accumulator: Float = 0, sinceMove: Float = 1, holdDuration: Float = 0,
    wakeAccumulator: Float = 0
  private var pointer = SIMD2<Float>(repeating: 0.5), grabOffset = SIMD2<Float>.zero
  private var sampledVelocity = SIMD2<Float>.zero, lastSample = SIMD2<Float>.zero,
    plantAnchor = SIMD2<Float>.zero
  private var lastDown = false, lastCancelSerial: UInt32 = 0
  private var lastMoveTime: Double = 0
  var time: Float { Float(tick) / 120 }
  var isAtRest: Bool {
    activity <= 0 && !held && !touchingWater && brushingPlant < 0
      && stones.allSatisfy { $0.settled && !$0.airborne }
      && plants.allSatisfy { $0.energy == 0 } && abs(hover - hoverTarget) < 0.002
  }
  var hint: String {
    if held { return "Move gently to place · Flick to skip · Scroll while holding to lift" }
    if brushingPlant >= 0 { return "Brush the leaves · Release to hear them ring" }
    if touchingWater { return "Trace the stream · Hold, then release a ripple" }
    if hoveredPlant >= 0 { return "Brush the leaves · Watch the water answer" }
    if hoveredStone >= 0 { return "Pick up a stone · Each stone has its own voice" }
    return "Play the stones · Brush the plants · Trace the stream"
  }
  func reset() {
    stones = Self.initialStones
    plants = [GardenPlant](repeating: GardenPlant(), count: 3)
    selectedStone = 0
    hoveredStone = -1
    hoveredPlant = -1
    brushingPlant = -1
    hover = 0
    hoverTarget = 0
    held = false
    touchingWater = false
    flow = 0
    activity = 0
    touch = .zero
    tick = 0
    impact = SIMD4(0, 0, -100, 0)
    impulses.removeAll(keepingCapacity: true)
    sounds.removeAll(keepingCapacity: true)
    accumulator = 0
    pointer = SIMD2(repeating: 0.5)
    lastDown = false
    lastCancelSerial = 0
    sampledVelocity = .zero
    lastMoveTime = 0
    sinceMove = 1
    holdDuration = 0
    wakeAccumulator = 0
    grabSerial = 0
    contactSerial = 0
  }
  func cancelGesture() {
    if held {
      stones[selectedStone].position.y = Self.restHeight
      stones[selectedStone].velocity = .zero
      stones[selectedStone].tilt = .zero
      stones[selectedStone].airborne = false
      stones[selectedStone].settled = true
      activity = max(activity, 1)
    }
    held = false
    touchingWater = false
    brushingPlant = -1
    lastDown = false
    sampledVelocity = .zero
    flow = 0
  }
  private func pick(_ uv: SIMD2<Float>, aspect: Float, zoom: Float) -> (Int, Int) {
    var nearest = Float.infinity
    var foundStone = -1
    var foundPlant = -1
    for i in stones.indices {
      let t = PoolProjection.hit(
        uv, center: stones[i].position, shape: PoolProjection.radii, aspect: aspect, zoom: zoom)
      if t < nearest {
        nearest = t
        foundStone = i
      }
    }
    for i in plants.indices {
      let root = PoolProjection.plantRoots[i]
      let bend = plants[i].bend
      let t = PoolProjection.hit(
        uv, center: SIMD3(root.x + bend.x * 0.4, 0.44, root.y + bend.y * 0.4),
        shape: SIMD3(0.38, 0.36, 0.38), aspect: aspect, zoom: zoom)
      if t < nearest {
        nearest = t
        foundStone = -1
        foundPlant = i
      }
    }
    return (foundStone, foundPlant)
  }
  private func sound(_ p: SIMD2<Float>, strength: Float, frequency: Float, splash: Float) {
    guard sounds.count < 24 else { return }
    sounds.append(
      .init(
        strength: min(1, strength), pan: min(1, max(-1, p.x / 2.1)), frequency: frequency,
        splash: splash))
    contactSerial &+= 1
  }
  private func disturb(
    _ p: SIMD2<Float>, strength: Float, radius: Float,
    sound level: Float = 0, splash: Float = 0.5, voice: Int? = nil
  ) {
    if impulses.count < 32 { impulses.append(.init(value: SIMD4(p.x, p.y, strength, radius))) }
    activity = 8
    if level > 0 {
      sound(p, strength: level, frequency: Self.pitches[voice ?? selectedStone], splash: splash)
    }
  }
  private func sample(_ uv: SIMD2<Float>, timestamp: Double, aspect: Float, zoom: Float) {
    pointer = uv
    let p = PoolProjection.plane(uv, aspect: aspect, zoom: zoom, y: held ? stone.y : 0)
    let elapsed = timestamp - lastMoveTime
    if elapsed > 0.0001 && elapsed < 0.15 {
      var speed = (p - lastSample) / Float(max(1 / 500, elapsed))
      let length = simd_length(speed)
      if length > 7 { speed *= 7 / length }
      sampledVelocity += (speed - sampledVelocity) * (1 - exp(-Float(elapsed) * 55))
    } else {
      sampledVelocity = .zero
    }
    lastSample = p
    lastMoveTime = timestamp
    sinceMove = 0
  }
  private func event(_ e: PoolPointerEvent, aspect: Float, zoom: Float) {
    guard e.position.x.isFinite && e.position.y.isFinite && e.timestamp.isFinite else {
      cancelGesture()
      return
    }
    switch e.kind {
    case .cancel: cancelGesture()
    case .press:
      cancelGesture()
      pointer = e.position
      sinceMove = 0
      lastMoveTime = e.timestamp
      holdDuration = 0
      let hit = pick(pointer, aspect: aspect, zoom: zoom)
      if hit.0 >= 0 {
        selectedStone = hit.0
        held = true
        stones[selectedStone].airborne = false
        stones[selectedStone].settled = false
        stones[selectedStone].skips = 0
        stones[selectedStone].velocity = .zero
        let p = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom, y: stone.y)
        lastSample = p
        grabOffset = SIMD2(stone.x, stone.z) - p
        grabSerial &+= 1
        disturb(SIMD2(stone.x, stone.z), strength: -0.025, radius: 0.22, sound: 0.10, splash: 0.12)
      } else if hit.1 >= 0 {
        brushingPlant = hit.1
        plantAnchor = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom, y: 0.44)
        lastSample = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom)
        plants[hit.1].velocity += SIMD2(0.11, -0.10)
        activity = 8
        grabSerial &+= 1
      } else {
        touch = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom)
        lastSample = touch
        touchingWater = PoolProjection.waterDistance(touch) < -0.04
        if touchingWater {
          disturb(touch, strength: 0.055, radius: 0.075, sound: 0.045, splash: 0.95)
        }
      }
    case .move:
      let previous = touch
      sample(e.position, timestamp: e.timestamp, aspect: aspect, zoom: zoom)
      if touchingWater {
        touch = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom)
        let distance = simd_distance(previous, touch)
        let steps = min(12, max(1, Int(distance / 0.06)))
        if distance > 0.03 {
          for i in 1...steps {
            let p = previous + (touch - previous) * Float(i) / Float(steps)
            if PoolProjection.waterDistance(p) < -0.03 {
              disturb(p, strength: -0.018, radius: 0.07)
            }
          }
        }
      }
    case .release:
      let age = max(Double(sinceMove), e.timestamp - lastMoveTime)
      let speed = sampledVelocity * exp(-Float(max(0, age - 0.035)) * 35)
      pointer = e.position
      if held {
        held = false
        var body = stones[selectedStone]
        body.airborne = true
        body.settled = false
        body.skips = 0
        activity = 8
        let p = PoolProjection.bounded(
          PoolProjection.plane(pointer, aspect: aspect, zoom: zoom, y: body.position.y) + grabOffset
        )
        body.position.x = p.x
        body.position.z = p.y
        body.position.y = max(0.235, body.position.y)
        body.velocity = SIMD3(
          speed.x * 0.92, simd_length(speed) > 1.3 ? 0.55 : -0.08, speed.y * 0.92)
        stones[selectedStone] = body
      } else if touchingWater {
        disturb(
          touch, strength: 0.055 + min(1.4, holdDuration) * 0.09,
          radius: 0.075 + min(1, holdDuration) * 0.06,
          sound: 0.055 + min(1, holdDuration) * 0.06, splash: 0.85)
      } else if brushingPlant >= 0 {
        let i = brushingPlant
        let root = PoolProjection.plantRoots[i]
        let energy = min(1, plants[i].energy)
        sound(root, strength: 0.055 + energy * 0.14, frequency: Self.pitches[i] * 2, splash: 0.06)
        disturb(
          PoolProjection.bounded(root, margin: 0.05), strength: 0.024 + energy * 0.04, radius: 0.10)
      }
      brushingPlant = -1
      touchingWater = false
      sampledVelocity = .zero
    }
  }
  private func freeStep(_ index: Int, _ h: Float) {
    var b = stones[index]
    b.cooldown = max(0, b.cooldown - h)
    if b.airborne {
      b.velocity.y -= h * 6.2
      b.position += b.velocity * h
      let planar = SIMD2(b.position.x, b.position.z)
      let p = PoolProjection.bounded(planar, margin: 0.37)
      if simd_distance(planar, p) > 0.00001 {
        let normal = simd_normalize(planar - p)
        let v = SIMD2(b.velocity.x, b.velocity.z)
        let bounced = (v - normal * max(0, simd_dot(v, normal)) * 1.65) * 0.72
        b.position.x = p.x
        b.position.z = p.y
        b.velocity.x = bounced.x
        b.velocity.z = bounced.y
        disturb(p, strength: 0.035, radius: 0.18, sound: 0.09, splash: 0.3, voice: index)
      }
      if b.position.y <= 0.20 && b.velocity.y < 0 && b.cooldown <= 0 {
        let speed = simd_length(SIMD2(b.velocity.x, b.velocity.z))
        let strike = abs(b.velocity.y)
        impact = SIMD4(b.position.x, b.position.z, time, min(1, strike * 0.22 + speed * 0.10))
        disturb(
          SIMD2(b.position.x, b.position.z),
          strength: min(0.14, 0.035 + strike * 0.028 + speed * 0.009), radius: 0.19,
          sound: min(0.8, 0.12 + strike * 0.10 + speed * 0.055), splash: 0.65, voice: index)
        b.wetness = 1
        if speed > 1.05 && b.skips < 4 {
          b.skips += 1
          b.position.y = 0.205
          b.velocity.y = max(0.32, min(0.95, speed * 0.24))
          b.velocity.x *= 0.66
          b.velocity.z *= 0.66
          b.cooldown = 0.07
        } else {
          b.airborne = false
          b.settled = false
          b.velocity.x *= 0.20
          b.velocity.z *= 0.20
        }
      }
      b.tilt += (SIMD2(-b.velocity.z, b.velocity.x) * 0.025 - b.tilt) * 0.09
    } else if !b.settled {
      b.velocity.y += ((Self.restHeight - b.position.y) * 110 - b.velocity.y * 17) * h
      b.velocity.x *= exp(-h * 7)
      b.velocity.z *= exp(-h * 7)
      b.position += b.velocity * h
      let p = PoolProjection.bounded(SIMD2(b.position.x, b.position.z))
      b.position.x = p.x
      b.position.z = p.y
      b.tilt *= exp(-h * 7)
      if abs(b.position.y - Self.restHeight) < 0.001 && simd_length(b.velocity) < 0.012 {
        b.position.y = Self.restHeight
        b.velocity = .zero
        b.tilt = .zero
        b.settled = true
      }
    }
    stones[index] = b
  }
  @discardableResult
  func advance(input: PointerState, dt: Float, aspect: Float, settings: Settings) -> Int {
    impulses.removeAll(keepingCapacity: true)
    sounds.removeAll(keepingCapacity: true)
    let zoom = min(0.35, max(-0.3, input.camera.z))
    if input.cancelSerial != lastCancelSerial {
      cancelGesture()
      lastCancelSerial = input.cancelSerial
    }
    if settings.paused {
      lastDown = input.down
      return 0
    }
    if !input.poolEvents.isEmpty {
      for e in input.poolEvents { event(e, aspect: aspect, zoom: zoom) }
    } else {
      if input.down && !lastDown {
        event(
          .init(kind: .press, position: input.position, timestamp: Double(time)), aspect: aspect,
          zoom: zoom)
      } else if input.position != pointer && input.inside {
        event(
          .init(kind: .move, position: input.position, timestamp: Double(time)), aspect: aspect,
          zoom: zoom)
      }
      if !input.down && lastDown {
        event(
          .init(kind: .release, position: input.position, timestamp: Double(time)), aspect: aspect,
          zoom: zoom)
      }
    }
    lastDown = input.down
    pointer = input.position
    let hit = input.inside ? pick(pointer, aspect: aspect, zoom: zoom) : (-1, -1)
    hoveredStone = hit.0
    hoveredPlant = hit.1
    hoverTarget = hit.0 >= 0 || hit.1 >= 0 ? 1 : 0
    accumulator += min(1 / 15, max(0, dt.isFinite ? dt : 0))
    let steps = min(8, Int((accumulator + 0.000001) * 120))
    accumulator = max(0, accumulator - Float(steps) / 120)
    let h = Self.step
    for _ in 0..<steps {
      tick &+= 1
      sinceMove += h
      holdDuration += h
      activity = max(0, activity - h)
      hover += (hoverTarget - hover) * (1 - exp(-h * 22))
      if abs(hover - hoverTarget) < 0.001 { hover = hoverTarget }
      var flowTarget: Float = 0
      if held {
        var b = stones[selectedStone]
        let previous = b.position
        b.position.y +=
          (0.29 + min(0.65, max(-0.16, input.camera.w)) - b.position.y) * (1 - exp(-h * 26))
        let p = PoolProjection.bounded(
          PoolProjection.plane(pointer, aspect: aspect, zoom: zoom, y: b.position.y) + grabOffset)
        b.position.x = p.x
        b.position.z = p.y
        b.velocity = (b.position - previous) / h
        let planar = min(5, simd_length(sampledVelocity) * exp(-max(0, sinceMove - 0.025) * 25))
        flowTarget = planar * exp(-max(0, b.position.y - 0.17) * 8) * 0.28
        let desired = SIMD2(-sampledVelocity.y, sampledVelocity.x) * 0.035
        b.tilt +=
          (simd_clamp(desired, SIMD2(repeating: -0.20), SIMD2(repeating: 0.20)) - b.tilt)
          * (1 - exp(-h * 16))
        wakeAccumulator += h
        if wakeAccumulator >= 1 / 60 && planar > 0.10 {
          disturb(p, strength: -min(0.060, flowTarget * 0.085), radius: 0.24)
          wakeAccumulator = 0
        }
        b.wetness = max(0.25, b.wetness - h * 0.055)
        stones[selectedStone] = b
        activity = 8
      }
      for i in stones.indices where !(held && i == selectedStone) { freeStep(i, h) }
      if touchingWater {
        touch = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom)
        if PoolProjection.waterDistance(touch) < (-0.03) {
          let speed = min(4, simd_length(sampledVelocity) * exp(-max(0, sinceMove - 0.025) * 28))
          flowTarget = min(1, speed * 0.35 + 0.025)
          wakeAccumulator += h
          if wakeAccumulator >= 1 / 60 {
            disturb(touch, strength: -(0.003 + speed * 0.028), radius: 0.065)
            wakeAccumulator = 0
          }
        }
        activity = 8
      }
      for i in plants.indices {
        var plant = plants[i]
        var target = SIMD2<Float>.zero
        if brushingPlant == i {
          let p = PoolProjection.plane(pointer, aspect: aspect, zoom: zoom, y: 0.44) - plantAnchor
          let length = simd_length(p)
          target = length > 0.32 ? p * (0.32 / length) : p
          activity = 8
        }
        plant.velocity += ((target - plant.bend) * 80 - plant.velocity * 7) * h
        plant.bend += plant.velocity * h
        if brushingPlant != i && plant.energy < 0.0006 {
          plant.bend = .zero
          plant.velocity = .zero
        }
        plants[i] = plant
      }
      flow += (flowTarget - flow) * (1 - exp(-h * 18))
      if flow < 0.0001 { flow = 0 }
    }
    return steps
  }
}
