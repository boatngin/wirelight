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
    var favorite: Bool = false
    var createdAt: Date?
    var splitDNSDomains: [String] = []
    var excludedCIDRs: [String] = []
    var id: String { name }

    init(name: String, endpoint: String?, addresses: [String], routeAll: Bool = false,
         favorite: Bool = false, createdAt: Date? = Date()) {
        self.name = name; self.endpoint = endpoint; self.addresses = addresses
        self.routeAll = routeAll; self.favorite = favorite; self.createdAt = createdAt
    }

    // Tolerate profiles saved by older versions (missing keys).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        routeAll = try c.decodeIfPresent(Bool.self, forKey: .routeAll) ?? false
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        splitDNSDomains = try c.decodeIfPresent([String].self, forKey: .splitDNSDomains) ?? []
        excludedCIDRs = try c.decodeIfPresent([String].self, forKey: .excludedCIDRs) ?? []
    }

    var upOptions: UpOptions { UpOptions(splitDNSDomains: splitDNSDomains, excludedCIDRs: excludedCIDRs) }
}

/// One traffic sample (bytes/second) derived from successive status polls.
struct TrafficSample: Identifiable, Equatable {
    let date: Date
    let rx: Double
    let tx: Double
    var id: Date { date }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
    let isError: Bool
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
    @Published private(set) var active: TunnelStatus? {
        didSet { activeChanged(from: oldValue) }
    }
    /// Traffic for the active tunnel over the last 60 seconds.
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var connectedSince: Date?
    @Published private(set) var log: [LogEntry] = []
    /// Which page the dashboard window shows (set by menu shortcuts too).
    @Published var mainSection: SidebarItem? = .all
    /// Tunnel selected in the dashboard list.
    @Published var mainSelection: String?
    /// Parsed configs cached from the Keychain (avoid reading it on every render).
    @Published private(set) var configs: [String: WGConfig] = [:]
    /// Main window open → poll as fast as when the menu is open.
    var windowOpen = false {
        didSet { if windowOpen && !oldValue { Task { await refresh() } } }
    }
    private var lastCounters: (date: Date, rx: UInt64, tx: UInt64)?
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

    /// Demo mode (`WIRELIGHT_DEMO=1`): sample data for screenshots, no helper,
    /// Keychain or UserDefaults access.
    static let isDemo = ProcessInfo.processInfo.environment["WIRELIGHT_DEMO"] == "1"

