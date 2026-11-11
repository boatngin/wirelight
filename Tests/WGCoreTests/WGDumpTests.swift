import XCTest
@testable import WGCore

final class WGDumpTests: XCTestCase {
    func testParsePeersSkipsInterfaceLine() {
        let dump = [
            "\(privA)\tUw6SpKDvoZIawVvCNlXqkeaYQ8N4CguZXSHT/19BTFs=\t0\toff",
            "\(pubB)\t(none)\t203.0.113.5:51820\t192.168.1.0/24,10.0.0.0/24\t1700000000\t1234\t5678\t25",
            "\(pubC)\t(none)\t(none)\t(none)\t0\t0\t0\toff",
        ].joined(separator: "\n")
        let peers = WGDump.parsePeers(dump)
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers[0].publicKey, pubB)
        XCTAssertEqual(peers[0].endpoint, "203.0.113.5:51820")
        XCTAssertEqual(peers[0].allowedIPs, ["192.168.1.0/24", "10.0.0.0/24"])
        XCTAssertEqual(peers[0].latestHandshake, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(peers[0].rxBytes, 1234)
        XCTAssertEqual(peers[0].txBytes, 5678)
        XCTAssertNil(peers[1].endpoint)
        XCTAssertNil(peers[1].latestHandshake)
        XCTAssertEqual(peers[1].allowedIPs, [])
        XCTAssertFalse(peers.contains { $0.publicKey == privA })
    }
}
