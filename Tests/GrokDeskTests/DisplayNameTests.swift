import XCTest
@testable import GrokDeskCore

final class DisplayNameTests: XCTestCase {
    func testFastSuffixBecomesFastLabel() {
        XCTAssertEqual(displayName(for: "grok-4.7-build-fast"), "Grok 4.7 Fast")
    }

    func testPlainGrokIdKeepsTheVersion() {
        XCTAssertEqual(displayName(for: "grok-4.6"), "Grok 4.6")
    }

    func testUnknownIdStillDropsThePrefix() {
        XCTAssertEqual(displayName(for: "grok-5"), "Grok 5")
    }
}
