import XCTest
@testable import GrokDeskCore

final class ChatBrowserTests: XCTestCase {
    func testEachChatKeepsItsOwnBrowser() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        ChatBrowserStore.save("a", ChatBrowserState(open: true, url: "https://example.com"), defaults: defaults)
        ChatBrowserStore.save("b", ChatBrowserState(), defaults: defaults)
        XCTAssertTrue(ChatBrowserStore.load("a", defaults: defaults).open)
        XCTAssertEqual(ChatBrowserStore.load("a", defaults: defaults).url, "https://example.com")
        XCTAssertFalse(ChatBrowserStore.load("b", defaults: defaults).open)
        XCTAssertEqual(ChatBrowserStore.load("missing", defaults: defaults).open, false)
        XCTAssertEqual(ChatBrowserStore.load("missing", defaults: defaults).tabs.count, 1)
    }

    func testOlderSavedBrowserBecomesOneTab() throws {
        let raw = #"{"open":true,"url":"https://example.com"}"#
        let state = try JSONDecoder().decode(ChatBrowserState.self, from: Data(raw.utf8))
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.tabs[0].url, "https://example.com")
        XCTAssertEqual(state.activeTabID, state.tabs[0].id)
    }

    func testAddressAcceptsWebURLsOnly() {
        XCTAssertEqual(ChatBrowserStore.address(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(ChatBrowserStore.address(from: "http://127.0.0.1:4000")?.scheme, "http")
        XCTAssertEqual(ChatBrowserStore.address(from: "localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(ChatBrowserStore.address(from: "signup form")?.host, "www.google.com")
        XCTAssertNil(ChatBrowserStore.address(from: "file:///etc/passwd"))
        XCTAssertNil(ChatBrowserStore.address(from: "javascript:alert(1)"))
    }
}
