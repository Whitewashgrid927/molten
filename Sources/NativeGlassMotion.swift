import AppKit
import SwiftUI
import simd

struct NativeGlassPiece: Identifiable, Equatable {
    let id: Int
    var center: CGPoint
    var diameter: CGFloat
    var form = 0
    var stretch: CGFloat = 1
}

struct NativeGlassLink: Identifiable, Equatable {
    let id: Int
    let a: Int
    let b: Int
    let restRatio: Double
    func contains(_ id: Int) -> Bool { a == id || b == id }
}

struct NativeGlassTear: Equatable {
    let id: Int
    let childID: Int
    let source: NativeGlassPiece
    let grip: CGPoint
    var gripLift: CGFloat = 0
    var outward = CGSize(width: 1,height: 0)
    var pull: CGSize = .zero
    var progress: CGFloat = 0
    var distance: CGFloat { hypot(pull.width, pull.height) }
    var angle: Double { atan2(pull.height, pull.width) }
    var growth: CGFloat { let p = min(1,max(0,progress)); return p*p*(3-2*p) }
}

struct NativeGlassHover: Equatable {
    let id: Int
    let location: CGPoint
    let outward: CGSize?
}

enum NativeGlassTearAvailability: Equatable {
    case ready, tooSmall, full, expanded
    var explanation: String {
        switch self {
        case .ready: return "Pull outward from the highlighted rim to tear. Release early to cancel."
        case .tooSmall: return "Too small to tear. Try a larger piece."
        case .full: return "24-piece limit reached. Remove a piece to tear another."
        case .expanded: return "Close this piece's controls to tear its edge."
        }
    }
}

enum NativeGlassFeedback { case joined, separated, pinned }

// Event-driven, bounded mechanics. AppDelegate advances this model from the
// existing MTKView loop only while visible and awake. There is no second timer.
@MainActor final class NativeGlassModel: ObservableObject {
    static let limit = 24
    @Published private(set) var pieces: [NativeGlassPiece] = []
    @Published private(set) var links: [NativeGlassLink] = []
    @Published private(set) var pinned: Set<Int> = []
    @Published private(set) var tearing: NativeGlassTear?
    @Published private(set) var tearHandoff: NativeGlassTear?
    @Published private(set) var returningTear: NativeGlassTear?
    @Published private(set) var settlingTear: NativeGlassSettlement?
    @Published private(set) var hover: NativeGlassHover?
    @Published private(set) var magnets = true
    @Published var haptics = true
    @Published var selected: Int? = 0
    @Published var expanded: Int?
    @Published var clear = true
    @Published private(set) var fusion: CGFloat = 36
    @Published private(set) var size: CGFloat = 1
    @Published private(set) var tint: CGFloat = 0.08
    @Published private(set) var preset = 0
    @Published private(set) var paused = false
    @Published private(set) var active = false
    @Published var reducedMotion = false { didSet { if reducedMotion { cancelDrag() } } }
    private(set) var isAwake = false
    private(set) var physicsTicks = 0
    var onActivityChange: (() -> Void)?
    var onFeedback: ((NativeGlassFeedback) -> Void)?
    var feedbackClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastFeedback: TimeInterval = -.infinity
    private var nextID = 0
    private var nextLinkID = 0
    @Published private(set) var dragID: Int?
    private var stageDragID: Int?
    private var dragTargetID: Int?
    private var dragStart: CGPoint?
    private var stage = CGSize(width: 920, height: 358)
    private var velocities: [Int: SIMD2<Double>] = [:]
    private var accumulator: Double = 0
    private var movingTime: Double = 0
    private var quietTime: Double = 0
    private var brokenPairs: Set<String> = []
    var isDragging: Bool { dragID != nil }
    var animation: Animation? { active && !paused && !reducedMotion ? .spring(response: 0.7, dampingFraction: 0.72) : nil }

