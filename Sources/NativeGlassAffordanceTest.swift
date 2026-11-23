import AppKit
import SwiftUI

@MainActor enum NativeGlassAffordanceTest {
    static func run(directory: URL) throws -> [String:Any] {
        var checks: [String:Bool] = [:]
        func require(_ ok: Bool, _ name: String) throws { if !ok { throw MoltenError.failed(name) } }
        func check(_ name: String, _ ok: Bool) throws { try require(ok,name); checks[name] = true; print("PASS \(name)") }
        let stage = CGSize(width: 920,height: 358)
        func model() -> NativeGlassModel {
            var settings = Settings(); settings.scene = .nativeGlass
            let m = NativeGlassModel(); m.configure(settings); m.resize(stage); m.setActive(true); m.toggleMagnets()
            return m
        }
        func grip(_ m: NativeGlassModel) -> CGPoint {
            let p = m.position(m.pieces[0],stage: stage), box = m.dimensions(m.pieces[0],stage: stage)
            return CGPoint(x: p.x+box.width*0.46,y: p.y)
        }
        let m = model(), before = m.pieces, start = grip(m)
        let original = m.contour(before[0],stage: stage)
        let rect = CGRect(origin: .zero,size: m.dimensions(before[0],stage: stage))
        m.updateHover(at: start,stage: stage)
        let hover = m.surfaceResponse(before[0],stage: stage)
        try check("hover_only_lifts_and_lights_the_eligible_touched_piece",
            hover.lift > 0 && hover.light > 0 && m.pieces == before &&
            before.dropFirst().allSatisfy { m.surfaceResponse($0,stage: stage) == .init() } && !m.isAwake)
        let lifted = m.contour(before[0],stage: stage)
        for angle: CGFloat in [-.pi,-.pi*0.75,-.pi*0.5,.pi*0.5,.pi*0.75,.pi] {
            let axis = CGSize(width: cos(angle),height: sin(angle))
            let a = original.rimPoint(toward: axis,in: rect), b = lifted.rimPoint(toward: axis,in: rect)
            try require(hypot(a.x-b.x,a.y-b.y) < 0.00001,"Hover reshaped an untouched edge.")
        }
        try check("hover_deformation_is_confined_to_the_grabbed_rim", true)
        m.reducedMotion = true; m.updateHover(at: start,stage: stage)
        let reduced = m.surfaceResponse(before[0],stage: stage)
        try check("reduced_motion_keeps_the_glint_without_optional_bulging", reduced.light > 0 && reduced.lift == 0 && !m.isAwake)
        m.reducedMotion = false
        let threshold = m.tearThreshold(before[0],stage: stage)
        m.dragFromStage(translation: CGSize(width: threshold*0.4,height: 0),stage: stage,startLocation: start)
        let early = m.surfaceResponse(m.displayedPieces[0],stage: stage)
        m.dragFromStage(translation: CGSize(width: threshold*0.9,height: 0),stage: stage,startLocation: start)
        let late = m.surfaceResponse(m.displayedPieces[0],stage: stage)
        let child = m.displayedPieces.last!, facing = m.surfaceResponse(child,stage: stage)
        try check("tension_light_concentrates_on_the_two_facing_edges", late.spread < early.spread && late.light > early.light &&
            facing.direction.width < -0.99 && late.direction.width > 0.99 && facing.light > 0.6)
        m.dragFromStage(translation: CGSize(width: threshold+0.01,height: 0),stage: stage,startLocation: start)
        let parentAtCut = m.pieces[0], childAtCut = m.pieces.last!
        try require(m.settlingTear?.age == 0 && m.surfaceResponse(parentAtCut,stage: stage).lift == 0,"Recoil jumped at the cut.")
        m.advance(elapsed: 0.06)
        let recoil = m.surfaceResponse(parentAtCut,stage: stage)
        try require(recoil.lift > 0 && recoil.lift < 3 && m.pieces[0] == parentAtCut && m.pieces.last == childAtCut,
                    "Recoil moved a piece or exceeded a subtle local deformation.")
        try check("split_recoil_starts_continuously_and_leaves_other_glass_untouched",
            before.dropFirst().allSatisfy { old in
                guard let current = m.pieces.first(where: { $0.id == old.id }) else { return false }
                return current.diameter == old.diameter && current.form == old.form && current.stretch == old.stretch &&
                    hypot(current.center.x-old.center.x,current.center.y-old.center.y) < 1e-9 &&
                    m.surfaceResponse(current,stage: stage) == .init()
            })
        for _ in 0..<20 { m.advance(elapsed: 1/60) }
        let ticks = m.physicsTicks
        for _ in 0..<120 { m.advance(elapsed: 1/60) }
        try check("recoil_finishes_and_the_existing_clock_sleeps_during_a_held_drag",
            m.settlingTear == nil && !m.isAwake && m.isDragging && m.physicsTicks == ticks &&
            m.surfaceResponse(parentAtCut,stage: stage) == .init())
        m.cancelDrag()
        for interruption in 0..<4 {
            let test = model()
            test.dragFromStage(translation: CGSize(width: threshold+1,height: 0),stage: stage,startLocation: grip(test))
            try require(test.settlingTear != nil,"No active recoil to interrupt.")
            switch interruption {
            case 0: test.setActive(false)
            case 1: test.reducedMotion = true
            case 2: var s = Settings(); s.scene = .nativeGlass; s.paused = true; test.configure(s)
            default: test.resize(CGSize(width: 760,height: 208))
            }
            test.advance(elapsed: 1)
            try require(test.settlingTear == nil && !test.isAwake && !test.isDragging,"An interrupted recoil retained activity.")
        }
        try check("hide_pause_reduce_motion_and_resize_cancel_recoil_immediately", true)
        let restricted = model(); restricted.dense()
        restricted.updateHover(at: grip(restricted),stage: stage)
        try check("unavailable_tears_do_not_advertise_a_material_grip",
            restricted.pieces.allSatisfy { restricted.surfaceResponse($0,stage: stage).light == 0 })
        try sheet(directory: directory)
        return ["all_passed":true,"checks":checks,"recoil_duration_seconds":NativeGlassSettlement.duration,
                "additional_glass_surfaces":0,"additional_timers":0,
                "scope":"Local contour and rim response, recoil and lifecycle. Saved sheet contains actual contours and rim overlays; native optical compositor excluded."]
    }

