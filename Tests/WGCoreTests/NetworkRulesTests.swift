import XCTest
@testable import WGCore

final class NetworkRulesTests: XCTestCase {
    func testCIDRContains() {
        XCTAssertTrue(CIDR.contains("192.168.1.0/24", "192.168.1.77"))
        XCTAssertFalse(CIDR.contains("192.168.1.0/24", "192.168.2.1"))
        XCTAssertTrue(CIDR.contains("10.0.0.0/8", "10.255.0.1"))
        XCTAssertTrue(CIDR.contains("0.0.0.0/0", "8.8.8.8"))
        XCTAssertTrue(CIDR.contains("2001:db8::/32", "2001:db8:1::5"))
        XCTAssertFalse(CIDR.contains("2001:db8::/32", "192.168.1.1"))
        XCTAssertFalse(CIDR.contains("garbage", "1.1.1.1"))
    }

    func testFirstMatchWinsAndFallback() {
        let rules = [NetworkRule(kind: .wifi, values: ["Home"], action: .disconnect),
                     NetworkRule(kind: .ethernet, values: ["10.20.0.0/16"], action: .connect)]
        XCTAssertEqual(NetworkRules.decide(rules, fallback: .connect, on: .init(wifiSSID: "Home"))?.action, .disconnect)
        XCTAssertEqual(NetworkRules.decide(rules, fallback: .connect, on: .init(wifiSSID: "Cafe"))?.rule, nil)
        XCTAssertEqual(NetworkRules.decide(rules, fallback: .connect, on: .init(wifiSSID: "Cafe"))?.action, .connect)
        XCTAssertEqual(NetworkRules.decide(rules, fallback: nil, on: .init(ethernetAddresses: ["10.20.3.4"]))?.rule, 1)
        XCTAssertNil(NetworkRules.decide(rules, fallback: nil, on: .init(ethernetAddresses: ["192.168.9.9"])))
        XCTAssertNil(NetworkRules.decide(rules, fallback: .connect, on: .init()))
    }

    func testEmptyValuesMatchAny() {
        XCTAssertTrue(NetworkRule(kind: .wifi, action: .connect).matches(.init(wifiSSID: "x")))
        XCTAssertFalse(NetworkRule(kind: .wifi, action: .connect).matches(.init(ethernetAddresses: ["1.2.3.4"])))
        XCTAssertTrue(NetworkRule(kind: .ethernet, action: .connect).matches(.init(ethernetAddresses: ["fe80::1%en5"])))
    }
}
