// Renders docs/assets/social-preview.png (1280x640) for GitHub's social preview.
// usage: swift scripts/make-social-preview.swift <repo-root>
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W = 1280, H = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background
let colors = [NSColor(white: 0.03, alpha: 1).cgColor, NSColor(white: 0.12, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])

// Faint ping rings behind the screenshot
for (i, r) in [180.0, 260.0, 340.0].enumerated() {
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06 - Double(i) * 0.015).cgColor)
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: CGRect(x: 960 - r, y: 320 - r, width: r * 2, height: r * 2))
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                 .foregroundColor: color])
}

let icon = NSImage(contentsOfFile: "\(root)/docs/assets/icon.png")!
icon.draw(in: NSRect(x: 72, y: 388, width: 150, height: 150))
text("Wirelight", size: 86, weight: .bold, color: .white, at: NSPoint(x: 80, y: 270))
text("A friendly menu bar client", size: 36, weight: .regular, color: NSColor(white: 0.78, alpha: 1), at: NSPoint(x: 84, y: 210))
text("for WireGuard® on macOS", size: 36, weight: .regular, color: NSColor(white: 0.78, alpha: 1), at: NSPoint(x: 84, y: 166))
text("Free · Open source · Split DNS · Split tunneling", size: 22, weight: .medium,
     color: NSColor(srgbRed: 0.42, green: 0.86, blue: 0.62, alpha: 1), at: NSPoint(x: 84, y: 96))

// Menu screenshot on the right with rounded corners
let shot = NSImage(contentsOfFile: "\(root)/docs/assets/screenshots/menu.png")!
let sh: CGFloat = 560, sw = sh * shot.size.width / shot.size.height
let rect = NSRect(x: 960 - sw / 2, y: (CGFloat(H) - sh) / 2, width: sw, height: sh)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: NSColor.black.withAlphaComponent(0.6).cgColor)
NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
ctx.restoreGState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).addClip()
shot.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(root)/docs/assets/social-preview.png"))
print("wrote docs/assets/social-preview.png")
