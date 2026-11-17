import SwiftUI

/// One thing that needs attention on a tunnel, with what to do about it.
struct HealthNotice: Identifiable {
    enum Fix { case retry, blockIPv6, reconnect, dismiss }
    let tunnel: String
    let icon: String
    let color: Color
    let title: String
    let detail: String
    let fix: Fix?
    var id: String { tunnel + title }

    var fixTitle: String {
        switch fix {
        case .retry: return "Retry"
        case .blockIPv6: return "Block IPv6"
        case .reconnect: return "Reconnect"
        case .dismiss, nil: return "Dismiss"
        }
    }
}

extension TunnelStore {
    /// Problems for one tunnel, most serious first.
    func notices(for name: String) -> [HealthNotice] {
        var out: [HealthNotice] = []
        if let err = failures[name] {
            out.append(HealthNotice(tunnel: name, icon: "xmark.octagon.fill", color: .red,
                                    title: lost.contains(name) ? "Couldn't reconnect" : "Couldn't connect",
                                    detail: err, fix: .retry))
        } else if lost.contains(name), !isActive(name) {
            out.append(HealthNotice(tunnel: name, icon: "bolt.horizontal.circle", color: .orange,
                                    title: "Connection lost", detail: "It went down on its own. Reconnecting…", fix: .dismiss))
        }
        if isSilent(name) {
            out.append(HealthNotice(tunnel: name, icon: "speaker.slash.fill", color: .red, title: "No answer from server",
                                    detail: "Packets go out but nothing comes back. Check the endpoint, the server's port forwarding and firewall, and that the server has this Mac's public key.",
                                    fix: .reconnect))
        } else if isStale(name) {
            out.append(HealthNotice(tunnel: name, icon: "hand.raised.slash", color: .orange, title: "Handshake is stale",
                                    detail: "No handshake for over 3 minutes. Wirelight re-resolves the server's address every 2 minutes in case it changed.",
                                    fix: .reconnect))
        }
        if let q = qualitySummary(name), q.grade == .poor {
            let what = q.median.map { String(format: "typical %.0f ms", $0) } ?? "no replies"
            out.append(HealthNotice(tunnel: name, icon: "waveform.path.ecg", color: .orange, title: "Link quality is poor",
                                    detail: "Measured \(what), \(String(format: "%.1f", q.loss))% loss to \(probeHost(name) ?? "the target"). This is a measurement, not a cause: the server, Wi-Fi or ISP can all be the reason.",
                                    fix: nil))
        }
        if isActive(name), leaksIPv6(name) {
            out.append(HealthNotice(tunnel: name, icon: "drop.triangle.fill", color: .orange, title: "IPv6 bypasses the tunnel",
                                    detail: "This tunnel takes all IPv4 but not IPv6, and your network has IPv6. Block IPv6 while it's connected, or add ::/0 if the server supports IPv6.",
                                    fix: .blockIPv6))
        }
        return out
    }

    func perform(_ n: HealthNotice) async {
        switch n.fix {
        case .retry: dismissFailure(n.tunnel); await connect(n.tunnel)
        case .reconnect: await reconnectIfActive(n.tunnel)
        case .blockIPv6: await setBlockIPv6(true, for: n.tunnel)
        case .dismiss, nil: dismissFailure(n.tunnel)
        }
    }
}

/// "Heads-up" rows: icon, what happened, what to do, and a one-click fix.
struct HealthStrip: View {
    @EnvironmentObject var store: TunnelStore
    let names: [String]
    var compact = false

    var body: some View {
        let notices = names.flatMap { store.notices(for: $0) }
        if !notices.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(notices.enumerated()), id: \.element.id) { i, n in
                    if i > 0 { Divider().padding(.leading, compact ? 30 : 36) }
                    row(n)
                }
            }
            .card(tint: notices[0].color, radius: compact ? 10 : 12)
        }
    }

    private func row(_ n: HealthNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.icon).foregroundStyle(n.color).font(.system(size: compact ? 12 : 14))
                .frame(width: compact ? 14 : 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(names.count > 1 ? "\(n.tunnel): \(n.title)" : n.title)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                Text(n.detail).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: !compact)
            }
            Spacer(minLength: 4)
            if n.fix != nil {
                Button(n.fixTitle) { Task { await store.perform(n) } }
                    .controlSize(.small)
                    .disabled(store.isBusy(n.tunnel))
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 7 : 10)
    }
}
