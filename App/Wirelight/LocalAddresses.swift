import Darwin
import Foundation

/// Addresses on this Mac's physical interfaces (tunnels and loopback left out).
enum LocalAddresses {
    static func current() -> [String] { all().map(\.address).sorted() }

    /// A global unicast IPv6 address (2000::/3) on a non-tunnel interface.
    static func hasGlobalIPv6() -> Bool {
        all().contains { $0.v6 && ["2", "3"].contains($0.address.prefix(1)) }
    }

    /// Addresses on the named interfaces (e.g. the wired Ethernet ports).
    static func addresses(on names: [String]) -> [String] {
        names.isEmpty ? [] : all().filter { names.contains($0.interface) }.map(\.address).sorted()
    }

    private static func all() -> [(address: String, v6: Bool, interface: String)] {
        var out: [(String, Bool, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p?.pointee {
            defer { p = ifa.ifa_next }
            let name = String(cString: ifa.ifa_name)
            guard let sa = ifa.ifa_addr, !name.hasPrefix("utun"), !name.hasPrefix("lo"),
                  [AF_INET, AF_INET6].contains(Int32(sa.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            if addr.lowercased().hasPrefix("fe80") { continue }
            out.append((addr, sa.pointee.sa_family == AF_INET6, name))
        }
        return out
    }
}
