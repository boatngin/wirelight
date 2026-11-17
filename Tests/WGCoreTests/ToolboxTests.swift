import XCTest
@testable import WGCore

final class ToolboxTests: XCTestCase {
    func testServerRejectsOptionInjection() {
        XCTAssertTrue(SSHForward.isValidServer("me@bastion.example.com"))
        XCTAssertTrue(SSHForward.isValidServer("homelab"))
        XCTAssertFalse(SSHForward.isValidServer("-oProxyCommand=evil"))
        XCTAssertFalse(SSHForward.isValidServer("a b"))
        XCTAssertFalse(SSHForward.isValidServer("a@b@c"))
        XCTAssertFalse(SSHForward.isValidServer("host;rm"))
    }

    func testArgumentsBindLoopbackAndEndOptions() {
        let f = SSHForward(name: "db", kind: .local, server: "me@h", sshPort: 2222, listenPort: 5433,
                           targetHost: "10.0.0.5", targetPort: 5432)
        let a = f.sshArguments()
        XCTAssertTrue(a.contains("BatchMode=yes"))
        XCTAssertEqual(Array(a.suffix(2)), ["--", "me@h"])
        XCTAssertTrue(a.contains("127.0.0.1:5433:10.0.0.5:5432"))
        XCTAssertTrue(a.contains("2222"))
        var s = f; s.kind = .socks
        XCTAssertTrue(s.sshArguments().contains("127.0.0.1:5433"))
        XCTAssertNil(f.validationError())
        var bad = f; bad.targetHost = "x y"
        XCTAssertNotNil(bad.validationError())
    }

    func testMagicPacket() {
        let p = WakeOnLAN.packet(mac: "AA:bb:cc:01:02:03")!
        XCTAssertEqual(p.count, 102)
        XCTAssertEqual(Array(p.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(p[6..<12]), [0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03])
        XCTAssertEqual(Array(p.suffix(6)), [0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03])
        XCTAssertNil(WakeOnLAN.packet(mac: "aa:bb:cc"))
        XCTAssertNil(WakeOnLAN.packet(mac: "zz:bb:cc:01:02:03"))
    }
}
