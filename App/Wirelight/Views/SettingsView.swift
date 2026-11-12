import Carbon
import ServiceManagement
import SwiftUI
import WGCore

struct SettingsView: View {
    @EnvironmentObject var store: TunnelStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var selected: String?
    @State private var editorText = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmDelete = false
    @State private var recordingHotKey = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLaunchAtLogin(on) }
            Toggle("Connect the last used tunnel when the app starts", isOn: Binding(
                get: { store.connectOnLaunch },
                set: { store.connectOnLaunch = $0 }))

            hotKeyRow

            Divider()

            HStack {
                Text("Tunnel")
                Picker("", selection: $selected) {
                    ForEach(store.profiles) { Text($0.name).tag(Optional($0.name)) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                Spacer()
            }

            if let name = selected {
                Text("Config (stored in Keychain)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editorText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
                    .border(Color.secondary.opacity(0.3))
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(messageIsError ? .red : .green)
                }
                HStack {
                    Button("Delete Tunnel…", role: .destructive) { confirmDelete = true }
                    Button("Rename…") { renaming = true; newName = name }
                    Spacer()
                    Button("Revert") { loadEditor(name) }
                    Button("Validate & Save") { save(name) }.keyboardShortcut("s")
                }
                .confirmationDialog("Delete tunnel '\(name)'?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) {
                        Task {
                            await store.delete(name)
                            selected = store.profiles.first?.name
                        }
                    }
                } message: {
                    Text("The config and its private key will be removed from the Keychain.")
                }
                if renaming {
                    HStack {
                        TextField("New name", text: $newName).frame(maxWidth: 200)
                        Button("Cancel") { renaming = false }
                        Button("Rename") { rename(name) }.keyboardShortcut(.return)
                    }
                }
                if store.active?.name == name {
                    Text("Changes apply the next time you connect.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No tunnels. Use Import config… from the menu.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if selected == nil { selected = store.mainSelection ?? store.currentProfile?.name } ; if let s = selected { loadEditor(s) } }
        .onChange(of: selected) { name in if let name { loadEditor(name) } else { editorText = "" } }
        .onDisappear { recordingHotKey = false }
    }

    private var hotKeyRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Toggle tunnel shortcut")
                Text(recordingHotKey
                     ? "Press a combination with ⌃ ⌥ ⇧ and/or ⌘, Esc to cancel"
                     : (store.toggleHotKey == nil ? "Disabled" : "Connects or disconnects the current tunnel from any app"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(store.toggleHotKey?.display ?? "None")
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            Button(recordingHotKey ? "Cancel" : (store.toggleHotKey == nil ? "Set…" : "Change…")) { recordingHotKey.toggle() }
            if store.toggleHotKey != nil {
                Button("Remove") { store.toggleHotKey = nil; recordingHotKey = false }
            }
            HotKeyCaptureView(active: recordingHotKey, onKey: capture)
                .frame(width: 1, height: 1)
        }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { recordingHotKey = false; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { return }
        recordingHotKey = false
        store.toggleHotKey = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    private func loadEditor(_ name: String) {
        editorText = store.configText(name) ?? ""
        message = nil
    }

    private func save(_ name: String) {
        do {
            try store.updateConfig(name: name, text: editorText)
            message = "Saved"
            messageIsError = false
        } catch {
            message = String(describing: error)
            messageIsError = true
        }
    }

    private func rename(_ name: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        do {
            try store.rename(name, to: trimmed)
            renaming = false
            selected = trimmed
            message = "Renamed to '\(trimmed)'"
            messageIsError = false
        } catch {
            message = String(describing: error)
            messageIsError = true
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Launch at login: \(error.localizedDescription)"
            messageIsError = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Invisible view that captures the next key press while `active`.
private struct HotKeyCaptureView: NSViewRepresentable {
    var active: Bool
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView { CaptureView(onKey: onKey) }

    func updateNSView(_ view: NSView, context: Context) {
        guard let v = view as? CaptureView else { return }
        v.onKey = onKey
        if active { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
    }

    private final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        init(onKey: @escaping (NSEvent) -> Void) { self.onKey = onKey; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { onKey?(event) }
    }
}
