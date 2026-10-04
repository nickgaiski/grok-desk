import XCTest
@testable import GrokDeskCore

final class OwnedProcessTests: XCTestCase {
    func testArgumentsPutThePrivateSocketOnTheSubcommand() {
        let args = grokArguments(
            leaderSocket: "/tmp/Grok Desk/leader.sock",
            user: ["update", "--check", "--json"]
        )
        XCTAssertEqual(args, ["update", "--check", "--json", "--leader-socket", "/tmp/Grok Desk/leader.sock"])
    }

    func testStopAllReturnsOnlyTrackedPIDs() {
        let owned = OwnedProcesses()
        owned.track(10)
        owned.track(11)
        XCTAssertEqual(owned.stopAll().sorted(), [10, 11])
        XCTAssertEqual(owned.stopAll(), [])
    }

    func testChildEnvironmentDisablesTheAutoUpdater() {
        XCTAssertEqual(grokChildEnvironment["GROK_DISABLE_AUTOUPDATER"], "1")
    }
}