    init() {
        if Self.isDemo {
            loadDemo()
            return
        }
        loadProfiles()
        selectedName = UserDefaults.standard.string(forKey: Keys.selected) ?? profiles.first?.name
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startPolling()
        watchSystemEvents()
        Task { await autoConnectIfNeeded() }
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
                let interval = (self.menuOpen || self.windowOpen) ? 2 : 10
                if elapsed == 0 { await self.refresh() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsed += 1
                if elapsed >= interval { elapsed = 0 }
            }
        }
    }

    func refresh() async {
        if Self.isDemo { return }
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
        if Self.isDemo { return }
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
            let options = profile(name)?.upOptions ?? UpOptions()
            let request: Request = (options.splitDNSDomains.isEmpty && options.excludedCIDRs.isEmpty)
                ? .up(name: name, config: text)
                : .upWithOptions(name: name, config: text, options: options)
            let r = try check(await HelperClient.send(request, timeout: 30))
            active = r.status?.first { $0.name == name }
            selectedName = name
            notifiedStale = false
            notify("Connected", name)
            addLog("Connected \(name)")
        } catch {
            lastError = String(describing: error)
            addLog(String(describing: error), isError: true)
        }
    }

    func disconnect() async {
        if Self.isDemo { return }
        guard !busy, let current = active else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            try check(await HelperClient.send(.down(name: current.name), timeout: 30))
            active = nil
            notify("Disconnected", current.name)
            addLog("Disconnected \(current.name)")
        } catch {
            lastError = String(describing: error)
            addLog(String(describing: error), isError: true)
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
        configs[name] = cfg
        addLog("Imported \(name)")
        profiles.append(TunnelProfile(name: name, endpoint: cfg.peers.first?.endpoint, addresses: cfg.interface.addresses))
        saveProfiles()
        if selectedName == nil { selectedName = name }
    }

    func configText(_ name: String) -> String? { KeychainStore.load(name) }

    func updateConfig(name: String, text: String) throws {
        let cfg = try WGConfig(parsing: text)
        try KeychainStore.save(text, account: name)
        configs[name] = cfg
        addLog("Updated config for \(name)")
        if let i = profiles.firstIndex(where: { $0.name == name }) {
            profiles[i].endpoint = cfg.peers.first?.endpoint
            profiles[i].addresses = cfg.interface.addresses
            saveProfiles()
        }
    }

    func delete(_ name: String) async {
        if active?.name == name { await disconnect() }
        KeychainStore.delete(name)
        configs[name] = nil
        addLog("Deleted \(name)")
        profiles.removeAll { $0.name == name }
        saveProfiles()
        if selectedName == name { selectedName = profiles.first?.name }
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Keys.profiles),
              let list = try? JSONDecoder().decode([TunnelProfile].self, from: data) else { return }
        profiles = list
        for p in list {
            if let text = KeychainStore.load(p.name), let c = try? WGConfig(parsing: text) { configs[p.name] = c }
        }
    }

    // MARK: Per-tunnel options (applied on next connect; reconnects if active)

    func setSplitDNS(_ domains: [String], for name: String) async {
        await updateProfile(name) { $0.splitDNSDomains = domains }
    }

    func setExclusions(_ cidrs: [String], for name: String) async {
        await updateProfile(name) { $0.excludedCIDRs = cidrs }
    }

    private func updateProfile(_ name: String, _ change: (inout TunnelProfile) -> Void) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }) else { return }
        change(&profiles[i])
        saveProfiles()
        if active?.name == name {
            await disconnect()
            await connect(name)
        }
    }

    // MARK: Connect on launch

    static let connectOnLaunchKey = "connectOnLaunch"
    var connectOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Self.connectOnLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.connectOnLaunchKey); objectWillChange.send() }
    }

    private func autoConnectIfNeeded() async {
        await refresh()
        guard connectOnLaunch, helperReachable, !isConnected, let name = currentProfile?.name else { return }
        addLog("Connecting \(name) at launch")
        await connect(name)
    }

    // MARK: Test connection

    /// Pings a host that should only be reachable through the tunnel.
    func testTarget(for name: String) -> String? {
        guard let cfg = config(name) else { return nil }
        if let dns = cfg.interface.dns.first { return dns }
        for cidr in cfg.peers.flatMap(\.allowedIPs) where !cidr.hasSuffix("/0") {
            let ip = Format.ip(cidr)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4 { return "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3] == 0 ? 1 : parts[3])" }
        }
        return nil
    }

    func testConnection(_ name: String) async -> String {
        guard let target = testTarget(for: name) else { return "No test target (config has no DNS or private AllowedIPs)" }
        let result: String = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/sbin/ping")
                p.arguments = ["-c", "3", "-t", "5", "-q", target]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                do { try p.run() } catch { cont.resume(returning: "ping failed: \(error.localizedDescription)"); return }
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if let line = text.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
                   let nums = line.split(separator: "=").last?.split(separator: "/"), nums.count >= 2 {
                    let loss = text.split(separator: "\n").first(where: { $0.contains("packet loss") })
                        .flatMap { $0.split(separator: ",").first(where: { $0.contains("loss") }) }
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    cont.resume(returning: "\(target): avg \(nums[1].trimmingCharacters(in: .whitespaces)) ms · \(loss)")
                } else {
                    cont.resume(returning: "\(target): no reply")
                }
            }
        }
        addLog("Test \(name): \(result)", isError: result.contains("no reply") || result.contains("failed"))
        return result
    }

    func toggleFavorite(_ name: String) {
        guard let i = profiles.firstIndex(where: { $0.name == name }) else { return }
        profiles[i].favorite.toggle()
        saveProfiles()
    }

    /// Read-only so it is safe to call from view bodies; filled in `loadProfiles`.
    func config(_ name: String) -> WGConfig? { configs[name] }

    func addLog(_ message: String, isError: Bool = false) {
        log.append(LogEntry(date: Date(), message: message, isError: isError))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func activeChanged(from old: TunnelStatus?) {
        if active?.name != old?.name {
            samples = []
            lastCounters = nil
            connectedSince = active == nil ? nil : Date()
        }
        guard let peer = active?.peers.first else { return }
        let now = Date()
        if let last = lastCounters, now.timeIntervalSince(last.date) > 0.5 {
            let dt = now.timeIntervalSince(last.date)
            let rx = Double(peer.rxBytes &- last.rx) / dt
            let tx = Double(peer.txBytes &- last.tx) / dt
            if peer.rxBytes >= last.rx && peer.txBytes >= last.tx {
                samples.append(TrafficSample(date: now, rx: rx, tx: tx))
                samples.removeAll { now.timeIntervalSince($0.date) > 60 }
            }
        }
        if lastCounters == nil || now.timeIntervalSince(lastCounters!.date) > 0.5 {
            lastCounters = (now, peer.rxBytes, peer.txBytes)
        }
    }

    private func loadDemo() {
        // Throwaway keys generated with `wg genkey`; documentation IP ranges only.
        let peers = ["hmSEV1i3X4AQyQpOeoMwt2DQEa+0nu5ZS3v5JSSrYFQ=", "v6jlChyb6k6nARaW+0zmEqB2GdLXK9ZTC2dtEAHrNV4=",
                     "Uw6SpKDvoZIawVvCNlXqkeaYQ8N4CguZXSHT/19BTFs="]
        let demos: [(String, String, String, String)] = [
            ("home", "vpn.example.com:51820", "10.8.0.2/32", "192.168.1.0/24, 10.8.0.0/24"),
            ("office", "198.51.100.20:51820", "10.20.0.7/32", "10.20.0.0/16"),
            ("tokyo-vps", "203.0.113.45:51820", "10.66.0.2/32", "0.0.0.0/0, ::/0"),
        ]
        for (i, d) in demos.enumerated() {
            let text = """
            [Interface]
            PrivateKey = aJZAOjSd91Y8ZUTmknBlNoqDd/yEMhr6u+lNsOSQ7Xo=
            Address = \(d.2)
            DNS = 10.8.0.1
            [Peer]
            PublicKey = \(peers[i])
            Endpoint = \(d.1)
            AllowedIPs = \(d.3)
            PersistentKeepalive = 25
            """
            if let cfg = try? WGConfig(parsing: text) { configs[d.0] = cfg }
            profiles.append(TunnelProfile(name: d.0, endpoint: d.1, addresses: [d.2], favorite: i == 0,
                                          createdAt: Date().addingTimeInterval(-86400 * Double(30 - i * 7))))
        }
        profiles[0].splitDNSDomains = ["lan", "home.arpa"]
        profiles[0].excludedCIDRs = ["192.168.1.50/32"]
        selectedName = "home"
        mainSelection = "home"
        let now = Date()
        let demoSamples: [TrafficSample] = (0..<30).map { i in
            let t = Double(i)
            return TrafficSample(date: now.addingTimeInterval(-58 + t * 2),
                                 rx: max(0, 180_000 + 140_000 * sin(t / 3.2) + 60_000 * sin(t * 1.7)),
                                 tx: max(0, 40_000 + 30_000 * sin(t / 2.5 + 1) + 15_000 * cos(t * 1.3)))
        }
        lastCounters = nil
        active = TunnelStatus(name: "home", interface: "utun7", peers: [
            PeerStatus(publicKey: peers[0], endpoint: "203.0.113.10:51820",
                       latestHandshake: now.addingTimeInterval(-12),
                       rxBytes: 1_284_000_000, txBytes: 214_500_000,
                       allowedIPs: ["192.168.1.0/24", "10.8.0.0/24"])])
        samples = demoSamples
        connectedSince = now.addingTimeInterval(-(3600 * 2 + 1260))
        addLog("Imported home")
        addLog("Connected home")
        addLog("Test home: 10.8.0.1: avg 18.4 ms · 0.0% packet loss")
    }

    private func saveProfiles() {
        if Self.isDemo { return }
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

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false   // "0 bytes", never "Zero KB"
        return f
    }()

    static func bytes(_ n: UInt64) -> String { byteFormatter.string(fromByteCount: Int64(clamping: n)) }

    static func rate(_ bps: Double) -> String {
        bps < 1 ? "0 B/s" : "\(byteFormatter.string(fromByteCount: Int64(bps)))/s"
    }

    static func ip(_ cidr: String) -> String { String(cidr.split(separator: "/").first ?? "") }
}
