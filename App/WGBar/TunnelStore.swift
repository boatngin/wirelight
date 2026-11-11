import AppKit
import Foundation
import Network
import SwiftUI
import UserNotifications
import WGCore

/// Non-secret metadata kept in UserDefaults. The config itself lives in the Keychain.
struct TunnelProfile: Codable, Identifiable, Equatable {
    var name: String
    var endpoint: String?
    var addresses: [String]
    var routeAll: Bool = false
    var id: String { name }
}

enum StoreError: Error, CustomStringConvertible {
    case helper(String)
    case missingConfig(String)
    case invalidName
    case duplicateName(String)

    var description: String {
        switch self {
        case let .helper(m): return m
        case let .missingConfig(n): return "No saved config for '\(n)' in Keychain"
        case .invalidName: return "Name must be 1–15 characters: letters, digits, _ or -"
        case let .duplicateName(n): return "A tunnel named '\(n)' already exists"
        }
    }
}

@MainActor
final class TunnelStore: ObservableObject {
    static let staleAfter: TimeInterval = 180

    @Published private(set) var profiles: [TunnelProfile] = []
    @Published private(set) var active: TunnelStatus?
    @Published private(set) var helperReachable = true
    @Published private(set) var busy = false {
        didSet { busy ? startIconAnimation() : stopIconAnimation() }
    }
    @Published private(set) var iconFrame = 0
    private var iconTimer: Timer?
    @Published var lastError: String?
    @Published var selectedName: String? {
        didSet { UserDefaults.standard.set(selectedName, forKey: Keys.selected) }
    }

    /// Polling is faster while the menu is open.
    var menuOpen = false {
        didSet { if menuOpen && !oldValue { Task { await refresh() } } }
    }

    private enum Keys {
        static let profiles = "profiles"
        static let selected = "selectedTunnel"
    }

    private var pollTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?
    private var wakeObserver: NSObjectProtocol?
    private var notifiedStale = false

    init() {
        loadProfiles()
        selectedName = UserDefaults.standard.string(forKey: Keys.selected) ?? profiles.first?.name
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startPolling()
        watchSystemEvents()
    }

    // MARK: Wake / network change

    private func watchSystemEvents() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Give Wi-Fi a moment to reassociate before re-resolving endpoints.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.helperRefresh(reason: "wake")
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let sig = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSignature = sig }
                guard let last = self.lastPathSignature, last != sig, path.status == .satisfied else { return }
                await self.helperRefresh(reason: "network change")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.thanaboat.wgbar.path"))
    }

    /// Asks the helper to re-resolve endpoints / re-pin routes. No-op when disconnected.
    func helperRefresh(reason: String) async {
        guard isConnected, !busy else { return }
        if let r = try? await HelperClient.send(.refresh, timeout: 15), r.ok {
            active = r.status?.first
        }
    }

    var isConnected: Bool { active != nil }

    var iconState: IconState {
        if busy { return .connecting(frame: iconFrame) }
        guard isConnected else { return .disconnected }
        return isHandshakeStale ? .stale : .connected
    }

    private func startIconAnimation() {
        guard iconTimer == nil else { return }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.iconFrame += 1 }
        }
    }

    private func stopIconAnimation() {
        iconTimer?.invalidate()
        iconTimer = nil
    }
    func profile(_ name: String) -> TunnelProfile? { profiles.first { $0.name == name } }
    var activeProfile: TunnelProfile? { active.flatMap { profile($0.name) } }
    var currentProfile: TunnelProfile? { activeProfile ?? selectedName.flatMap(profile) ?? profiles.first }

    var isHandshakeStale: Bool {
        guard let hs = active?.peers.first?.latestHandshake else { return false }
        return Date().timeIntervalSince(hs) > Self.staleAfter
    }

    // MARK: Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.menuOpen ? 2 : 10
                if elapsed == 0 { await self.refresh() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsed += 1
                if elapsed >= interval { elapsed = 0 }
            }
        }
    }

    func refresh() async {
        guard !busy else { return }
        do {
            let r = try await HelperClient.send(.status)
            helperReachable = true
            active = r.status?.first
            checkHandshake()
        } catch {
            helperReachable = false
            active = nil
        }
    }

    private func checkHandshake() {
        guard let a = active else { notifiedStale = false; return }
        let stale = isHandshakeStale
        if stale && !notifiedStale {
            notify("Handshake lost", "\(a.name): no handshake for over 3 minutes")
        }
        notifiedStale = stale
    }

    // MARK: Connect / disconnect

    @discardableResult
    private func check(_ r: Response) throws -> Response {
        guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
        return r
    }

    func connect(_ name: String) async {
        guard !busy, active?.name != name else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            // Only one tunnel at a time.
            if let current = active {
                try check(await HelperClient.send(.down(name: current.name), timeout: 30))
                active = nil
            }
            guard var text = KeychainStore.load(name) else { throw StoreError.missingConfig(name) }
            if profile(name)?.routeAll == true {
                var cfg = try WGConfig(parsing: text)
                if !cfg.peers.isEmpty { cfg.peers[0].allowedIPs = ["0.0.0.0/0", "::/0"] }
                text = cfg.wgQuickText()
            }
            let r = try check(await HelperClient.send(.up(name: name, config: text), timeout: 30))
            active = r.status?.first { $0.name == name }
            selectedName = name
            notifiedStale = false
            notify("Connected", name)
        } catch {
            lastError = String(describing: error)
        }
    }

    func disconnect() async {
        guard !busy, let current = active else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            try check(await HelperClient.send(.down(name: current.name), timeout: 30))
            active = nil
            notify("Disconnected", current.name)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Switches between the config's AllowedIPs and 0.0.0.0/0, ::/0. Reconnects if active.
    func setRouteAll(_ on: Bool, for name: String) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }), profiles[i].routeAll != on else { return }
        profiles[i].routeAll = on
        saveProfiles()
        if active?.name == name {
            await disconnect()
            await connect(name)
        }
    }

    // MARK: Profiles

    func importConfig(name: String, text: String) throws {
        guard Validation.isValidTunnelName(name) else { throw StoreError.invalidName }
        guard profile(name) == nil else { throw StoreError.duplicateName(name) }
        let cfg = try WGConfig(parsing: text)
        try KeychainStore.save(text, account: name)
        profiles.append(TunnelProfile(name: name, endpoint: cfg.peers.first?.endpoint, addresses: cfg.interface.addresses))
        saveProfiles()
        if selectedName == nil { selectedName = name }
    }

    func configText(_ name: String) -> String? { KeychainStore.load(name) }

    func updateConfig(name: String, text: String) throws {
        let cfg = try WGConfig(parsing: text)
        try KeychainStore.save(text, account: name)
        if let i = profiles.firstIndex(where: { $0.name == name }) {
            profiles[i].endpoint = cfg.peers.first?.endpoint
            profiles[i].addresses = cfg.interface.addresses
            saveProfiles()
        }
    }

    func delete(_ name: String) async {
        if active?.name == name { await disconnect() }
        KeychainStore.delete(name)
        profiles.removeAll { $0.name == name }
        saveProfiles()
        if selectedName == name { selectedName = profiles.first?.name }
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Keys.profiles),
              let list = try? JSONDecoder().decode([TunnelProfile].self, from: data) else { return }
        profiles = list
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    // MARK: Notifications

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

enum Format {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .binary)
    }

    static func ip(_ cidr: String) -> String { String(cidr.split(separator: "/").first ?? "") }
}
