import XCTest
@testable import WGCore

final class PlaceholderTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(WGCore.version.isEmpty)
    }
}
