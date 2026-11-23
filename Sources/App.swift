import AppKit
import MetalKit
import QuartzCore
import UniformTypeIdentifiers

final class CanvasView: MTKView {
    var pointerState = PointerState()
    var onPointerChange: (() -> Void)?
    var onAudioFile: ((URL) -> Void)?
    var onImageFile: ((URL) -> Void)?
    private var tracking: NSTrackingArea?
    var activeScene: Scene = .liquid
    private var heldKeys: Set<UInt16> = []
    func releaseInput() {
        pointerState.down = false; pointerState.orbiting = false
        pointerState.delta = .zero; pointerState.navigation = .zero; pointerState.modifiers = 0
        heldKeys.removeAll()
        pointerState.cancelSerial &+= 1
        pointerState.poolEvents.removeAll(keepingCapacity: true)
        if activeScene == .resonantGarden { pointerState.inside = false }
    }
    func resetCamera() { releaseInput(); pointerState.camera = .zero; pointerState.eye = .zero; pointerState.actionSerial = 0; pointerState.freeCamera = false }
    private func notify() { onPointerChange?() }
    private func poolEvent(_ kind: PoolPointerEvent.Kind, _ event: NSEvent) {
        guard activeScene == .resonantGarden else { return }
        if case .move = kind, pointerState.poolEvents.count >= 2,
           case .move = pointerState.poolEvents[pointerState.poolEvents.count-1].kind,
           case .move = pointerState.poolEvents[pointerState.poolEvents.count-2].kind {
            pointerState.poolEvents.remove(at: pointerState.poolEvents.count-2)
        }
        if pointerState.poolEvents.count >= 64 {
            pointerState.poolEvents.removeAll(keepingCapacity: true)
            pointerState.poolEvents.append(.init(kind: .cancel, position: pointerState.position, timestamp: event.timestamp))
        }
        pointerState.poolEvents.append(.init(kind: kind, position: pointerState.position, timestamp: event.timestamp))
    }
    private func modifiers(_ event: NSEvent) {
        pointerState.modifiers = (event.modifierFlags.contains(.shift) ? 1 : 0) | (event.modifierFlags.contains(.option) ? 2 : 0)
    }
    override var acceptsFirstResponder: Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if activeScene == .blockGlass { return acceptedFile(sender.draggingPasteboard) != nil ? .copy : [] }
        return activeScene == .koi && audioURL(sender) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if activeScene == .blockGlass, let url = acceptedFile(sender.draggingPasteboard) { onImageFile?(url); return true }
        guard activeScene == .koi, let url = audioURL(sender) else { return false }
        onAudioFile?(url); return true
    }
    func acceptedFile(_ pasteboard: NSPasteboard) -> URL? {
        guard activeScene == .blockGlass else { return nil }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { $0.isFileURL && (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false) }
    }
    private func audioURL(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: { url in
            guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audio)
        })
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    private func update(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let next = SIMD2<Float>(Float(p.x / max(bounds.width, 1)), Float(1 - p.y / max(bounds.height, 1)))
        let delta = next - pointerState.position
        pointerState.delta += delta
        modifiers(event)
        if activeScene == .holographic && pointerState.down && pointerState.modifiers & 1 == 0 {
            pointerState.camera.x += delta.x * 4
            pointerState.camera.y = min(0.85, max(-0.85, pointerState.camera.y + delta.y * 3))
        } else if pointerState.orbiting && activeScene.isImageScene {
            pointerState.camera.x = min(0.6, max(-0.6, pointerState.camera.x + delta.x * 4))
            pointerState.camera.y = min(0.6, max(-0.6, pointerState.camera.y + delta.y * 3))
        } else if pointerState.orbiting {
            pointerState.camera.x += delta.x * 4
            let lower: Float = activeScene == .cove && pointerState.freeCamera ? -2.01 : -1.1
            let upper: Float = activeScene == .cove && pointerState.freeCamera ? 0.89 : 1.1
            pointerState.camera.y = min(upper, max(lower, pointerState.camera.y + delta.y * 3))
        }
        pointerState.position = simd_clamp(next, SIMD2(repeating: 0), SIMD2(repeating: 1))
        pointerState.inside = bounds.contains(p)
        if delta != .zero { poolEvent(.move, event) }
        if !activeScene.isCinematic || activeScene == .resonantGarden || pointerState.down || pointerState.orbiting { notify() }
    }
    override func mouseMoved(with event: NSEvent) { update(event) }
    override func mouseEntered(with event: NSEvent) { update(event) }
    override func mouseExited(with event: NSEvent) {
        pointerState.inside = false
        if activeScene == .resonantGarden && NSApp.isActive { NSCursor.arrow.set() }
        onPointerChange?()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        update(event)
        if activeScene == .holographic && event.clickCount == 2 {
            pointerState.camera.x += .pi; pointerState.down = false; notify(); return
        }
        if activeScene == .paperFolders { pointerState.actionSerial &+= 1; pointerState.actionPosition = pointerState.position }
        pointerState.down = true
        pointerState.delta = .zero
        poolEvent(.press, event)
        notify()
    }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func mouseUp(with event: NSEvent) { pointerState.down = false; update(event); poolEvent(.release, event); notify() }
    override func rightMouseDown(with event: NSEvent) {
        guard activeScene.isCinematic && activeScene != .resonantGarden else { super.rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        update(event); pointerState.delta = .zero; pointerState.orbiting = true; notify()
    }
    override func rightMouseDragged(with event: NSEvent) { if pointerState.orbiting { update(event) } }
    override func rightMouseUp(with event: NSEvent) { pointerState.orbiting = false; notify() }
    override func scrollWheel(with event: NSEvent) {
        guard activeScene.isCinematic else { super.scrollWheel(with: event); return }
        if activeScene == .resonantGarden {
            if pointerState.down { pointerState.camera.w = min(0.65, max(-0.16, pointerState.camera.w + Float(event.scrollingDeltaY) * 0.006)) }
            else { pointerState.camera.z = min(0.35, max(-0.3, pointerState.camera.z + Float(event.scrollingDeltaY) * 0.004)) }
        } else if activeScene == .portal {
            pointerState.camera.w = min(1120, max(0, pointerState.camera.w + Float(event.scrollingDeltaY) * 0.035))
        } else if activeScene == .fractal {
            let yaw = pointerState.camera.x, pitch = pointerState.camera.y
            let forward = SIMD3<Float>(-sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
            pointerState.eye += forward * Float(event.scrollingDeltaY) * 0.035
        } else {
            pointerState.camera.z = min(0.8, max(activeScene == .stormPlanet ? -6 : -0.8,
                pointerState.camera.z + Float(event.scrollingDeltaY) * 0.008))
        }
        notify()
    }
    private func updateNavigation() {
        func key(_ value: UInt16) -> Float { heldKeys.contains(value) ? 1 : 0 }
        pointerState.navigation = SIMD3(key(2)-key(0), activeScene == .cove ? key(15)-key(3) : key(14)-key(12), key(13)-key(1))
        notify()
    }
    override func flagsChanged(with event: NSEvent) {
        modifiers(event); notify()
    }
    override func keyDown(with event: NSEvent) {
        if activeScene == .cove && !event.modifierFlags.contains(.command) {
            modifiers(event)
            if [0,1,2,3,13,15].contains(event.keyCode) {
                heldKeys.insert(event.keyCode); updateNavigation(); return
            }
            if event.keyCode == 14 {
                if !event.isARepeat { pointerState.actionSerial &+= 1; notify() }; return
            }
            if event.keyCode == 8 {
                if !event.isARepeat { pointerState.freeCamera.toggle(); notify() }; return
            }
        }
        if activeScene == .fractal && !event.modifierFlags.contains(.command) && [0,1,2,12,13,14].contains(event.keyCode) {
            heldKeys.insert(event.keyCode); modifiers(event); updateNavigation()
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if activeScene == .cove && [8,14].contains(event.keyCode) { return }
        if heldKeys.remove(event.keyCode) != nil { updateNavigation() } else { super.keyUp(with: event) }
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let engine: MetalEngine
    var settings: Settings
    var onMetrics: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    var onConverged: (() -> Void)?
    var onResize: (() -> Void)?
    var onTurntable: ((TurntableMotion, Float) -> Void)?
    var onCove: ((CoveMotion) -> Void)?
    var onPool: ((PoolSimulation) -> Void)?
    var onNativeGlass: ((TimeInterval) -> Void)?
    private let inflight = DispatchSemaphore(value: 2)
    private var time: Float = 0
    private var frame: UInt32 = 0
    private var lastDraw: TimeInterval?
    private var metricStart = ProcessInfo.processInfo.systemUptime
    private var metricFrames = 0
    private var gpuTotal: Double = 0
    private(set) var totalFrames: UInt64 = 0
    private(set) var needsRedraw = true
    func requestRedraw() { needsRedraw = true; engine.cinematic.invalidateHistory() }

    init(engine: MetalEngine, settings: Settings) {
        self.engine = engine
        self.settings = settings
    }
    func reset() { engine.reset(); time = 0; frame = 0; lastDraw = nil; needsRedraw = true }
    func resetClock() { lastDraw = nil; metricStart = ProcessInfo.processInfo.systemUptime; metricFrames = 0; gpuTotal = 0 }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        engine.cinematic.invalidateHistory()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
    func draw(in view: MTKView) {
        guard let canvas = view as? CanvasView, view.bounds.width > 0, view.bounds.height > 0,
              inflight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let command = engine.queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - (lastDraw ?? now - 1.0 / Double(settings.fps)), 0), 1.0 / 30.0)
        lastDraw = now
        if settings.scene == .nativeGlass { onNativeGlass?(elapsed) }
        if settings.scene == .fractal && canvas.pointerState.navigation != .zero {
            let yaw = canvas.pointerState.camera.x, pitch = canvas.pointerState.camera.y
            let forward = SIMD3<Float>(-sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
            let right = SIMD3<Float>(cos(yaw), 0, sin(yaw))
            let move = canvas.pointerState.navigation
            canvas.pointerState.eye += (right * move.x + SIMD3<Float>(0, move.y, 0) + forward * move.z)
                * Float(elapsed) * (canvas.pointerState.modifiers & 1 != 0 ? 1.8 : 0.65)
        }
        let dt = settings.paused || settings.scene.isStatic || settings.nativeBackdropStill ? Float(0) : Float(elapsed) * settings.speed
        time += dt
        var (width, height) = settings.renderSize(for: view.drawableSize)
        if settings.scene.isCinematic && settings.scene != .resonantGarden && settings.quality == 3 && (canvas.pointerState.down || canvas.pointerState.orbiting || canvas.pointerState.navigation != .zero) {
            width = max(1, Int(Float(width) * 0.7)); height = max(1, Int(Float(height) * 0.7))
        }
        do {
            let texture = try engine.encode(command: command, width: width, height: height,
                                            time: time, dt: dt, frame: frame, settings: settings, input: canvas.pointerState)
            if settings.scene == .koi { onTurntable?(engine.cinematic.atelier.motion, settings.speed) }
            if settings.scene == .cove { onCove?(engine.cinematic.cove.motion) }
            if settings.scene == .resonantGarden { onPool?(engine.cinematic.pool.motion) }
            needsRedraw = false
            canvas.pointerState.delta = .zero
            canvas.pointerState.poolEvents.removeAll(keepingCapacity: true)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw MoltenError.failed("Could not present the frame.")
            }
            encoder.setRenderPipelineState(engine.presentPipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            let permit = inflight
            command.addCompletedHandler { [weak self] completed in
                permit.signal()
                let duration = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000
                let error = completed.error?.localizedDescription
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error { self.onError?(error); return }
                    self.totalFrames += 1
                    if self.settings.paused || self.settings.scene.isStatic || self.settings.nativeBackdropStill
                        || (self.settings.scene == .resonantGarden && self.engine.cinematic.pool.motion.isAtRest) { self.onConverged?() }
                    self.metricFrames += 1
                    self.gpuTotal += duration
                    let now = ProcessInfo.processInfo.systemUptime
                    let interval = now - self.metricStart
                    let settled = self.settings.nativeBackdropStill || (self.settings.scene == .resonantGarden && self.engine.cinematic.pool.motion.isAtRest) || (self.settings.paused || self.settings.scene.isStatic)
                        && (!self.settings.scene.isCinematic || self.engine.cinematic.converged
                            || (self.settings.paused && self.settings.quality < 3))
                    if interval >= 0.75 || settled {
                        let metrics: [String: Any] = [
                            "scene": self.settings.scene.title,
                            "fps": Double(self.metricFrames) / interval,
                            "gpu_ms": self.gpuTotal / Double(max(self.metricFrames, 1)),
                            "gpu_allocated_mb": Double(self.engine.device.currentAllocatedSize) / 1048576,
                            "render_width": width, "render_height": height,
                            "particles": self.settings.scene == .particles ? self.settings.particleCount : 0,
                            "refinement_samples": self.engine.cinematic.samples,
                            "total_frames": self.totalFrames
                        ]
                        self.onMetrics?(metrics)
                        self.metricStart = now
                        self.metricFrames = 0
                        self.gpuTotal = 0
                    }
                }
            }
            command.commit()
            frame &+= 1
        } catch {
            inflight.signal()
            view.isPaused = true
            onError?(error.localizedDescription)
        }
    }
}

final class LayoutView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var renderer: Renderer?
    private var nativeGlassHost: NativeGlassHost?
    private var settings = Settings()
    private let root = LayoutView()
    private var scenes: NSPopUpButton!
    private let preset = NSPopUpButton()
    private let intensity = NSSlider(value: 1, minValue: 0.3, maxValue: 2, target: nil, action: nil)
    private let intensityLabel = NSTextField(labelWithString: "Intensity")
    private let tuningPopover = NSPopover()
    private var tuningValues: [Int: NSTextField] = [:]
    private var sceneSettings: [Scene: (Int, Float, SIMD4<Float>)] = [:]
    private let quality = NSPopUpButton()
    private let fps = NSPopUpButton()
    private let hint = NSTextField(labelWithString: "")
    private let statistics = NSTextField(labelWithString: "")
    private let loading = NSTextField(labelWithString: "Preparing Metal…")
    private let topGlass = NSGlassEffectView()
    private let bottomGlass = NSGlassEffectView()
    private let statsGlass = NSGlassEffectView()
    private var playButton: NSButton!
    private var statsButton: NSButton!
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var renderingFailed = false
    private var diagnosticURL: URL?
    private var lastMetrics: [String: Any] = [:]
    private var verifyingControls = false
    private let turntableAudio = TurntableAudio()
    private let poolAudio = PoolAudio()
    private var lastPoolGrab: UInt32 = 0
    private var lastPoolContact: UInt32 = 0
    private let audioGlass = NSGlassEffectView()
    private var audioButton: NSButton!
    private var musicButton: NSButton!
    private let imageGlass = NSGlassEffectView()
    private var imageButton: NSButton!
    private var defaultImageButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--diagnostics"), arguments.indices.contains(index + 1) {
            diagnosticURL = URL(fileURLWithPath: arguments[index + 1])
        }
        let defaults = UserDefaults.standard
        settings.scene = Scene(rawValue: defaults.integer(forKey: "scene")) ?? .liquid
        if !settings.scene.isAvailable { settings.scene = .liquid }
        settings.quality = defaults.object(forKey: "quality") == nil ? 1 : min(3, max(0, defaults.integer(forKey: "quality")))
        settings.fps = [30, 60, 120].contains(defaults.integer(forKey: "fps")) ? defaults.integer(forKey: "fps") : 60
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 670),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Molten"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.015, green: 0.02, blue: 0.035, alpha: 1)
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.contentView = root
        window.setFrameAutosaveName("MoltenCanvas")
        canvas = CanvasView(frame: .zero, device: nil)
        canvas.colorPixelFormat = .bgra8Unorm
        canvas.framebufferOnly = true
        canvas.isPaused = true
        canvas.enableSetNeedsDisplay = false
        canvas.preferredFramesPerSecond = settings.fps
        canvas.autoResizeDrawable = true
        canvas.setAccessibilityLabel("Interactive Metal canvas")
        canvas.layer?.isOpaque = true
        (canvas.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        root.addSubview(canvas)
        // Give glass containers their final size before they install content constraints.
        layout()
        configureControls()
        configureMenus()
        root.onLayout = { [weak self] in self?.layout() }
        canvas.onPointerChange = { [weak self] in self?.redrawIfPaused() }
        canvas.registerForDraggedTypes([.fileURL])
        canvas.onAudioFile = { [weak self] url in self?.turntableAudio.load(url) }
        canvas.onImageFile = { [weak self] url in self?.loadGlassImage(url) }
        turntableAudio.onChange = { [weak self] in self?.updateAudioControls(); self?.updateRendering() }
        turntableAudio.onError = { [weak self] message in self?.hint.stringValue = message }
        poolAudio.onChange = { [weak self] in self?.updateAudioControls(); self?.updateRendering() }
        poolAudio.onError = { [weak self] message in self?.hint.stringValue = message }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installObservers()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try MetalEngine() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let engine):
                    self.canvas.device = engine.device
                    let renderer = Renderer(engine: engine, settings: self.settings)
                    renderer.onError = { [weak self] message in self?.showError(message) }
                    renderer.onMetrics = { [weak self] metrics in self?.updateMetrics(metrics) }
                    renderer.onConverged = { [weak self] in self?.updateRendering() }
                    renderer.onResize = { [weak self] in self?.redrawIfPaused() }
                    renderer.onNativeGlass = { [weak self] elapsed in self?.nativeGlassHost?.model.advance(elapsed: elapsed) }
                    renderer.onTurntable = { [weak self] motion, speed in self?.turntableAudio.synchronize(motion: motion, animationSpeed: speed) }
                    renderer.onCove = { [weak self] motion in
                        guard let self else { return }
                        let text = motion.controlHint
                        if self.hint.stringValue != text { self.hint.stringValue = text }
                    }
                    renderer.onPool = { [weak self] motion in
                        guard let self else { return }
                        if self.hint.stringValue != motion.hint { self.hint.stringValue = motion.hint }
                        self.poolAudio.setActive(self.canRender && !self.settings.paused && !motion.isAtRest)
                        self.poolAudio.synchronize(motion: motion, settings: self.settings)
                        if NSApp.isActive && self.canvas.pointerState.inside {
                            if motion.held || motion.brushingPlant >= 0 { NSCursor.closedHand.set() }
                            else if motion.hoverTarget > 0.5 { NSCursor.openHand.set() }
                            else { NSCursor.arrow.set() }
                            if motion.grabSerial != self.lastPoolGrab && motion.grabSerial > 0 {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
                            } else if motion.contactSerial != self.lastPoolContact && motion.sounds.contains(where: { $0.strength > 0.2 }) {
                                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .drawCompleted)
                            }
                        }
                        self.lastPoolGrab = motion.grabSerial; self.lastPoolContact = motion.contactSerial
                    }

                    self.renderer = renderer
                    self.canvas.delegate = renderer
                    self.loading.isHidden = true
                    if self.canRender { self.canvas.draw() }
                    self.updateRendering()
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func text(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = NSColor.white.withAlphaComponent(0.72)
        return field
    }
    private func symbolButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
    private func glass(_ glass: NSGlassEffectView, content: NSView) {
        glass.style = .regular
        glass.cornerRadius = 22
        glass.contentView = content
        root.addSubview(glass)
    }
    private func configureControls() {
        scenes = NSPopUpButton(frame: .zero, pullsDown: false)
        for scene in Scene.allCases {
            scenes.addItem(withTitle: scene.title)
            scenes.lastItem?.tag = scene.rawValue
        }
        scenes.selectItem(withTag: settings.scene.rawValue)
        scenes.target = self
        scenes.action = #selector(selectScene)
        scenes.controlSize = .large
        scenes.setAccessibilityLabel("Scene")
        let topContent = NSView()
        topContent.addSubview(scenes)
        scenes.frame = NSRect(x: 12, y: 7, width: 270, height: 32)
        glass(topGlass, content: topContent)
        let audioStack = NSStackView()
        audioStack.orientation = .horizontal; audioStack.spacing = 7
        audioStack.edgeInsets = NSEdgeInsets(top: 8, left: 11, bottom: 8, right: 11)
        audioButton = symbolButton("speaker.slash", label: "Enable turntable sound", action: #selector(toggleTurntableSound))
        musicButton = symbolButton("music.note", label: "Open local music…", action: #selector(openMusic))
        audioStack.addArrangedSubview(audioButton); audioStack.addArrangedSubview(musicButton)
        glass(audioGlass, content: audioStack)
        let imageStack = NSStackView()
        imageStack.orientation = .horizontal; imageStack.spacing = 7
        imageStack.edgeInsets = NSEdgeInsets(top: 8, left: 11, bottom: 8, right: 11)
        imageButton = symbolButton("photo", label: "Choose image for glass…", action: #selector(openGlassImage))
        defaultImageButton = symbolButton("photo.on.rectangle", label: "Restore seaside image", action: #selector(restoreGlassImage))
        imageStack.addArrangedSubview(imageButton); imageStack.addArrangedSubview(defaultImageButton)
        glass(imageGlass, content: imageStack)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 14)
        preset.controlSize = .small
        preset.target = self
        preset.action = #selector(selectPreset)
        preset.setAccessibilityLabel("Material preset")
        preset.translatesAutoresizingMaskIntoConstraints = false
        preset.widthAnchor.constraint(equalToConstant: 140).isActive = true
        intensity.target = self
        intensity.action = #selector(changeIntensity)
        intensity.isContinuous = true
        intensity.controlSize = .small
        intensity.setAccessibilityLabel("Intensity")
        intensity.translatesAutoresizingMaskIntoConstraints = false
        intensity.widthAnchor.constraint(equalToConstant: 94).isActive = true
        intensityLabel.font = .systemFont(ofSize: 11, weight: .medium)
        intensityLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        intensityLabel.translatesAutoresizingMaskIntoConstraints = false
        intensityLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let tune = symbolButton("slider.horizontal.3", label: "Tune this scene", action: #selector(showTuning(_:)))
        quality.addItems(withTitles: ["Eco", "Balanced", "High", "Cinematic"])
        quality.selectItem(at: settings.quality)
        quality.controlSize = .small
        quality.target = self
        quality.action = #selector(selectQuality)
        quality.setAccessibilityLabel("Rendering quality")
        quality.toolTip = "Cinematic: more ray detail; still scenes refine to 128 samples, then rest."
        fps.addItems(withTitles: ["30 fps", "60 fps", "120 fps"])
        fps.selectItem(at: [30, 60, 120].firstIndex(of: settings.fps) ?? 1)
        fps.controlSize = .small
        fps.target = self
        fps.action = #selector(selectFPS)
        fps.setAccessibilityLabel("Frame rate limit")
        playButton = symbolButton("pause.fill", label: "Pause animation", action: #selector(togglePause))
        let reset = symbolButton("arrow.counterclockwise", label: "Reset scene", action: #selector(resetScene))
        statsButton = symbolButton("chart.xyaxis.line", label: "Show performance", action: #selector(toggleStats))
        for view in [preset, intensityLabel, intensity, tune, quality, fps, playButton!, reset, statsButton!] {
            stack.addArrangedSubview(view)
        }
        glass(bottomGlass, content: stack)
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.62)
        hint.alignment = .center
        root.addSubview(hint)
        statistics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statistics.textColor = NSColor.white.withAlphaComponent(0.82)
        statistics.alignment = .center
        statistics.stringValue = "Measuring…"
        let statsContent = NSView()
        statistics.frame = NSRect(x: 12, y: 10, width: 390, height: 16)
        statsContent.addSubview(statistics)
        glass(statsGlass, content: statsContent)
        statsGlass.isHidden = true
        loading.font = .systemFont(ofSize: 13, weight: .medium)
        loading.textColor = .secondaryLabelColor
        loading.alignment = .center
        root.addSubview(loading)
        updateSceneControls()
    }
    private func layout() {
        let b = root.bounds
        canvas.frame = b
        nativeGlassHost?.frame = NSRect(x: 0, y: 115, width: b.width, height: max(200,b.height-260))
        topGlass.frame = NSRect(x: (b.width - 294) / 2, y: b.height - 91, width: 294, height: 46)
        let audioWidth: CGFloat = settings.scene == .resonantGarden ? 48 : 81
        audioGlass.frame = NSRect(x: b.width - audioWidth - 22, y: b.height - 91, width: audioWidth, height: 46)
        imageGlass.frame = NSRect(x: b.width - 103, y: b.height - 91, width: 81, height: 46)
        bottomGlass.frame = NSRect(x: (b.width - 724) / 2, y: 22, width: 724, height: 50)
        hint.frame = NSRect(x: 20, y: 82, width: b.width - 40, height: 16)
        statsGlass.frame = NSRect(x: (b.width - 414) / 2, y: b.height - 137, width: 414, height: 36)
        loading.frame = NSRect(x: 20, y: b.midY - 14, width: b.width - 40, height: 28)
    }
    @objc func showPrivacy() { PrivacyWindow.shared.show() }
    private func configureMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            item.submenu = sub
            main.addItem(item)
            return sub
        }
        func item(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target ?? self
            menu.addItem(item)
        }
        let app = menu("Molten")
        item("About Molten", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", in: app, target: NSApp)
        item("Privacy…", #selector(showPrivacy), "", in: app)
        app.addItem(.separator())
        item("Hide Molten", #selector(NSApplication.hide(_:)), "h", in: app, target: NSApp)
        item("Quit Molten", #selector(NSApplication.terminate(_:)), "q", in: app, target: NSApp)
        let file = menu("File")
        item("Save Image…", #selector(saveImage), "s", in: file)
        item("Open Image for Glass…", #selector(openGlassImage), "O", in: file)
        item("Restore Glass Background", #selector(restoreGlassImage), "", in: file)
        item("Open Music for Turntable…", #selector(openMusic), "o", in: file)
        item("Close Window", #selector(closeWindow), "w", in: file)
        let edit = menu("Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            // A nil target routes editing commands to the current field editor,
            // including the filename field in the native save panel.
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let sceneMenu = menu("Scene")
        for scene in Scene.allCases {
            let shortcut = scene.rawValue < 9 ? String(scene.rawValue + 1) : ""
            let entry = NSMenuItem(title: scene.title, action: #selector(sceneFromMenu(_:)), keyEquivalent: shortcut)
            entry.tag = scene.rawValue
            entry.target = self
            sceneMenu.addItem(entry)
        }
        sceneMenu.addItem(.separator())
        item("Pause / Resume", #selector(togglePause), " ", in: sceneMenu)
        sceneMenu.items.last?.keyEquivalentModifierMask = []
        item("Reset Scene", #selector(resetScene), "r", in: sceneMenu)
        item("Show / Hide Performance", #selector(toggleStats), "i", in: sceneMenu)
        let windows = menu("Window")
        item("Minimize", #selector(NSWindow.miniaturize(_:)), "m", in: windows, target: window)
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", in: windows, target: window)
        windows.items.last?.keyEquivalentModifierMask = [.command, .control]
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }
    private func installObservers() {
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRendering() }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.scene == .nativeGlass else { return }
                self.apply(); self.renderer?.requestRedraw(); self.redrawIfPaused(); self.updateRendering()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true
                self?.updateRendering()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = false
                self?.updateRendering()
            }
        })
    }
    private var canRender: Bool {
        renderer != nil && !renderingFailed && !sleeping && !NSApp.isHidden && window.isVisible
        && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    private func updateRendering() {
        nativeGlassHost?.model.setActive(canRender)
        let refines = settings.scene.isStatic || (settings.scene.isCinematic && settings.quality == 3 && settings.paused)
        let navigating = canvas.pointerState.navigation != .zero
        let needsRefinement = refines && !(renderer?.engine.cinematic.converged ?? false)
            && !canvas.pointerState.down && !canvas.pointerState.orbiting && !navigating
        let shouldRun = settings.scene == .nativeGlass
            ? FrameScheduling.shouldRunNativeGlass(visible: canRender, paused: settings.paused,
                backdropStill: settings.nativeBackdropStill, physicsAwake: nativeGlassHost?.model.isAwake ?? false,
                redrawPending: renderer?.needsRedraw ?? false)
            : settings.scene == .resonantGarden
            ? FrameScheduling.shouldRunPool(visible: canRender, paused: settings.paused,
                atRest: renderer?.engine.cinematic.pool.motion.isAtRest ?? true, redrawPending: renderer?.needsRedraw ?? false)
            : FrameScheduling.shouldRun(visible: canRender, paused: settings.paused,
            staticScene: settings.scene.isStatic || settings.nativeBackdropStill, refinementPending: needsRefinement,
            interacting: navigating, redrawPending: renderer?.needsRedraw ?? false)
        if canvas.isPaused == shouldRun { renderer?.resetClock() }
        canvas.isPaused = !shouldRun
        if !verifyingControls { turntableAudio.setActive(FrameScheduling.shouldPlayAudio(visible: canRender, paused: settings.paused, scene: settings.scene)) }
        if !verifyingControls { poolAudio.setActive(canRender && !settings.paused && settings.scene == .resonantGarden
            && !(renderer?.engine.cinematic.pool.motion.isAtRest ?? true)) }
        if !canRender { canvas.releaseInput() }
        writeDiagnostics()
    }
    private func redrawIfPaused() {
        guard canRender else { return }
        if settings.scene == .resonantGarden {
            renderer?.requestRedraw()
            updateRendering()
            return
        }
        if settings.paused || settings.scene.isStatic || settings.nativeBackdropStill {
            renderer?.requestRedraw()
            canvas.draw()
            updateRendering()
        }
    }
    private func apply(reset: Bool = false) {
        if settings.scene == .nativeGlass {
            settings.reduceNativeMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            nativeGlassHost?.model.configure(settings)
        }
        if verifyingControls { return }
        renderer?.settings = settings
        if reset { renderer?.reset() }
        canvas.preferredFramesPerSecond = settings.fps
        let defaults = UserDefaults.standard
        defaults.set(settings.scene.rawValue, forKey: "scene")
        defaults.set(settings.quality, forKey: "quality")
        defaults.set(settings.fps, forKey: "fps")
        redrawIfPaused()
        if settings.scene == .nativeGlass { updateRendering() }
    }
    private func updateNativeGlass() {
        guard settings.scene == .nativeGlass else { releaseNativeGlass(); return }
        if nativeGlassHost == nil {
            let host = NativeGlassHost(model: NativeGlassModel())
            nativeGlassHost = host
            host.model.onActivityChange = { [weak self] in self?.updateRendering() }
            host.model.onFeedback = { [weak self] event in
                guard let self, !self.verifyingControls, self.canRender, self.window.isKeyWindow, NSApp.isActive else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(event == .separated ? .generic : .alignment, performanceTime: .drawCompleted)
            }
            root.addSubview(host, positioned: .above, relativeTo: canvas)
        }
        settings.reduceNativeMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        nativeGlassHost?.model.configure(settings)
        nativeGlassHost?.model.setActive(canRender)
        layout()
    }
    private func releaseNativeGlass() {
        nativeGlassHost?.model.onActivityChange = nil
        nativeGlassHost?.model.onFeedback = nil
        nativeGlassHost?.model.setActive(false)
        nativeGlassHost?.removeFromSuperview()
        nativeGlassHost = nil
    }
    private func updateSceneControls() {
        tuningPopover.close()
        preset.removeAllItems()
        preset.addItems(withTitles: settings.scene.presets)
        preset.selectItem(at: settings.preset)
        hint.stringValue = settings.scene.hint
        statistics.stringValue = ""
        statistics.toolTip = nil
        updateHintColor()
        canvas.activeScene = settings.scene
        updateNativeGlass()
        playButton.isEnabled = !settings.scene.isStatic
        quality.toolTip = settings.scene == .nativeGlass ? "Backdrop resolution. Native glass always uses the display's resolution." : "Cinematic: more ray detail; still scenes refine to 128 samples, then rest."
        fps.toolTip = settings.scene == .nativeGlass ? "Frame-rate limit for the backdrop and chain simulation. macOS renders native glass." : "Frame-rate limit"
        intensityLabel.stringValue = settings.scene.primaryTitle
        intensity.setAccessibilityLabel(settings.scene.primaryTitle)
        intensity.toolTip = "\(settings.scene.primaryTitle): \(String(format: "%.2f", settings.intensity))"
        intensity.floatValue = settings.intensity
        updateAudioControls()
    }
    @objc func selectScene() {
        sceneSettings[settings.scene] = (settings.preset, settings.intensity, settings.sceneParameters)
        settings.scene = Scene(rawValue: scenes.selectedItem?.tag ?? Scene.liquid.rawValue) ?? .liquid
        if settings.scene != .koi { turntableAudio.release() }
        if settings.scene != .resonantGarden { poolAudio.release() }
        if let saved = sceneSettings[settings.scene] {
            settings.preset = saved.0
            settings.intensity = saved.1
            settings.sceneParameters = saved.2
        }
        canvas.resetCamera()
        updateSceneControls()
        apply(reset: true)
        if settings.scene == .cove || settings.scene == .fractal { window.makeFirstResponder(canvas) }
        updateRendering()
    }
    @objc func sceneFromMenu(_ sender: NSMenuItem) { scenes.selectItem(withTag: sender.tag); selectScene() }
    @objc func selectPreset() { settings.preset = preset.indexOfSelectedItem; updateHintColor(); if settings.scene == .cove && tuningPopover.isShown { tuningPopover.contentViewController = makeTuningController() }; apply(reset: true) }
    private func updateHintColor() {
        let dark = (settings.scene == .koi && settings.preset != 2) || (settings.scene == .portal && settings.preset != 1) || settings.scene == .batman || settings.scene == .paperCity || (settings.scene == .resonantGarden && settings.preset != 1) || settings.scene == .nativeGlass
        hint.textColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.65)
    }
    private func updateAudioControls() {
        audioGlass.isHidden = settings.scene != .koi && settings.scene != .resonantGarden
        imageGlass.isHidden = settings.scene != .blockGlass
        guard audioButton != nil else { return }
        musicButton.isHidden = settings.scene == .resonantGarden
        if settings.scene == .resonantGarden {
            audioButton.image = NSImage(systemSymbolName: poolAudio.enabled ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: nil)
            audioButton.toolTip = poolAudio.enabled ? "Mute pool sound" : "Enable pool sound"
            audioButton.setAccessibilityLabel(audioButton.toolTip); layout(); return
        }
        audioButton.image = NSImage(systemSymbolName: turntableAudio.enabled ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: nil)
        audioButton.toolTip = turntableAudio.enabled ? "Mute turntable" : "Enable turntable sound"
        audioButton.setAccessibilityLabel(audioButton.toolTip)
        musicButton.toolTip = turntableAudio.trackName.map { "Playing: \($0) · Choose another track" } ?? "Open local music, or drop an audio file on the pond"
        layout()
    }
    private func loadGlassImage(_ url: URL?) {
        guard !verifyingControls, let engine = renderer?.engine else { return }
        do {
            // Scene selection resets resources; install the new texture afterward.
            if settings.scene != .blockGlass { scenes.selectItem(withTag: Scene.blockGlass.rawValue); selectScene() }
            try engine.cinematic.glassEffect.setImage(url)
            engine.cinematic.invalidateHistory()
            canvas.resetCamera()
            hint.stringValue = settings.scene.hint
            imageButton.toolTip = url.map { "Image: \($0.lastPathComponent) · Choose another" } ?? "Choose image for glass…"
            apply(reset: true); renderer?.requestRedraw(); redrawIfPaused(); updateRendering()
        } catch { hint.stringValue = error.localizedDescription }
    }
    @objc func openGlassImage() {
        guard !verifyingControls else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = "Choose an image to view through the glass blocks."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.loadGlassImage(url)
        }
    }
    @objc func restoreGlassImage() { loadGlassImage(nil) }
    @objc func toggleTurntableSound() {
        if settings.scene == .resonantGarden { poolAudio.toggle() } else { turntableAudio.toggle() }
    }
    @objc func openMusic() {
        guard !verifyingControls else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choose a local track for the koi turntable. Drag the record to scratch; lift the tonearm to mute."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let url = panel.url else { return }
            if self.settings.scene != .koi { self.scenes.selectItem(withTag: Scene.koi.rawValue); self.selectScene() }
            self.turntableAudio.load(url)
        }
    }
    @objc func changeIntensity() {
        settings.intensity = intensity.floatValue
        intensity.toolTip = "\(settings.scene.primaryTitle): \(String(format: "%.2f", settings.intensity))"
        apply()
    }
    @objc func showTuning(_ sender: NSButton) {
        if tuningPopover.isShown { tuningPopover.close(); return }
        tuningPopover.contentViewController = makeTuningController()
        tuningPopover.behavior = .transient
        tuningPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    private func makeTuningController() -> NSViewController {
        tuningValues.removeAll()
        let controller = NSViewController()
        let definitions = settings.scene.controls + (settings.scene.isStatic ? [] : [.init(title: "Animation speed", range: 0.15...2, initial: 1)])
        let height = 66 + definitions.count * 66
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: height))
        let heading = NSTextField(labelWithString: settings.scene.title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 20, y: height - 36, width: 270, height: 20)
        controller.view.addSubview(heading)
        for (index, definition) in definitions.enumerated() {
            let isSpeed = index == settings.scene.controls.count
            let tag = isSpeed ? 3 : index
            let value = isSpeed ? settings.speed : settings.sceneParameters[index]
            let y = height - 78 - index * 66
            let title = text(definition.title)
            title.frame = NSRect(x: 20, y: y, width: 190, height: 18)
            controller.view.addSubview(title)
            let reading = text(String(format: "%.3g", value))
            reading.alignment = .right
            reading.frame = NSRect(x: 218, y: y, width: 70, height: 18)
            controller.view.addSubview(reading)
            tuningValues[tag] = reading
            let slider = NSSlider(value: Double(value), minValue: Double(definition.range.lowerBound),
                                  maxValue: Double(definition.range.upperBound), target: self, action: #selector(changeTuning(_:)))
            slider.tag = tag
            slider.isContinuous = true
            if definition.isIntegral {
                slider.numberOfTickMarks = Int(definition.range.upperBound - definition.range.lowerBound) + 1
                slider.allowsTickMarkValuesOnly = true
            }
            slider.setAccessibilityLabel(definition.title)
            slider.frame = NSRect(x: 20, y: y - 27, width: 270, height: 24)
            controller.view.addSubview(slider)
        }
        return controller
    }
    @objc func changeTuning(_ sender: NSSlider) {
        if sender.tag == 3 { settings.speed = sender.floatValue }
        else { settings.sceneParameters[sender.tag] = sender.floatValue }
        tuningValues[sender.tag]?.stringValue = String(format: "%.3g", sender.floatValue)
        apply()
    }
    @objc func selectQuality() { settings.quality = quality.indexOfSelectedItem; apply(); updateRendering() }
    @objc func selectFPS() { settings.fps = [30, 60, 120][fps.indexOfSelectedItem]; apply(); updateRendering() }
    @objc func togglePause() {
        settings.paused.toggle()
        if settings.scene == .resonantGarden && settings.paused {
            canvas.releaseInput(); renderer?.engine.cinematic.pool.motion.cancelGesture()
        }
        playButton.image = NSImage(systemSymbolName: settings.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        playButton.toolTip = settings.paused ? "Resume animation" : "Pause animation"
        playButton.setAccessibilityLabel(playButton.toolTip)
        apply()
        updateRendering()
    }
    @objc func resetScene() { canvas.resetCamera(); nativeGlassHost?.model.reset(); poolAudio.release(); renderer?.reset(); redrawIfPaused(); updateRendering() }
    @objc func toggleStats() {
        settings.showStats.toggle()
        statsGlass.isHidden = !settings.showStats
        statsButton.contentTintColor = settings.showStats ? .systemCyan : .labelColor
        statsButton.setAccessibilityLabel(settings.showStats ? "Hide performance" : "Show performance")
        statsButton.toolTip = settings.showStats ? "Hide performance" : "Show performance"
        if settings.showStats && !lastMetrics.isEmpty { updateMetrics(lastMetrics) }
    }
    @objc func closeWindow() { window.performClose(nil) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveImage) {
            menuItem.toolTip = settings.scene == .nativeGlass ? "Use a macOS screenshot to include the system-composited glass." : nil
            return settings.scene != .nativeGlass && (verifyingControls || renderer?.engine.output != nil)
        }
        return true
    }
    @objc func saveImage() {
        // A Metal readback contains only the backdrop, never SwiftUI's glass.
        guard settings.scene != .nativeGlass else { return }
        guard let renderer, let texture = renderer.engine.output else { return }
        do {
            let pixels = try renderer.engine.readback(texture)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.currentContentType = .png
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = "Molten-\(settings.scene.title).png"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try pixels.save(to: url) }
                catch { NSAlert(error: error).runModal() }
            }
        } catch { NSAlert(error: error).runModal() }
    }
    private func updateMetrics(_ metrics: [String: Any]) {
        lastMetrics = metrics
        if settings.showStats {
            if settings.scene == .nativeGlass {
                statistics.stringValue = canvas.isPaused
                    ? String(format: "Backdrop paused   ·   %.0f MB Metal", metrics["gpu_allocated_mb"] as? Double ?? 0)
                    : String(format: "Backdrop: %.0f fps   ·   %.2f ms GPU", metrics["fps"] as? Double ?? 0, metrics["gpu_ms"] as? Double ?? 0)
                statistics.toolTip = "Backdrop measurements only. Apple's native glass compositor is additional."
            } else if canvas.isPaused && canRender {
                let samples = renderer?.engine.cinematic.samples ?? 0
                statistics.stringValue = settings.scene == .resonantGarden && !settings.paused
                    ? String(format: "Resting   ·   %.0f MB GPU", metrics["gpu_allocated_mb"] as? Double ?? 0)
                    : samples > 0
                    ? String(format: "Resting   ·   %d samples   ·   %.0f MB GPU", samples, metrics["gpu_allocated_mb"] as? Double ?? 0)
                    : String(format: "Paused   ·   %.0f MB GPU", metrics["gpu_allocated_mb"] as? Double ?? 0)
            } else {
                statistics.stringValue = String(format: "%.0f fps   ·   %.2f ms GPU   ·   %.0f MB GPU",
                    metrics["fps"] as? Double ?? 0, metrics["gpu_ms"] as? Double ?? 0, metrics["gpu_allocated_mb"] as? Double ?? 0)
            }
        }
        writeDiagnostics()
    }
    private func writeDiagnostics() {
        guard let url = diagnosticURL else { return }
        var record = lastMetrics
        record["rendering"] = !canvas.isPaused
        record["paused_by_user"] = settings.paused
        record["visible"] = canRender
        record["hidden"] = NSApp.isHidden
        record["miniaturized"] = window.isMiniaturized
        record["occluded"] = !window.occlusionState.contains(.visible)
        record["pid"] = ProcessInfo.processInfo.processIdentifier
        record["scene"] = settings.scene.title
        record["preset"] = settings.scene.presets[settings.preset]
        record["intensity"] = settings.intensity
        record["speed"] = settings.speed
        record["scene_controls"] = settings.scene.controls.enumerated().reduce(into: [String: Float]()) {
            $0[$1.element.title] = settings.sceneParameters[$1.offset]
        }
        record["quality"] = settings.quality
        record["refinement_samples"] = renderer?.engine.cinematic.samples ?? 0
        record["fps_limit"] = settings.fps
        record["measurement_scope"] = settings.scene == .nativeGlass ? "Metal backdrop only; excludes native Liquid Glass compositor" : "Metal scene"
        if let model = nativeGlassHost?.model {
            record["glass_pieces"] = model.pieces.count
            record["glass_active"] = model.active
            record["glass_style"] = model.clear ? "clear" : "regular"
            record["glass_links"] = model.links.count
            record["glass_pins"] = model.pinned.count
            record["glass_physics_awake"] = model.isAwake
            record["glass_physics_ticks"] = model.physicsTicks
        }
        record["total_frames"] = renderer?.totalFrames ?? 0
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    private func showError(_ message: String) {
        guard !renderingFailed else { return }
        renderingFailed = true
        nativeGlassHost?.model.setActive(false)
        canvas.isPaused = true
        loading.isHidden = false
        loading.stringValue = "Unable to render. See error details."
        let alert = NSAlert()
        alert.messageText = "Molten couldn’t start this scene"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
    func windowDidResignKey(_ notification: Notification) { canvas.releaseInput(); nativeGlassHost?.model.cancelDrag(); updateRendering() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateRendering() }
    func windowDidMiniaturize(_ notification: Notification) { updateRendering() }
    func windowDidDeminiaturize(_ notification: Notification) { updateRendering() }
    func windowWillClose(_ notification: Notification) { canvas.isPaused = true; releaseNativeGlass(); turntableAudio.release(); poolAudio.release(); writeDiagnostics() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { canvas?.isPaused = true; releaseNativeGlass(); turntableAudio.release(); poolAudio.release(); writeDiagnostics() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        updateRendering()
        return true
    }

    // Build native controls without ordering any window or starting a render loop.
    // This test does not read or write the user's saved scene/quality preferences.
    func verifyControls() throws {
        verifyingControls = true
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 670),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.contentView = root
        canvas = CanvasView(frame: root.bounds, device: nil)
        root.addSubview(canvas)
        layout()
        configureControls()
        guard scenes.numberOfItems == Scene.allCases.count else { throw MoltenError.failed("Incomplete scene picker.") }
        for width in [760, 920, 1400] {
            window.setContentSize(NSSize(width: width, height: 670))
            layout()
            root.layoutSubtreeIfNeeded()
            guard root.bounds.contains(bottomGlass.frame), root.bounds.contains(topGlass.frame),
                  let stack = bottomGlass.contentView as? NSStackView else {
                throw MoltenError.failed("Controls leave the window at width \(width).")
            }
            stack.layoutSubtreeIfNeeded()
            for control in stack.arrangedSubviews {
                guard control.frame.minX >= -0.5, control.frame.maxX <= stack.bounds.width + 0.5,
                      control.frame.width > 0 else {
                    throw MoltenError.failed("A bottom control is clipped at width \(width).")
                }
            }
        }
        for scene in Scene.allCases {
            try autoreleasepool {
            scenes.selectItem(withTag: scene.rawValue)
            selectScene()
            guard (nativeGlassHost != nil) == (scene == .nativeGlass) else {
                throw MoltenError.failed("Native glass host escaped its scene.")
            }
            guard settings.scene == scene, preset.numberOfItems == 3, audioGlass.isHidden == (scene != .koi && scene != .resonantGarden),
                  imageGlass.isHidden == (scene != .blockGlass),
                  intensityLabel.stringValue == scene.primaryTitle else {
                throw MoltenError.failed("Scene picker or primary control mismatch.")
            }
            let controller = makeTuningController()
            let sliders = controller.view.subviews.compactMap { $0 as? NSSlider }
            guard sliders.count == scene.controls.count + (scene.isStatic ? 0 : 1) else { throw MoltenError.failed("Missing tuning control.") }
            for slider in sliders {
                guard controller.view.bounds.contains(slider.frame) else { throw MoltenError.failed("Clipped tuning slider.") }
                slider.doubleValue = slider.maxValue
                changeTuning(slider)
                let applied = slider.tag == 3 ? settings.speed : settings.sceneParameters[slider.tag]
                guard abs(applied - slider.floatValue) < 0.00001 else { throw MoltenError.failed("Tuning control did not apply.") }
            }
            if scene == .nativeGlass {
                guard let host = nativeGlassHost else { throw MoltenError.failed("Missing native glass host.") }
                intensity.floatValue = 1.6; changeIntensity()
                guard abs(host.model.fusion - 57.6) < 0.001, host.model.size == 1.5, host.model.tint == 1 else {
                    throw MoltenError.failed("Native glass tuning did not reach SwiftUI.")
                }
                for index in 0..<3 {
                    preset.selectItem(at: index); selectPreset()
                    guard host.model.preset == index else { throw MoltenError.failed("Native glass backdrop selection did not reach SwiftUI.") }
                }
                for size in [NSSize(width: 760,height: 520),NSSize(width: 920,height: 670),NSSize(width: 1400,height: 900)] {
                    window.setContentSize(size); layout(); host.layoutSubtreeIfNeeded()
                    guard root.bounds.contains(host.frame), host.frame.minY > hint.frame.maxY,
                          host.frame.maxY < statsGlass.frame.minY else {
                        throw MoltenError.failed("Native glass stage overlaps app controls.")
                    }
                }
                let save = NSMenuItem(title: "Save Image",action: #selector(saveImage),keyEquivalent: "s")
                guard !validateMenuItem(save) else { throw MoltenError.failed("Native glass exposes incomplete Metal-only export.") }
                host.model.dense(); resetScene()
                guard host.model.pieces.count == 7 else { throw MoltenError.failed("Scene reset did not reset native pieces.") }
                host.model.setActive(true); host.model.beginDrag(0)
                windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification,object: window))
                guard !host.model.isDragging, !host.model.active, canvas.isPaused else {
                    throw MoltenError.failed("Hidden native glass remained active.")
                }
            }
            }
        }
        weak var removedHost = nativeGlassHost
        autoreleasepool { scenes.selectItem(withTag: Scene.liquid.rawValue); selectScene() }
        for _ in 0..<3 { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
        guard nativeGlassHost == nil, removedHost == nil, !root.subviews.contains(where: { $0 is NativeGlassHost }) else {
            throw MoltenError.failed("Leaving native glass retained its hosting view.")
        }
        removedHost = nil
        print("PASS native glass bindings, compact layouts, reset, focus loss, export guard and host deallocation")
        // Feed native mouse events directly to the hidden view. No event is
        // posted to the desktop and no window is ordered or activated.
        func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clicks: Int = 1, shift: Bool = false) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else {
                throw MoltenError.failed("Could not create offscreen pointer event.")
            }
            return event
        }
        canvas.activeScene = .holographic; canvas.resetCamera()
        canvas.mouseDown(with: try mouse(.leftMouseDown, x: 450, y: 330))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: 570, y: 350))
        canvas.mouseUp(with: try mouse(.leftMouseUp, x: 570, y: 350))
        guard canvas.pointerState.camera.x > 0.1 else { throw MoltenError.failed("Card drag did not tilt.") }
        let tilted = canvas.pointerState.camera
        canvas.mouseDown(with: try mouse(.leftMouseDown, x: 570, y: 350, shift: true))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: 620, y: 370, shift: true))
        canvas.mouseUp(with: try mouse(.leftMouseUp, x: 620, y: 370, shift: true))
        guard canvas.pointerState.camera == tilted else { throw MoltenError.failed("Light drag also rotated the card.") }
        canvas.mouseDown(with: try mouse(.leftMouseDown, x: 620, y: 370, clicks: 2))
        guard abs(canvas.pointerState.camera.x - tilted.x - .pi) < 0.0001,
              !canvas.pointerState.down else { throw MoltenError.failed("Double click did not flip and release the card.") }
        for scene in [Scene.reef, .river, .koi, .portal, .cove, .batman, .paperCity, .glassBlocks, .blockGlass, .turbine, .paperFolders] {
            canvas.activeScene = scene; canvas.resetCamera()
            canvas.rightMouseDown(with: try mouse(.rightMouseDown, x: 450, y: 330))
            canvas.rightMouseDragged(with: try mouse(.rightMouseDragged, x: 570, y: 350))
            canvas.rightMouseUp(with: try mouse(.rightMouseUp, x: 570, y: 350))
            guard canvas.pointerState.camera.x > 0.1, !canvas.pointerState.orbiting else {
                throw MoltenError.failed("\(scene.title) orbit did not move and release.")
            }
            let camera = canvas.pointerState.camera
            canvas.mouseDown(with: try mouse(.leftMouseDown, x: 450, y: 330))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: 490, y: 310))
            guard canvas.pointerState.down, canvas.pointerState.delta != .zero,
                  canvas.pointerState.camera == camera else {
                throw MoltenError.failed("\(scene.title) stirring did not preserve the camera and supply input.")
            }
            canvas.mouseUp(with: try mouse(.leftMouseUp, x: 490, y: 310))
            guard !canvas.pointerState.down else { throw MoltenError.failed("\(scene.title) stirring did not release.") }
            if scene == .paperFolders {
                guard canvas.pointerState.actionSerial == 1,
                      canvas.pointerState.actionPosition != canvas.pointerState.position else {
                    throw MoltenError.failed("Paper press position was lost before its frame.")
                }
            }
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        canvas.activeScene = .blockGlass
        board.writeObjects([URL(fileURLWithPath: "/tmp/check-glass.png") as NSURL])
        guard canvas.acceptedFile(board)?.lastPathComponent == "check-glass.png" else { throw MoltenError.failed("Glass image drop was rejected.") }
        board.clearContents(); board.writeObjects([URL(fileURLWithPath: "/tmp/check-glass.txt") as NSURL])
        guard canvas.acceptedFile(board) == nil else { throw MoltenError.failed("Glass accepted a non-image drop.") }
        canvas.activeScene = .paperCity
        board.clearContents(); board.writeObjects([URL(fileURLWithPath: "/tmp/check-glass.png") as NSURL])
        guard canvas.acceptedFile(board) == nil else { throw MoltenError.failed("Image drop escaped the glass scene.") }
        print("PASS glass image buttons, image-only drop routing, and scene isolation")
        canvas.releaseInput()
        canvas.activeScene = .portal; canvas.resetCamera()
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 120, wheel2: 0, wheel3: 0),
           let scroll = NSEvent(cgEvent: event) {
            canvas.scrollWheel(with: scroll)
            guard canvas.pointerState.camera.w > 0, canvas.pointerState.camera.z == 0 else {
                throw MoltenError.failed("Portal scrolling did not travel independently of orbit zoom.")
            }
        } else { throw MoltenError.failed("Could not create an offscreen scroll event.") }
        canvas.resetCamera()
        print("PASS native card tilt, Shift-light drag, double-click flip, reef, river, koi and portal orbit/stir/release events")
        print("PASS native portal travel and scene-specific audio controls")
        canvas.activeScene = .resonantGarden; canvas.resetCamera()
        canvas.mouseDown(with: try mouse(.leftMouseDown, x: 450, y: 330))
        for x in 451..<650 { canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: CGFloat(x), y: 330)) }
        canvas.mouseUp(with: try mouse(.leftMouseUp, x: 650, y: 330))
        let poolEvents = canvas.pointerState.poolEvents
        guard poolEvents.contains(where: { if case .press = $0.kind { return true }; return false }),
              poolEvents.contains(where: { if case .release = $0.kind { return true }; return false }),
              poolEvents.count <= 6, !canvas.pointerState.down else {
            throw MoltenError.failed("Pool native events lost an edge or retained unbounded motion.")
        }
        let cancel = canvas.pointerState.cancelSerial
        canvas.releaseInput()
        guard canvas.pointerState.poolEvents.isEmpty && canvas.pointerState.cancelSerial != cancel else {
            throw MoltenError.failed("Pool focus cancellation did not clear queued gestures.")
        }
        canvas.rightMouseDown(with: try mouse(.rightMouseDown, x: 450, y: 330))
        canvas.rightMouseDragged(with: try mouse(.rightMouseDragged, x: 600, y: 420))
        canvas.rightMouseUp(with: try mouse(.rightMouseUp, x: 600, y: 420))
        guard canvas.pointerState.camera == .zero else { throw MoltenError.failed("Pool fixed camera rotated during a right drag.") }
        print("PASS native pool quick-release edges, bounded motion queue, focus cancellation and fixed camera")
        func key(_ type: NSEvent.EventType, _ code: UInt16, shift: Bool = false, repeated: Bool = false) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:shift ? .shift:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:repeated,keyCode:code) else { throw MoltenError.failed("Could not create offscreen key event.") }
            return event
        }
        canvas.activeScene = .cove; canvas.resetCamera()
        canvas.keyDown(with:try key(.keyDown,13,shift:true))
        canvas.keyDown(with:try key(.keyDown,2,shift:true))
        guard canvas.pointerState.navigation == SIMD3(1,0,1),canvas.pointerState.modifiers == 1 else { throw MoltenError.failed("Cove walk/run keys failed.") }
        canvas.keyUp(with:try key(.keyUp,13)); canvas.keyUp(with:try key(.keyUp,2))
        guard canvas.pointerState.navigation == .zero else { throw MoltenError.failed("Cove key release stuck.") }
        canvas.keyDown(with:try key(.keyDown,14)); canvas.keyDown(with:try key(.keyDown,14,repeated:true))
        guard canvas.pointerState.actionSerial == 1 else { throw MoltenError.failed("Interaction repeated while held.") }
        canvas.keyDown(with:try key(.keyDown,8)); canvas.keyDown(with:try key(.keyDown,8,repeated:true))
        guard canvas.pointerState.freeCamera else { throw MoltenError.failed("Free camera toggle repeated while held.") }
        canvas.rightMouseDown(with:try mouse(.rightMouseDown,x:500,y:250))
        canvas.rightMouseDragged(with:try mouse(.rightMouseDragged,x:500,y:650))
        canvas.rightMouseUp(with:try mouse(.rightMouseUp,x:500,y:650))
        guard canvas.pointerState.camera.y < -1.1 else { throw MoltenError.failed("Free camera cannot look up into the canopy.") }

        canvas.keyDown(with:try key(.keyDown,15))
        guard canvas.pointerState.navigation.y == 1 else { throw MoltenError.failed("Free camera ascent failed.") }
        canvas.keyUp(with:try key(.keyUp,15)); canvas.keyDown(with:try key(.keyDown,3))
        guard canvas.pointerState.navigation.y == -1 else { throw MoltenError.failed("Free camera descent failed.") }
        canvas.releaseInput()
        guard canvas.pointerState.navigation == .zero,canvas.pointerState.modifiers == 0 else { throw MoltenError.failed("Focus loss retained movement or running.") }
        canvas.resetCamera()
        guard !canvas.pointerState.freeCamera,canvas.pointerState.actionSerial == 0 else { throw MoltenError.failed("Cove reset retained camera or interaction.") }
        print("PASS native cove walking, running, key release, nonrepeating E/C, free-camera ascent/descent, focus loss and reset")

        guard !window.isVisible, NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else {
            throw MoltenError.failed("Offscreen control verification affected the desktop.")
        }
        print("PASS \(Scene.allCases.count) scene selections, \(Scene.allCases.count * 3) presets, \(Scene.allCases.reduce(0) { $0 + $1.controls.count }) scene controls, four quality levels, and layouts at 760/920/1400 points.")
        guard quality.numberOfItems == 4 else { throw MoltenError.failed("Missing Cinematic quality control.") }
        for paused in [false, true] {
            for refining in [false, true] {
                for interacting in [false, true] {
                    guard !FrameScheduling.shouldRun(visible: false, paused: paused, staticScene: false,
                        refinementPending: refining, interacting: interacting, redrawPending: true) else {
                        throw MoltenError.failed("Hidden windows can schedule GPU work.")
                    }
                }
            }
        }
        guard !FrameScheduling.shouldRun(visible: true, paused: false, staticScene: true, refinementPending: false, interacting: false, redrawPending: false),
              !FrameScheduling.shouldRun(visible: true, paused: true, staticScene: false, refinementPending: false, interacting: false, redrawPending: false),
              FrameScheduling.shouldRun(visible: true, paused: true, staticScene: false, refinementPending: false, interacting: false, redrawPending: true),
              FrameScheduling.shouldRun(visible: true, paused: true, staticScene: false, refinementPending: true, interacting: false, redrawPending: false) else {
            throw MoltenError.failed("Render scheduling failed pause, convergence, or pending input checks.")
        }
        print("PASS hidden, paused, converged, refining, and pending-input rendering policies.")
        print("PASS no window was shown and foreground application remained unchanged.")
    }
}

