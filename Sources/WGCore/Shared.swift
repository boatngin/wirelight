import Foundation

/// What an admin allows other users to do with a shared tunnel.
public struct SharePolicy: Codable, Equatable, Sendable {
    public var usersCanConnect: Bool
    public var usersCanDisconnect: Bool

    public init(usersCanConnect: Bool = true, usersCanDisconnect: Bool = true) {
        self.usersCanConnect = usersCanConnect; self.usersCanDisconnect = usersCanDisconnect
    }
}

/// A shared tunnel as any local user sees it: no keys, no config text.
public struct SharedTunnelInfo: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var endpoint: String?
    public var addresses: [String]
    public var policy: SharePolicy
    public var id: String { name }

    public init(name: String, endpoint: String?, addresses: [String], policy: SharePolicy) {
        self.name = name; self.endpoint = endpoint; self.addresses = addresses; self.policy = policy
    }
}