    private struct Surface {
        let position: CGPoint
        let box: CGSize
        let shape: NativeGlassContour
        let response: NativeGlassSurfaceResponse
    }
    private struct Frame {
        let label: String
        let surfaces: [Surface]
    }
    private static func sheet(directory: URL) throws {
        let m = NativeGlassModel(); var settings = Settings(); settings.scene = .nativeGlass
        m.configure(settings); m.setActive(true); m.toggleMagnets()
        let stage = CGSize(width: 920,height: 358), origin = m.position(m.pieces[0],stage: stage)
        let start = CGPoint(x: origin.x+m.dimensions(m.pieces[0],stage: stage).width*0.46,y: origin.y)
        let threshold = m.tearThreshold(m.pieces[0],stage: stage)
        var frames: [Frame] = []
        func capture(_ label: String) {
            let surfaces = m.displayedPieces.filter { $0.id == 0 || $0.id >= 7 }.map { piece in
                let p = m.position(piece,stage: stage)
                return Surface(position: CGPoint(x: p.x-origin.x+90,y: p.y-origin.y+82),
                    box: m.dimensions(piece,stage: stage),shape: m.contour(piece,stage: stage),
                    response: m.surfaceResponse(piece,stage: stage))
            }
            frames.append(Frame(label: label,surfaces: surfaces))
        }
        capture("At rest")
        m.updateHover(at: start,stage: stage); capture("Rim hover")
        for (label,fraction) in [("Stretch",0.45),("Tension",0.92),("Separate",1.0001)] {
            m.dragFromStage(translation: CGSize(width: threshold*fraction,height: 0),stage: stage,startLocation: start)
            capture(label)
        }
        m.advance(elapsed: 0.06); capture("Local recoil")
        m.cancelDrag()
        let view = VStack(spacing: 8) {
            Text("Material contours and edge cues").font(.system(size: 16,weight: .semibold))
            Text("Geometry proof on light and dark backgrounds. Native glass optics excluded.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(frames.indices,id: \.self) { index in
                HStack(spacing: 10) {
                    Text(frames[index].label).font(.system(size: 12)).frame(width: 80,alignment: .leading)
                    ForEach([false,true],id: \.self) { dark in
                        ZStack(alignment: .topLeading) {
                            Color(white: dark ? 0.13 : 0.92)
                            ForEach(frames[index].surfaces.indices,id: \.self) { i in
                                let s = frames[index].surfaces[i]
                                s.shape.fill(Color(white: dark ? 0.26 : 0.80))
                                    .overlay { NativeGlassRimLight(shape: s.shape,response: s.response,box: s.box) }
                                    .frame(width: s.box.width,height: s.box.height).position(s.position)
                            }
                        }.frame(width: 320,height: 164).clipped()
                    }
                }
            }
        }.padding(20).background(.white).environment(\.colorScheme,.light)
        let renderer = ImageRenderer(content: view); renderer.scale = 1.5
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else {
            throw MoltenError.failed("Unable to render local material response proof.")
        }
        try data.write(to: directory.appendingPathComponent("material-contours-only.png"))
    }
}
