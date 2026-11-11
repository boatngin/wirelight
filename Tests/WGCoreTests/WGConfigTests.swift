import XCTest
@testable import WGCore

// Throwaway keys generated with `wg genkey` for tests only.
let privA = "aJZAOjSd91Y8ZUTmknBlNoqDd/yEMhr6u+lNsOSQ7Xo="
let pubB = "hmSEV1i3X4AQyQpOeoMwt2DQEa+0nu5ZS3v5JSSrYFQ="
let pubC = "v6jlChyb6k6nARaW+0zmEqB2GdLXK9ZTC2dtEAHrNV4="
let psk = "6zlg3U+9PxgeORCx5EAYPAIlcuzkWUN/7Zm0Z7rAuQQ="

final class WGConfigTests: XCTestCase {
    let sample = """
    # exported from OPNsense
    [Interface]
    PrivateKey = \(privA)
    Address = 10.10.10.2/32, fd00:10::2/128
    DNS = 192.168.1.1, home.lan
    MTU = 1420

    [Peer]
    PublicKey = \(pubB)
    PresharedKey = \(psk)
    Endpoint = vpn.example.com:51820
    AllowedIPs = 192.168.1.0/24, 10.10.10.0/24  # LAN
    PersistentKeepalive = 25
    """

    func testParseSample() throws {
        let c = try WGConfig(parsing: sample)
        XCTAssertEqual(c.interface.privateKey, privA)
        XCTAssertEqual(c.interface.addresses, ["10.10.10.2/32", "fd00:10::2/128"])
        XCTAssertEqual(c.interface.dns, ["192.168.1.1"])
        XCTAssertEqual(c.interface.dnsSearch, ["home.lan"])
        XCTAssertEqual(c.interface.mtu, 1420)
        XCTAssertEqual(c.peers.count, 1)
        XCTAssertEqual(c.peers[0].presharedKey, psk)
        XCTAssertEqual(c.peers[0].endpoint, "vpn.example.com:51820")
        XCTAssertEqual(c.peers[0].allowedIPs, ["192.168.1.0/24", "10.10.10.0/24"])
        XCTAssertEqual(c.peers[0].persistentKeepalive, 25)
    }

    func testNoDNS() throws {
        let c = try WGConfig(parsing: """
        [Interface]
        PrivateKey = \(privA)
        Address = 10.0.0.2/32
        [Peer]
        PublicKey = \(pubB)
        AllowedIPs = 10.0.0.0/24
        """)
        XCTAssertTrue(c.interface.dns.isEmpty)
        XCTAssertNil(c.peers[0].endpoint)
    }

    func testMultiplePeersAndIPv6() throws {
        let c = try WGConfig(parsing: """
        [interface]
        privatekey = \(privA)
        Address = fd00::2/64
        Address = 10.0.0.2/32
        DNS = 2001:4860:4860::8888
        [Peer]
        PublicKey = \(pubB)
        Endpoint = [2001:db8::1]:51820
        AllowedIPs = ::/0
        [Peer]
        PublicKey = \(pubC)
        Endpoint = 203.0.113.5:443
        AllowedIPs = 0.0.0.0/0
        """)
        XCTAssertEqual(c.interface.addresses, ["fd00::2/64", "10.0.0.2/32"])
        XCTAssertEqual(c.interface.dns, ["2001:4860:4860::8888"])
        XCTAssertEqual(c.peers.map(\.publicKey), [pubB, pubC])
        XCTAssertEqual(c.peers[0].endpoint, "[2001:db8::1]:51820")
    }

    func testRejectHooks() {
        for key in ["PostUp", "PreUp", "PostDown", "PreDown", "SaveConfig", "Table"] {
            let text = sample.replacingOccurrences(of: "MTU = 1420", with: "\(key) = rm -rf /")
            XCTAssertThrowsError(try WGConfig(parsing: text), key) { err in
                guard case .forbiddenKey = err as? WGConfigError else { return XCTFail("\(err)") }
            }
        }
    }

    func testRejectBadKey() {
        let text = sample.replacingOccurrences(of: pubB, with: "notakey")
        XCTAssertThrowsError(try WGConfig(parsing: text))
        let short = sample.replacingOccurrences(of: privA, with: "AAAA")
        XCTAssertThrowsError(try WGConfig(parsing: short))
    }

