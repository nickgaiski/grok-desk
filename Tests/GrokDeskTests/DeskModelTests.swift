import XCTest
@testable import GrokDeskCore

final class DeskModelTests: XCTestCase {
    @MainActor
    func testRefreshStoresSessionsModelsAndHidesTheButton() async throws {
        let check = #"{"currentVersion":"1.0.46","latestVersion":"1.0.46","updateAvailable":false,"error":null}"#
        let runner = ScriptedRunner([
            CommandResult(status: 0, stdout: "  * grok-4.7 (default)\n", stderr: ""),
            CommandResult(status: 0, stdout: check, stderr: ""),
        ])
        let model = DeskModel(runner: runner, leaderSocket: "/tmp/desk.sock", sessionsRoot: URL(fileURLWithPath: "/no/such"))
        await model.refresh()
        XCTAssertEqual(model.models.map(\.id), ["grok-4.7"])
        XCTAssertNil(model.updateTitle)
        XCTAssertFalse(model.modelsStale)
    }
}
