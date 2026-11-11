import AppKit
import Charts
import SwiftUI
import WGCore

struct TunnelDetailView: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow
    let profile: TunnelProfile

    private var isActive: Bool { store.active?.name == profile.name }
    private var config: WGConfig? { store.config(profile.name) }
    private var peer: PeerStatus? { isActive ? store.active?.peers.first : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 16)

                section("Interface") {
                    row("Interface", isActive ? (store.active?.interface ?? "-") : "-")
                    row("Address", config?.interface.addresses.joined(separator: "\n") ?? "-", mono: true)
                    row("Endpoint", profile.endpoint ?? "-", mono: true)
                    row("Allowed IPs", allowedIPs, mono: true)
                    row("DNS", dns, mono: true)
                    row("Peer key", config?.peers.first?.publicKey ?? "-", mono: true)
                }

                if isActive {
                    Divider().padding(.vertical, 16)
                    section("Status") {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            VStack(alignment: .leading, spacing: 8) {
                                row("Connected for", store.connectedSince.map { duration(ctx.date.timeIntervalSince($0)) } ?? "-")
                                row("Last handshake", peer?.latestHandshake.map { Format.relative($0, now: ctx.date) } ?? "never",
                                    warn: store.isHandshakeStale || peer?.latestHandshake == nil)
                            }
                        }
                        row("Received", Format.bytes(peer?.rxBytes ?? 0))
                        row("Sent", Format.bytes(peer?.txBytes ?? 0))
                    }

                    Divider().padding(.vertical, 16)
                    section("Traffic (last 60s)") {
                        TrafficChart(title: "Received", total: peer?.rxBytes ?? 0, color: .green,
                                     icon: "arrow.down.circle.fill", samples: store.samples, value: \.rx)
                        TrafficChart(title: "Sent", total: peer?.txBytes ?? 0, color: .blue,
                                     icon: "arrow.up.circle.fill", samples: store.samples, value: \.tx)
                            .padding(.top, 12)
                    }
                }

                Divider().padding(.vertical, 16)
                section("Routing") {
                    Toggle(isOn: Binding(
                        get: { profile.routeAll },
                        set: { on in Task { await store.setRouteAll(on, for: profile.name) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Route all traffic")
                            Text("Send everything through this tunnel (0.0.0.0/0, ::/0). Reconnects if active.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(store.busy)
                }

                Divider().padding(.vertical, 16)
                section("Configuration") {
                    row("Stored in", "Keychain · com.thanaboat.wgbar")
                    row("Created", profile.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-")
                    row("Peers", "\(config?.peers.count ?? 0)")
                    HStack(spacing: 8) {
                        Button { store.toggleFavorite(profile.name) } label: {
                            Label(profile.favorite ? "Unfavorite" : "Favorite", systemImage: profile.favorite ? "star.fill" : "star")
                        }
                        Button { openWindow(id: "settings") } label: { Label("Edit", systemImage: "pencil") }
                        Button { copyPublicKey() } label: { Label("Copy peer key", systemImage: "doc.on.doc") }
                    }
                    .padding(.top, 6)
                }

                if let err = store.lastError {
                    Text(err).font(.callout).foregroundStyle(.red).padding(.top, 16)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((isActive ? Color.green : Color.secondary).opacity(0.15))
                Image(nsImage: MenuBarIcon.image(isActive ? (store.isHandshakeStale ? .stale : .connected) : .disconnected))
                    .renderingMode(.template)
                    .foregroundStyle(isActive ? Color.green : .secondary)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(isActive ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(statusText).foregroundStyle(isActive ? Color.green : .secondary)
                }
                .font(.system(size: 13, weight: .medium))
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect() } }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(store.busy || !store.helperReachable)
        }
    }

    private var statusText: String {
        if !store.helperReachable { return "Helper not running" }
        if store.busy { return "Working…" }
        if isActive { return store.isHandshakeStale ? "Connected · no recent handshake" : "Connected" }
        return "Disconnected"
    }

    // MARK: Helpers

    private var allowedIPs: String {
        if profile.routeAll { return "0.0.0.0/0\n::/0" }
        let ips = config?.peers.flatMap(\.allowedIPs) ?? []
        return ips.isEmpty ? "-" : ips.joined(separator: "\n")
    }

    private var dns: String {
        let all = (config?.interface.dns ?? []) + (config?.interface.dnsSearch ?? [])
        return all.isEmpty ? "-" : all.joined(separator: ", ")
    }

    private func copyPublicKey() {
        guard let key = config?.peers.first?.publicKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    private func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.bottom, 4)
            content()
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .foregroundStyle(warn ? Color.orange : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
    }
}

// MARK: - Charts

struct TrafficChart: View {
    let title: String
    let total: UInt64
    let color: Color
    let icon: String
    let samples: [TrafficSample]
    let value: KeyPath<TrafficSample, Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text("\(rate(samples.last?[keyPath: value] ?? 0))").foregroundStyle(color).monospacedDigit()
                Spacer()
                Text("Total \(title.lowercased()): \(Format.bytes(total))").foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            Chart(samples) { s in
                AreaMark(x: .value("Time", s.date), y: .value(title, s[keyPath: value]))
                    .foregroundStyle(color.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.date), y: .value(title, s[keyPath: value]))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: Date().addingTimeInterval(-60)...Date())
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(rate(d)).font(.system(size: 10, design: .monospaced)) } }
                }
            }
            .frame(height: 90)
        }
    }

    private func rate(_ bps: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .binary))/s"
    }
}

/// Tiny combined rx+tx sparkline used in the tunnel list.
struct Sparkline: View {
    let samples: [TrafficSample]

    var body: some View {
        GeometryReader { geo in
            let values = samples.suffix(30).map { $0.rx + $0.tx }
            let maxV = max(values.max() ?? 1, 1)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / maxV)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                if values.count < 2 {
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                }
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
