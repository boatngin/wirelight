import SwiftUI
import WGCore

/// Tunnels an administrator made available to every user on this Mac.
struct SharedView: View {
    @EnvironmentObject var store: TunnelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared").font(.title2.weight(.semibold))
                    Text(TunnelStore.isAdminUser
                         ? "Tunnels you share are kept by the helper, readable only by root. Other users can use them as you allow, but never see the keys."
                         : "Tunnels an administrator shared with everyone on this Mac. Their keys stay with the system.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.shared.isEmpty {
                    Text(TunnelStore.isAdminUser ? "Nothing shared yet. Open a tunnel and choose Share." : "Nothing is shared on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                ForEach(store.shared) { SharedRow(info: $0) }
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task { await store.refreshShared() }
    }
}

private struct SharedRow: View {
    @EnvironmentObject var store: TunnelStore
    let info: SharedTunnelInfo

    private var up: Bool { store.isActive(info.name) }
    private var admin: Bool { TunnelStore.isAdminUser }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill").foregroundStyle(up ? .green : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.system(size: 13, weight: .semibold))
                    Text([info.endpoint, info.addresses.first].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if let err = store.failures[info.name] {
                        Text(err).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { up }, set: { on in
                    Task { on ? await store.connectShared(info.name) : await store.disconnectShared(info.name) }
                }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(store.isBusy(info.name) || !store.helperReachable
                          || (!admin && (up ? !info.policy.usersCanDisconnect : !info.policy.usersCanConnect)))
            }
            if admin {
                HStack(spacing: 14) {
                    Toggle("Others can connect", isOn: policy(\.usersCanConnect))
                    Toggle("Others can disconnect", isOn: policy(\.usersCanDisconnect))
                    Spacer()
                    Button("Stop sharing", role: .destructive) { Task { await store.unshare(info.name) } }
                        .controlSize(.small)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                if store.profile(info.name) == nil {
                    Text("Shared from another account; its config changes when they share it again.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(rights).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .card(tint: up ? .green : nil)
    }

    private var rights: String {
        switch (info.policy.usersCanConnect, info.policy.usersCanDisconnect) {
        case (true, true): return "You can connect and disconnect it."
        case (true, false): return "You can connect it; only an administrator can disconnect it."
        case (false, true): return "You can disconnect it; only an administrator can connect it."
        case (false, false): return "Only an administrator can turn it on or off."
        }
    }

    private func policy(_ key: WritableKeyPath<SharePolicy, Bool>) -> Binding<Bool> {
        Binding(get: { info.policy[keyPath: key] }, set: { v in
            var p = info.policy
            p[keyPath: key] = v
            Task { await store.setSharePolicy(info.name, p) }
        })
    }
}
