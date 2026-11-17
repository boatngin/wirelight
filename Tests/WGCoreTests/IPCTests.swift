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

final class ViaOptionTests: XCTestCase {
    func testViaValidatedAndOptional() throws {
        XCTAssertNil(UpOptions(via: "home").validationError())
        XCTAssertNotNil(UpOptions(via: "../x").validationError())
        let old = try JSONDecoder().decode(UpOptions.self, from: Data(#"{"splitDNSDomains":[],"excludedCIDRs":[]}"#.utf8))
        XCTAssertNil(old.via)
    }
}

final class SharedRequestTests: XCTestCase {
    func testStandardUserRequestSet() {
        XCTAssertTrue(Request.upShared(name: "office").allowedForStandardUsers)
        XCTAssertTrue(Request.listShared.allowedForStandardUsers)
        XCTAssertFalse(Request.up(name: "x", config: "").allowedForStandardUsers)
        XCTAssertFalse(Request.shareTunnel(name: "x", config: "", options: UpOptions(), policy: SharePolicy()).allowedForStandardUsers)
        XCTAssertFalse(Request.applyPlace(nil).allowedForStandardUsers)
        XCTAssertFalse(Request.refresh.allowedForStandardUsers)
    }

    func testResponseWithoutSharedDecodes() throws {
        let r = try JSONDecoder().decode(Response.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(r.shared)
    }
}

final class SharePolicyRequestTests: XCTestCase {
    func testPolicyChangeIsAdminOnly() {
        XCTAssertFalse(Request.setSharePolicy(name: "x", policy: SharePolicy()).allowedForStandardUsers)
    }
}
