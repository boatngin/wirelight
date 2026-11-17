import XCTest
@testable import WGCore

final class ConfigLintTests: XCTestCase {
    let priv = "aJZAOjSd91Y8ZUTmknBlNoqDd/yEMhr6u+lNsOSQ7Xo="
    let peer = "hmSEV1i3X4AQyQpOeoMwt2DQEa+0nu5ZS3v5JSSrYFQ="

    func conf(_ iface: String, _ p: String) -> String {
        "[Interface]\nPrivateKey = \(priv)\n\(iface)\n[Peer]\nPublicKey = \(peer)\n\(p)\n"
    }

    func testCleanConfigHasNoIssues() {
        let t = conf("Address = 10.0.0.2/32\nDNS = 10.0.0.1",
                     "Endpoint = vpn.example.com:51820\nAllowedIPs = 10.0.0.0/24\nPersistentKeepalive = 25")
        XCTAssertEqual(ConfigLint.check(t), [])
    }

    func testParserErrorKeepsLineNumber() {
        let issues = ConfigLint.check(conf("Address = 10.0.0.2/32\nPostUp = rm -rf /", "AllowedIPs = 10.0.0.0/24"))
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.first?.line, 4)
    }

    func testRouteAllWarnings() {
        let issues = ConfigLint.check(conf("Address = 10.0.0.2/32", "Endpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25"))
        let msgs = issues.map(\.message)
        XCTAssertTrue(msgs.contains { $0.contains("no IPv6 address") })
        XCTAssertTrue(msgs.contains { $0.contains("sets no DNS") })
        XCTAssertTrue(issues.allSatisfy { $0.severity != .error })
    }

    func testHostBitsAndSelfPeer() {
        let selfPub = WGKey.publicKey(fromPrivate: priv)!
        let t = "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = \(selfPub)\nEndpoint = 1.2.3.4:1\nAllowedIPs = 10.0.0.5/24\nPersistentKeepalive = 25\n"
        let issues = ConfigLint.check(t)
        XCTAssertTrue(issues.contains { $0.message == "The peer is this device" && $0.line == 5 })
        XCTAssertTrue(issues.contains { $0.message.contains("host bits") && $0.hint.contains("10.0.0.0/24") })
    }

    func testGeneratedKeysAreValid() {
        let k = WGKey.generatePrivate()
        XCTAssertTrue(Validation.isValidKey(k))
        XCTAssertTrue(Validation.isValidKey(WGKey.publicKey(fromPrivate: k)!))
        XCTAssertTrue(Validation.isValidKey(WGKey.generatePreshared()))
        XCTAssertNotEqual(WGKey.generatePrivate(), k)
    }
}

final class AmneziaConfigTests: XCTestCase {
    let base = "[Interface]\nPrivateKey = aJZAOjSd91Y8ZUTmknBlNoqDd/yEMhr6u+lNsOSQ7Xo=\nAddress = 10.0.0.2/32\n"
    let peer = "[Peer]\nPublicKey = hmSEV1i3X4AQyQpOeoMwt2DQEa+0nu5ZS3v5JSSrYFQ=\nAllowedIPs = 0.0.0.0/0\n"

    func testParsesAndRoundTrips() throws {
        let cfg = try WGConfig(parsing: base + "Jc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nH1 = 100-200\nI1 = <b 0x0a0b><r 16>\n" + peer)
        XCTAssertTrue(cfg.interface.isAmnezia)
        XCTAssertEqual(cfg.interface.amnezia["H1"], "100-200")
        XCTAssertEqual(try WGConfig(parsing: cfg.wgQuickText()), cfg)
        XCTAssertTrue(cfg.wgSetconfText().contains("Jc = 4"))
    }

    func testRejectsBadValues() {
        XCTAssertThrowsError(try WGConfig(parsing: base + "Jc = lots\n" + peer))
        XCTAssertThrowsError(try WGConfig(parsing: base + "I1 = <b 0x0a>\nPostUp = x\n" + peer))
        XCTAssertThrowsError(try WGConfig(parsing: base + "I1 = a=b\n" + peer))
        XCTAssertFalse(try WGConfig(parsing: base + peer).interface.isAmnezia)
    }
}
