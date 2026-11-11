import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WGCore

struct ImportView: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.dismiss) private var dismiss

    @State private var text: String?
    @State private var name = ""
    @State private var summary: String?
    @State private var error: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone
            if let summary {
                Text(summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            if text != nil {
                HStack {
                    Text("Tunnel name")
                    TextField("home", text: $name).textFieldStyle(.roundedBorder)
                }
                if !name.isEmpty && !Validation.isValidTunnelName(name) {
                    Text(StoreError.invalidName.description).font(.caption).foregroundStyle(.red)
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { reset(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import", action: doImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == nil || !Validation.isValidTunnelName(name))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Drop a WireGuard .conf file here").font(.system(size: 13))
            Button("Choose File…", action: choose)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { load(url) } }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .data, .plainText]
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        error = nil
        do {
            let t = try String(contentsOf: url, encoding: .utf8)
            let cfg = try WGConfig(parsing: t)
            text = t
            if name.isEmpty { name = Self.suggestName(url.deletingPathExtension().lastPathComponent) }
            summary = """
            Address:  \(cfg.interface.addresses.joined(separator: ", "))
            Peers:    \(cfg.peers.count)
            Endpoint: \(cfg.peers.first?.endpoint ?? "-")
            DNS:      \((cfg.interface.dns + cfg.interface.dnsSearch).joined(separator: ", ").isEmpty ? "-" : (cfg.interface.dns + cfg.interface.dnsSearch).joined(separator: ", "))
            """
        } catch {
            text = nil
            summary = nil
            self.error = "Invalid config: \(error)"
        }
    }

    private func doImport() {
        guard let text else { return }
        do {
            try store.importConfig(name: name, text: text)
            reset()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func reset() {
        text = nil; name = ""; summary = nil; error = nil
    }

    static func suggestName(_ s: String) -> String {
        String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(15))
    }
}
