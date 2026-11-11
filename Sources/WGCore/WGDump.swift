import Foundation

/// Parser for `wg show <if> dump`. Only peer lines (8 fields) are read,
/// so the interface line with the private key is never touched.
public enum WGDump {
    public static func parsePeers(_ text: String) -> [PeerStatus] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8, Validation.isValidKey(f[0]) else { return nil }
            let hs = UInt64(f[4]) ?? 0
            return PeerStatus(
                publicKey: f[0],
                endpoint: f[2] == "(none)" ? nil : f[2],
                latestHandshake: hs == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(hs)),
                rxBytes: UInt64(f[5]) ?? 0,
                txBytes: UInt64(f[6]) ?? 0,
                allowedIPs: f[3] == "(none)" ? [] : f[3].split(separator: ",").map(String.init)
            )
        }
    }
}
