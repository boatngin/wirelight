import XCTest
@testable import WGCore

final class ValidationTests: XCTestCase {
    func testValidSSIDs() {
        XCTAssertTrue(Validation.isValidSSID("a"))
        XCTAssertTrue(Validation.isValidSSID("HomeWiFi"))
        XCTAssertTrue(Validation.isValidSSID("Cafe-5G"))           // case-sensitive, kept as typed
        XCTAssertTrue(Validation.isValidSSID("Café"))               // multibyte counts as bytes
        XCTAssertTrue(Validation.isValidSSID(String(repeating: "x", count: 32)))
    }

    func testInvalidSSIDs() {
        XCTAssertFalse(Validation.isValidSSID(""))
        XCTAssertFalse(Validation.isValidSSID(String(repeating: "x", count: 33)))
        XCTAssertFalse(Validation.isValidSSID("bad\nname"))
        XCTAssertFalse(Validation.isValidSSID("tab\there"))
    }

    func testSSIDByteLimitCountsUTF8() {
        // 16 two-byte scalars = 32 bytes: allowed. 17 = 34 bytes: rejected.
        XCTAssertTrue(Validation.isValidSSID(String(repeating: "é", count: 16)))
        XCTAssertFalse(Validation.isValidSSID(String(repeating: "é", count: 17)))
    }
}
