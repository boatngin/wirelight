import SwiftUI
import WGCore

/// Toolbox: other mesh VPNs, SSH port forwards and Wake-on-LAN, in one place.
struct ToolboxView: View {
    @ObservedObject private var box = Toolbox.shared
    @State private var editing: UUID?
    @State private var wakeResult: [UUID: String] = [:]
    @State private var meshError: String?
    @State private var newDevice = WakeDevice(name: "", mac: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toolbox").font(.title2.weight(.semibold))
                    Text("Things that sit next to your tunnels. Everything runs as you, with your own keys and apps.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                mesh
                forwards
                wake
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task { await box.refreshMesh() }
    }

    // MARK: Mesh

    private var mesh: some View {
        section("Mesh VPNs", icon: "circle.hexagongrid") {
            if box.mesh.isEmpty {
                Text("Tailscale and NetBird aren't installed. When they are, you can turn them on or off and pick an exit node here; Headscale networks work through the Tailscale client.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(box.mesh) { m in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(m.running ? Color.green : .secondary).frame(width: 8, height: 8)
                        Text(m.kind.title).font(.system(size: 13, weight: .semibold))
                        Text(m.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(get: { m.running }, set: { on in
                            Task { meshError = await box.meshAction(m.kind, [on ? "up" : "down"]) }
                        }))
                        .toggleStyle(.switch).labelsHidden()
                    }
                    if !m.addresses.isEmpty {
                        Text(m.addresses.joined(separator: ", ")).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if m.kind == .tailscale && !m.exitNodes.isEmpty {
                        Picker("Exit node", selection: Binding(get: { m.exitNodes.first { $0.active }?.ip ?? "" }, set: { ip in
                            Task { meshError = await box.meshAction(.tailscale, ["set", "--exit-node=\(ip)"]) }
                        })) {
                            Text("None").tag("")
                            ForEach(m.exitNodes, id: \.ip) { Text($0.name).tag($0.ip) }
                        }
                        .frame(maxWidth: 320)
                    }
                }
                .padding(10)
                .card(radius: 10)
            }
            if let meshError { Text(meshError).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Refresh") { Task { await box.refreshMesh() } }.controlSize(.small) }
        }
    }

    // MARK: SSH

    private var forwards: some View {
        section("SSH port forwards", icon: "arrow.left.arrow.right") {
            Text("Uses your SSH keys and agent, never a password. Listens on 127.0.0.1 only, and reconnects on its own (2 s, doubling up to 1 min). Stops when Wirelight quits.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(box.forwards) { f in
                ForwardRow(forward: f, editing: editing == f.id) {
                    editing = editing == f.id ? nil : f.id
                }
            }
            Button {
                let f = SSHForward(name: "New forward")
                box.forwards.append(f)
                editing = f.id
            } label: { Label("Add forward", systemImage: "plus") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
    }

    // MARK: Wake-on-LAN

    private var wake: some View {
        section("Wake-on-LAN", icon: "power.circle") {
            ForEach(box.devices) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.system(size: 12, weight: .medium))
                        Text("\(d.mac) → \(d.broadcast)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        if let r = wakeResult[d.id] {
                            Text(r).font(.system(size: 10)).foregroundStyle(r.hasPrefix("Magic") ? .green : .red)
                        }
                    }
                    Spacer()
                    Button("Wake") { wakeResult[d.id] = box.wake(d) }.controlSize(.small)
                    Button { box.devices.removeAll { $0.id == d.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(8).card(radius: 8)
            }
            HStack(spacing: 6) {
                TextField("Name", text: $newDevice.name).frame(width: 120)
                TextField("MAC, e.g. aa:bb:cc:dd:ee:ff", text: $newDevice.mac)
                TextField("Broadcast", text: $newDevice.broadcast).frame(width: 130)
                Button("Add") {
                    box.devices.append(newDevice)
                    newDevice = WakeDevice(name: "", mac: "")
                }
                .disabled(newDevice.name.isEmpty || WakeOnLAN.packet(mac: newDevice.mac) == nil
                          || !Validation.isValidIPv4(newDevice.broadcast))
            }
            .textFieldStyle(.roundedBorder)
            Text("Reaches the local network only (or a remote LAN through a tunnel that routes its broadcast address).")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func section<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct ForwardRow: View {
    @ObservedObject private var box = Toolbox.shared
    let forward: SSHForward
    let editing: Bool
    let toggleEdit: () -> Void
    @State private var draft: SSHForward?

    private var st: Toolbox.ForwardState? { box.state[forward.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(st?.running == true ? Color.green : (st?.error != nil ? .orange : .secondary)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(forward.name).font(.system(size: 12, weight: .medium))
                    Text(describe(forward)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    if let err = st?.error {
                        let retry = st?.retryAt.map { " · retrying \(Format.relative($0).replacingOccurrences(of: " ago", with: ""))" } ?? ""
                        Text(err + retry).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                Spacer()
                Button(editing ? "Done" : "Edit") {
                    if editing, let d = draft { box.update(d) }
                    draft = editing ? nil : forward
                    toggleEdit()
                }
                .controlSize(.small)
                Toggle("", isOn: Binding(get: { forward.enabled }, set: { box.setEnabled($0, forward) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(forward.validationError() != nil)
            }
            if editing, draft != nil { editor }
        }
        .padding(8)
        .card(radius: 8)
    }

    private var editor: some View {
        let d = Binding(get: { draft ?? forward }, set: { draft = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: d.name)
                Picker("", selection: d.kind) {
                    Text("Local -L").tag(SSHForward.Kind.local)
                    Text("Remote -R").tag(SSHForward.Kind.remote)
                    Text("SOCKS5 -D").tag(SSHForward.Kind.socks)
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                TextField("Server: user@host or ssh alias", text: d.server)
                TextField("SSH port", value: d.sshPort, format: .number.grouping(.never)).frame(width: 80)
            }
            HStack {
                TextField("Listen port", value: d.listenPort, format: .number.grouping(.never)).frame(width: 100)
                if d.wrappedValue.kind != .socks {
                    Text("→").foregroundStyle(.secondary)
                    TextField("Target host", text: d.targetHost)
                    TextField("Port", value: d.targetPort, format: .number.grouping(.never)).frame(width: 70)
                }
            }
            HStack {
                if let err = d.wrappedValue.validationError() {
                    Text(err).font(.system(size: 10)).foregroundStyle(.red)
                }
                Spacer()
                Button("Delete", role: .destructive) { box.remove(forward) }.controlSize(.small)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
    }

    private func describe(_ f: SSHForward) -> String {
        switch f.kind {
        case .local: return "localhost:\(f.listenPort) → \(f.server) → \(f.targetHost):\(f.targetPort)"
        case .remote: return "\(f.server):\(f.listenPort) → this Mac → \(f.targetHost):\(f.targetPort)"
        case .socks: return "SOCKS5 localhost:\(f.listenPort) → \(f.server)"
        }
    }
}
