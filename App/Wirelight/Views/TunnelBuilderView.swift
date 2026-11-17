import AppKit
import SwiftUI
import WGCore

/// Editable shape of a config for the form view. Strings so half-typed values survive.
struct ConfigDraft: Equatable {
    struct Peer: Equatable, Identifiable {
        var id = UUID()
        var publicKey = ""
        var presharedKey = ""
        var endpoint = ""
        var allowedIPs = ""
        var keepalive = "25"
    }
    var privateKey = WGKey.generatePrivate()
    var addresses = ""
    var dnsServers = ""
    var searchDomains = ""
    var mtu = ""
    var listenPort = ""
    var peers = [Peer()]

    init() {}

    init(_ c: WGConfig) {
        privateKey = c.interface.privateKey
        addresses = c.interface.addresses.joined(separator: ", ")
        dnsServers = c.interface.dns.joined(separator: ", ")
        searchDomains = c.interface.dnsSearch.joined(separator: ", ")
        mtu = c.interface.mtu.map(String.init) ?? ""
        listenPort = c.interface.listenPort.map(String.init) ?? ""
        peers = c.peers.map {
            Peer(publicKey: $0.publicKey, presharedKey: $0.presharedKey ?? "", endpoint: $0.endpoint ?? "",
                 allowedIPs: $0.allowedIPs.joined(separator: ", "),
                 keepalive: $0.persistentKeepalive.map(String.init) ?? "")
        }
    }

    func render() -> String {
        func line(_ k: String, _ v: String) -> String? {
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : "\(k) = \(t)"
        }
        let dns = [dnsServers, searchDomains].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        var out = ["[Interface]"] + [line("PrivateKey", privateKey), line("Address", addresses), line("DNS", dns),
                                     line("MTU", mtu), line("ListenPort", listenPort)].compactMap { $0 }
        for p in peers {
            out += ["", "[Peer]"] + [line("PublicKey", p.publicKey), line("PresharedKey", p.presharedKey),
                                     line("Endpoint", p.endpoint), line("AllowedIPs", p.allowedIPs),
                                     line("PersistentKeepalive", p.keepalive)].compactMap { $0 }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// Starting points for a new tunnel. The private key is always fresh.
enum BuilderTemplate: String, CaseIterable, Identifiable {
    case everything, homeLAN, subnet, blank
    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .homeLAN: return "Home network"
        case .subnet: return "One subnet"
        case .blank: return "Blank"
        }
    }

    var subtitle: String {
        switch self {
        case .everything: return "All traffic and DNS through the server"
        case .homeLAN: return "Reach your LAN while away"
        case .subnet: return "Only a work or lab range"
        case .blank: return "Fill everything in yourself"
        }
    }

    var icon: String {
        switch self {
        case .everything: return "globe"
        case .homeLAN: return "house"
        case .subnet: return "building.2"
        case .blank: return "square.dashed"
        }
    }

    func apply(to d: inout ConfigDraft) {
        d.privateKey = WGKey.generatePrivate()
        var p = ConfigDraft.Peer()
        switch self {
        case .everything:
            d.addresses = "10.66.0.2/32"; d.dnsServers = "10.66.0.1"
            p.allowedIPs = "0.0.0.0/0, ::/0"; p.endpoint = "vpn.example.com:51820"
        case .homeLAN:
            d.addresses = "10.8.0.2/32"; d.dnsServers = "192.168.1.1"; d.searchDomains = "lan"
            p.allowedIPs = "10.8.0.0/24, 192.168.1.0/24"; p.endpoint = "home.example.com:51820"
        case .subnet:
            d.addresses = "10.20.0.7/32"; d.dnsServers = ""
            p.allowedIPs = "10.20.0.0/16"; p.endpoint = "203.0.113.10:51820"
        case .blank:
            d.addresses = ""; d.dnsServers = ""; d.searchDomains = ""
            p.allowedIPs = ""; p.endpoint = ""
        }
        d.peers = [p]
    }
}

/// Create a tunnel from scratch or edit one: a form and the raw text, with live checks.
struct TunnelBuilderView: View {
    @EnvironmentObject var store: TunnelStore
    /// nil creates a new tunnel.
    let editing: String?

