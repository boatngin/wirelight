import AppKit
import CoreLocation
import CoreWLAN
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
    /// Network rules are active for this tunnel.
    var onDemand: Bool = false
    /// First matching rule decides; `otherwise` applies on any other network (nil: leave it).
    var rules: [NetworkRule] = []
    var otherwise: NetworkRule.Action?
    /// Block all non-tunnel traffic if the tunnel drops unexpectedly.
    var killSwitch: Bool = false
    /// Drop IPv6 while connected when the tunnel only takes IPv4 (stops IPv6 leaks).
    var blockIPv6: Bool = false
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
        onDemand = try c.decodeIfPresent(Bool.self, forKey: .onDemand) ?? false
        otherwise = try c.decodeIfPresent(NetworkRule.Action.self, forKey: .otherwise)
        if let saved = try c.decodeIfPresent([NetworkRule].self, forKey: .rules) {
            rules = saved
        } else {
            // 0.2 kept a trusted Wi-Fi list: disconnect there, connect on any other Wi-Fi.
            let trusted = try c.decodeIfPresent([String].self, forKey: .trustedSSIDs) ?? []
            if !trusted.isEmpty { rules.append(NetworkRule(kind: .wifi, values: trusted, action: .disconnect)) }
            if onDemand || !trusted.isEmpty { rules.append(NetworkRule(kind: .wifi, action: .connect)) }
        }
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? false
        blockIPv6 = try c.decodeIfPresent(Bool.self, forKey: .blockIPv6) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case name, endpoint, addresses, routeAll, favorite, createdAt, splitDNSDomains, excludedCIDRs
        case onDemand, rules, otherwise, trustedSSIDs, killSwitch, blockIPv6
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(endpoint, forKey: .endpoint)
        try c.encode(addresses, forKey: .addresses)
        try c.encode(routeAll, forKey: .routeAll)
        try c.encode(favorite, forKey: .favorite)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(splitDNSDomains, forKey: .splitDNSDomains)
        try c.encode(excludedCIDRs, forKey: .excludedCIDRs)
        try c.encode(onDemand, forKey: .onDemand)
        try c.encode(rules, forKey: .rules)
        try c.encodeIfPresent(otherwise, forKey: .otherwise)
        try c.encode(killSwitch, forKey: .killSwitch)
        try c.encode(blockIPv6, forKey: .blockIPv6)
    }

    var upOptions: UpOptions {
        UpOptions(splitDNSDomains: splitDNSDomains, excludedCIDRs: excludedCIDRs, killSwitch: killSwitch,
                  blockIPv6: blockIPv6)
    }
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
    case activeTunnel(String)

    var description: String {
        switch self {
        case let .helper(m): return m
        case let .missingConfig(n): return "No saved config for '\(n)' in Keychain"
        case .invalidName: return "Name must be 1–32 characters: letters, digits, _ or -"
        case let .duplicateName(n): return "A tunnel named '\(n)' already exists"
        case let .activeTunnel(n): return "Disconnect '\(n)' before renaming it"
        }
    }
}

@MainActor
final class TunnelStore: ObservableObject {
    static let staleAfter: TimeInterval = 180

    @Published private(set) var profiles: [TunnelProfile] = []
    /// Every tunnel the helper reports as up, keyed by name.
    @Published private(set) var statuses: [String: TunnelStatus] = [:]
    /// Traffic per connected tunnel over the last 60 seconds.
    @Published private(set) var traffic: [String: [TrafficSample]] = [:]
    @Published private(set) var since: [String: Date] = [:]
    @Published private(set) var log: [LogEntry] = []
    /// Which page the dashboard window shows (set by menu shortcuts too).
    @Published var mainSection: SidebarItem? = .all
    /// Tunnel selected in the dashboard list.
    @Published var mainSelection: String?
    /// Tunnel open in the builder; nil while creating a new one.
    @Published var builderTarget: String?
    /// Config text (and suggested name) handed to the builder, e.g. from Import.
    var builderSeed: String?
    var builderSeedName: String?
    /// Bumped on every `openBuilder` so the builder view starts fresh.
    @Published private(set) var builderSession = 0

