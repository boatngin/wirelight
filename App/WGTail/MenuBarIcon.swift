import AppKit

/// Menu bar icon: a sonar "ping".
///  - disconnected: hollow centre, faint dashed outer ring
///  - connecting:   solid centre, two rings pulsing outward
///  - connected:    solid centre, two steady rings
///  - stale:        hollow centre, steady rings
/// Rendered as a template image so macOS tints it for light/dark menu bars.
enum IconState: Equatable {
    case disconnected
    case connecting(frame: Int)
    case connected
    case stale
}

enum MenuBarIcon {
    static let side: CGFloat = 21
    /// Geometry is designed on an 18pt grid and scaled up to `side`.
    static let k: CGFloat = side / 18
    static let frames = 12

    /// Draws the icon into the current context (y-down). `color` is black for
    /// template images; any color for previews.
    static func draw(_ state: IconState, color: NSColor, scale: CGFloat = 1) {
        let s = scale * k
        let c = NSPoint(x: 9 * s, y: 9 * s)
        let line = 1.15 * s

        func ring(_ r: CGFloat, alpha: CGFloat, dashed: Bool = false) {
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            p.lineWidth = line
            if dashed { p.setLineDash([2 * s, 2.6 * s], count: 2, phase: 0) }
            color.withAlphaComponent(alpha).setStroke()
            p.stroke()
        }

        func centre(filled: Bool, alpha: CGFloat = 1) {
            let r = (filled ? 2.3 : 2.0) * s
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if filled {
                color.withAlphaComponent(alpha).setFill()
                p.fill()
            } else {
                p.lineWidth = 1.15 * s
                color.withAlphaComponent(alpha).setStroke()
                p.stroke()
            }
        }

        switch state {
        case .disconnected:
            centre(filled: false, alpha: 0.5)
            ring(7.3 * s, alpha: 0.3, dashed: true)
        case let .connecting(frame):
            centre(filled: true, alpha: 1)
            // Two pulses half a cycle apart, growing and fading out.
            for offset in [0, frames / 2] {
                let t = CGFloat((frame + offset) % frames) / CGFloat(frames)
                ring((3.2 + t * 4.4) * s, alpha: 1 - t)
            }
        case .connected:
            centre(filled: true)
            ring(5 * s, alpha: 0.65)
            ring(7.6 * s, alpha: 0.35)
        case .stale:
            centre(filled: false)
            ring(5 * s, alpha: 0.65)
            ring(7.6 * s, alpha: 0.35)
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(_ state: IconState) -> NSImage {
        let key = "\(state)"
        if let img = cache[key] { return img }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            draw(state, color: .black)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "WGTail"
        cache[key] = img
        return img
    }
}
