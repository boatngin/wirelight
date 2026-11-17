import Carbon
import ServiceManagement
import SwiftUI
import WGCore

struct SettingsView: View {
    @EnvironmentObject var store: TunnelStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var selected: String?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmDelete = false
    @State private var recordingHotKey = false
    @State private var renaming = false
    @State private var newName = ""
    @AppStorage(MenuBarIcon.coloredKey) private var coloredIcon = false
    @AppStorage(NotchPill.enabledKey) private var notchPill = false
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLaunchAtLogin(on) }
            Toggle("Connect the last used tunnel when the app starts", isOn: Binding(
                get: { store.connectOnLaunch },
                set: { store.connectOnLaunch = $0 }))

            hotKeyRow

            if updater.available {
                HStack {
                    Toggle("Check for updates automatically", isOn: $updater.automatic)
                    Spacer()
                    Button("Check Now") { updater.checkNow() }
                }
            }

            Divider()
            appearance
            Divider()
            monitoring

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
                Text("The config is stored in your Keychain.").font(.caption).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(messageIsError ? .red : .green)
                }
                HStack {
                    Button("Delete Tunnel…", role: .destructive) { confirmDelete = true }
                    Button("Rename…") { renaming = true; newName = name }
                    Spacer()
                    Button("Edit Config…") { store.openBuilder(edit: name) }
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
            } else {
                Text("No tunnels. Use Import config… from the menu.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if selected == nil { selected = store.mainSelection ?? store.currentProfile?.name } }
        .onChange(of: selected) { _ in message = nil }
        .onDisappear { recordingHotKey = false }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance").font(.headline)
            Picker("Menu bar icon", selection: $coloredIcon) {
                Text("Monochrome").tag(false)
                Text("Colored by status").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Toggle("Show a status pill beside the notch", isOn: $notchPill)
            Text("Connected tunnels and live speed next to the camera housing; hover for details. Only on screens with a notch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var monitoring: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monitoring").font(.headline)
            Toggle("Measure link quality (latency and packet loss)", isOn: $store.quality.enabled)
            if store.quality.enabled {
                Group {
                    Picker("Ping", selection: $store.quality.target) {
                        Text("Each tunnel's server (outside the tunnel)").tag(QualitySettings.Target.server)
                        Text("A host through the tunnel").tag(QualitySettings.Target.custom)
                    }
                    if store.quality.target == .custom {
                        TextField("Host, e.g. 10.0.0.1", text: $store.quality.customHost)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    }
                    HStack {
                        Picker("Every", selection: $store.quality.interval) {
                            ForEach([5, 10, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                        }.fixedSize()
                        Picker("Keep", selection: $store.quality.historyHours) {
                            ForEach([1, 6, 24], id: \.self) { Text("\($0) h").tag($0) }
                        }.fixedSize()
                    }
                    HStack(spacing: 16) {
                        Stepper("Fair from \(Int(store.quality.fairMs)) ms", value: $store.quality.fairMs, in: 10...1000, step: 10)
                        Stepper("Poor from \(Int(store.quality.poorMs)) ms", value: $store.quality.poorMs, in: 20...2000, step: 10)
                    }
                    HStack(spacing: 16) {
                        Stepper("Fair from \(store.quality.fairLoss, specifier: "%.0f")% loss", value: $store.quality.fairLoss, in: 0...50)
                        Stepper("Poor from \(store.quality.poorLoss, specifier: "%.0f")% loss", value: $store.quality.poorLoss, in: 1...100)
                    }
                    Text("About \(Format.bytes(UInt64(store.quality.bytesPerHourPerTunnel))) per hour per connected tunnel, \(store.quality.samplesKept) probes kept in memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 18)
            }
            HStack {
                Text("Speed test file")
                TextField("https://… a large file you own",
                          text: Binding(get: { store.speedTestURL }, set: { store.speedTestURL = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
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