    func openBuilder(edit name: String? = nil, seed: String? = nil, seedName: String? = nil) {
        builderTarget = name
        builderSeed = seed
        builderSeedName = seedName
        builderSession += 1
        mainSection = .create
    }
    /// Parsed configs cached from the Keychain (avoid reading it on every render).
    @Published private(set) var configs: [String: WGConfig] = [:]
    /// Main window open → poll as fast as when the menu is open.
    var windowOpen = false {
        didSet { if windowOpen && !oldValue { Task { await refresh() } } }
    }
    private var lastCounters: [String: (date: Date, rx: UInt64, tx: UInt64)] = [:]
    @Published private(set) var helperReachable = true
    /// Tunnels with a connect or disconnect in flight.
    @Published private(set) var busyNames: Set<String> = [] {
        didSet { busy ? startIconAnimation() : stopIconAnimation() }
    }
    var busy: Bool { !busyNames.isEmpty }
    func isBusy(_ name: String) -> Bool { busyNames.contains(name) }
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
    private let hotKey = GlobalHotKey()
    private let locationManager = CLLocationManager()
    private var lastPathSignature: String?
    private var lastNetwork: NetworkSnapshot?
    /// Wired Ethernet interface names from the last network path update.
    private var wiredInterfaces: [String] = []
    private var wakeObserver: NSObjectProtocol?
    private var notifiedStale: Set<String> = []

    /// Demo mode (`WIRELIGHT_DEMO=1`): sample data for screenshots, no helper,
    /// Keychain or UserDefaults access.
    static let isDemo = ProcessInfo.processInfo.environment["WIRELIGHT_DEMO"] == "1"
    static let toggleHotKeyKey = "toggleHotKey"

    /// Copies settings saved under the pre-rename bundle id (com.thanaboat.wgbar) once.
    private static func migrateLegacyDefaults() {
        let legacy = "com.thanaboat.wgbar"
        guard let id = Bundle.main.bundleIdentifier, id != legacy,
              UserDefaults.standard.persistentDomain(forName: id)?[Keys.profiles] == nil,
              let old = UserDefaults.standard.persistentDomain(forName: legacy) else { return }
        UserDefaults.standard.setPersistentDomain(old, forName: id)
    }

    /// The running store, for App Intents (Shortcuts, Siri, Spotlight).
    static weak var shared: TunnelStore?

