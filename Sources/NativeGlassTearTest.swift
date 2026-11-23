import AppKit
import SwiftUI

@MainActor enum NativeGlassTearTest {
    static func run(directory: URL) throws -> [String:Any] {
        var checks: [String:Bool] = [:]
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw MoltenError.failed(message) } }
        func check(_ name: String, _ ok: Bool) throws {
            try require(ok,name); checks[name] = true; print("PASS \(name)")
        }
        let stage = CGSize(width: 1800,height: 1100)
        func model(scale: Float = 1, form: Int = 0, stretch: CGFloat = 1) -> NativeGlassModel {
            var settings = Settings(); settings.scene = .nativeGlass; settings.sceneParameters.x = scale
            let m = NativeGlassModel(); m.configure(settings); m.resize(stage); m.setActive(true)
            m.reducedMotion = true; m.toggleMagnets()
            for _ in 0..<form { m.morph(0) }
            m.stretch(0,value: stretch)
            return m
        }
        func grab(_ m: NativeGlassModel, direction: CGSize) -> CGPoint {
            let piece = m.pieces[0], box = m.dimensions(piece,stage: stage), p = m.position(piece,stage: stage)
            let shape = NativeGlassContour(square: piece.form == 2 ? 1 : 0,petals: piece.form == 3 ? 1 : 0)
            let path = shape.path(in: CGRect(x: p.x-box.width/2,y: p.y-box.height/2,width: box.width,height: box.height))
            var low: CGFloat = 0, high = hypot(box.width,box.height)
            for _ in 0..<20 {
                let mid = (low+high)/2
                if path.contains(CGPoint(x: p.x+direction.width*mid,y: p.y+direction.height*mid)) { low = mid } else { high = mid }
            }
            return CGPoint(x: p.x+direction.width*low*0.98,y: p.y+direction.height*low*0.98)
        }
        var maxCommitJump: CGFloat = 0, maxDiameterJump: CGFloat = 0, maxRimJump: CGFloat = 0, samples = 0
        for scale: Float in [0.6,1,1.5] {
            for form in 0..<4 {
                for stretch: CGFloat in [0.65,1,1.75] {
                    for octant in 0..<8 {
                        let angle = CGFloat(octant) * .pi / 4
                        let direction = CGSize(width: cos(angle),height: sin(angle))
                        let m = model(scale: scale,form: form,stretch: stretch), initial = m.pieces
                        m.reducedMotion = false
                        let start = grab(m,direction: direction), threshold = m.tearThreshold(m.pieces[0],stage: stage)
                        func pull(_ distance: CGFloat) {
                            m.dragFromStage(translation: CGSize(width: direction.width*distance,height: direction.height*distance),stage: stage,startLocation: start)
                        }
                        pull(threshold*0.4)
                        try require(m.tearing != nil,"No stage-owned tear for form \(form), direction \(octant).")
                        for piece in m.displayedPieces {
                            let box = m.dimensions(piece,stage: stage)
                            let frame = CGRect(x: 0,y: 0,width: box.width+NativeGlassEnvelope.margin*2,height: box.height+NativeGlassEnvelope.margin*2)
                            let envelope = NativeGlassEnvelope(contour: m.contour(piece,stage: stage))
                            try require(frame.contains(envelope.path(in: frame).boundingRect),"A material lip escapes its native render bounds.")
                        }
                        let childID = m.tearing!.childID
                        pull(threshold-0.01)
                        let before = m.displayedPieces
                        let contoursBefore = before.map { m.contour($0,stage: stage) }
                        try require(m.tearing != nil && m.pieces == initial,"A preview committed before its threshold.")
                        pull(threshold+0.01)
                        let after = m.displayedPieces

                        try require(m.tearing == nil && m.tearHandoff?.childID == childID && m.pieces.count == initial.count+1,"Split did not commit exactly once.")
                        try require(before.map(\.id) == after.map(\.id),"A visible glass identity was replaced at the threshold.")
                        for id in [0,childID] {
                            let a = before.first { $0.id == id }!, b = after.first { $0.id == id }!
                            let p = m.position(a,stage: stage), q = m.position(b,stage: stage)
                            maxCommitJump = max(maxCommitJump,hypot(q.x-p.x,q.y-p.y))
                            maxDiameterJump = max(maxDiameterJump,abs(a.diameter-b.diameter))
                            let ia = before.firstIndex { $0.id == id }!
                            for index in 0..<32 {
                                let angle = CGFloat(index) * .pi/16, axis = CGSize(width: cos(angle),height: sin(angle))
                                let ba = m.dimensions(a,stage: stage), bb = m.dimensions(b,stage: stage)
                                let ra = CGRect(x: p.x-ba.width/2,y: p.y-ba.height/2,width: ba.width,height: ba.height)
                                let rb = CGRect(x: q.x-bb.width/2,y: q.y-bb.height/2,width: bb.width,height: bb.height)
                                let u = contoursBefore[ia].rimPoint(toward: axis,in: ra)
                                let v = m.contour(b,stage: stage).rimPoint(toward: axis,in: rb)
                                maxRimJump = max(maxRimJump,hypot(v.x-u.x,v.y-u.y))
                            }
                            try require(a.form == b.form && a.stretch == b.stretch,"A piece changed shape at birth.")
                        }
                        try require(initial.dropFirst().allSatisfy { old in after.contains(old) },"An unrelated piece reset during the split.")
                        let child = m.pieces.first { $0.id == childID }!
                        try require(abs(pow(m.pieces[0].diameter,2)+pow(child.diameter,2)-pow(initial[0].diameter,2)) < 0.001,"Split changed total area.")
                        pull(threshold+4)
                        let moved = m.pieces.first { $0.id == childID }!
                        let p = m.position(child,stage: stage), q = m.position(moved,stage: stage)
                        try require(abs(hypot(q.x-p.x,q.y-p.y)-3.99) < 0.01,"The stage lost or jumped its child handoff.")
                        m.endStageDrag(translation: .zero,predicted: .zero,stage: stage)
                        try require(!m.isDragging && m.tearCue == nil,"A completed gesture left a tear handoff.")
                        samples += 1
                    }
                }
            }
        }
        try check("tear_commit_has_no_position_or_size_jump_across_288_cases", samples == 288 && maxCommitJump < 0.05 && maxDiameterJump < 0.001)
        try check("preview_and_committed_lobes_keep_the_same_native_ids_and_forms", true)
        try check("stage_owns_drag_through_parent_shrink_and_child_handoff", true)
        try check("split_preserves_unrelated_pieces_and_total_area", true)
        try check("deformed_native_contours_remain_continuous_at_commit", maxRimJump < 0.05)

        let interrupted = model()
        let start = grab(interrupted,direction: CGSize(width: 1,height: 0))
        interrupted.dragFromStage(translation: CGSize(width: 30,height: 0),stage: stage,startLocation: start)
        let previewIDs = interrupted.displayedPieces.map(\.id)
        interrupted.resize(CGSize(width: stage.width+0.1,height: stage.height-0.1))
        try check("subpixel_layout_noise_cannot_cancel_a_live_tear", interrupted.isDragging && interrupted.displayedPieces.map(\.id) == previewIDs)
        interrupted.resize(CGSize(width: stage.width-100,height: stage.height))
        try check("real_viewport_resize_clears_tear_preview_and_handoff", !interrupted.isDragging && interrupted.tearing == nil && interrupted.returningTear == nil && interrupted.tearHandoff == nil && interrupted.displayedPieces.count == 7)

        let limits = model()
        for _ in 0..<16 { limits.add() }
        limits.choose(0)
        limits.dragFromStage(translation: CGSize(width: 35,height: 0),stage: stage,startLocation: grab(limits,direction: CGSize(width: 1,height: 0)))
        try require(limits.pieces.count == 23 && limits.displayedPieces.count == 24,"Tear preview exceeds the 24-surface budget.")
        limits.endStageDrag(translation: .zero,predicted: .zero,stage: stage); limits.add()
        try check("cancelling_and_adding_never_exceed_24_native_surfaces", limits.displayedPieces.count == 24 && limits.pieces.count == 24)
        limits.cancelDrag(); limits.setActive(false)
        try check("hidden_scene_releases_every_transient_tear_surface", limits.tearing == nil && limits.returningTear == nil && limits.tearHandoff == nil && !limits.isAwake)

        let controls = model(); controls.toggleExpanded(0)
        controls.dragFromStage(translation: CGSize(width: 60,height: 0),stage: stage,startLocation: controls.position(controls.pieces[0],stage: stage))
        try check("stage_drag_does_not_capture_expanded_controls", !controls.isDragging && controls.tearing == nil)
        let feedback = model(); var events = 0
        feedback.onFeedback = { if $0 == .separated { events += 1 } }
        let point = grab(feedback,direction: CGSize(width: 1,height: 0))
        for distance: CGFloat in [20,60,100,140,170,190] { feedback.dragFromStage(translation: CGSize(width: distance,height: 0),stage: stage,startLocation: point) }
        try check("one_physical_pull_creates_one_child_and_one_split_feedback", events == 1 && feedback.pieces.count == 8)
        feedback.cancelDrag()

        let retract = model(); retract.reducedMotion = false; retract.arrange(.chain); retract.togglePin(1)
        let grabPoint = grab(retract,direction: CGSize(width: 1,height: 0))
        retract.dragFromStage(translation: CGSize(width: 20,height: 0),stage: stage,startLocation: grabPoint)
        retract.endStageDrag(translation: CGSize(width: 20,height: 0),predicted: .zero,stage: stage)
        let returning = retract.returningTear != nil, anchor = retract.pieces[0].center
        retract.advance(elapsed: 0.06)
        try require(!returning || retract.pieces[0].center == anchor,"Physics moved the anchor during visual retraction.")
        let deadline = Date().addingTimeInterval(0.7)
        while retract.returningTear != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check("short_pull_retraction_finishes_and_keeps_its_anchor_stable", retract.returningTear == nil && retract.displayedPieces.count == 7 && !retract.isDragging)
        retract.setActive(false)

        try geometrySheet(directory: directory)
        return ["all_passed":true,"checks":checks,"continuity_cases":samples,
                "pointer_step_at_commit_points":0.02,"maximum_commit_position_step_points":maxCommitJump,
                "maximum_commit_diameter_step_points":maxDiameterJump,
                "maximum_commit_contour_step_points":maxRimJump,
                "scope":"Actual displayed geometry, stage gesture ownership and lifecycle. Geometry sheet excludes Apple's optical compositor."]
    }
    private static func geometrySheet(directory: URL) throws {
        var settings = Settings(); settings.scene = .nativeGlass
        let m = NativeGlassModel(); m.configure(settings); m.setActive(true); m.reducedMotion = true; m.toggleMagnets()
        let stage = CGSize(width: 920,height: 358)
        let p = m.position(m.pieces[0],stage: stage), box = m.dimensions(m.pieces[0],stage: stage)
        let start = CGPoint(x: p.x+box.width*0.46,y: p.y), threshold = m.tearThreshold(m.pieces[0],stage: stage)
        var frames: [(String,[NativeGlassPiece])] = []
        for (label,fraction) in [("25%",0.25),("75%",0.75),("Just before split",0.9999),("Just after split",1.0001),("Continue dragging",1.2)] {
            m.dragFromStage(translation: CGSize(width: threshold*fraction,height: 0),stage: stage,startLocation: start)
            frames.append((label,m.displayedPieces))
        }
        let view = VStack(spacing: 14) {
            Text("Tear geometry — native glass optics excluded").font(.system(size: 14,weight: .semibold))
            ForEach(frames.indices,id: \.self) { index in
                HStack(spacing: 16) {
                    Text(frames[index].0).font(.system(size: 12)).frame(width: 125,alignment: .leading)
                    ZStack(alignment: .topLeading) {
                        ForEach(frames[index].1) { piece in
                            let box = m.dimensions(piece,stage: stage), center = m.position(piece,stage: stage)
                            NativeGlassContour(square: piece.form == 2 ? 1 : 0,petals: piece.form == 3 ? 1 : 0)
                                .fill(piece.id == 0 || piece.id >= 7 ? Color.blue.opacity(0.65) : Color.gray.opacity(0.2))
                                .frame(width: box.width,height: box.height).position(center)
                        }
                    }.frame(width: stage.width,height: stage.height)
                        .scaleEffect(0.55,anchor: .topLeading).frame(width: stage.width*0.55,height: stage.height*0.55,alignment: .topLeading)
                        .background(Color(white: 0.96))
                }
            }
        }.padding(20).background(.white).environment(\.colorScheme,.light)
        let renderer = ImageRenderer(content: view)
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else {
            throw MoltenError.failed("Unable to render tear geometry proof.")
        }
        try data.write(to: directory.appendingPathComponent("tear-geometry-only.png"))
    }
}
