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
