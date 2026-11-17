import AppKit
import SwiftUI

/// A black pill that grows out of the right edge of the notch: a status dot, how
/// many tunnels are up and the combined download rate. Hovering drops a small
/// list of each tunnel. Read-only; off by default.
@MainActor
final class NotchPill {
    static let shared = NotchPill()
    static let enabledKey = "notchPill"

    private var panel: NSPanel?
    private var store: TunnelStore?
    private var screenObserver: NSObjectProtocol?
    private static let collapsedWidth: CGFloat = 170
    private static let expandedWidth: CGFloat = 300

    func update(enabled: Bool, store: TunnelStore) {
        self.store = store
        hide()
        guard enabled else { return }
        show()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                self.update(enabled: true, store: store)
            }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
    }

    /// The first screen with a notch, its menu bar height, and the notch's right edge.
    private func anchor() -> (screen: NSScreen, height: CGFloat, x: CGFloat)? {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let right = s.auxiliaryTopRightArea else { return nil }
        return (s, s.safeAreaInsets.top, right.minX)
    }

    private func show() {
        guard let store, let a = anchor() else { return }
        let p = NSPanel(contentRect: frame(expanded: false, a), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: NotchPillView(barHeight: a.height) { [weak self] expanded in
            self?.resize(expanded: expanded)
        }.environmentObject(store))
        p.orderFrontRegardless()
        panel = p
    }

    private func frame(expanded: Bool, _ a: (screen: NSScreen, height: CGFloat, x: CGFloat)) -> NSRect {
        // One 20 pt row per tunnel (at least one for the empty message) under the bar.
        let rows = CGFloat(max(1, store?.activeNames.count ?? 0))
        let size = expanded ? NSSize(width: Self.expandedWidth, height: a.height + rows * 20 + 18)
                            : NSSize(width: Self.collapsedWidth, height: a.height)
        // Overlap the notch slightly so the pill reads as part of it.
        return NSRect(x: a.x - 14, y: a.screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func resize(expanded: Bool) {
        guard let panel, let a = anchor() else { return }
        panel.setFrame(frame(expanded: expanded, a), display: true, animate: false)
    }
}

struct NotchPillView: View {
    @EnvironmentObject var store: TunnelStore
    let barHeight: CGFloat
    let onExpand: (Bool) -> Void
    @State private var expanded = false

    private var color: Color {
        guard store.isConnected else { return .gray }
        return store.activeNames.contains { store.isSilent($0) || store.isStale($0) } ? .orange : .green
    }

    private var downRate: Double { store.activeNames.compactMap { store.samples($0).last?.rx }.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.8), radius: store.isConnected ? 3 : 0)
                Text(store.isConnected ? "\(store.activeNames.count)" : "off")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                if store.isConnected {
                    Text("↓ \(Format.rate(downRate))")
                        .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20).padding(.trailing, 8)
            .frame(height: barHeight)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if store.activeNames.isEmpty {
                        Text("No tunnels connected").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    ForEach(store.activeNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Circle().fill(StatusStyle.color(store, name)).frame(width: 6, height: 6)
                            Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).layoutPriority(1)
                            Spacer()
                            if let q = store.qualitySummary(name), let m = q.median {
                                Text("\(Int(m)) ms").font(.system(size: 9)).foregroundStyle(q.grade.color)
                            }
                            let s = store.samples(name).last
                            Text("↓\(Format.rate(s?.rx ?? 0)) ↑\(Format.rate(s?.tx ?? 0))")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 4)
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(UnevenRoundedCorners(bottom: expanded ? 14 : barHeight / 2).fill(Color.black))
        .onHover { h in
            expanded = h
            onExpand(h)
        }
    }
}

/// Square top (flush with the screen edge), rounded bottom, like the notch itself.
private struct UnevenRoundedCorners: Shape {
    let bottom: CGFloat

    func path(in r: CGRect) -> Path {
        let b = min(bottom, r.height / 2, r.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.maxX - b, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - b), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
