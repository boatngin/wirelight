import Foundation

/// An SSH port forward kept up by the app with the user's own keys and agent.
public struct SSHForward: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// -L: a port on this Mac reaches a host:port behind the server.
        case local
        /// -R: a port on the server reaches a host:port on this side.
        case remote
        /// -D: a SOCKS5 proxy on this Mac that exits at the server.
        case socks
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// `host`, `user@host` or an ~/.ssh/config alias.
    public var server: String
    public var sshPort: Int?
    public var listenPort: Int
    public var targetHost: String
    public var targetPort: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind = .local, server: String = "", sshPort: Int? = nil,
                listenPort: Int = 8080, targetHost: String = "127.0.0.1", targetPort: Int = 80, enabled: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.server = server; self.sshPort = sshPort
        self.listenPort = listenPort; self.targetHost = targetHost; self.targetPort = targetPort; self.enabled = enabled
    }

    /// `user@host` or `host`: letters, digits, `._-`, one optional `@`, never starting with `-`
    /// (which ssh would read as an option).
    public static func isValidServer(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-") else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-@".contains($0)) }
    }

    public func validationError() -> String? {
        guard Self.isValidServer(server) else { return "Server must be host, user@host or an ssh config alias" }
        guard (1...65535).contains(listenPort), sshPort.map({ (1...65535).contains($0) }) ?? true else { return "Ports are 1–65535" }
        if kind != .socks {
            guard Validation.isValidIP(targetHost) || Validation.isValidHostname(targetHost) else { return "Target must be a host name or IP" }
            guard (1...65535).contains(targetPort) else { return "Ports are 1–65535" }
        }
        return nil
    }

    /// Arguments for /usr/bin/ssh. Keys only (BatchMode: never a password prompt);
    /// local listeners bind to loopback so the LAN can't use them.
    public func sshArguments() -> [String] {
        var a = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if let p = sshPort { a += ["-p", String(p)] }
        let target = targetHost.contains(":") ? "[\(targetHost)]" : targetHost
        switch kind {
        case .local: a += ["-L", "127.0.0.1:\(listenPort):\(target):\(targetPort)"]
        case .remote: a += ["-R", "127.0.0.1:\(listenPort):\(target):\(targetPort)"]
        case .socks: a += ["-D", "127.0.0.1:\(listenPort)"]
        }
        return a + ["--", server]
    }
}

/// A machine to wake with a magic packet.
public struct WakeDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mac: String
    /// Usually the LAN's broadcast address, e.g. 192.168.1.255.
    public var broadcast: String

    public init(id: UUID = UUID(), name: String, mac: String, broadcast: String = "255.255.255.255") {
        self.id = id; self.name = name; self.mac = mac; self.broadcast = broadcast
    }
}

public enum WakeOnLAN {
    /// Six 0xFF bytes followed by the MAC sixteen times; nil for a malformed MAC.
    public static func packet(mac: String) -> Data? {
        let hex = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard hex.count == 6 else { return nil }
        let bytes = hex.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard bytes.count == 6 else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }
}
