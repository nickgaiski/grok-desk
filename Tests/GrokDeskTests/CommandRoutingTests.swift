import XCTest
@testable import GrokDeskCore
final class CommandRoutingTests: XCTestCase {
    @MainActor func testAlwaysApproveSurvivesARuntimeUpdate() {
        let model = DeskModel(runner: ScriptedRunner([]), leaderSocket: "/tmp/permission-persist.sock", sessionsRoot: FileManager.default.temporaryDirectory)
        model.permissionMode = "bypassPermissions"
        model.cancel()
        XCTAssertEqual(model.permissionMode, "bypassPermissions")
    }
    func testNativeQueueAndTerminalPlanDoNotFallThroughAsPrompt() {
        XCTAssertEqual(routeCommand("/queue", advertised: [], skills: []), .native("queue"))
        XCTAssertEqual(routeCommand("/plan improve this", advertised: [], skills: []), .native("plan"))
        XCTAssertEqual(routeCommand("/view-plan", advertised: [], skills: []), .native("view-plan"))
        XCTAssertEqual(routeCommand("/unknown", advertised: [], skills: []), .unsupported("unknown"))
        XCTAssertNil(routeCommand("hello", advertised: [], skills: []))
        XCTAssertEqual(routeCommand("/local:review", advertised: [], skills: ["local:review"]), .skill("local:review"))
    }
}
