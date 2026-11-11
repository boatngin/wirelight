// Renders the app icon set and a menu bar icon preview.
// usage: swift scripts/make-icons.swift <repo-root>
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(root)/App/Wirelight/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)


func render(_ px: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ ctx: CGContext, _ s: CGFloat) {
    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024, body = s - inset * 2, radius = body * 0.225
    let rect = CGRect(x: inset, y: inset, width: body, height: body)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: inset), end: CGPoint(x: 0, y: s - inset), options: [])
    ctx.restoreGState()

    // Sonar ping: white core with concentric white rings fading outward.
    let c = CGPoint(x: s / 2, y: s / 2)
    let u = body / 18
    let teal = NSColor.white
    for (r, a, w) in [(4.0, 0.95, 0.55), (5.9, 0.6, 0.5), (7.7, 0.3, 0.45)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setStrokeColor(teal.withAlphaComponent(a).cgColor)
        ctx.setLineWidth(w * u)
        ctx.strokeEllipse(in: CGRect(x: c.x - r * u, y: c.y - r * u, width: r * 2 * u, height: r * 2 * u))
    }
    let dr: CGFloat = 1.7 * u
    let amber = NSColor.white
    ctx.setShadow(offset: .zero, blur: u * 1.6, color: amber.withAlphaComponent(0.5).cgColor)
    ctx.setFillColor(amber.cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2))
}

var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try render(pt * sc, appIcon).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(sc)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(iconset)/Contents.json"))
try #"{"info":{"version":1,"author":"xcode"}}"#.data(using: .utf8)!
    .write(to: URL(fileURLWithPath: "\(root)/App/Wirelight/Assets.xcassets/Contents.json"))
print("wrote \(iconset)")
