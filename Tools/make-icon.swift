import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let sizes = [(16, ""), (32, "@2x"), (32, ""), (64, "@2x"), (128, ""), (256, "@2x"), (256, ""), (512, "@2x"), (512, ""), (1024, "@2x")]
for (pixels, suffix) in sizes {
    let base = suffix.isEmpty ? pixels : pixels / 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.2, blue: 0.28, alpha: 1),
               ending: NSColor(srgbRed: 0.018, green: 0.025, blue: 0.05, alpha: 1))!.draw(in: background, angle: -80)
    let blob = NSBezierPath()
    blob.move(to: NSPoint(x: 218, y: 310))
    blob.curve(to: NSPoint(x: 214, y: 690), controlPoint1: NSPoint(x: 124, y: 432), controlPoint2: NSPoint(x: 244, y: 528))
    blob.curve(to: NSPoint(x: 492, y: 814), controlPoint1: NSPoint(x: 189, y: 826), controlPoint2: NSPoint(x: 361, y: 737))
    blob.curve(to: NSPoint(x: 789, y: 634), controlPoint1: NSPoint(x: 668, y: 917), controlPoint2: NSPoint(x: 860, y: 826))
    blob.curve(to: NSPoint(x: 776, y: 278), controlPoint1: NSPoint(x: 717, y: 467), controlPoint2: NSPoint(x: 936, y: 327))
    blob.curve(to: NSPoint(x: 486, y: 290), controlPoint1: NSPoint(x: 677, y: 219), controlPoint2: NSPoint(x: 571, y: 376))
    blob.curve(to: NSPoint(x: 218, y: 310), controlPoint1: NSPoint(x: 378, y: 176), controlPoint2: NSPoint(x: 261, y: 242))
    blob.close()
    let gradient = NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.02, green: 0.07, blue: 0.12, alpha: 1), 0),
        (NSColor(srgbRed: 0.82, green: 0.48, blue: 0.22, alpha: 1), 0.18),
        (NSColor(srgbRed: 0.04, green: 0.08, blue: 0.14, alpha: 1), 0.24),
        (NSColor(srgbRed: 0.09, green: 0.21, blue: 0.31, alpha: 1), 0.47),
        (NSColor(srgbRed: 0.64, green: 0.91, blue: 1, alpha: 1), 0.63),
        (NSColor(srgbRed: 0.87, green: 0.96, blue: 1, alpha: 1), 0.76),
        (NSColor(srgbRed: 0.31, green: 0.47, blue: 0.57, alpha: 1), 1))!
    gradient.draw(in: blob, angle: 82)
    NSColor.white.withAlphaComponent(0.28).setStroke()
    blob.lineWidth = 3
    blob.stroke()
    NSGraphicsContext.saveGraphicsState()
    blob.addClip()
    let highlight = NSBezierPath(ovalIn: NSRect(x: 234, y: 662, width: 228, height: 76))
    NSColor.white.withAlphaComponent(0.85).setFill()
    highlight.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: folder.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
}