    init() {
        defer { Self.shared = self }
        if Self.isDemo {
            loadDemo()
            return
        }
        Self.migrateLegacyDefaults()
        loadProfiles()
        selectedName = UserDefaults.standard.string(forKey: Keys.selected) ?? profiles.first?.name
        hotKey.onTrigger = { [weak self] in Task { @MainActor in await self?.toggle() } }
        hotKey.update(toggleHotKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startPolling()
        watchSystemEvents()
        restartQualityMonitor()
        // Reading the Wi-Fi SSID via CoreWLAN needs Location permission on recent macOS.
        locationManager.requestWhenInUseAuthorization()
        Task {
            await autoConnectIfNeeded()
            await evaluateOnDemand()
        }
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
            // Local addresses are part of the signature, so a DHCP renewal that hands
            // out a new IP on the same network still triggers a refresh.
            let sig = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
                + "|" + LocalAddresses.current().joined(separator: ",")
            let wired = path.availableInterfaces.filter { $0.type == .wiredEthernet }.map(\.name)
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSignature = sig }
                self.wiredInterfaces = wired
                if let last = self.lastPathSignature, last != sig, path.status == .satisfied {
                    await self.helperRefresh(reason: "network change")
                }
                await self.evaluateOnDemand()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "io.github.boatngin.wirelight.path"))
    }

    /// Asks the helper to re-resolve endpoints / re-pin routes. No-op when disconnected.
    func helperRefresh(reason: String) async {
        guard isConnected, !busy else { return }
        if let r = try? await HelperClient.send(.refresh, timeout: 15), r.ok {
            apply(r.status)
        }
    }

    var isConnected: Bool { !statuses.isEmpty }
    func isActive(_ name: String) -> Bool { statuses[name] != nil }
    func status(_ name: String) -> TunnelStatus? { statuses[name] }
    func samples(_ name: String) -> [TrafficSample] { traffic[name] ?? [] }
    func connectedSince(_ name: String) -> Date? { since[name] }
    /// Connected tunnels in list order.
    var activeNames: [String] { profiles.map(\.name).filter(isActive) }

    /// The tunnel the menu hero shows: the selected one if it is up, else the first one up.
    var active: TunnelStatus? {
        if let n = selectedName, let s = statuses[n] { return s }
        return activeNames.first.flatMap { statuses[$0] } ?? statuses.values.sorted { $0.name < $1.name }.first
    }

    var iconState: IconState {
        if busy { return .connecting(frame: iconFrame) }
        guard isConnected else { return .disconnected }
        return statuses.keys.contains(where: { isStale($0) || isSilent($0) }) ? .stale : .connected
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

    func isStale(_ name: String) -> Bool {
        guard let hs = statuses[name]?.peers.first?.latestHandshake else { return false }
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
            apply(r.status)
            checkHandshake()
        } catch {
            helperReachable = false
            apply([])
        }
        await evaluateOnDemand()
    }

    private func checkHandshake() {
        notifiedStale.formIntersection(statuses.keys)
        notifiedSilent.formIntersection(statuses.keys)
        for name in statuses.keys.sorted() {
            let stale = isStale(name)
            if stale && !notifiedStale.contains(name) {
                notify("Handshake lost", "\(name): no handshake for over 3 minutes")
            }
            if stale { notifiedStale.insert(name) } else { notifiedStale.remove(name) }
            if isSilent(name) && !notifiedSilent.contains(name) {
                notifiedSilent.insert(name)
                notify("No answer from server", "\(name): data goes out but nothing comes back")
                addLog("\(name): no answer from the server after \(Int(Self.silentAfter))s", isError: true)
            }
        }
        // A stale handshake may mean the server's address changed (DDNS): re-resolve now and then.
        if statuses.keys.contains(where: isStale), Date().timeIntervalSince(lastStaleRefresh) > 120 {
            lastStaleRefresh = Date()
            Task { await helperRefresh(reason: "stale handshake") }
        }
    }

    // MARK: Health

    static let silentAfter: TimeInterval = 25
    private var notifiedSilent: Set<String> = []
    private var lastStaleRefresh = Date.distantPast
    /// Tunnels we are taking down on purpose, so their disappearance isn't a "lost" connection.
    private var expectedDown: Set<String> = []
    /// Tunnels that vanished without a disconnect (helper restart, wireguard-go crash).
    @Published private(set) var lost: Set<String> = []
    /// Last connect error per tunnel, cleared on success.
    @Published private(set) var failures: [String: String] = [:]

    /// Up for a while, has sent data, and never got a byte or a handshake back.
    func isSilent(_ name: String) -> Bool {
        guard let since = since[name], Date().timeIntervalSince(since) >= Self.silentAfter,
              let peer = statuses[name]?.peers.first else { return false }
        return peer.latestHandshake == nil && peer.rxBytes == 0 && peer.txBytes > 0
    }

    /// The tunnel takes all IPv4, not IPv6, and this Mac has a public IPv6 address:
    /// IPv6 traffic goes around the tunnel.
    func leaksIPv6(_ name: String) -> Bool {
        guard let p = profile(name), !p.routeAll, !p.blockIPv6 else { return false }
        let ips = config(name)?.peers.flatMap(\.allowedIPs) ?? []
        return ips.contains("0.0.0.0/0") && !ips.contains("::/0") && LocalAddresses.hasGlobalIPv6()
    }

    func dismissFailure(_ name: String) { failures[name] = nil; lost.remove(name) }

    func setBlockIPv6(_ on: Bool, for name: String) async {
        await updateProfile(name) { $0.blockIPv6 = on }
    }

    // MARK: Connect / disconnect

    @discardableResult
    private func check(_ r: Response) throws -> Response {
        guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
        return r
    }

    /// True when the tunnel would take the default route (route all, or 0.0.0.0/0 / ::/0 in the config).
    func routesAll(_ name: String) -> Bool {
        if profile(name)?.routeAll == true { return true }
        let ips = config(name)?.peers.flatMap(\.allowedIPs) ?? []
        return ips.contains("0.0.0.0/0") || ips.contains("::/0")
    }

    func connect(_ name: String) async {
        if Self.isDemo { return }
        guard !isBusy(name), !isActive(name) else { return }
        // Two tunnels cannot both own the default route: the new one takes over.
        if routesAll(name) {
            for other in activeNames where other != name && routesAll(other) {
                addLog("\(name) routes all traffic, so \(other) disconnects first")
                await disconnect(other)
            }
        }
        busyNames.insert(name)
        lastError = nil
        defer { busyNames.remove(name) }
        do {
            guard var text = KeychainStore.load(name) else { throw StoreError.missingConfig(name) }
            if profile(name)?.routeAll == true {
                var cfg = try WGConfig(parsing: text)
                if !cfg.peers.isEmpty { cfg.peers[0].allowedIPs = ["0.0.0.0/0", "::/0"] }
                text = cfg.wgQuickText()
            }
            let options = profile(name)?.upOptions ?? UpOptions()
            let r = try check(await HelperClient.send(.upWithOptions(name: name, config: text, options: options), timeout: 30))
            apply(r.status)
            failures[name] = nil
            lost.remove(name)
            selectedName = name
            notifiedStale.remove(name)
            notifiedSilent.remove(name)
            notify("Connected", name)
            addLog("Connected \(name)")
        } catch {
            failures[name] = String(describing: error)
            addLog("\(name): \(error)", isError: true)
        }
    }

    func disconnect(_ name: String) async {
        if Self.isDemo { return }
        failures[name] = nil
        lost.remove(name)
        guard !isBusy(name), isActive(name) else { return }
        busyNames.insert(name)
        expectedDown.insert(name)
        lastError = nil
        defer { busyNames.remove(name); expectedDown.remove(name) }
        do {
            let r = try check(await HelperClient.send(.down(name: name), timeout: 30))
            apply(r.status)
            notify("Disconnected", name)
            addLog("Disconnected \(name)")
        } catch {
            lastError = String(describing: error)
            addLog(String(describing: error), isError: true)
        }
    }

    /// Disconnects every connected tunnel.
    func disconnectAll() async {
        for name in activeNames { await disconnect(name) }
    }

    /// Connects every favorite (a route-all favorite wins over earlier ones).
    func connectFavorites() async {
        for p in profiles where p.favorite && !isActive(p.name) { await connect(p.name) }
    }

    /// Hotkey: disconnects the tunnel shown in the menu, or connects the current one when none is up.
    func toggle() async {
        guard let name = currentProfile?.name else { return }
        isActive(name) ? await disconnect(name) : await connect(name)
    }

    /// Switches between the config's AllowedIPs and 0.0.0.0/0, ::/0. Reconnects if active.
    func setRouteAll(_ on: Bool, for name: String) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }), profiles[i].routeAll != on else { return }
        profiles[i].routeAll = on
        saveProfiles()
        await reconnectIfActive(name)
    }

    func reconnectIfActive(_ name: String) async {
        guard isActive(name) else { return }
        await disconnect(name)
        await connect(name)
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

    /// Copies a tunnel's config and per-tunnel options under a free name like `home-2`.
    func duplicate(_ name: String) {
        guard let text = configText(name), let source = profile(name) else {
            lastError = StoreError.missingConfig(name).description
            return
        }
        var n = 2
        while n < 1000 {
            let suffix = "-\(n)"
            let candidate = String(name.prefix(32 - suffix.count)) + suffix
            guard Validation.isValidTunnelName(candidate), profile(candidate) == nil else { n += 1; continue }
            do {
                try importConfig(name: candidate, text: text)
            } catch {
                lastError = String(describing: error)
                addLog(String(describing: error), isError: true)
                return
            }
            if let i = profiles.firstIndex(where: { $0.name == candidate }) {
                profiles[i].splitDNSDomains = source.splitDNSDomains
                profiles[i].excludedCIDRs = source.excludedCIDRs
                profiles[i].routeAll = source.routeAll
                saveProfiles()
            }
            mainSelection = candidate
            addLog("Duplicated \(name) as \(candidate)")
            return
        }
        lastError = StoreError.invalidName.description
        addLog(StoreError.invalidName.description, isError: true)
    }

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
        if isActive(name) { await disconnect(name) }
        KeychainStore.delete(name)
        configs[name] = nil
        addLog("Deleted \(name)")
        profiles.removeAll { $0.name == name }
        saveProfiles()
        if selectedName == name { selectedName = profiles.first?.name }
    }

    func rename(_ oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        guard Validation.isValidTunnelName(newName) else { throw StoreError.invalidName }
        guard profile(newName) == nil else { throw StoreError.duplicateName(newName) }
        guard !isActive(oldName) else { throw StoreError.activeTunnel(oldName) }
        if !Self.isDemo {
            guard let text = KeychainStore.load(oldName) else { throw StoreError.missingConfig(oldName) }
            try KeychainStore.save(text, account: newName)
            KeychainStore.delete(oldName)
            if let cfg = configs.removeValue(forKey: oldName) { configs[newName] = cfg }
        }
        if let i = profiles.firstIndex(where: { $0.name == oldName }) {
            profiles[i].name = newName
            saveProfiles()
        }
        if selectedName == oldName { selectedName = newName }
        if mainSelection == oldName { mainSelection = newName }
        addLog("Renamed \(oldName) to \(newName)")
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

    /// Persisted for the next connect; applied live via IPC when the tunnel is active.
    func setKillSwitch(_ on: Bool, for name: String) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }), profiles[i].killSwitch != on else { return }
        profiles[i].killSwitch = on
        saveProfiles()
        guard isActive(name) else { return }
        do {
            _ = try check(await HelperClient.send(.setKillSwitch(name: name, enabled: on), timeout: 15))
            addLog("Kill switch \(on ? "on" : "off") for \(name)")
        } catch {
            lastError = String(describing: error)
            addLog(String(describing: error), isError: true)
        }
    }

    private func updateProfile(_ name: String, _ change: (inout TunnelProfile) -> Void) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }) else { return }
        change(&profiles[i])
        saveProfiles()
        await reconnectIfActive(name)
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

    // MARK: Network rules (on demand)

    /// Current Wi-Fi SSID via CoreWLAN, or nil on Ethernet / no Wi-Fi.
    /// Requires Location permission on recent macOS (requested in `init`).
    func currentSSID() -> String? {
        guard let iface = CWWiFiClient.shared().interface(),
              let ssid = iface.ssid(), !ssid.isEmpty else { return nil }
        return ssid
    }

    func currentNetwork() -> NetworkSnapshot {
        NetworkSnapshot(wifiSSID: currentSSID(), ethernetAddresses: LocalAddresses.addresses(on: wiredInterfaces))
    }

    /// The rule (index, or nil for "otherwise") that applies to a tunnel on the current network.
    func ruleDecision(_ name: String) -> (action: NetworkRule.Action, rule: Int?)? {
        guard let p = profile(name), p.onDemand else { return nil }
        return NetworkRules.decide(p.rules, fallback: p.otherwise, on: lastNetwork ?? currentNetwork())
    }

    /// Applies every tunnel's network rules. Acts only when the network changed (unless
    /// `force`), so a manual switch isn't undone on the next poll and a failed connect
    /// isn't retried forever.
    private func evaluateOnDemand(force: Bool = false) async {
        if Self.isDemo { return }
        let net = currentNetwork()
        if !force, net == lastNetwork { return }
        lastNetwork = net
        let place = net.wifiSSID.map { "Wi-Fi '\($0)'" } ?? (net.onEthernet ? "Ethernet" : "no network")
        for p in profiles where p.onDemand {
            guard let d = NetworkRules.decide(p.rules, fallback: p.otherwise, on: net) else { continue }
            let why = d.rule.map { "rule \($0 + 1)" } ?? "everywhere else"
            switch d.action {
            case .connect where !isActive(p.name):
                addLog("Rules: \(place) → connect \(p.name) (\(why))")
                await connect(p.name)
            case .disconnect where isActive(p.name):
                addLog("Rules: \(place) → disconnect \(p.name) (\(why))")
                await disconnect(p.name)
            default: break
            }
        }
    }

    func setOnDemand(_ on: Bool, for name: String) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }), profiles[i].onDemand != on else { return }
        profiles[i].onDemand = on
        saveProfiles()
        if on { await evaluateOnDemand(force: true) }
    }

    func setRules(_ rules: [NetworkRule], otherwise: NetworkRule.Action?, for name: String) async {
        guard let i = profiles.firstIndex(where: { $0.name == name }) else { return }
        profiles[i].rules = rules
        profiles[i].otherwise = otherwise
        saveProfiles()
        if profiles[i].onDemand { await evaluateOnDemand(force: true) }
    }

    /// Global shortcut that toggles the current tunnel; nil disables it. Defaults to ⌃⌥⌘W on first run.
    var toggleHotKey: HotKeyCombo? {
        get {
            guard let dict = UserDefaults.standard.dictionary(forKey: Self.toggleHotKeyKey) as? [String: Int] else {
                return UserDefaults.standard.object(forKey: Self.toggleHotKeyKey) == nil ? .default : nil
            }
            guard let code = dict["keyCode"], let mods = dict["modifiers"] else { return nil }
            return HotKeyCombo(keyCode: UInt32(truncatingIfNeeded: code), modifiers: UInt32(truncatingIfNeeded: mods))
        }
        set {
            if let c = newValue {
                UserDefaults.standard.set(["keyCode": Int(c.keyCode), "modifiers": Int(c.modifiers)], forKey: Self.toggleHotKeyKey)
            } else {
                UserDefaults.standard.set([String: Int](), forKey: Self.toggleHotKeyKey)
            }
            hotKey.update(newValue)
            objectWillChange.send()
        }
    }

    // MARK: Link quality

    @Published var quality = QualitySettings.load() {
        didSet {
            guard quality != oldValue else { return }
            if !Self.isDemo { quality.save() }
            restartQualityMonitor()
        }
    }
    @Published private(set) var qualitySamples: [String: [QualitySample]] = [:]
    private var qualityTask: Task<Void, Never>?

    func qualitySummary(_ name: String) -> QualitySummary? {
        guard quality.enabled, isActive(name) else { return nil }
        return QualitySummary(qualitySamples[name] ?? [], settings: quality)
    }

    /// The host probed for a tunnel: its server (reached outside the tunnel) or the user's host.
    func probeHost(_ name: String) -> String? {
        if quality.target == .custom {
            let h = quality.customHost.trimmingCharacters(in: .whitespaces)
            return Validation.isValidIP(h) || Validation.isValidHostname(h) ? h : nil
        }
        let ep = statuses[name]?.peers.first?.endpoint ?? profile(name)?.endpoint ?? ""
        if ep.hasPrefix("["), let close = ep.firstIndex(of: "]") { return String(ep[ep.index(after: ep.startIndex)..<close]) }
        return ep.split(separator: ":").first.map(String.init)
    }

    func restartQualityMonitor() {
        qualityTask?.cancel()
        guard quality.enabled, !Self.isDemo else { qualitySamples = [:]; return }
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let targets = self.activeNames.compactMap { n in self.probeHost(n).map { (n, $0) } }
                await withTaskGroup(of: (String, QualitySample).self) { group in
                    for (name, host) in targets { group.addTask { (name, await Pinger.probe(host)) } }
                    for await (name, sample) in group {
                        var list = self.qualitySamples[name] ?? []
                        list.append(sample)
                        if list.count > self.quality.samplesKept { list.removeFirst(list.count - self.quality.samplesKept) }
                        self.qualitySamples[name] = list
                    }
                }
                for gone in Set(self.qualitySamples.keys).subtracting(self.activeNames) { self.qualitySamples[gone] = nil }
                try? await Task.sleep(nanoseconds: UInt64(self.quality.interval) * 1_000_000_000)
            }
        }
    }

    // MARK: Speed test

    static let speedTestURLKey = "speedTestURL"
    /// An HTTPS file of the user's own; nothing is downloaded unless they set one.
    var speedTestURL: String {
        get { UserDefaults.standard.string(forKey: Self.speedTestURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.speedTestURLKey); objectWillChange.send() }
    }

    /// Downloads up to 10 s or 100 MB from `speedTestURL` and reports the rate.
    func speedTest() async -> String {
        guard let url = URL(string: speedTestURL), url.scheme == "https" else {
            return "Set an HTTPS file URL in Settings › Monitoring first"
        }
        let probe = await SpeedProbe.run(url, limitBytes: 100_000_000, limitSeconds: 10)
        if let err = probe.error { return "Speed test failed: \(err)" }
        let bytes = probe.bytes
        let rate = Double(bytes) / max(probe.seconds, 0.001)
        let result = "Download \(Format.rate(rate)) (\(Format.bytes(UInt64(bytes))) in \(String(format: "%.1f", probe.seconds)) s)"
        addLog("Speed test: \(result)")
        return result
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

    func clearLog() { log = [] }

    func addLog(_ message: String, isError: Bool = false) {
        log.append(LogEntry(date: Date(), message: message, isError: isError))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    /// A tunnel dropped without being asked to: say so, then try once to bring it back.
    private func connectionLost(_ name: String) {
        lost.insert(name)
        notify("Connection lost", "\(name) went down. Reconnecting…")
        addLog("\(name): connection lost, reconnecting in 5s", isError: true)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard lost.contains(name), !isActive(name) else { return }
            await connect(name)
        }
    }

    /// Replaces the connected set with the helper's report and derives per-tunnel rates.
    private func apply(_ list: [TunnelStatus]?) {
        let now = Date()
        let next = Dictionary((list ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for gone in Set(statuses.keys).subtracting(next.keys) {
            traffic[gone] = nil; since[gone] = nil; lastCounters[gone] = nil
            if !expectedDown.contains(gone), helperReachable, profile(gone) != nil { connectionLost(gone) }
        }
        for (name, st) in next {
            if since[name] == nil { since[name] = now }
            guard let peer = st.peers.first else { continue }
            if let last = lastCounters[name] {
                let dt = now.timeIntervalSince(last.date)
                guard dt > 0.5 else { continue }
                if peer.rxBytes >= last.rx && peer.txBytes >= last.tx {
                    var list = traffic[name] ?? []
                    list.append(TrafficSample(date: now, rx: Double(peer.rxBytes - last.rx) / dt,
                                              tx: Double(peer.txBytes - last.tx) / dt))
                    list.removeAll { now.timeIntervalSince($0.date) > 60 }
                    traffic[name] = list
                }
            }
            lastCounters[name] = (now, peer.rxBytes, peer.txBytes)
        }
        statuses = next
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
        profiles[0].onDemand = true
        profiles[0].rules = [NetworkRule(kind: .wifi, values: ["HomeWiFi"], action: .disconnect),
                             NetworkRule(kind: .ethernet, values: ["10.20.0.0/16"], action: .disconnect)]
        profiles[0].otherwise = .connect
        profiles[0].excludedCIDRs = ["192.168.1.50/32"]
        selectedName = "home"
        mainSelection = "home"
        // WIRELIGHT_DEMO_SECTION=create (etc.) opens that dashboard page for screenshots.
        if let page = ProcessInfo.processInfo.environment["WIRELIGHT_DEMO_SECTION"].flatMap(SidebarItem.init) {
            mainSection = page
        }
        let now = Date()
        let demoSamples: [TrafficSample] = (0..<30).map { i in
            let t = Double(i)
            return TrafficSample(date: now.addingTimeInterval(-58 + t * 2),
                                 rx: max(0, 180_000 + 140_000 * sin(t / 3.2) + 60_000 * sin(t * 1.7)),
                                 tx: max(0, 40_000 + 30_000 * sin(t / 2.5 + 1) + 15_000 * cos(t * 1.3)))
        }
        statuses["home"] = TunnelStatus(name: "home", interface: "utun7", peers: [
            PeerStatus(publicKey: peers[0], endpoint: "203.0.113.10:51820",
                       latestHandshake: now.addingTimeInterval(-12),
                       rxBytes: 1_284_000_000, txBytes: 214_500_000,
                       allowedIPs: ["192.168.1.0/24", "10.8.0.0/24"])])
        traffic["home"] = demoSamples
        since["home"] = now.addingTimeInterval(-(3600 * 2 + 1260))
        // A second tunnel up at the same time, to show multi-tunnel views.
        statuses["office"] = TunnelStatus(name: "office", interface: "utun8", peers: [
            PeerStatus(publicKey: peers[1], endpoint: "198.51.100.20:51820",
                       latestHandshake: now.addingTimeInterval(-41),
                       rxBytes: 52_300_000, txBytes: 8_900_000, allowedIPs: ["10.20.0.0/16"])])
        traffic["office"] = demoSamples.map { TrafficSample(date: $0.date, rx: $0.rx * 0.2, tx: $0.tx * 0.3) }
        since["office"] = now.addingTimeInterval(-1800)
        failures["tokyo-vps"] = "wireguard-go failed: control socket for utun9 did not appear"
        quality.enabled = true
        qualitySamples["home"] = (0..<60).map { i -> QualitySample in
            let t = Double(i)
            let spike: Double = i % 17 == 0 ? 40 : 0
            let rtt: Double = 24 + 8 * sin(t / 4) + spike
            let loss: Double = i % 23 == 0 ? 33 : 0
            return QualitySample(date: now.addingTimeInterval(-600 + t * 10), rtt: rtt, loss: loss)
        }
        qualitySamples["office"] = (0..<60).map { i -> QualitySample in
            let t = Double(i)
            let rtt: Double = 170 + Double(i % 7) * 9
            let loss: Double = i % 5 == 0 ? 33 : 0
            return QualitySample(date: now.addingTimeInterval(-600 + t * 10), rtt: rtt, loss: loss)
        }
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
