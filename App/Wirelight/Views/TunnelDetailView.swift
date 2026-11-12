import AppKit
import Charts
import SwiftUI
import WGCore

/// Dashboard for one tunnel. Same visual language as the menu bar dropdown:
/// ping hero, stat tiles, traffic card, then compact info and options cards.
struct TunnelDetailView: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow
    let profile: TunnelProfile

    @State private var testResult: String?
    @State private var testing = false
    @State private var showAdvanced = false
    @State private var copiedField: String?

    private var isActive: Bool { store.active?.name == profile.name }
    private var config: WGConfig? { store.config(profile.name) }
    private var peer: PeerStatus? { isActive ? store.active?.peers.first : nil }
    private var accent: Color { StatusStyle.color(connected: isActive, stale: store.isHandshakeStale) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                hero
                if let err = store.lastError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isActive {
                    stats
                    traffic
                }
                connectionCard
                optionsCard
                actions
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 14) {
            PingBadge(color: accent, animating: isActive || (store.busy && store.currentProfile?.name == profile.name),
                      fast: store.busy)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.system(size: 20, weight: .semibold))
                    if profile.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow) }
                }
                HStack(spacing: 5) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(isActive ? accent : .secondary)
                }
                .font(.system(size: 12, weight: .medium))
                Text(profile.endpoint ?? "no endpoint")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect() } }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(store.busy || !store.helperReachable)
        }
        .padding(16)
        .card(tint: isActive ? accent : nil, radius: 14)
    }

    private var statusText: String {
        if !store.helperReachable { return "Helper not running" }
        if store.busy { return "Working…" }
        if isActive { return store.isHandshakeStale ? "Connected · no recent handshake" : "Connected" }
        return "Disconnected"
    }

    // MARK: Live

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
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

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Traffic · last 60s").font(.system(size: 12, weight: .semibold))
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
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(rate(d)).font(.system(size: 9, design: .monospaced)) } }
                }
            }
            .frame(height: 110)
            .overlay {
                if store.samples.count < 2 { Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .card()
    }

    // MARK: Info

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Connection", icon: "point.3.connected.trianglepath.dotted")
            infoRow("Address", config?.interface.addresses.joined(separator: ", ") ?? "-", copy: true)
            infoRow("Interface", isActive ? (store.active?.interface ?? "-") : "-")
            infoRow("Allowed IPs", allowedIPs)
            infoRow("DNS", dns)
            infoRow("Peer key", config?.peers.first?.publicKey ?? "-", copy: true, last: true)
        }
        .card()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Options", icon: "slider.horizontal.3")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route all traffic").font(.system(size: 13))
                    Text("Send everything through this tunnel").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { profile.routeAll },
                                         set: { on in Task { await store.setRouteAll(on, for: profile.name) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(store.busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On demand").font(.system(size: 13))
                    Text("Connect on untrusted Wi-Fi, disconnect on trusted networks. Reads the Wi-Fi name, which needs Location permission.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { profile.onDemand },
                                         set: { on in Task { await store.setOnDemand(on, for: profile.name) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced").font(.system(size: 13))
                    if !profile.splitDNSDomains.isEmpty || !profile.excludedCIDRs.isEmpty || !profile.trustedSSIDs.isEmpty {
                        Text("\(profile.splitDNSDomains.count + profile.excludedCIDRs.count + profile.trustedSSIDs.count) rules")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    advancedBlock(title: "Split DNS",
                                  hint: "Use this tunnel's DNS only for these domains. Others keep your normal DNS.") {
                        EditableList(items: profile.splitDNSDomains, placeholder: "Domain, e.g. lan",
                                     icon: "network", validate: Validation.isValidHostname) { list in
                            Task { await store.setSplitDNS(list, for: profile.name) }
                        }
                    }
                    advancedBlock(title: "Exclusions",
                                  hint: "These ranges skip the tunnel and use your normal connection.") {
                        EditableList(items: profile.excludedCIDRs, placeholder: "CIDR, e.g. 10.0.5.0/24",
                                     icon: "arrow.triangle.branch", validate: Validation.isValidCIDR) { list in
                            Task { await store.setExclusions(list, for: profile.name) }
                        }
                    }
                    if profile.onDemand {
                        advancedBlock(title: "Trusted Wi-Fi networks",
                                      hint: "On these networks the tunnel disconnects; on any other Wi-Fi it connects. Names are case-sensitive. On Ethernet the tunnel is left as is. Reading the Wi-Fi name needs Location permission — it is only used on this Mac.") {
                            EditableList(items: profile.trustedSSIDs, placeholder: "SSID, e.g. HomeWiFi",
                                         icon: "wifi", lowercase: false, validate: Validation.isValidSSID) { list in
                                Task { await store.setTrustedSSIDs(list, for: profile.name) }
                            }
                        }
                    }
                    Text("Changes reconnect the tunnel if it's active.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .card()
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isActive {
                    PillButton(icon: "waveform.path.ecg", title: testing ? "Testing…" : "Test", tint: .accentColor) {
                        guard !testing else { return }
                        testing = true
                        Task { testResult = await store.testConnection(profile.name); testing = false }
                    }
                }
                PillButton(icon: profile.favorite ? "star.fill" : "star",
                           title: profile.favorite ? "Unfavorite" : "Favorite") { store.toggleFavorite(profile.name) }
                PillButton(icon: "pencil", title: "Edit") { store.mainSection = .settings }
                PillButton(icon: "square.and.arrow.up", title: "Export") { exportConfig() }
                PillButton(icon: "plus.square.on.square", title: "Duplicate") { store.duplicate(profile.name) }
                Spacer()
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(testResult.contains("avg") ? Color.green : .orange)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Pieces

    private func cardTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }

    private func infoRow(_ label: String, _ value: String, copy: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if copy && value != "-" {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        copiedField = label
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedField == label { copiedField = nil } }
                    } label: {
                        Image(systemName: copiedField == label ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedField == label ? Color.green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if !last { Divider().padding(.leading, 14) }
        }
        .padding(.bottom, last ? 4 : 0)
    }

    private func advancedBlock<C: View>(title: String, hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var allowedIPs: String {
        if profile.routeAll { return "0.0.0.0/0, ::/0" }
        let ips = config?.peers.flatMap(\.allowedIPs) ?? []
        return ips.isEmpty ? "-" : ips.joined(separator: ", ")
    }

    private var dns: String {
        let all = (config?.interface.dns ?? []) + (config?.interface.dnsSearch ?? [])
        return all.isEmpty ? "-" : all.joined(separator: ", ")
    }

    private func rate(_ bps: Double) -> String { Format.rate(bps) }

    private func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// Saves the full config (including the private key) to a file the user picks.
    private func exportConfig() {
        guard let text = store.configText(profile.name) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).conf"
        panel.message = "The exported file contains your private key. Keep it safe."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            store.addLog("Exported \(profile.name) to \(url.path)")
        } catch {
            store.addLog("Export failed: \(error.localizedDescription)", isError: true)
        }
    }
}

/// Tiny combined rx+tx sparkline used in the tunnel list.
struct Sparkline: View {
    let samples: [TrafficSample]
    var color: Color = .green

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
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
