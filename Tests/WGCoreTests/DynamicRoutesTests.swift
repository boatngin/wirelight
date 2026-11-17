import XCTest
@testable import WGCore

final class DynamicRoutesTests: XCTestCase {
    func testAcceptsNormalRanges() {
        XCTAssertNil(DynamicRoutes.problem("10.20.0.0/16"))
        XCTAssertNil(DynamicRoutes.problem("203.0.113.7"))
        XCTAssertNil(DynamicRoutes.problem("2001:db8:1::/48"))
        XCTAssertEqual(DynamicRoutes.normalize("203.0.113.7"), "203.0.113.7/32")
    }

    func testRefusesBroadAndSpecial() {
        XCTAssertNotNil(DynamicRoutes.problem("0.0.0.0/0"))
        XCTAssertNotNil(DynamicRoutes.problem("10.0.0.0/7"))
        XCTAssertNotNil(DynamicRoutes.problem("127.0.0.1"))
        XCTAssertNotNil(DynamicRoutes.problem("169.254.1.1"))
        XCTAssertNotNil(DynamicRoutes.problem("224.0.0.1"))
        XCTAssertNotNil(DynamicRoutes.problem("::/0"))
        XCTAssertNotNil(DynamicRoutes.problem("fe80::1"))
        XCTAssertNotNil(DynamicRoutes.problem("2001::/16"))
        XCTAssertNotNil(DynamicRoutes.problem("example.com"))
    }

    func testParseMixedOutput() {
        let r = DynamicRoutes.parse("# from inventory\n10.1.0.0/16, 10.2.3.4\n\n127.0.0.1 10.1.0.0/16  # dup\nbogus\n")
        XCTAssertEqual(r.routes, ["10.1.0.0/16", "10.2.3.4/32"])
        XCTAssertEqual(r.rejected.map(\.0), ["127.0.0.1", "bogus"])
    }
}