    init() { reset() }
    func reset() {
        cancelDrag(); expanded = nil; selected = 0; nextID = 7; nextLinkID = 0
        links = []; pinned = []; physicsTicks = 0
        pieces = [
            .init(id: 0, center: CGPoint(x: 0.49,y: 0.46), diameter: 158),
            .init(id: 1, center: CGPoint(x: 0.32,y: 0.30), diameter: 105),
            .init(id: 2, center: CGPoint(x: 0.66,y: 0.28), diameter: 120),
            .init(id: 3, center: CGPoint(x: 0.67,y: 0.67), diameter: 98),
            .init(id: 4, center: CGPoint(x: 0.28,y: 0.72), diameter: 86),
            .init(id: 5, center: CGPoint(x: 0.13,y: 0.48), diameter: 57),
            .init(id: 6, center: CGPoint(x: 0.86,y: 0.47), diameter: 60)
        ]
    }
    func configure(_ settings: Settings) {
        if size != CGFloat(settings.sceneParameters.x) { cancelDrag() }
        fusion = CGFloat(settings.intensity) * 36
        size = CGFloat(settings.sceneParameters.x); tint = CGFloat(settings.sceneParameters.y)
        preset = settings.preset; paused = settings.paused
        if paused { cancelDrag() }
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value { cancelDrag() }
    }
    func resize(_ value: CGSize) {
        guard value.width > 0, value.height > 0,
              abs(stage.width-value.width) > 0.5 || abs(stage.height-value.height) > 0.5 else { return }
        cancelDrag(); stage = value
        for i in pieces.indices { pieces[i].center = clamped(pieces[i].center,piece: pieces[i],stage: stage) }
    }
    static func fit(_ stage: CGSize) -> CGFloat { max(0.35,min(1.15,min(stage.width/880,stage.height/410))) }
    func dimensions(_ piece: NativeGlassPiece, stage: CGSize) -> CGSize {
        let factor = Self.fit(stage)
        if expanded == piece.id { return CGSize(width: max(254,268*factor),height: max(152,156*factor)) }
        let d = piece.diameter * size * factor
        return CGSize(width: d * (piece.form == 1 ? 1.5 : 1) * piece.stretch,
                      height: d * (piece.form == 1 ? 0.62 : 1))
    }
    func position(_ piece: NativeGlassPiece, stage: CGSize) -> CGPoint {
        let box = dimensions(piece,stage: stage)
        return CGPoint(x: min(max(box.width/2+9,piece.center.x*stage.width),max(box.width/2+9,stage.width-box.width/2-9)),
                       y: min(max(box.height/2+9,piece.center.y*stage.height),max(box.height/2+9,stage.height-box.height/2-9)))
    }
    private func clamped(_ point: CGPoint, piece: NativeGlassPiece, stage: CGSize) -> CGPoint {
        let box = dimensions(piece,stage: stage)
        let px = min(max(box.width/2+9,point.x*stage.width),max(box.width/2+9,stage.width-box.width/2-9))
        let py = min(max(box.height/2+9,point.y*stage.height),max(box.height/2+9,stage.height-box.height/2-9))
        return CGPoint(x: px/max(1,stage.width),y: py/max(1,stage.height))
    }
    var displayedPieces: [NativeGlassPiece] {
        guard let tear = tearing ?? returningTear,
              !pieces.contains(where: { $0.id == tear.childID }),
              let index = pieces.firstIndex(where: { $0.id == tear.id }) else { return pieces }
        let lobes = tearLobes(tear,stage: stage)
        var display = pieces; display[index] = lobes.parent; display.append(lobes.child)
        return display
    }
    func tearThreshold(_ piece: NativeGlassPiece, stage: CGSize) -> CGFloat {
        let fit = Self.fit(stage)
        return max(48*fit,min(112*fit,piece.diameter*size*fit*0.72))
    }
    func tearLobes(_ tear: NativeGlassTear, stage: CGSize) -> (parent: NativeGlassPiece, child: NativeGlassPiece) {
        let amount = tear.growth
        var parent = tear.source
        parent.diameter *= sqrt(1-pow(0.6*amount,2))
        let direction = tear.distance > 0 ? CGSize(width: tear.pull.width/tear.distance,height: tear.pull.height/tear.distance) : tear.outward
        let box = dimensions(tear.source,stage: stage)
        let exponent: CGFloat = tear.source.form == 2 ? 5 : 2
        let radius = pow(pow(abs(direction.width)/(box.width/2),exponent)
                         + pow(abs(direction.height)/(box.height/2),exponent),-1/exponent)
        let target = max(tearThreshold(tear.source,stage: stage),radius*1.4+(fusion+8)*Self.fit(stage))
        // The extra separation develops during the pull, not in a jump at birth.
        let separation = tear.distance+(target-tearThreshold(tear.source,stage: stage))*amount
        var child = NativeGlassPiece(id: tear.childID,
            center: CGPoint(x: parent.center.x+direction.width*separation/stage.width,
                            y: parent.center.y+direction.height*separation/stage.height),
            diameter: max(1/(size*Self.fit(stage)),tear.source.diameter*0.6*amount),form: parent.form,stretch: parent.stretch)
        child.center = clamped(child.center,piece: child,stage: stage)
        return (parent,child)
    }
    func isGesturePiece(_ id: Int) -> Bool {
        dragID == id || dragTargetID == id || tearing?.childID == id
    }
    var tearCue: NativeGlassTear? { tearing ?? tearHandoff }
    func tearAvailability(_ piece: NativeGlassPiece) -> NativeGlassTearAvailability {
        if expanded == piece.id { return .expanded }
        if pieces.count >= Self.limit { return .full }
        return piece.diameter >= 68 ? .ready : .tooSmall
    }
    // Both the pointer cue and the gesture use this exact rim boundary.
    func edgeDirection(_ piece: NativeGlassPiece, at location: CGPoint, stage: CGSize) -> CGSize? {
        let box = dimensions(piece,stage: stage), p = position(piece,stage: stage)
        let dx = location.x-p.x, dy = location.y-p.y
        guard hypot(dx/(box.width/2),dy/(box.height/2)) >= 0.72 else { return nil }
        let length = max(1,hypot(dx,dy))
        return CGSize(width: dx/length,height: dy/length)
    }
    private func hoverTarget(at location: CGPoint, stage: CGSize) -> NativeGlassPiece? {
        func contains(_ piece: NativeGlassPiece) -> Bool {
            let box = dimensions(piece,stage: stage), p = position(piece,stage: stage)
            let rect = CGRect(x: p.x-box.width/2,y: p.y-box.height/2,width: box.width,height: box.height)
            // Keep the current grip hittable as its lip bulges beyond the old
            // silhouette; otherwise slow edge hovering would flicker on/off.
            guard rect.insetBy(dx: -8,dy: -8).contains(location) else { return false }
            let shape = contour(piece,stage: stage)
            return shape.path(in: rect).contains(location)
        }
        // Match the view's z-order, including selected pieces and open controls.
        if let piece = pieces.first(where: { $0.id == selected }), contains(piece) { return piece }
        return pieces.reversed().first(where: { $0.id != selected && contains($0) })
    }
    func updateHover(at location: CGPoint?, stage: CGSize) {
        var next: NativeGlassHover?
        if let location, active, !isDragging, CGRect(origin: .zero,size: stage).contains(location),
           let piece = hoverTarget(at: location,stage: stage), expanded != piece.id {
            let direction = edgeDirection(piece,at: location,stage: stage)
            next = NativeGlassHover(id: piece.id,location: direction == nil ? position(piece,stage: stage) : location,outward: direction)
        }
        if hover != next { hover = next }
    }
    // The fixed stage owns compact dragging. The glass surfaces can change size
    // and split without moving or replacing the recognizer under the pointer.
    func dragFromStage(translation: CGSize, stage: CGSize, startLocation: CGPoint) {
        guard active else { return }
        if stageDragID == nil {
            guard !isDragging, CGRect(origin: .zero,size: stage).contains(startLocation),
                  let piece = hoverTarget(at: startLocation,stage: stage), expanded != piece.id else { return }
            resize(stage)
            stageDragID = piece.id
        }
        if let id = stageDragID { drag(id,translation: translation,stage: stage,startLocation: startLocation) }
    }
    func endStageDrag(translation: CGSize, predicted: CGSize, stage: CGSize) {
        if let id = stageDragID { endDrag(id,translation: translation,predicted: predicted,stage: stage) }
    }
    func beginDrag(_ id: Int, stage: CGSize? = nil, startLocation: CGPoint? = nil) {
        guard active, dragID == nil, let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        if let stage { resize(stage) }
        returningTear = nil; tearHandoff = nil; settlingTear = nil
        if hover != nil { hover = nil }
        selected = id; dragID = id; dragTargetID = id
        dragStart = clamped(pieces[i].center,piece: pieces[i],stage: self.stage)
        pieces[i].center = dragStart!; velocities[id] = .zero
        if let startLocation, tearAvailability(pieces[i]) == .ready,
           let direction = edgeDirection(pieces[i],at: startLocation,stage: self.stage) {
            tearing = NativeGlassTear(id: id,childID: nextID,source: pieces[i],grip: startLocation,
                gripLift: gripLift(pieces[i],at: startLocation,stage: self.stage),outward: direction)
            nextID += 1
        }
    }
    func drag(_ id: Int, translation: CGSize, stage: CGSize, startLocation: CGPoint? = nil) {
        guard active else { return }
        beginDrag(id,stage: stage,startLocation: startLocation)
        guard dragID == id, let targetID = dragTargetID, let start = dragStart,
              let i = pieces.firstIndex(where: { $0.id == targetID }) else { return }
        if var tear = tearing {
            if translation.width*tear.outward.width + translation.height*tear.outward.height <= 0 {
                tear.pull = .zero; tear.progress = 0; tearing = tear; return
            }
            let d = pieces[i].diameter * size * Self.fit(stage)
            let radius = d/2 + 9
            let anchor = CGPoint(x: start.x*stage.width,y: start.y*stage.height)
            let end = CGPoint(x: min(stage.width-radius,max(radius,anchor.x+translation.width)),
                              y: min(stage.height-radius,max(radius,anchor.y+translation.height)))
            tear.pull = CGSize(width: end.x-anchor.x,height: end.y-anchor.y)
            let threshold = tearThreshold(tear.source,stage: stage)
            tear.progress = min(1,tear.distance/threshold)
            tearing = tear
            if tear.progress >= 1 { finishTear(i,tear: tear,translation: translation) }
            return
        }
        guard !pinned.contains(targetID) else { return }
        let target = CGPoint(x: start.x+translation.width/max(1,stage.width),y: start.y+translation.height/max(1,stage.height))
        pieces[i].center = clamped(target,piece: pieces[i],stage: stage)
        velocities[targetID] = .zero
        breakStretchedLinks(at: targetID)
        connectNear(targetID)
        if !links.isEmpty { wake() }
    }
    private func finishTear(_ index: Int, tear: NativeGlassTear, translation: CGSize) {
        guard pieces.count < Self.limit else { return }
        let (parent,child) = tearLobes(tear,stage: stage)
        var next = pieces; next[index] = parent; next.append(child)
        dragTargetID = child.id
        dragStart = CGPoint(x: child.center.x-translation.width/stage.width,y: child.center.y-translation.height/stage.height)
        // Preview and committed pieces have identical geometry and IDs. No
        // container-wide spring or matched-geometry insertion occurs here.
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            pieces = next; tearHandoff = tear; tearing = nil; selected = child.id
            if animation != nil {
                let direction = CGSize(width: tear.pull.width/tear.distance,height: tear.pull.height/tear.distance)
                settlingTear = NativeGlassSettlement(parentID: parent.id,childID: child.id,direction: direction)
            }
        }
        brokenPairs.insert(pair(parent.id,child.id))
        feedback(.separated)
        if settlingTear != nil || links.contains(where: { $0.contains(parent.id) }) { wake() }
    }
    func endDrag(_ id: Int, translation: CGSize, predicted: CGSize, stage: CGSize) {
        guard dragID == id, let target = dragTargetID, pieces.contains(where: { $0.id == target }) else { return }
        if let tear = tearing {
            returningTear = tear; tearing = nil; finishGesture()
            if animation != nil {
                withAnimation(.easeOut(duration: 0.18),completionCriteria: .logicallyComplete) {
                    returningTear?.pull = .zero; returningTear?.progress = 0
                    returningTear?.gripLift = 0
                } completion: { [weak self] in
                    if self?.returningTear?.childID == tear.childID { self?.returningTear = nil }
                }
            } else { returningTear = nil }
            return
        }
        if !pinned.contains(target) {
            connectNear(target)
            if animation != nil {
                velocities[target] = SIMD2(Double(min(600,max(-600,(predicted.width-translation.width)*3))),
                                           Double(min(450,max(-450,(predicted.height-translation.height)*3))))
            }
        }
        finishGesture()
        if animation != nil, !links.isEmpty || velocities.values.contains(where: { simd_length_squared($0) > 1 }) { wake() }
    }
    private func finishGesture() { dragID = nil; stageDragID = nil; dragTargetID = nil; dragStart = nil; brokenPairs = []; tearHandoff = nil }
    func cancelDrag() { finishGesture(); tearing = nil; returningTear = nil; settlingTear = nil; if hover != nil { hover = nil }; stopMotion() }
    private func setAwake(_ value: Bool) {
        guard value != isAwake else { return }
        isAwake = value; onActivityChange?()
    }
    private func wake() {
        guard active, !paused, !reducedMotion else { return }
        movingTime = 0; quietTime = 0; setAwake(true)
    }
    private func stopMotion() {
        velocities = [:]; accumulator = 0; movingTime = 0; quietTime = 0; setAwake(false)
    }
    private func feedback(_ event: NativeGlassFeedback) {
        let now = feedbackClock()
        guard active, haptics, now-lastFeedback >= 0.09 else { return }
        lastFeedback = now; onFeedback?(event)
    }
    func choose(_ id: Int) { if pieces.contains(where: { $0.id == id }) { selected = id } }
    func toggleExpanded(_ id: Int) {
        guard pieces.contains(where: { $0.id == id }) else { return }
        cancelDrag(); selected = id
        withAnimation(animation) { expanded = expanded == id ? nil : id }
    }
    func togglePin(_ id: Int? = nil) {
        guard let id = id ?? selected, pieces.contains(where: { $0.id == id }) else { return }
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        velocities[id] = .zero; feedback(.pinned)
        if !links.isEmpty { wake() }
    }
    func toggleMagnets() {
        cancelDrag(); magnets.toggle()
        if !magnets { links = [] }
    }
    func morph(_ id: Int? = nil) {
        guard let id = id ?? selected, let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        cancelDrag()
        withAnimation(animation) { pieces[i].form = (pieces[i].form+1)%4 }
    }
    func stretch(_ id: Int, value: CGFloat) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        pieces[i].stretch = min(1.75,max(0.65,value))
    }
    func add() {
        guard pieces.count < Self.limit else { return }
        cancelDrag()
        let id = nextID; nextID += 1
        let angle = CGFloat(id)*2.399963
        let p = NativeGlassPiece(id: id,center: CGPoint(x: 0.5+cos(angle)*0.27,y: 0.49+sin(angle)*0.26),diameter: 76)
        withAnimation(animation) { pieces.append(p); selected = id }
    }
    func split() {
        guard pieces.count < Self.limit, let id = selected, let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        cancelDrag()
        var original = pieces[i]; original.diameter = max(38,original.diameter*0.7071068)
        let child = NativeGlassPiece(id: nextID,center: CGPoint(x: min(0.91,original.center.x+0.055),y: original.center.y),diameter: original.diameter,form: original.form,stretch: original.stretch)
        nextID += 1; original.center.x = max(0.09,original.center.x-0.055)
        withAnimation(animation) { expanded = nil; pieces[i] = original; pieces.append(child) }
        feedback(.separated)
    }
    func remove() {
        guard pieces.count > 1, let selected else { return }
        cancelDrag(); links.removeAll { $0.contains(selected) }; pinned.remove(selected)
        withAnimation(animation) { pieces.removeAll { $0.id == selected }; expanded = nil; self.selected = pieces.first?.id }
    }
    enum Arrangement { case gather, scatter, ribbon, chain }
    func arrange(_ layout: Arrangement) {
        cancelDrag(); links = []; pinned = []
        withAnimation(animation) {
            expanded = nil
            for i in pieces.indices {
                let t = CGFloat(i)/CGFloat(max(1,pieces.count-1)), a = CGFloat(i)*2.399963
                switch layout {
                case .gather:
                    let r = sqrt(CGFloat(i))*0.023
                    pieces[i].center = CGPoint(x: 0.5+cos(a)*r,y: 0.49+sin(a)*r)
                case .scatter:
                    let cols = pieces.count > 12 ? 6 : pieces.count > 6 ? 4 : 3
                    let rows = (pieces.count+cols-1)/cols
                    pieces[i].center = CGPoint(x: (CGFloat(i%cols)+0.5)/CGFloat(cols),y: (CGFloat(i/cols)+0.5)/CGFloat(rows))
                case .ribbon:
                    pieces[i].center = CGPoint(x: 0.15+t*0.7,y: 0.5+sin(t * .pi*2)*0.19)
                    pieces[i].form = 0; pieces[i].stretch = 1
                case .chain:
                    let diameter: CGFloat = pieces.count > 12 ? 48 : 72
                    let spacing = diameter*size*Self.fit(stage)*0.97
                    let columns = min(pieces.count,max(2,Int(stage.width*0.78/spacing)))
                    let row = i/columns, col = row%2 == 0 ? i%columns : columns-1-i%columns
                    pieces[i].diameter = diameter; pieces[i].form = 0; pieces[i].stretch = 1
                    pieces[i].center = CGPoint(x: (stage.width/2+(CGFloat(col)-CGFloat(columns-1)/2)*spacing)/stage.width,
                                              y: 0.4+CGFloat(row)*spacing/stage.height)
                }
            }
        }
        if layout == .chain {
            magnets = true
            for i in 1..<pieces.count { connect(pieces[i-1].id,pieces[i].id,ratio: 0.97) }
            selected = pieces.first?.id
        }
    }
    func dense() {
        cancelDrag()
        while pieces.count < Self.limit { pieces.append(.init(id: nextID,center: CGPoint(x: 0.5,y: 0.5),diameter: 66)); nextID += 1 }
        arrange(.scatter)
    }
    private func pair(_ a: Int, _ b: Int) -> String { "\(min(a,b)):\(max(a,b))" }
    private func point(_ piece: NativeGlassPiece) -> SIMD2<Double> {
        // Optical tear offsets do not move the anchor in the spring simulation.
        SIMD2(Double(piece.center.x*stage.width),Double(piece.center.y*stage.height))
    }
    private func radius(_ piece: NativeGlassPiece) -> Double {
        Double(piece.diameter * size * Self.fit(stage) * 0.5 * (piece.form == 1 ? 0.75 : 1))
    }
    private func component(_ start: Int) -> Set<Int> {
        var visited: Set<Int> = [start], pending = [start]
        while let id = pending.popLast() {
            for link in links where link.contains(id) {
                let next = link.a == id ? link.b : link.a
                if visited.insert(next).inserted { pending.append(next) }
            }
        }
        return visited
    }
    private func connect(_ a: Int, _ b: Int, ratio: Double) {
        guard a != b, links.count < Self.limit-1, !component(a).contains(b),
              links.filter({ $0.contains(a) }).count < 2, links.filter({ $0.contains(b) }).count < 2 else { return }
        links.append(.init(id: nextLinkID,a: a,b: b,restRatio: min(1.10,max(0.85,ratio))))
        nextLinkID += 1
    }
    private func connectNear(_ id: Int) {
        guard magnets, expanded != id, let source = pieces.first(where: { $0.id == id }),
              links.filter({ $0.contains(id) }).count < 2 else { return }
        let connected = component(id), gap = Double(14*Self.fit(stage))
        let candidates = pieces.filter { p in
            !connected.contains(p.id) && expanded != p.id && !brokenPairs.contains(pair(id,p.id)) && links.filter({ $0.contains(p.id) }).count < 2
        }.sorted { simd_distance(point($0),point(source)) < simd_distance(point($1),point(source)) }
        for p in candidates {
            let distance = simd_distance(point(p),point(source)), sum = radius(p)+radius(source)
            if distance >= sum*0.45 && distance <= sum+gap {
                connect(id,p.id,ratio: distance/max(1,sum)); feedback(.joined); wake(); return
            }
        }
    }
    private func breakStretchedLinks(at id: Int) {
        let removed = links.filter { link in
            guard link.contains(id), let a = pieces.first(where: { $0.id == link.a }), let b = pieces.first(where: { $0.id == link.b }) else { return false }
            return simd_distance(point(a),point(b)) > (radius(a)+radius(b))*link.restRatio*1.72 + Double(28*Self.fit(stage))
        }
        guard !removed.isEmpty else { return }
        for link in removed { brokenPairs.insert(pair(link.a,link.b)) }
        let ids = Set(removed.map(\.id)); links.removeAll { ids.contains($0.id) }
        feedback(.separated)
    }
    func advance(elapsed: Double) {
        guard active, !paused, !reducedMotion, isAwake, elapsed.isFinite, elapsed > 0 else { return }
        // The existing visible-scene clock supplies one small local recoil.
        // Nothing new is scheduled once it finishes, even during a held drag.
        if var settling = settlingTear {
            settling.age += min(elapsed,1.0/15)
            settlingTear = settling.age >= NativeGlassSettlement.duration ? nil : settling
        }
        accumulator += min(elapsed,1.0/15)
        let steps = min(8,Int((accumulator+1e-8)*120))
        guard steps > 0 else { return }
        accumulator = max(0,accumulator-Double(steps)/120)
        let dt = 1.0/120, damping = exp(-5.2*dt), scale = Double(Self.fit(stage))
        var moving = pieces, p = pieces.map(point), v = pieces.map { velocities[$0.id] ?? .zero }
        let indices = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { ($1.id,$0) })
        var hanging: Set<Int> = []
        for id in pinned { hanging.formUnion(component(id)) }
        for _ in 0..<steps {
            var force = pieces.map { hanging.contains($0.id) ? SIMD2<Double>(0,110*scale) : .zero }
            for link in links {
                guard let a = indices[link.a], let b = indices[link.b] else { continue }
                let delta = p[b]-p[a], length = simd_length(delta)
                guard length > 0.001 else { continue }
                let direction = delta/length, rest = (radius(pieces[a])+radius(pieces[b]))*link.restRatio
                let strength = 190*(length-rest) + 13*simd_dot(v[b]-v[a],direction)
                let f = direction * min(30_000,max(-30_000,strength))
                force[a] += f; force[b] -= f
            }
            for i in pieces.indices {
                let id = pieces[i].id
                if pinned.contains(id) || dragTargetID == id || expanded == id || returningTear?.id == id { v[i] = .zero; continue }
                let mass = min(3,max(0.5,pow(Double(pieces[i].diameter)/72,2)))
                v[i] = (v[i]+force[i]/mass*dt)*damping
                let speed = simd_length(v[i]); if speed > 900*scale { v[i] *= 900*scale/speed }
                let proposed = p[i]+v[i]*dt
                let c = clamped(CGPoint(x: proposed.x/Double(stage.width),y: proposed.y/Double(stage.height)),piece: pieces[i],stage: stage)
                p[i] = SIMD2(Double(c.x*stage.width),Double(c.y*stage.height))
                if abs(p[i].x-proposed.x) > 0.001 { v[i].x = 0 }
                if abs(p[i].y-proposed.y) > 0.001 { v[i].y = 0 }
            }
            physicsTicks += 1; movingTime += dt
            let maxSpeed = v.map { simd_length($0) }.max() ?? 0
            quietTime = maxSpeed < 1.5*scale && !isDragging ? quietTime+dt : 0
        }
        for i in moving.indices {
            moving[i].center = CGPoint(x: p[i].x/Double(stage.width),y: p[i].y/Double(stage.height))
            velocities[moving[i].id] = v[i]
        }
        pieces = moving
        let stillWhileHeld = isDragging && links.isEmpty && v.allSatisfy { simd_length_squared($0) < 1 }
        if settlingTear == nil && (stillWhileHeld || !isDragging && (quietTime > 0.22 || movingTime >= 8)) { stopMotion() }
    }
}