    func testRejectUnknownKeyAndBadValues() {
        XCTAssertThrowsError(try WGConfig(parsing: sample.replacingOccurrences(of: "MTU = 1420", with: "FwMark = 1")))
        XCTAssertThrowsError(try WGConfig(parsing: sample.replacingOccurrences(of: "192.168.1.0/24", with: "192.168.1.0/33")))
        XCTAssertThrowsError(try WGConfig(parsing: sample.replacingOccurrences(of: ":51820", with: ":99999")))
        XCTAssertThrowsError(try WGConfig(parsing: "[Interface]\nPrivateKey = \(privA)\nAddress = 10.0.0.2/32\n"))
    }

    func testWgQuickTextRoundTrips() throws {
        let c = try WGConfig(parsing: sample)
        XCTAssertEqual(try WGConfig(parsing: c.wgQuickText()), c)
    }

    func testSetconfTextStripsWgQuickKeys() throws {
        let out = try WGConfig(parsing: sample).wgSetconfText()
        XCTAssertFalse(out.contains("Address"))
        XCTAssertFalse(out.contains("DNS"))
        XCTAssertFalse(out.contains("MTU"))
        XCTAssertTrue(out.contains("PrivateKey = \(privA)"))
        XCTAssertTrue(out.contains("AllowedIPs = 192.168.1.0/24, 10.10.10.0/24"))
        XCTAssertTrue(out.contains("PersistentKeepalive = 25"))
    }
}

final class ValidationTests: XCTestCase {
    func testTunnelName() {
        XCTAssertTrue(Validation.isValidTunnelName("home"))
        XCTAssertTrue(Validation.isValidTunnelName("oci_tokyo-1"))
        XCTAssertFalse(Validation.isValidTunnelName(""))
        XCTAssertFalse(Validation.isValidTunnelName("this-name-is-too-long"))
        XCTAssertFalse(Validation.isValidTunnelName("../etc"))
        XCTAssertFalse(Validation.isValidTunnelName("a b"))
        XCTAssertFalse(Validation.isValidTunnelName("x;rm"))
    }

    func testEndpoint() {
        XCTAssertTrue(Validation.isValidEndpoint("1.2.3.4:51820"))
        XCTAssertTrue(Validation.isValidEndpoint("[::1]:51820"))
        XCTAssertFalse(Validation.isValidEndpoint("::1:51820"))
        XCTAssertFalse(Validation.isValidEndpoint("host"))
        XCTAssertFalse(Validation.isValidEndpoint("host:0"))
        XCTAssertFalse(Validation.isValidEndpoint("bad_host!:80"))
    }

    func testCIDR() {
        XCTAssertTrue(Validation.isValidCIDR("0.0.0.0/0"))
        XCTAssertTrue(Validation.isValidCIDR("::/0"))
        XCTAssertFalse(Validation.isValidCIDR("10.0.0.1"))
        XCTAssertFalse(Validation.isValidCIDR("fd00::/129"))
        XCTAssertFalse(Validation.isValidCIDR("10.0.0.0/-1"))
    }
}

final class IPCTests: XCTestCase {
    func testRoundTrip() throws {
        let reqs: [Request] = [.up(name: "home", config: "x"), .down(name: "home"), .status, .ping]
        for r in reqs { XCTAssertEqual(try IPCFraming.decode(Request.self, from: IPCFraming.encode(r)), r) }

        let resp = Response(ok: true, status: [TunnelStatus(name: "home", interface: "utun5", peers: [
            PeerStatus(publicKey: pubB, endpoint: "1.2.3.4:51820", latestHandshake: Date(timeIntervalSince1970: 1_700_000_000),
                       rxBytes: 1, txBytes: 2, allowedIPs: ["10.0.0.0/24"])])])
        let frame = try IPCFraming.encode(resp)
        XCTAssertEqual(try IPCFraming.length(fromHeader: frame), frame.count - 4)
        XCTAssertEqual(try IPCFraming.decode(Response.self, from: frame), resp)
    }

    func testOversizedHeaderRejected() {
        XCTAssertThrowsError(try IPCFraming.length(fromHeader: Data([0x7f, 0, 0, 0])))
    }
}
