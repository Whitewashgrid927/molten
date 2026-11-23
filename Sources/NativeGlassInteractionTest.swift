import AppKit
import Combine
import SwiftUI

@MainActor enum NativeGlassInteractionTest {
    static func run() throws -> [String: Any] {
        var checks: [String: Bool] = [:]
        let stage = CGSize(width: 920,height: 358)
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw MoltenError.failed(message) } }
        func check(_ name: String, _ ok: Bool) throws {
            try require(ok,name); checks[name] = true; print("PASS \(name)")
        }
        func model() -> NativeGlassModel {
            var s = Settings(); s.scene = .nativeGlass
            let m = NativeGlassModel(); m.configure(s); m.resize(stage); m.setActive(true)
            return m
        }
        func edge(_ m: NativeGlassModel, id: Int = 0) -> CGPoint {
            let piece = m.pieces.first { $0.id == id }!, p = m.position(piece,stage: stage)
            return CGPoint(x: p.x+m.dimensions(piece,stage: stage).width*0.46,y: p.y)
        }
        func graphValid(_ m: NativeGlassModel) -> Bool {
            let ids = Set(m.pieces.map(\.id))
            guard ids.count == m.pieces.count, m.pieces.count <= 24, m.links.count <= m.pieces.count-1,
                  m.pinned.isSubset(of: ids) else { return false }
            var pairs: Set<String> = []
            for link in m.links {
                guard ids.contains(link.a), ids.contains(link.b), link.a != link.b,
                      pairs.insert("\(min(link.a,link.b)):\(max(link.a,link.b))").inserted else { return false }
            }
            return ids.allSatisfy { id in m.links.filter { $0.contains(id) }.count <= 2 }
        }
        let cues = model()
        let center = cues.position(cues.pieces[0],stage: stage)
        cues.updateHover(at: center,stage: stage)
        try check("center_hover_leaves_the_rim_at_rest", cues.hover?.id == 0 && cues.hover?.outward == nil)
        cues.updateHover(at: edge(cues),stage: stage)
        let cueDirection = cues.hover?.outward
        cues.beginDrag(0,stage: stage,startLocation: edge(cues))
        try check("highlighted_edge_starts_the_same_outward_tear", cueDirection == CGSize(width: 1,height: 0) && cues.tearing?.outward == cueDirection && cues.hover == nil)
        cues.cancelDrag()
        for dimensions in [CGSize(width: 760,height: 208),stage,CGSize(width: 1400,height: 588)] {
            cues.resize(dimensions); cues.arrange(.scatter)
            for _ in 0..<4 {
                let piece = cues.pieces[0], p = cues.position(piece,stage: dimensions), box = cues.dimensions(piece,stage: dimensions)
                for fraction: CGFloat in [0.35,0.37] {
                    let point = CGPoint(x: p.x+box.width*fraction,y: p.y)
                    cues.updateHover(at: point,stage: dimensions)
                    try require(cues.hover?.id == piece.id && (cues.hover?.outward != nil) == (fraction > 0.36),"Rim cue differs at a shape or window size.")
                    cues.beginDrag(piece.id,stage: dimensions,startLocation: point)
                    try require((cues.tearing != nil) == (fraction > 0.36),"Cue and actual grab boundary disagree.")
                    cues.cancelDrag()
                }
                cues.morph(0)
            }
        }
        try check("rim_cue_and_grab_boundary_match_all_shapes_and_sizes", true)
        cues.reset(); cues.resize(stage)
        let p = cues.position(cues.pieces[0],stage: stage), hoverBox = cues.dimensions(cues.pieces[0],stage: stage)
        cues.updateHover(at: CGPoint(x: p.x+hoverBox.width*0.49,y: p.y+hoverBox.height*0.49),stage: stage)
        try check("transparent_bounding_box_corners_have_no_false_grip", cues.hover == nil)
        cues.arrange(.gather); cues.choose(0)
        cues.updateHover(at: cues.position(cues.pieces[0],stage: stage),stage: stage)
        try require(cues.hover?.id == 0,"An obscured piece captured the cue.")
        cues.toggleExpanded(0)
        cues.updateHover(at: cues.position(cues.pieces[0],stage: stage),stage: stage)
        try check("overlapping_pieces_and_open_controls_respect_z_order", cues.hover == nil)
        cues.reset()
        cues.updateHover(at: edge(cues,id: 5),stage: stage)
        try require(cues.hover?.id == 5 && cues.tearAvailability(cues.pieces[5]) == .tooSmall,"Small pieces incorrectly advertise a tear.")
        cues.dense(); cues.updateHover(at: edge(cues),stage: stage)
        try check("small_pieces_and_full_collection_reject_tearing", cues.hover?.id == 0 && cues.tearAvailability(cues.pieces[0]) == .full)
        cues.reset()
        cues.updateHover(at: center,stage: stage)
        var notifications = 0, wakeups = 0
        let observation = cues.objectWillChange.sink { notifications += 1 }
        cues.onActivityChange = { wakeups += 1 }
        for i in 0..<1000 { cues.updateHover(at: CGPoint(x: center.x+CGFloat(i%5),y: center.y),stage: stage) }
        try check("center_hover_is_deduplicated_and_never_wakes_physics", notifications == 0 && wakeups == 0 && !cues.isAwake && cues.physicsTicks == 0)
        observation.cancel()
        cues.updateHover(at: nil,stage: stage)
        try require(cues.hover == nil,"Hover exit left a cue.")
        cues.updateHover(at: edge(cues),stage: stage); cues.cancelDrag()
        try require(cues.hover == nil,"Focus cancellation left a cue.")
        cues.updateHover(at: edge(cues),stage: stage); cues.setActive(false)
        cues.updateHover(at: edge(cues),stage: stage)
        try require(cues.hover == nil,"Hidden scene accepted a cue.")
        cues.setActive(true); cues.updateHover(at: edge(cues),stage: stage); cues.resize(CGSize(width: 760,height: 208))
        try check("hover_exit_focus_loss_hiding_and_resize_clear_cues", cues.hover == nil)
        cues.reset(); cues.resize(stage)
        cues.updateHover(at: edge(cues),stage: stage)
        let hoverPiece = cues.pieces[0], hoverCenter = cues.position(hoverPiece,stage: stage)
        let extended = CGPoint(x: hoverCenter.x+cues.dimensions(hoverPiece,stage: stage).width/2+1,y: hoverCenter.y)
        cues.updateHover(at: extended,stage: stage)
        try check("bulging_rim_remains_hittable_outside_its_original_bounds", cues.hover?.id == 0 && cues.hover?.outward != nil)

        let tear = model(), initial = tear.pieces, start = edge(tear)
        tear.drag(0,translation: CGSize(width: 36,height: 0),stage: stage,startLocation: start)
        try check("edge_pull_builds_neck_without_moving_anchor", tear.tearing != nil && tear.tearing!.progress > 0.1 && tear.pieces == initial)
        let lobes = tear.displayedPieces.filter { $0.id == 0 || $0.id == tear.tearing?.childID }
        let outlinesValid = lobes.allSatisfy { piece in
            let box = CGRect(origin: .zero,size: tear.dimensions(piece,stage: stage))
            let outline = NativeGlassContour(square: piece.form == 2 ? 1 : 0,petals: piece.form == 3 ? 1 : 0).path(in: box)
            return !outline.isEmpty && box.insetBy(dx: -3,dy: -3).contains(outline.boundingRect)
        }
        try check("native_tear_lobes_are_finite_and_bounded", lobes.count == 2 && outlinesValid)
        tear.endDrag(0,translation: CGSize(width: 36,height: 0),predicted: CGSize(width: 300,height: 0),stage: stage)
        try check("short_pull_release_restores_without_creating_a_piece", tear.tearing == nil && tear.pieces == initial && !tear.isDragging)
        tear.drag(0,translation: CGSize(width: -180,height: 0),stage: stage,startLocation: start)
        try check("pushing_an_edge_inward_does_not_tear", tear.pieces.count == 7 && tear.tearing?.progress == 0)
        tear.cancelDrag()
        tear.drag(0,translation: CGSize(width: 115,height: 0),stage: stage,startLocation: start)
        let childID = tear.selected!
        let childAtBirth = tear.pieces.first { $0.id == childID }!
        let area = pow(tear.pieces[0].diameter,2) + pow(childAtBirth.diameter,2)
        try check("tear_creates_one_child_and_preserves_area", tear.pieces.count == 8 && tear.tearing == nil && childID != 0 && abs(area-pow(initial[0].diameter,2)) < 0.001)
        for x in [130,145,160,175] { tear.drag(0,translation: CGSize(width: x,height: 0),stage: stage,startLocation: start) }
        try check("gesture_continues_on_child_without_repeated_tearing", tear.pieces.count == 8 && tear.pieces[0].center == initial[0].center && tear.pieces.first { $0.id == childID }!.center.x > childAtBirth.center.x)
        tear.endDrag(0,translation: CGSize(width: 175,height: 0),predicted: CGSize(width: 175,height: 0),stage: stage)
        try check("tear_gesture_releases_after_child_handoff", !tear.isDragging && graphValid(tear))

        let pin = model(); pin.togglePin(0)
        let pinCenter = pin.pieces[0].center
        pin.drag(0,translation: CGSize(width: 80,height: 30),stage: stage)
        pin.endDrag(0,translation: .zero,predicted: .zero,stage: stage)
        try check("pinned_center_rejects_translation", pin.pieces[0].center == pinCenter)
        pin.drag(0,translation: CGSize(width: 115,height: 0),stage: stage,startLocation: edge(pin))
        try check("pinned_anchor_can_shed_an_unpinned_child", pin.pieces.count == 8 && pin.pinned == [0] && pin.pieces[0].center == pinCenter)
        pin.cancelDrag()
        let cap = model(); cap.dense()
        let beforeCap = cap.pieces.count
        cap.drag(0,translation: CGSize(width: 200,height: 0),stage: stage,startLocation: edge(cap))
        try check("tear_respects_24_piece_limit", cap.tearing == nil && cap.pieces.count == beforeCap)

        let snap = model()
        let a = snap.position(snap.pieces[0],stage: stage), b = snap.position(snap.pieces[1],stage: stage)
        let movement = CGSize(width: b.x+110-a.x,height: b.y-a.y)
        snap.drag(0,translation: movement,stage: stage)
        try check("nearby_drag_creates_a_magnetic_link", snap.links.count == 1 && snap.links[0].contains(0) && snap.links[0].contains(1))
        snap.endDrag(0,translation: movement,predicted: movement,stage: stage)

        var trajectories: [[CGPoint]] = []
        for fps in [30,60,120] {
            let m = model(); m.arrange(.chain); m.togglePin(0)
            let anchor = m.pieces[0].center, rest = m.pieces
            let last = m.pieces.last!.id
            m.drag(last,translation: CGSize(width: 15,height: -36),stage: stage)
            for _ in 0..<fps/2 { m.advance(elapsed: 1/Double(fps)) }
            try require(m.pieces[0].center == anchor && m.pieces[1].center != rest[1].center,"Chain did not transmit motion around a fixed anchor.")
            m.endDrag(last,translation: CGSize(width: 15,height: -36),predicted: CGSize(width: 65,height: -70),stage: stage)
            for _ in 0..<fps/2 { m.advance(elapsed: 1/Double(fps)) }
            trajectories.append(m.pieces.map(\.center))
        }
        let differences = trajectories.dropFirst().flatMap { points in zip(points,trajectories[0]).map { hypot($0.x-$1.x,$0.y-$1.y) } }
        try check("chain_springs_match_at_30_60_120hz", differences.allSatisfy { $0 < 0.0000001 })
        try check("anchored_chain_transmits_motion_to_other_beads", true)
        let breakable = model(); breakable.arrange(.chain)
        let endID = breakable.pieces.last!.id, linkCount = breakable.links.count
        breakable.drag(endID,translation: CGSize(width: 340,height: -40),stage: stage)
        try check("hard_pull_breaks_connection_without_branching", breakable.links.count == linkCount-1 && graphValid(breakable))
        breakable.endDrag(endID,translation: CGSize(width: 340,height: -40),predicted: CGSize(width: 500,height: -80),stage: stage)
        for _ in 0..<600 { breakable.advance(elapsed: 1/60) }
        let resting = breakable.pieces, restingTick = breakable.physicsTicks
        for _ in 0..<120 { breakable.advance(elapsed: 1/60) }
        try check("released_chain_sleeps_and_stops_advancing", !breakable.isAwake && breakable.pieces == resting && breakable.physicsTicks == restingTick)
        breakable.arrange(.chain); breakable.togglePin(0); breakable.toggleMagnets()
        try check("disabling_magnetism_releases_all_links_and_motion", breakable.links.isEmpty && !breakable.isAwake && !breakable.magnets)

        let lifecycle = model(); lifecycle.arrange(.chain); lifecycle.togglePin(0)
        try require(lifecycle.isAwake,"Pin did not wake the chain.")
        lifecycle.advance(elapsed: 0.1)
        try check("delayed_frame_has_at_most_eight_physics_steps", lifecycle.physicsTicks <= 8)
        lifecycle.setActive(false)
        let hidden = lifecycle.pieces, hiddenTick = lifecycle.physicsTicks
        lifecycle.advance(elapsed: 10)
        try check("hidden_chain_cancels_motion_and_never_catches_up", !lifecycle.isAwake && lifecycle.pieces == hidden && lifecycle.physicsTicks == hiddenTick)
        lifecycle.setActive(true); lifecycle.togglePin(0); lifecycle.togglePin(0)
        var paused = Settings(); paused.scene = .nativeGlass; paused.paused = true
        lifecycle.configure(paused); lifecycle.advance(elapsed: 1)
        try check("paused_chain_submits_no_physics_ticks", !lifecycle.isAwake && lifecycle.physicsTicks == hiddenTick)
        paused.paused = false; lifecycle.configure(paused); lifecycle.togglePin(0); lifecycle.reducedMotion = true
        lifecycle.advance(elapsed: 1)
        try check("reduce_motion_stops_chain_physics", !lifecycle.isAwake && lifecycle.physicsTicks == hiddenTick)
        let interrupted = model()
        interrupted.drag(0,translation: CGSize(width: 35,height: 0),stage: stage,startLocation: edge(interrupted))
        interrupted.resize(CGSize(width: 760,height: 208))
        try check("resize_cancels_unfinished_tear_without_creating_objects", interrupted.tearing == nil && !interrupted.isDragging && interrupted.pieces.count == 7)

        let feedback = model(); var clock: TimeInterval = 1, events: [NativeGlassFeedback] = []
        feedback.feedbackClock = { clock }; feedback.onFeedback = { events.append($0) }
        feedback.togglePin(0); clock += 0.01; feedback.togglePin(0); clock += 0.15; feedback.togglePin(0)
        try check("haptic_events_are_throttled_for_direct_interaction", events.count == 2)
        feedback.haptics = false; clock += 0.2; feedback.togglePin(0)
        feedback.haptics = true; feedback.setActive(false); clock += 0.2; feedback.togglePin(0)
        try check("haptics_mute_and_hidden_state_suppress_feedback", events.count == 2)
        feedback.setActive(true); feedback.arrange(.chain); clock += 0.2; feedback.togglePin(0)
        let eventCount = events.count
        for _ in 0..<120 { clock += 1/60; feedback.advance(elapsed: 1/60) }
        try check("autonomous_physics_does_not_trigger_haptics", events.count == eventCount)

        let stress = model(); stress.dense(); stress.arrange(.chain); stress.togglePin(stress.pieces[0].id)
        let lastID = stress.pieces.last!.id
        stress.drag(lastID,translation: CGSize(width: 8,height: -15),stage: stage)
        let startTime = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1_000 { stress.advance(elapsed: 1/60) }
        let modelMS = (ProcessInfo.processInfo.systemUptime-startTime)*1000/1_000
        try check("dense_24_piece_chain_remains_bounded_and_finite", graphValid(stress) && stress.pieces.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite && (0...1).contains($0.center.x) && (0...1).contains($0.center.y) })
        stress.cancelDrag(); stress.remove()
        try check("removal_cleans_links_and_pins", graphValid(stress))
        try check("idle_backdrop_wakes_only_for_active_physics", FrameScheduling.shouldRunNativeGlass(visible: true,paused: false,backdropStill: true,physicsAwake: true,redrawPending: false) && !FrameScheduling.shouldRunNativeGlass(visible: true,paused: false,backdropStill: true,physicsAwake: false,redrawPending: false))
        try check("hidden_and_paused_native_scene_reject_physics_frames", !FrameScheduling.shouldRunNativeGlass(visible: false,paused: false,backdropStill: false,physicsAwake: true,redrawPending: true) && !FrameScheduling.shouldRunNativeGlass(visible: true,paused: true,backdropStill: false,physicsAwake: true,redrawPending: false))
        for symbol in ["link","pin","pin.fill","hand.tap","point.3.connected.trianglepath.dotted","arrow.up.left.and.arrow.down.right"] {
            try require(NSImage(systemSymbolName: symbol,accessibilityDescription: nil) != nil,"Missing glass control symbol: \(symbol)")
        }
        try check("native_controls_have_available_system_symbols", true)
        return ["all_passed":true,"checks":checks,"physics_24_piece_mean_ms":modelMS,
                "haptic_hardware_exercised":false,"scope":"Deterministic mechanics, native shape geometry, feedback dispatch and lifecycle. Timing measures only model updates, excluding SwiftUI layout and native compositing."]
    }
}
