import XCTest
@testable import WGCore

final class KillSwitchIPCTests: XCTestCase {
    func testUpOptionsKillSwitchDefaultsOff() {
        let o = UpOptions()
        XCTAssertFalse(o.killSwitch)
        XCTAssertNil(o.validationError())
    }

    func testUpOptionsWithKillSwitchRoundTrip() throws {
        let o = UpOptions(splitDNSDomains: ["lan"], excludedCIDRs: ["10.0.0.0/8"], killSwitch: true)
        let req = Request.upWithOptions(name: "home", config: "[Interface]", options: o)
        let frame = try IPCFraming.encode(req)
        XCTAssertEqual(try IPCFraming.decode(Request.self, from: frame), req)
    }

    func testSetKillSwitchRequestRoundTrip() throws {
        for enabled in [true, false] {
            let req = Request.setKillSwitch(name: "home", enabled: enabled)
            let frame = try IPCFraming.encode(req)
            XCTAssertEqual(try IPCFraming.decode(Request.self, from: frame), req)
        }
    }

    func testLegacyUpOptionsDecodeWithoutKillSwitch() throws {
        let json = #"{"splitDNSDomains":["lan"],"excludedCIDRs":[]}"#
        let o = try JSONDecoder().decode(UpOptions.self, from: Data(json.utf8))
        XCTAssertFalse(o.killSwitch)
    }
}
