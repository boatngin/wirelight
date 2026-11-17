import Foundation
import XCTest
@testable import WGCore

final class ValidationTests: XCTestCase {
    func testValidKeys() {
        for byte: UInt8 in [0, 127, 255] {
            let key = Data(repeating: byte, count: 32).base64EncodedString()
            XCTAssertTrue(Validation.isValidKey(key), key)
        }
    }

    func testInvalidKeys() {
        let valid = Data(repeating: 0, count: 32).base64EncodedString()
        let invalid = [
            "", "not a key", String(valid.dropLast()), valid + "=",
            Data(repeating: 0, count: 31).base64EncodedString(),
            Data(repeating: 0, count: 33).base64EncodedString(),
            String(repeating: "!", count: 43) + "=",
            String(repeating: "_", count: 43) + "=",
        ]
        for value in invalid { XCTAssertFalse(Validation.isValidKey(value), value.debugDescription) }
    }

    func testValidIPv4Addresses() {
        for value in ["0.0.0.0", "127.0.0.1", "192.0.2.1", "192.00.2.1", "255.255.255.255"] {
            XCTAssertTrue(Validation.isValidIPv4(value), value)
        }
    }

    func testInvalidIPv4Addresses() {
        for value in [
            "", "127.1", "192.0.2", "256.0.0.1", "192.0.2.256",
            "192.0.2.1.", ".192.0.2.1", " 192.0.2.1", "192.0.2.1\n",
            "192.0.2.1/24", "::1", "192.0.2.1\0", "192.0.2.1\0ignored",
        ] {
            XCTAssertFalse(Validation.isValidIPv4(value), value.debugDescription)
        }
    }

    func testValidIPv6Addresses() {
        for value in ["::", "::1", "2001:db8::1", "2001:db8:0:1:2:3:4:5", "::ffff:192.0.2.1", "fe80::1%en0"] {
            XCTAssertTrue(Validation.isValidIPv6(value), value)
        }
    }

    func testInvalidIPv6Addresses() {
        for value in [
            "", "192.0.2.1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "2001:db8::g",
            "2001::db8::1", "[::1]", "::1/128", " ::1", "::1\n",
            "::1\0", "::1\0ignored",
        ] {
            XCTAssertFalse(Validation.isValidIPv6(value), value.debugDescription)
        }
    }

    func testIPAcceptsBothAddressFamilies() {
        for value in ["192.0.2.1", "2001:db8::1", "::ffff:192.0.2.1", "fe80::1%en0"] {
            XCTAssertTrue(Validation.isValidIP(value), value)
        }
    }

    func testIPRejectsNonAddresses() {
        for value in ["", "vpn.example.com", "256.0.0.1", "[::1]", "::1\0ignored"] {
            XCTAssertFalse(Validation.isValidIP(value), value.debugDescription)
        }
    }

    func testCIDRPrefixBoundaries() {
        for value in ["0.0.0.0/0", "192.0.2.1/32", "::/0", "2001:db8::1/128", "fe80::1%en0/64"] {
            XCTAssertTrue(Validation.isValidCIDR(value), value)
        }
    }

    func testInvalidCIDRs() {
        for value in [
            "", "192.0.2.1", "::1", "192.0.2.1/33", "::1/129", "192.0.2.1/-1", "::1/-1",
            "192.0.2.1/", "/24", "192.0.2.1/24/1", "256.0.0.1/24", "[::1]/128",
            "192.0.2.1/+24", "192.0.2.1/024", "192.0.2.1/ 24", "192.0.2.1/24\n",
            "192.0.2.1\0ignored/24", "::1\0ignored/64",
        ] {
            XCTAssertFalse(Validation.isValidCIDR(value), value.debugDescription)
        }
    }

    func testValidHostnames() {
        let label = String(repeating: "a", count: 63)
        let longest = [label, label, label, String(repeating: "b", count: 61)].joined(separator: ".")
        for value in ["localhost", "vpn.example.com", "VPN.Example.COM", "a-b.example", "example.com.", label, longest] {
            XCTAssertTrue(Validation.isValidHostname(value), value)
        }
    }

    func testInvalidHostnames() {
        let label = String(repeating: "a", count: 63)
        let tooLong = [label, label, label, String(repeating: "b", count: 62)].joined(separator: ".")
        for value in [
            "", ".", ".example.com", "example..com", "-example.com", "example-.com", "bad_host!",
            "a b", "café.example", String(repeating: "a", count: 64), tooLong,
            "example.com\n", "example.com\r\n", "example.com\0ignored",
        ] {
            XCTAssertFalse(Validation.isValidHostname(value), value.debugDescription)
        }
    }

    func testValidPortBoundaries() {
        for value in ["1", "80", "51820", "65535"] { XCTAssertTrue(Validation.isValidPort(value), value) }
    }

    func testInvalidPorts() {
        for value in ["", "0", "65536", "-1", "+80", "080", " 80", "80 ", "80\n", "80.0", "http", String(repeating: "9", count: 30)] {
            XCTAssertFalse(Validation.isValidPort(value), value.debugDescription)
        }
    }

    func testValidEndpoints() {
        for value in ["vpn.example.com:51820", "localhost:1", "example.com.:65535", "1.2.3.4:51820", "[::1]:51820", "[2001:db8::1]:65535", "[fe80::1%en0]:51820"] {
            XCTAssertTrue(Validation.isValidEndpoint(value), value)
        }
    }

    func testInvalidEndpoints() {
        for value in [
            "", "host", "host:", ":80", "host:0", "host:65536", "host:080", "host:80\n", "bad_host!:80",
            "::1:51820", "[::1]", "[::1]51820", "[::1]:", "[::1]:0", "[::1]:65536", "[::1]:80:90",
            "[::1", "[]:80", "[192.0.2.1]:80", "https://example.com:443",
            "example.com\n:80", "192.0.2.1\0ignored:80", "[::1\0ignored]:80",
        ] {
            XCTAssertFalse(Validation.isValidEndpoint(value), value.debugDescription)
        }
    }

    func testValidTunnelNames() {
        for value in ["a", "home", "oci_tokyo-1", String(repeating: "a", count: 15)] {
            XCTAssertTrue(Validation.isValidTunnelName(value), value)
        }
    }

    func testInvalidTunnelNames() {
        for value in [
            "", String(repeating: "a", count: 16), "this-name-is-too-long", "café", "隧道", "a b", "../etc", "a/b",
            "x;rm", "$(id)", "a|b", "home\n", "home\r\n", "home\0ignored",
        ] {
            XCTAssertFalse(Validation.isValidTunnelName(value), value.debugDescription)
        }
    }
}
