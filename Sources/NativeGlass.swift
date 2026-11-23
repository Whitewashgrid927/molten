import AppKit
import SwiftUI

// A public SwiftUI Shape supplies a changing silhouette to Apple's material.
// The optical shading, backdrop refraction and unions belong to glassEffect.
struct NativeGlassContour: Shape {
    var square: CGFloat
    var petals: CGFloat
    var lip: CGSize = .zero
    var animatableData: AnimatablePair<AnimatablePair<CGFloat,CGFloat>,AnimatablePair<CGFloat,CGFloat>> {
        get { .init(.init(square,petals),.init(lip.width,lip.height)) }
        set { square = newValue.first.first; petals = newValue.first.second
              lip = CGSize(width: newValue.second.first,height: newValue.second.second) }
    }
    private func point(angle: CGFloat, in rect: CGRect) -> CGPoint {
        let exponent = 2 / (2 + max(0,square)*3)
        let flower = min(1,max(0,petals))*0.15
        let c = cos(angle), s = sin(angle), r = (1+flower*cos(5*angle))/(1+flower)
        let x = (c < 0 ? -1 : 1)*pow(abs(c),exponent)*r*rect.width/2
        let y = (s < 0 ? -1 : 1)*pow(abs(s),exponent)*r*rect.height/2
        let length = max(0.001,hypot(x,y)), lift = max(0.001,hypot(lip.width,lip.height))
        let alignment = (x*lip.width+y*lip.height)/(length*lift)
        let t = min(1,max(0,(alignment-0.65)/0.35)), weight = t*t*(3-2*t)
        return CGPoint(x: rect.midX+x+lip.width*weight,y: rect.midY+y+lip.height*weight)
    }
    func rimPoint(toward direction: CGSize, in rect: CGRect) -> CGPoint {
        // Convert a screen-space direction to this superellipse's parameter.
        // A unit-circle shortcut misplaces the glint on stretched/flower pieces.
        let exponent = (2+max(0,square)*3)/2
        let x = direction.width/max(0.001,rect.width/2), y = direction.height/max(0.001,rect.height/2)
        let angle = atan2((y < 0 ? -1 : 1)*pow(abs(y),exponent),(x < 0 ? -1 : 1)*pow(abs(x),exponent))
        return point(angle: angle,in: rect)
    }
    func path(in rect: CGRect) -> Path {
        let count = 64
        let points = (0..<count).map { point(angle: CGFloat($0)/CGFloat(count) * .pi*2,in: rect) }
        var result = Path(); result.move(to: points[0])
        for i in 0..<count {
            let a = points[(i+count-1)%count], b = points[i], c = points[(i+1)%count], d = points[(i+2)%count]
            result.addCurve(to: c, control1: CGPoint(x: b.x+(c.x-a.x)/6,y: b.y+(c.y-a.y)/6),
                            control2: CGPoint(x: c.x-(d.x-b.x)/6,y: c.y-(d.y-b.y)/6))
        }
        result.closeSubpath(); return result
    }
}

// Reserve fixed transparent space around the silhouette. The system material
// can render an outward lip without relying on drawing beyond its view bounds.
struct NativeGlassEnvelope: Shape {
    var contour: NativeGlassContour
    static let margin: CGFloat = 10
    var animatableData: NativeGlassContour.AnimatableData {
        get { contour.animatableData }
        set { contour.animatableData = newValue }
    }
    func path(in rect: CGRect) -> Path {
        contour.path(in: rect.insetBy(dx: Self.margin,dy: Self.margin))
    }
}