    enum Mode: String { case form = "Form", text = "Text" }
    @State private var mode = Mode.form
    @State private var draft = ConfigDraft()
    @State private var text = ""
    @State private var name = ""
    @State private var template: BuilderTemplate?
    @State private var error: String?
    @State private var saved = false

    private var currentText: String { mode == .form ? draft.render() : text }
    private var issues: [ConfigIssue] { ConfigLint.check(currentText) }
    private var nameError: String? {
        if !Validation.isValidTunnelName(name) { return name.isEmpty ? nil : StoreError.invalidName.description }
        if name != editing, store.profile(name) != nil { return StoreError.duplicateName(name).description }
        return nil
    }
    private var canSave: Bool {
        Validation.isValidTunnelName(name) && nameError == nil && !issues.contains { $0.severity == .error }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if editing == nil { templates }
                nameField
                if mode == .form { form } else { textEditor }
                ChecksList(issues: issues, cleanText: "Looks good. Valid syntax isn't a connection test; connect to try it.")
                footer
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: load)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(editing.map { "Edit \($0)" } ?? "New tunnel").font(.title2.weight(.semibold))
                Text(editing == nil ? "Start from a template, or paste a config in Text."
                                    : "Changes reconnect the tunnel if it's on.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { mode }, set: switchMode)) {
                Text("Form").tag(Mode.form)
                Text("Text").tag(Mode.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private var templates: some View {
        HStack(spacing: 8) {
            ForEach(BuilderTemplate.allCases) { t in
                Button {
                    template = t
                    t.apply(to: &draft)
                    if mode == .text { text = draft.render() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 15)).foregroundStyle(Color.accentColor)
                        Text(t.title).font(.system(size: 12, weight: .semibold))
                        Text(t.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .padding(10)
                    .card(tint: template == t ? .accentColor : nil, radius: 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Name").frame(width: 90, alignment: .leading)
                TextField("home", text: $name).textFieldStyle(.roundedBorder)
            }
            if let nameError { Text(nameError).font(.caption).foregroundStyle(.red).padding(.leading, 98) }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 12) {
            section("This Mac", icon: "laptopcomputer") {
                keyRow
                field("Address", "10.0.0.2/32, fd00::2/128", $draft.addresses)
                field("DNS servers", "10.0.0.1", $draft.dnsServers)
                field("Search domains", "lan, corp.example", $draft.searchDomains)
                HStack(spacing: 12) {
                    field("MTU", "1420", $draft.mtu)
                    field("Listen port", "auto", $draft.listenPort, labelWidth: 80)
                }
            }
            ForEach($draft.peers) { $peer in
                section(draft.peers.count > 1 ? "Server \(index(of: peer) + 1)" : "Server", icon: "server.rack",
                        trailing: draft.peers.count > 1 ? AnyView(Button(role: .destructive) {
                            draft.peers.removeAll { $0.id == peer.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.red)) : nil) {
                    field("Public key", "server's public key", $peer.publicKey, mono: true)
                    field("Endpoint", "vpn.example.com:51820", $peer.endpoint)
                    field("Allowed IPs", "0.0.0.0/0, ::/0", $peer.allowedIPs)
                    HStack(spacing: 6) {
                        field("Preshared key", "optional", $peer.presharedKey, mono: true)
                        Button("Generate") { peer.presharedKey = WGKey.generatePreshared() }.controlSize(.small)
                    }
                    field("Keepalive", "seconds, e.g. 25", $peer.keepalive)
                }
            }
            HStack {
                Button { draft.peers.append(ConfigDraft.Peer()) } label: { Label("Add server", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Spacer()
            }
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Private key").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SecureField("", text: $draft.privateKey).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                Button("New key") { draft.privateKey = WGKey.generatePrivate() }
                    .controlSize(.small)
                    .help("Make a new key pair. The server needs the new public key.")
            }
            HStack(spacing: 6) {
                Text("Public key").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                let pub = WGKey.publicKey(fromPrivate: draft.privateKey) ?? "—"
                Text(pub).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pub, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy, then add it to the server")
                Spacer()
            }
        }
    }

    private func index(of p: ConfigDraft.Peer) -> Int { draft.peers.firstIndex { $0.id == p.id } ?? 0 }

    private func section<C: View>(_ title: String, icon: String, trailing: AnyView? = nil,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content()
        }
        .padding(14)
        .card()
    }

    private func field(_ label: String, _ placeholder: String, _ value: Binding<String>,
                       mono: Bool = false, labelWidth: CGFloat = 110) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
        }
    }

    // MARK: Text

    private var textEditor: some View {
        HStack(alignment: .top, spacing: 0) {
            // Line numbers, so the checks below are easy to find.
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").indices), id: \.self) { i in
                    Text("\(i + 1)")
                        .foregroundStyle(issues.contains { $0.line == i + 1 && $0.severity == .error } ? Color.red : .secondary)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.top, 8).padding(.horizontal, 6)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollDisabled(true)
        }
        .frame(minHeight: 280)
        .card(radius: 10)
    }

    private func switchMode(_ new: Mode) {
        guard new != mode else { return }
        if new == .text {
            text = draft.render()
        } else {
            guard let cfg = try? WGConfig(parsing: text) else {
                error = "Fix the errors below before switching to Form."
                return
            }
            draft = ConfigDraft(cfg)
        }
        error = nil
        mode = new
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            if saved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)) }
            Spacer()
            Button("Cancel") { store.mainSection = .all }.keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Create" : "Save") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private func load() {
        if let editing, let t = store.configText(editing) {
            name = editing
            text = t
            if let cfg = try? WGConfig(parsing: t) { draft = ConfigDraft(cfg) } else { mode = .text }
        } else if let seed = store.builderSeed {
            store.builderSeed = nil
            text = seed
            mode = .text
            name = store.builderSeedName ?? ""
        } else {
            template = .everything
            BuilderTemplate.everything.apply(to: &draft)
        }
    }

