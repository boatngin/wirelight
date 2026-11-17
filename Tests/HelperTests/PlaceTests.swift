import XCTest
import WGCore
@testable import wgbar_helper

final class PlaceTests: XCTestCase {
    func testParseProxyServer() {
        let s = ProxyState.parseServer("Enabled: Yes\nServer: proxy.lan\nPort: 3128\nAuthenticated Proxy Enabled: 0\n")
        XCTAssertEqual(s, ProxyServer(host: "proxy.lan", port: 3128, enabled: true))
        XCTAssertNil(ProxyState.parseServer("Enabled: No\nServer: \nPort: 0\n"))
    }

    func testParsePAC() {
        let p = ProxyState.parsePAC("URL: http://wpad/proxy.pac\nEnabled: Yes\n")
        XCTAssertEqual(p.url, "http://wpad/proxy.pac")
        XCTAssertTrue(p.enabled)
        XCTAssertNil(ProxyState.parsePAC("URL: (null)\nEnabled: No\n").url)
    }

    func testSettingToState() {
        let st = ProxyState(ProxySetting(mode: .manual, http: "proxy.lan:3128", socks: "[2001:db8::1]:1080", bypass: ["*.local"]))
        XCTAssertEqual(st.web, ProxyServer(host: "proxy.lan", port: 3128, enabled: true))
        XCTAssertEqual(st.socks?.host, "2001:db8::1")
        XCTAssertNil(st.secure)
        XCTAssertFalse(st.pacEnabled)
        XCTAssertTrue(ProxyState(ProxySetting(mode: .auto, pacURL: "http://x/p.pac")).pacEnabled)
        XCTAssertNil(ProxyState(ProxySetting(mode: .off)).web)
    }
}
