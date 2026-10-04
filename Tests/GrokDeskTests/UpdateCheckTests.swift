import XCTest
@testable import GrokDeskCore

final class UpdateCheckTests: XCTestCase {
    func testHiddenWhenCurrent() throws {
        let raw = #"{"currentVersion":"1.0.46","latestVersion":"1.0.46","updateAvailable":false,"installer":"internal","channel":"stable","autoUpdate":true,"error":null}"#
        let check = try decodeUpdateCheck(Data(raw.utf8))
        XCTAssertNil(updateButtonTitle(check))
    }

    func testTitleWhenUpdateAvailable() throws {
        let raw = #"{"currentVersion":"1.0.46","latestVersion":"1.0.47","updateAvailable":true,"installer":"internal","channel":"stable","autoUpdate":true,"error":null}"#
        let check = try decodeUpdateCheck(Data(raw.utf8))
        XCTAssertEqual(updateButtonTitle(check), "Update Grok to 1.0.47")
    }

    func testHiddenWhenCheckErrors() throws {
        let raw = #"{"currentVersion":"1.0.46","latestVersion":"1.0.47","updateAvailable":true,"installer":"internal","channel":"stable","autoUpdate":true,"error":"offline"}"#
        let check = try decodeUpdateCheck(Data(raw.utf8))
        XCTAssertNil(updateButtonTitle(check))
    }
}
