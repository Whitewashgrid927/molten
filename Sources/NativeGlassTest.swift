import AppKit
import Metal
import SwiftUI

@MainActor enum NativeGlassTest {
    static func run() throws {
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--output")
        let directory = URL(fileURLWithPath: index.flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? "/tmp/molten-native-glass")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let interactionReport = try NativeGlassInteractionTest.run()
        let tearReport = try NativeGlassTearTest.run(directory: directory)
        var checks: [String: Bool] = [:]
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw MoltenError.failed(message) }
        }
        func check(_ name: String, _ ok: Bool) throws {
            try require(ok, name); checks[name] = true; print("PASS \(name)")
        }
        var settings = Settings(); settings.scene = .nativeGlass
        let model = NativeGlassModel(); model.configure(settings); model.setActive(true)
        let original = model.pieces
        let stage = CGSize(width: 920, height: 358)
        model.drag(0, translation: CGSize(width: 70,height: 30), stage: stage)
        try check("drag_moves_the_selected_piece_only", model.pieces[0].center != original[0].center && Array(model.pieces.dropFirst()) == Array(original.dropFirst()))
        model.endDrag(0, translation: CGSize(width: 70,height: 30), predicted: CGSize(width: 9000,height: -9000), stage: stage)
        try check("release_bounds_prediction_and_finishes_gesture", !model.isDragging && abs(model.pieces[0].center.x-original[0].center.x) < 0.25)
        model.beginDrag(0); model.setActive(false)
        let hidden = model.pieces
        model.drag(0, translation: CGSize(width: 200,height: 300), stage: stage)
        model.endDrag(0, translation: .zero, predicted: CGSize(width: 1000,height: 1000), stage: stage)
        try check("hiding_cancels_gesture_and_rejects_late_pointer_input", !model.isDragging && model.pieces == hidden && model.animation == nil)
        model.setActive(true); model.beginDrag(0)
        settings.paused = true; model.configure(settings)
        try check("pause_cancels_drag_and_spring_animation", !model.isDragging && model.animation == nil)
        settings.paused = false; model.configure(settings)
        model.reducedMotion = true
        model.drag(0, translation: CGSize(width: -10,height: 10), stage: stage)
        let beforeRelease = model.pieces
        model.endDrag(0, translation: .zero, predicted: CGSize(width: 500,height: 500), stage: stage)
        try check("reduced_motion_removes_release_coasting", model.pieces == beforeRelease && model.animation == nil)
        model.reducedMotion = false
        model.reset(); model.choose(0); model.split()
        try check("split_preserves_existing_identity_and_adds_one_piece", model.pieces.count == 8 && model.pieces[0].id == 0 && Set(model.pieces.map(\.id)).count == 8 && model.pieces[0].diameter < original[0].diameter)
        model.toggleExpanded(0)
        try check("expanded_controls_have_usable_minimum_size", model.dimensions(model.pieces[0],stage: CGSize(width: 760,height: 208)).height >= 152)
        model.stretch(0, value: 1.6); model.toggleExpanded(0)
        try check("stretch_survives_return_to_compact_piece", model.dimensions(model.pieces[0],stage: stage).width > model.dimensions(model.pieces[0],stage: stage).height * 1.5)
        var forms: Set<Int> = []
        for _ in 0..<4 { model.morph(0); forms.insert(model.pieces[0].form) }
        try check("four_native_shape_states", forms.count == 4)
        for _ in 0..<100 { model.add(); model.split() }
        try check("all_creation_paths_enforce_24_piece_cap", model.pieces.count == 24 && Set(model.pieces.map(\.id)).count == 24)
        for _ in 0..<40 { model.remove() }
        try check("removal_preserves_one_valid_selectable_piece", model.pieces.count == 1 && model.pieces[0].id == model.selected)
        model.dense()
        try check("dense_mode_reuses_one_bounded_collection", model.pieces.count == 24 && Set(model.pieces.map(\.id)).count == 24)
        for arrangement in [NativeGlassModel.Arrangement.gather, .ribbon, .scatter] {
            model.arrange(arrangement)
            for size in [CGSize(width: 760,height: 208), CGSize(width: 920,height: 358), CGSize(width: 1400,height: 588)] {
                for scale: Float in [0.6,1,1.5] {
                    settings.sceneParameters.x = scale; model.configure(settings)
                    for piece in model.pieces {
                        let b = model.dimensions(piece,stage: size), p = model.position(piece,stage: size)
                        try require(p.x-b.width/2 >= 0 && p.x+b.width/2 <= size.width && p.y-b.height/2 >= 0 && p.y+b.height/2 <= size.height, "Piece outside stage after resize or rearrange.")
                    }
                }
            }
        }
        try check("gather_ribbon_scatter_remain_bounded_at_all_window_sizes", true)
        for square: CGFloat in [0,0.5,1] {
            for petals: CGFloat in [0,0.5,1] {
                let rect = CGRect(x: 0,y: 0,width: 260,height: 160)
                let path = NativeGlassContour(square: square,petals: petals).path(in: rect)
                try require(!path.isEmpty && rect.insetBy(dx: -3,dy: -3).contains(path.boundingRect), "Invalid native glass shape.")
            }
        }
        try check("animated_native_shape_contours_remain_finite", true)
        // Construct/layout actual SwiftUI hosting trees without ordering a window.
        // This validates hosting and layout, not WindowServer's optical output.
        try autoreleasepool {
            let host = NativeGlassHost(model: model)
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 920,height: 670),styleMask: [.titled,.resizable],backing: .buffered,defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for size in [CGSize(width: 760,height: 260),CGSize(width: 920,height: 410),CGSize(width: 1400,height: 640)] {
                for clear in [true,false] {
                    for preset in 0..<3 {
                        settings.preset = preset; model.configure(settings); model.clear = clear
                        window.setContentSize(size); host.layoutSubtreeIfNeeded()
                        try require(host.bounds.size == size && !window.isVisible,"Hidden native host failed layout or displayed a window.")
                    }
                }
            }
            settings.sceneParameters.x = 1; model.configure(settings); model.reducedMotion = true
            for size in [CGSize(width: 760,height: 260),CGSize(width: 920,height: 410),CGSize(width: 1400,height: 640)] {
                window.setContentSize(size); host.layoutSubtreeIfNeeded(); model.reset()
                let viewport = CGSize(width: size.width,height: size.height-52)
                let source = model.pieces[0], p = model.position(source,stage: viewport)
                let start = CGPoint(x: p.x+model.dimensions(source,stage: viewport).width*0.46,y: p.y)
                let distance = model.tearThreshold(source,stage: viewport)
                var previewIDs: [Int]?
                for fraction: CGFloat in [0.3,0.6,0.99,1.001,1.15] {
                    model.dragFromStage(translation: CGSize(width: distance*fraction,height: 0),stage: viewport,startLocation: start)
                    host.layoutSubtreeIfNeeded()
                    try require(host.model === model && window.contentView === host && !window.isVisible && host.bounds.size == size,
                                "Tearing replaced or resized the native host.")
                    if let previewIDs { try require(model.displayedPieces.map(\.id) == previewIDs,"Native layout replaced the tear's glass identities.") }
                    else { previewIDs = model.displayedPieces.map(\.id) }
                    try require(model.isDragging,"Native layout cancelled the ongoing drag.")
                }
                model.endStageDrag(translation: .zero,predicted: .zero,stage: viewport)
                try require(model.pieces.count == 8 && model.tearCue == nil,"Native host did not finish a single split.")
            }
            try check("hidden_native_host_survives_every_tear_phase_without_reset", true)
            model.toggleExpanded(model.pieces[0].id); host.layoutSubtreeIfNeeded()
            window.contentView = nil; model.setActive(false)
        }
        try check("swiftui_host_all_presets_styles_sizes_without_showing_window", true)

        let affordanceReport = try NativeGlassAffordanceTest.run(directory: directory)

        let engine = try MetalEngine()
        var time: Float = 2
        func draw(width: Int = 720,height: Int = 480) throws -> (PixelImage,Double) {
            try autoreleasepool {
                guard let command = engine.queue.makeCommandBuffer() else { throw MoltenError.failed("No backdrop command.") }
                let texture = try engine.encode(command: command,width: width,height: height,time: time,dt: 0,frame: 0,settings: settings,input: PointerState())
                command.commit(); command.waitUntilCompleted()
                try require(command.status == .completed && command.error == nil,"Backdrop Metal failure: \(String(describing:command.error))")
                return (try engine.readback(texture),(command.gpuEndTime-command.gpuStartTime)*1000)
            }
        }
        func fingerprint(_ image: PixelImage) -> UInt64 {
            image.bytes.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        settings = Settings(); settings.scene = .nativeGlass
        try check("landscapes_default_to_still_background", settings.nativeBackdropStill && settings.sceneParameters.z == 0)
        var looks: Set<UInt64> = [], timings: [[String:Any]] = []
        var landscapeResources: [[String:Any]] = []
        for preset in 0..<3 {
            settings.preset = preset; settings.sceneParameters.z = 0; time = 2
            let baseline = try draw().0
            looks.insert(fingerprint(baseline))
            try baseline.save(to: directory.appendingPathComponent("backdrop-only-\(preset).png"))
            guard let landscape = engine.nativeGlassBackdrop else { throw MoltenError.failed("No landscape texture.") }
            try require(landscape.allocatedSize > 0 && landscape.allocatedSize < 8*1024*1024,
                "Landscape exceeds its 8 MiB texture budget.")
            landscapeResources.append(["preset":settings.scene.presets[preset],"width":landscape.width,
                "height":landscape.height,"texture_allocated_bytes":landscape.allocatedSize])
            for _ in 0..<3 {
                try require(fingerprint(try draw().0) == fingerprint(baseline),"Backdrop redraw changed while time was frozen.")
            }
            time = 100
            try require(fingerprint(try draw().0) == fingerprint(baseline),"Default landscape moves while the glass physics clock advances.")
            try require(engine.nativeGlassBackdrop === landscape,"A redraw reloaded the landscape texture.")
            settings.sceneParameters.z = 0.45; time = 2
            let moving = try draw().0
            time = 4
            try require(fingerprint(try draw().0) != fingerprint(moving),"Optional backdrop drift does not animate.")
            settings.sceneParameters.z = 0
            let still = try draw().0; time = 100
            try require(fingerprint(still) == fingerprint(baseline) && fingerprint(try draw().0) == fingerprint(still),"Zero drift does not restore the still landscape.")
            settings.sceneParameters.z = 1.5; settings.reduceNativeMotion = true
            let reduced = try draw().0; time = 200
            try require(fingerprint(reduced) == fingerprint(baseline) && fingerprint(try draw().0) == fingerprint(reduced),"Reduced motion does not freeze the landscape.")
            settings.reduceNativeMotion = false
            settings.sceneParameters.z = 0.45
            for quality in 0..<4 {
                settings.quality = quality
                let (w,h) = settings.renderSize(for: CGSize(width: 1840,height: 1340))
                var gpu: [Double] = []
                for frame in 0..<12 {
                    time += 1/60
                    let image = try draw(width: w,height: h)
                    if frame >= 3 { gpu.append(image.1) }
                }
                gpu.sort()
                timings.append(["preset":settings.scene.presets[preset],"quality":quality,"width":w,"height":h,"backdrop_gpu_median_ms":gpu[gpu.count/2]])
            }
        }
        try check("three_distinct_backdrops_animation_and_deterministic_pause", looks.count == 3)
        try check("selected_landscape_stays_below_8_MiB_and_reuses_texture", landscapeResources.count == 3)
        try check("static_and_reduced_motion_keep_landscapes_stationary", true)
        try check("all_four_backdrop_pixel_budgets_render_successfully", timings.count == 12)
        settings.preset = 0; settings.sceneParameters.z = 0
        for (width,height,label) in [(1280,560,"wide"),(520,900,"tall")] {
            try draw(width: width,height: height).0.save(to: directory.appendingPathComponent("backdrop-crop-\(label).png"))
        }
        // Repeated high-budget scene exits must release the previous GPU payload.
        var allocations: [Int] = []
        for _ in 0..<5 {
            settings.scene = .particles; _ = try draw(width: 360,height: 240)
            try require(engine.nativeGlassBackdrop == nil,"Inactive landscape texture was retained.")
            settings.scene = .nativeGlass; _ = try draw(width: 360,height: 240)
            allocations.append(engine.device.currentAllocatedSize)
        }
        try check("leaving_native_glass_releases_landscape_texture", true)
        try check("scene_changes_release_inactive_gpu_payload_without_growth", (allocations.max()!-allocations.min()!) < 4*1024*1024 && engine.cinematic.samples == 0)
        settings.sceneParameters.z = 0
        try check("zero_drift_requests_no_continuous_backdrop_loop", settings.nativeBackdropStill && !FrameScheduling.shouldRun(visible: true,paused: false,staticScene: settings.nativeBackdropStill,refinementPending: false,interacting: false,redrawPending: false))
        settings.sceneParameters.z = 1; settings.reduceNativeMotion = true
        try check("reduce_motion_requests_no_continuous_backdrop_loop", settings.nativeBackdropStill)
        for paused in [true,false] {
            try require(!FrameScheduling.shouldRun(visible: false,paused: paused,staticScene: false,refinementPending: false,interacting: true,redrawPending: true),"Hidden native scene schedules work.")
        }
        try check("hidden_scene_never_schedules_metal_work", true)
        try check("foreground_application_unchanged", NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        let report: [String:Any] = [
            "all_passed":true,"checks":checks,"device":engine.device.name,"backdrop_timings":timings,
            "interactions":interactionReport,
            "tear_continuity":tearReport,
            "material_affordances":affordanceReport,
            "landscape_resources":landscapeResources,
            "scope":"Model interactions, actual hidden SwiftUI host layout, lifecycle policy and Metal backdrops. Native compositor optics, interactive FPS and WindowServer memory require a visible-window evaluation and are not measured here.",
            "native_compositor_visually_verified":false,"preview_only":false,"window_shown":false,
            "native_glass_object_limit":24,"scene_exit_metal_allocations_bytes":allocations
        ]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("native-glass-test.json"),options: .atomic)
        print("PASS native glass suite; backdrop timings exclude Apple's compositor. No window shown.")
    }
}
