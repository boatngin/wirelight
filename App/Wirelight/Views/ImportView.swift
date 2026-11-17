import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WGCore

struct ImportView: View {
    @EnvironmentObject var store: TunnelStore

    @State private var text: String?
    @State private var name = ""
    @State private var summary: String?
    @State private var error: String?
    @State private var dropTargeted = false
    /// Checks for the loaded text, valid or not.
    @State private var issues: [ConfigIssue] = []
    /// Text that failed to parse, kept so it can be fixed in the builder.
    @State private var brokenText: String?

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
            if text != nil || brokenText != nil {
                ChecksList(issues: issues)
            }
            if let brokenText {
                Button { store.openBuilder(seed: brokenText, seedName: name); reset() } label: {
                    Label("Fix in editor", systemImage: "square.and.pencil")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { reset(); store.mainSection = .all }.keyboardShortcut(.cancelAction)
                Button("Import", action: doImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == nil || !Validation.isValidTunnelName(name))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Drop a WireGuard .conf file or QR code image here").font(.system(size: 13))
            HStack {
                Button("Choose File…", action: choose)
                Button("Paste", action: paste).help("Paste config text or a QR code image from the clipboard")
            }
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
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .data, .plainText, .image]
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func paste() {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            load(qr: CIImage(data: tiff), suggestedName: "")
        } else if let s = pb.string(forType: .string) {
            load(text: s, suggestedName: "")
        } else {
            fail("The clipboard has no config text or image.")
        }
    }

    private func load(_ url: URL) {
        let suggested = url.deletingPathExtension().lastPathComponent
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            load(qr: CIImage(contentsOf: url), suggestedName: suggested)
        } else if let t = try? String(contentsOf: url, encoding: .utf8) {
            load(text: t, suggestedName: suggested)
        } else {
            fail("Couldn't read that file as text.")
        }
    }

    /// Decodes on-device; the payload holds a private key, so it is never logged.
    private func load(qr image: CIImage?, suggestedName: String) {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let payload = image.flatMap { detector?.features(in: $0) }?
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
        guard let payload else { return fail("No QR code found in that image.") }
        load(text: payload, suggestedName: suggestedName)
    }

    private func fail(_ message: String) {
        text = nil
        summary = nil
        brokenText = nil
        issues = []
        error = message
    }

    private func load(text t: String, suggestedName: String) {
        error = nil
        issues = ConfigLint.check(t)
        if name.isEmpty { name = Self.suggestName(suggestedName) }
        do {
            let cfg = try WGConfig(parsing: t)
            text = t
            brokenText = nil
            summary = """
            Address:  \(cfg.interface.addresses.joined(separator: ", "))
            Peers:    \(cfg.peers.count)
            Endpoint: \(cfg.peers.first?.endpoint ?? "-")
            DNS:      \((cfg.interface.dns + cfg.interface.dnsSearch).joined(separator: ", ").isEmpty ? "-" : (cfg.interface.dns + cfg.interface.dnsSearch).joined(separator: ", "))
            """
        } catch {
            text = nil
            summary = nil
            brokenText = t
            self.error = "This config has errors. See the checks below, or fix it in the editor."
        }
    }

    private func doImport() {
        guard let text else { return }
        do {
            try store.importConfig(name: name, text: text)
            let imported = name
            reset()
            store.mainSelection = imported
            store.mainSection = .all
        } catch {
            self.error = String(describing: error)
        }
    }

    private func reset() {
        text = nil; name = ""; summary = nil; error = nil; brokenText = nil; issues = []
    }

    static func suggestName(_ s: String) -> String {
        String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(32))
    }
}
