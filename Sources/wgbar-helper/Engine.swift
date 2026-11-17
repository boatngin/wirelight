import Foundation

/// WireGuard or AmneziaWG. A running interface's engine is whichever runtime folder
/// holds its control socket, so the right control tool is found per interface.
enum Engine {
    static let wireguardRunDir = "/var/run/wireguard"
    static let amneziaRunDir = "/var/run/amneziawg"

    static func isAmnezia(_ utun: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(amneziaRunDir)/\(utun).sock")
    }

    /// `awg` for AmneziaWG interfaces, `wg` otherwise.
    static func ctl(_ utun: String) -> Tool { isAmnezia(utun) ? .awg : .wg }

    static func socket(_ utun: String) -> String {
        "\(isAmnezia(utun) ? amneziaRunDir : wireguardRunDir)/\(utun).sock"
    }
}
