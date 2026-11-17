import Foundation

extension CIDR {
    /// True when two CIDRs of the same family share any address.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "/"), pb = b.split(separator: "/")
        guard pa.count == 2, pb.count == 2, let la = Int(pa[1]), let lb = Int(pb[1]) else { return false }
        // The wider range contains the narrower one's network address iff they overlap.
        return la <= lb ? contains(a, String(pb[0])) : contains(b, String(pa[0]))
    }
}
