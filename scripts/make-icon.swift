// Renders the app icon and every size the asset catalog needs.
// Usage: swift scripts/make-icon.swift App/Squeeze/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let canvas = 1024.0

func renderIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824 pt body centred on a 1024 canvas, continuous-corner radius ≈ 22.5%.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.95, alpha: 1)
    )!
    gradient.draw(in: shape, angle: -60)

    // A film frame being squeezed: the frame, then inward arrows on top.
    let frame = NSRect(x: 262, y: 322, width: 500, height: 380)
    let film = NSBezierPath(roundedRect: frame, xRadius: 48, yRadius: 48)
    NSColor.white.withAlphaComponent(0.22).setFill()
    film.fill()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    film.lineWidth = 22
    film.stroke()

    let configuration = NSImage.SymbolConfiguration(pointSize: 300, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let arrows = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = arrows.size
        arrows.draw(in: NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2 + 2,
                               width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let master = renderIcon()
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []

for (points, scale) in sizes {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let resized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try resized.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes to \(outputDirectory.path)")
