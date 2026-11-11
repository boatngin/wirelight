import AppKit
import Charts
import SwiftUI
import WGCore

/// The menu bar dropdown: a compact live dashboard.
struct MenuView: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    private var connected: Bool { store.isConnected }
    private var peer: PeerStatus? { store.active?.peers.first }

    var body: some View {
        VStack(spacing: 12) {
            if !store.helperReachable { helperBanner }
            hero
            if let err = store.lastError {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if connected {
                statsGrid
                trafficCard
                addressRow
            }
            tunnelsCard
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { store.menuOpen = true }
        .onDisappear { store.menuOpen = false }
    }

    // MARK: Hero

    private var accent: Color {
        if !connected { return .secondary }
        return store.isHandshakeStale ? .orange : .green
    }

    private var hero: some View {
        HStack(spacing: 14) {
            PingBadge(color: accent, animating: connected || store.busy, fast: store.busy)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.active?.name ?? store.currentProfile?.name ?? "WGTail")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(connected ? accent : .secondary)
                }
                .font(.system(size: 12, weight: .medium))
                if let ep = store.currentProfile?.endpoint {
                    Text(ep).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: connectedBinding)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(store.busy || !store.helperReachable || store.profiles.isEmpty)
        }
        .padding(14)
        .background(card(tint: connected ? accent : nil))
    }

    private var statusText: String {
        if store.busy { return connected ? "Disconnecting…" : "Connecting…" }
        if connected { return store.isHandshakeStale ? "Connected · no recent handshake" : "Connected" }
        return "Disconnected"
    }

    private var connectedBinding: Binding<Bool> {
        Binding(get: { store.isConnected }, set: { on in
            Task {
                if on, let name = store.currentProfile?.name { await store.connect(name) }
                else if !on { await store.disconnect() }
            }
        })
    }

    // MARK: Stats

    private var statsGrid: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                StatTile(icon: "arrow.down", tint: .green, title: "Download",
                         value: rate(store.samples.last?.rx ?? 0), sub: "Total \(Format.bytes(peer?.rxBytes ?? 0))")
                StatTile(icon: "arrow.up", tint: .blue, title: "Upload",
                         value: rate(store.samples.last?.tx ?? 0), sub: "Total \(Format.bytes(peer?.txBytes ?? 0))")
                StatTile(icon: "hand.wave", tint: store.isHandshakeStale ? .orange : .purple, title: "Handshake",
                         value: peer?.latestHandshake.map { Format.relative($0, now: ctx.date) } ?? "never",
                         sub: store.isHandshakeStale ? "Stale" : "Healthy")
                StatTile(icon: "clock", tint: .teal, title: "Uptime",
                         value: store.connectedSince.map { duration(ctx.date.timeIntervalSince($0)) } ?? "-",
                         sub: store.active?.interface ?? "")
            }
        }
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Traffic").font(.system(size: 12, weight: .semibold))
                Spacer()
                legend(.green, "Down")
                legend(.blue, "Up")
            }
            Chart {
                ForEach(store.samples) { s in
                    AreaMark(x: .value("t", s.date), y: .value("down", s.rx), series: .value("s", "down"))
                        .foregroundStyle(Color.green.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", s.date), y: .value("down", s.rx), series: .value("s", "down"))
                        .foregroundStyle(Color.green)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", s.date), y: .value("up", s.tx), series: .value("s", "up"))
                        .foregroundStyle(Color.blue)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: Date().addingTimeInterval(-60)...Date())
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 64)
            .overlay {
                if store.samples.count < 2 {
                    Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(card())
    }

    private var addressRow: some View {
        HStack(spacing: 10) {
            if let addr = store.activeProfile?.addresses.first.map(Format.ip) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(addr, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        Text(addr).font(.system(size: 12, design: .monospaced))
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10)).foregroundStyle(copied ? Color.green : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy IP address")
            }
            Spacer()
            if let p = store.activeProfile {
                Text("Route all").font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { p.routeAll },
                                         set: { on in Task { await store.setRouteAll(on, for: p.name) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(store.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(card())
    }

    // MARK: Tunnels

    private var tunnelsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tunnels").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 4).padding(.bottom, 2)
            if store.profiles.isEmpty {
                Button { open("import") } label: {
                    Label("Import your first config", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(8)
            }
            ForEach(store.profiles) { p in
                TunnelRow(profile: p, isActive: store.active?.name == p.name, busy: store.busy) {
                    Task { await store.connect(p.name) }
                }
            }
        }
        .padding(8)
        .background(card())
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(icon: "rectangle.grid.2x2", title: "Dashboard") { open("main") }
            FooterButton(icon: "plus", title: "Import") { open("import") }
            FooterButton(icon: "gearshape", title: "Settings") { open("settings") }
            FooterButton(icon: "power", title: "Quit") { NSApp.terminate(nil) }
        }
    }

    private var helperBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Helper not running").font(.system(size: 12, weight: .semibold))
                Text("Run ./scripts/install-helper.sh in the project folder, then reopen this menu.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow))
    }

    // MARK: Helpers

    private func card(tint: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(tint.map { $0.opacity(0.10) } ?? Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.25), lineWidth: 0.5))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func rate(_ bps: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .binary))/s"
    }

    private func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Components

/// Large animated version of the menu bar "ping" mark.
struct PingBadge: View {
    let color: Color
    let animating: Bool
    var fast = false

    var body: some View {
        TimelineView(.animation(paused: !animating)) { ctx in
            let period = fast ? 1.0 : 2.4
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            ZStack {
                Circle().fill(color.opacity(0.12))
                if animating {
                    ForEach(0..<2, id: \.self) { i in
                        let p = (t + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(color.opacity(1 - p), lineWidth: 1.5)
                            .scaleEffect(0.35 + p * 0.6)
                    }
                } else {
                    Circle().strokeBorder(color.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .padding(6)
                }
                Circle()
                    .fill(animating ? color : Color.clear)
                    .overlay(Circle().stroke(color, lineWidth: animating ? 0 : 1.5))
                    .frame(width: 14, height: 14)
            }
        }
    }
}

struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(tint.opacity(0.15)))
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)))
    }
}

private struct FooterButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hovering ? 0.10 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