    private func save() async {
        error = nil
        let body = currentText
        do {
            if let editing {
                try store.updateConfig(name: editing, text: body)
                if name != editing { try store.rename(editing, to: name) }
                await store.reconnectIfActive(name)
                saved = true
            } else {
                try store.importConfig(name: name, text: body)
                store.mainSelection = name
                store.mainSection = .all
            }
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// The checks panel shared by the builder and Import: one row per issue, worst first.
struct ChecksList: View {
    let issues: [ConfigIssue]
    var cleanText = "No problems found."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Checks", systemImage: "checklist").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                ForEach([ConfigIssue.Severity.error, .warning, .tip], id: \.self) { s in
                    let n = issues.filter { $0.severity == s }.count
                    if n > 0 { badge(s, n) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if issues.isEmpty {
                Label(cleanText, systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            ForEach(issues) { i in
                Divider().padding(.leading, 14)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.icon(i.severity)).foregroundStyle(Self.color(i.severity)).font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let l = i.line {
                                Text("Line \(l)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(i.message).font(.system(size: 12, weight: .medium))
                        }
                        Text(i.hint).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .card()
    }

    private func badge(_ s: ConfigIssue.Severity, _ n: Int) -> some View {
        Text("\(n) \(Self.label(s))\(n == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Self.color(s).opacity(0.15)))
            .foregroundStyle(Self.color(s))
    }

    static func icon(_ s: ConfigIssue.Severity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .tip: return "lightbulb.fill"
        }
    }

    static func color(_ s: ConfigIssue.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .tip: return .blue
        }
    }

    static func label(_ s: ConfigIssue.Severity) -> String {
        switch s {
        case .error: return "error"
        case .warning: return "warning"
        case .tip: return "tip"
        }
    }
}