@MainActor struct NativeGlassPlayground: View {
    @ObservedObject var model: NativeGlassModel
    @Namespace private var material
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.accessibilityReduceTransparency) private var reducedTransparency
    private var accent: Color { model.preset == 1 ? .green : model.preset == 2 ? .orange : .blue }
    var body: some View {
        GeometryReader { geometry in
            let stage = CGSize(width: geometry.size.width, height: max(100,geometry.size.height-52))
            ZStack(alignment: .topLeading) {
                GlassEffectContainer(spacing: model.fusion * NativeGlassModel.fit(stage)) {
                    ZStack(alignment: .topLeading) {
                        links(stage: stage)
                        ForEach(model.displayedPieces) { piece in
                            pieceView(piece, stage: stage)
                        }
                    }.frame(width: stage.width,height: stage.height)
                }
                toolbar
                    .frame(width: geometry.size.width, height: 40)
                    .position(x: geometry.size.width/2,y: geometry.size.height-22)
            }
            .frame(width: geometry.size.width,height: geometry.size.height)
            .coordinateSpace(name: "native-glass-stage")
            .simultaneousGesture(
                DragGesture(minimumDistance: 3,coordinateSpace: .named("native-glass-stage"))
                    .onChanged { model.dragFromStage(translation: $0.translation,stage: stage,startLocation: $0.startLocation) }
                    .onEnded { model.endStageDrag(translation: $0.translation,predicted: $0.predictedEndTranslation,stage: stage) }
            )
            .onContinuousHover(coordinateSpace: .named("native-glass-stage")) { phase in
                switch phase {
                case .active(let location): model.updateHover(at: location,stage: stage)
                case .ended: model.updateHover(at: nil,stage: stage)
                }
            }
        }
        .onAppear { model.reducedMotion = reducedMotion }
        .onChange(of: reducedMotion) { _, value in model.reducedMotion = value }
        .onExitCommand { model.cancelDrag() }
        .environment(\.colorScheme, .light)
        .transaction {
            if model.isDragging || !model.active || model.paused || reducedMotion {
                $0.animation = nil; $0.disablesAnimations = true
            }
        }
    }
    private func drag(_ id: Int, stage: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("native-glass-stage"))
            .onChanged { model.drag(id, translation: $0.translation, stage: stage, startLocation: $0.startLocation) }
            .onEnded { model.endDrag(id, translation: $0.translation, predicted: $0.predictedEndTranslation, stage: stage) }
    }
    private func pieceView(_ piece: NativeGlassPiece, stage: CGSize) -> some View {
        pieceSurface(piece,stage: stage)
            .zIndex(model.isGesturePiece(piece.id) ? 2 : model.selected == piece.id ? 1 : 0)
            .transition(.identity)
            .accessibilityHidden(model.tearing?.childID == piece.id || model.returningTear?.childID == piece.id)
            .accessibilityElement(children: model.expanded == piece.id ? .contain : .ignore)
            .accessibilityLabel("Glass piece \(piece.id+1)")
            .accessibilityValue(model.tearing?.id == piece.id ? "Tearing, \(Int((model.tearing?.progress ?? 0)*100)) percent" : model.pinned.contains(piece.id) ? "Pinned" : "Movable")
            .accessibilityHint("\(model.pinned.contains(piece.id) ? "Pinned in place." : "Drag the center to move.") \(model.tearAvailability(piece).explanation) Double-click for controls.")
            .accessibilityAction(named: "Open controls") { model.toggleExpanded(piece.id) }
            .accessibilityAction(named: "Change shape") { model.choose(piece.id); model.morph() }
            .accessibilityAction(named: "Split") { model.choose(piece.id); model.split() }
            .accessibilityAction(named: "Pin or unpin") { model.togglePin(piece.id) }
            .contextMenu {
                Button(model.pinned.contains(piece.id) ? "Unpin" : "Pin here",systemImage: "pin") { model.togglePin(piece.id) }
                Button("Split",systemImage: "circle.lefthalf.filled") { model.choose(piece.id); model.split() }
                    .disabled(model.pieces.count >= NativeGlassModel.limit)
            }
    }
    private func compactContents(_ piece: NativeGlassPiece, box: CGSize, shape: NativeGlassContour,
                                 stage: CGSize) -> some View {
        let highlighted = model.selected == piece.id || model.isGesturePiece(piece.id)
        let preview = model.tearing ?? model.returningTear
        let prominent = model.pinned.contains(piece.id) || piece.id == 0
        let symbol = model.pinned.contains(piece.id) ? "pin.fill" : piece.id == 0 ? "sparkle" : "circle.fill"
        return Image(systemName: symbol)
            .font(.system(size: prominent ? 16 : 4,weight: .medium))
            .foregroundStyle(.primary.opacity(highlighted ? 0.65 : 0.30))
            .opacity(preview?.childID == piece.id ? Double(preview?.growth ?? 0) : 1)
            .frame(width: box.width,height: box.height)
            .contentShape(shape)
            .onTapGesture(count: 2) { model.toggleExpanded(piece.id) }
            .onTapGesture { model.choose(piece.id) }
    }
    private func pieceSurface(_ piece: NativeGlassPiece, stage: CGSize) -> some View {
        let box = model.dimensions(piece, stage: stage)
        let opened = model.expanded == piece.id
        let response = model.surfaceResponse(piece,stage: stage)
        let shape = model.contour(piece,stage: stage)
        let envelope = NativeGlassEnvelope(contour: shape)
        let glass = (model.clear ? Glass.clear : Glass.regular).tint(model.tint > 0.001 ? accent.opacity(model.tint) : nil).interactive()
        return Group {
            if opened {
                expandedContents(piece, stage: stage)
            } else {
                compactContents(piece,box: box,shape: shape,stage: stage)
            }
        }
        .frame(width: box.width,height: box.height)
        .padding(NativeGlassEnvelope.margin)
        .background { if reducedTransparency { envelope.fill(.background) } }
        .glassEffect(glass, in: envelope)
        .glassEffectID(piece.id,in: material)
        .glassEffectTransition(.identity)
        .overlay { NativeGlassRimLight(shape: shape,response: response,box: box).frame(width: box.width,height: box.height) }
        .animation(model.animation != nil && !model.isDragging && model.returningTear == nil ? .easeOut(duration: 0.12) : nil,value: model.hover)
        .position(model.position(piece,stage: stage))
    }
    private func links(stage: CGSize) -> some View {
        // A fine tether marks a stretched magnetic connection. It disappears
        // inside touching beads; all glass material remains native glassEffect.
        Path { path in
            for link in model.links {
                guard let a = model.pieces.first(where: { $0.id == link.a }),
                      let b = model.pieces.first(where: { $0.id == link.b }) else { continue }
                let p = model.position(a,stage: stage), q = model.position(b,stage: stage)
                let dx = q.x-p.x, dy = q.y-p.y, length = hypot(dx,dy)
                let ar = min(model.dimensions(a,stage: stage).width,model.dimensions(a,stage: stage).height)/2
                let br = min(model.dimensions(b,stage: stage).width,model.dimensions(b,stage: stage).height)/2
                guard length > ar+br+1 else { continue }
                path.move(to: CGPoint(x: p.x+dx/length*ar,y: p.y+dy/length*ar))
                path.addLine(to: CGPoint(x: q.x-dx/length*br,y: q.y-dy/length*br))
            }
        }.stroke(.primary.opacity(0.22),style: StrokeStyle(lineWidth: 1.3,lineCap: .round))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func expandedContents(_ piece: NativeGlassPiece, stage: CGSize) -> some View {
        let scale = max(0.95,NativeGlassModel.fit(stage))
        return VStack(spacing: 9*scale) {
            HStack {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text("Piece \(piece.id+1)").fontWeight(.medium)
                Spacer()
                Button { model.toggleExpanded(piece.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close this piece")
            }.contentShape(Rectangle()).gesture(drag(piece.id,stage:stage))
            HStack {
                Text("Stretch").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.pieces.first(where: { $0.id == piece.id })?.stretch ?? 1 },
                                      set: { model.stretch(piece.id,value: $0) }),in: 0.65...1.75)
                    .accessibilityLabel("Stretch this glass piece")
            }
            HStack {
                Button("Shape",systemImage: "circle.square") { model.morph(piece.id) }
                Button("Split",systemImage: "circle.lefthalf.filled") { model.choose(piece.id); model.split() }
                    .disabled(model.pieces.count >= NativeGlassModel.limit)
                Button(model.pinned.contains(piece.id) ? "Unpin" : "Pin",systemImage: "pin") { model.togglePin(piece.id) }
            }.buttonStyle(.borderless)
        }
        .font(.system(size: max(10,12*scale)))
        .padding(18*scale)
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Glass",selection: $model.clear) {
                Text("Clear").tag(true)
                Text("Regular").tag(false)
            }.pickerStyle(.segmented).frame(width: 132).help("Apple's native glass variants")
            Divider().frame(height: 18)
            action("circle.hexagongrid.fill", "Gather") { model.arrange(.gather) }
            action("waveform.path", "Ribbon") { model.arrange(.ribbon) }
            action("square.grid.3x3", "Scatter") { model.arrange(.scatter) }
            action("link", "Make a magnetic chain") { model.arrange(.chain) }
            action("circle.lefthalf.filled", "Split",disabled: model.pieces.count >= NativeGlassModel.limit) { model.split() }
            editMenu
            toggle("point.3.connected.trianglepath.dotted", "Magnetism",on: model.magnets) { model.toggleMagnets() }
            toggle("pin", "Pin selected piece",on: model.selected.map { model.pinned.contains($0) } ?? false) { model.togglePin() }
            toggle("hand.tap", "Trackpad feedback",on: model.haptics) { model.haptics.toggle() }
            Text("\(model.pieces.count)/24").monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 32)
        }.controlSize(.small)
    }
    private var editMenu: some View {
        Menu {
            Button("Add piece",systemImage: "plus") { model.add() }.disabled(model.pieces.count >= NativeGlassModel.limit)
            Button("Change shape",systemImage: "circle.square") { model.morph() }
            Button("Fill with 24 pieces",systemImage: "square.grid.4x3.fill") { model.dense() }
            Button("Remove selected piece",systemImage: "minus") { model.remove() }.disabled(model.pieces.count <= 1)
        } label: {
            Image(systemName: "ellipsis").frame(width: 22,height: 23)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .glassEffect(.regular,in: .capsule)
        .help("More glass actions").accessibilityLabel("More glass actions")
    }
    private func action(_ symbol: String, _ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22,height: 23) }
            .buttonStyle(.glass).help(title).accessibilityLabel(title).disabled(disabled)
    }
    private func toggle(_ symbol: String, _ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22,height: 23).foregroundStyle(on ? accent : .secondary)
        }.buttonStyle(.glass).help("\(title): \(on ? "on" : "off")")
            .accessibilityLabel(title).accessibilityValue(on ? "On" : "Off")
    }
}

@MainActor final class NativeGlassHost: NSHostingView<NativeGlassPlayground> {
    let model: NativeGlassModel
    init(model: NativeGlassModel) {
        self.model = model
        super.init(rootView: NativeGlassPlayground(model: model))
        sizingOptions = []
        setAccessibilityLabel("Native Liquid Glass playground")
    }
    @available(*, unavailable) required init(rootView: NativeGlassPlayground) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Only the AppKit viewport resizes the model, not the glass/cue layout.
        model.resize(CGSize(width: newSize.width,height: max(100,newSize.height-52)))
    }
}
