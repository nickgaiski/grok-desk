import XCTest
@testable import GrokDeskCore

final class UpdateInstallerTests: XCTestCase {
    func testInstallStopsOwnedAgentThenUpdatesThenRechecks() async throws {
        let owned = OwnedProcesses()
        owned.track(42)
        let ok = #"{"currentVersion":"1.0.47","latestVersion":"1.0.47","updateAvailable":false,"error":null}"#
        let runner = ScriptedRunner([
            CommandResult(status: 0, stdout: "", stderr: ""),
            CommandResult(status: 0, stdout: ok, stderr: ""),
        ])
        var stopped: [Int32] = []
        let result = try await installGrokUpdate(
            runner: runner,
            leaderSocket: "/tmp/desk.sock",
            stopOwned: {
                stopped = owned.stopAll()
            }
        )
        XCTAssertEqual(stopped, [42])
        XCTAssertEqual(runner.calls[0], ["update", "--leader-socket", "/tmp/desk.sock"])
        XCTAssertEqual(runner.calls[1].prefix(3), ["update", "--check", "--json"])
        XCTAssertEqual(result.buttonTitle, nil)
        XCTAssertEqual(result.currentVersion, "1.0.47")
    }

    func testFailedInstallReturnsStderrAndDoesNotClaimSuccess() async {
        let runner = ScriptedRunner([
            CommandResult(status: 1, stdout: "", stderr: "disk full"),
        ])
        let result = try? await installGrokUpdate(
            runner: runner,
            leaderSocket: "/tmp/desk.sock",
            stopOwned: {}
        )
        XCTAssertEqual(result?.error, "disk full")
        XCTAssertEqual(runner.calls.count, 1)
    }
}