@main enum Main {
    static func main() {
        if CommandLine.arguments.contains("--native-glass-test") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            do { try NativeGlassTest.run(); exit(0) }
            catch { fputs("Native glass test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--paper-test") {
            do { try PaperTest.run(); exit(0) }
            catch { fputs("Paper test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--turbine-test") {
            do { try WindTest.run(); exit(0) }
            catch { fputs("Turbine test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--garden-test") || CommandLine.arguments.contains("--pool-test") {
            do { try PoolTest.run(); exit(0) }
            catch { fputs("Pool test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--verify-controls") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            do { try AppDelegate().verifyControls(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--glass-effect-test") {
            do { try GlassEffectTest.run(); exit(0) }
            catch { fputs("Glass effect test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--urban-test") {
            do { try UrbanTest.run(); exit(0) }
            catch { fputs("Urban test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--batman-test") {
            do { try BatmanTest.run(); exit(0) }
            catch { fputs("Batman test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--cove-test") {
            do { try CoveTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--river-test") {
            do { try RiverTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--atelier-test") {
            do { try AtelierTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--immersive-test") {
            do { try ImmersiveTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--cinematic-test") {
            do { try CinematicTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--stress-test") {
            do { try StabilityTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--benchmark") {
            do { try Benchmark.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try SelfTest.run(); exit(0) }
            catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
