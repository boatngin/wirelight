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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLaunchAtLogin(on) }
            Toggle("Connect the last used tunnel when the app starts", isOn: Binding(
                get: { store.connectOnLaunch },
                set: { store.connectOnLaunch = $0 }))

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
                if store.active?.name == name {
                    Text("Changes apply the next time you connect.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No tunnels. Use Import config… from the menu.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if selected == nil { selected = store.currentProfile?.name } ; if let s = selected { loadEditor(s) } }
        .onChange(of: selected) { name in if let name { loadEditor(name) } else { editorText = "" } }
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
