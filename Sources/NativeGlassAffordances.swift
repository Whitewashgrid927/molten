import SwiftUI

// Only the touched part of the native material responds. No instruction views,
// extra glass surfaces, backdrop filters or independent animation clocks.
struct NativeGlassSurfaceResponse: Equatable {
    var direction: CGSize = .zero
    var lift: CGFloat = 0
    var light: Double = 0
    var spread: CGFloat = 0.34
    var displacement: CGSize { CGSize(width: direction.width*lift,height: direction.height*lift) }
}

struct NativeGlassSettlement {
    let parentID: Int
    let childID: Int
    let direction: CGSize
    var age: Double = 0
    static let duration = 0.24
    var pulse: CGFloat {
        let t = min(1,max(0,age/Self.duration))
        // Both endpoints are zero: the cut itself cannot change the silhouette.
        return CGFloat(sin(.pi*t)*exp(-1.8*t))
    }
}

@MainActor extension NativeGlassModel {
    func gripLift(_ piece: NativeGlassPiece, at point: CGPoint, stage: CGSize) -> CGFloat {
        let box = dimensions(piece,stage: stage), center = position(piece,stage: stage)
        let distance = hypot((point.x-center.x)/(box.width/2),(point.y-center.y)/(box.height/2))
        let t = min(1,max(0,(distance-0.72)/0.24))
        return 3.5*Self.fit(stage)*t*t*(3-2*t)
    }
    func surfaceResponse(_ piece: NativeGlassPiece, stage: CGSize) -> NativeGlassSurfaceResponse {
        guard active, expanded != piece.id else { return .init() }
        let scale = Self.fit(stage)
        if let tear = tearing ?? returningTear,
           piece.id == tear.id || piece.id == tear.childID {
            let p = min(1,max(0,tear.progress))
            let direction = tear.distance > 0 ? CGSize(width: tear.pull.width/tear.distance,height: tear.pull.height/tear.distance) : tear.outward
            let child = piece.id == tear.childID
            let facing = child ? CGSize(width: -direction.width,height: -direction.height) : direction
            let lift = child ? 6*scale*sin(.pi*p)*tear.growth : tear.gripLift*(1-p)+5*scale*sin(.pi*p)
            var response = NativeGlassSurfaceResponse(direction: facing,
                lift: reducedMotion || paused ? 0 : min(6.4*scale,lift),
                light: child ? Double(tear.growth)*(0.48+0.42*Double(p)) : 0.48+0.42*Double(p),
                spread: 0.34-0.16*p)
            // Partial release returns both shape and light to rest together.
            if returningTear != nil { response.light *= Double(min(1,p*5)) }
            return response
        }
        if let settling = settlingTear, piece.id == settling.parentID || piece.id == settling.childID {
            let direction = piece.id == settling.parentID ? settling.direction : CGSize(width: -settling.direction.width,height: -settling.direction.height)
            return .init(direction: direction,lift: 5*scale*settling.pulse,
                         light: 0.9*max(0,1-settling.age/NativeGlassSettlement.duration),spread: 0.18)
        }
        if !isDragging, let hover, hover.id == piece.id, let direction = hover.outward,
           tearAvailability(piece) == .ready {
            let lift = gripLift(piece,at: hover.location,stage: stage)
            return .init(direction: direction,lift: reducedMotion || paused ? 0 : lift,
                         light: 0.32+0.3*Double(lift/(3.5*scale)),spread: 0.34)
        }
        return .init()
    }
    func contour(_ piece: NativeGlassPiece, stage: CGSize) -> NativeGlassContour {
        let opened = expanded == piece.id
        return NativeGlassContour(square: opened || piece.form == 2 ? 1 : 0,
                                  petals: piece.form == 3 && !opened ? 1 : 0,
                                  lip: surfaceResponse(piece,stage: stage).displacement)
    }
}

// A paired light/dark glint remains legible on bright and dark landscapes. Its
// soft mask covers a short section of the real contour, never a full outline.
struct NativeGlassRimLight: View {
    let shape: NativeGlassContour
    let response: NativeGlassSurfaceResponse
    let box: CGSize
    var body: some View {
        let tip = shape.rimPoint(toward: response.direction,in: CGRect(origin: .zero,size: box))
        let center = UnitPoint(x: (tip.x+5)/max(1,box.width+10),y: (tip.y+5)/max(1,box.height+10))
        let radius = max(5,min(box.width,box.height)*response.spread)
        shape.stroke(.black.opacity(0.32),style: StrokeStyle(lineWidth: 3,lineCap: .round))
            .overlay {
                shape.stroke(.white.opacity(0.95),style: StrokeStyle(lineWidth: 1.15,lineCap: .round))
            }
            .mask {
                RadialGradient(colors: [.white,.white.opacity(0.75),.clear],center: center,
                               startRadius: 0,endRadius: radius)
                    .padding(-5)
            }
            .opacity(response.light)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
