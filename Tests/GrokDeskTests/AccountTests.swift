import XCTest
@testable import GrokDeskCore

final class AccountTests: XCTestCase {
    func testReadsNameAndEmailAndDropsSecrets() {
        let raw = #"{"https://auth.x.ai::client":{"email":"ada@example.com","first_name":"Ada","key":"secret-token","refresh_token":"nope"}}"#
        let account = parseAccount(Data(raw.utf8))
        XCTAssertTrue(account.ok)
        XCTAssertEqual(account.name, "Ada")
        XCTAssertEqual(account.email, "ada@example.com")
        XCTAssertEqual(account.initials, "AD")
        XCTAssertFalse(account.message.contains("secret"))
    }

    func testParsesPluginRows() {
        let items = parseJsonList(#"[{"name":"superpowers","enabled":true,"scope":"user","path":"/tmp/p"}]"#)
        XCTAssertEqual(items.map(\.name), ["superpowers"])
        XCTAssertEqual(items.first?.detail, "/tmp/p")
    }
}
