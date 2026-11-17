import XCTest
@testable import wgbar_helper

final class PFGuardTests: XCTestCase {
    func testRulesPassEveryTunnelInterface() {
        let r = PFGuard.rules(utuns: ["utun4", "utun7"], endpointIPs: ["203.0.113.1"])
        XCTAssertTrue(r.contains("pass quick on utun4 all"))
        XCTAssertTrue(r.contains("pass quick on utun7 all"))
        XCTAssertTrue(r.contains("pass quick to 203.0.113.1"))
        XCTAssertTrue(r.hasSuffix("block drop quick all\n"))
    }

    func testRulesDropInvalidInterfaceNames() {
        let r = PFGuard.rules(utuns: ["utun1; pass all", "en0"], endpointIPs: ["not-an-ip"])
        XCTAssertFalse(r.contains("en0"))
        XCTAssertFalse(r.contains("pass all"))
        XCTAssertFalse(r.contains("not-an-ip"))
    }
}

final class RouteEntryTests: XCTestCase {
    func testBlackholeRouteTargetsLoopback() {
        let r = RouteEntry(family: "inet6", destination: "::/1", blackhole: true)
        XCTAssertEqual(r.targetArgs, ["::1", "-blackhole"])
    }

    func testGatewayRouteUnchanged() {
        XCTAssertEqual(RouteEntry(family: "inet", destination: "1.2.3.4", gateway: "192.168.1.1").targetArgs, ["192.168.1.1"])
        XCTAssertEqual(RouteEntry(family: "inet", destination: "1.2.3.4", interface: "en0").targetArgs, ["-interface", "en0"])
    }
}
