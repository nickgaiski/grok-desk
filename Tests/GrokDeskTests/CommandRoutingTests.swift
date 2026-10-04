import XCTest
@testable import GrokDeskCore
final class CommandRoutingTests: XCTestCase {
    func testNativeQueueAndTerminalPlanDoNotFallThroughAsPrompt() {
        XCTAssertEqual(routeCommand("/queue", advertised: [], skills: []), .native("queue"))
        XCTAssertEqual(routeCommand("/plan improve this", advertised: [], skills: []), .terminal("plan"))
        XCTAssertEqual(routeCommand("/unknown", advertised: [], skills: []), .unsupported("unknown"))
        XCTAssertNil(routeCommand("hello", advertised: [], skills: []))
        XCTAssertEqual(routeCommand("/local:review", advertised: [], skills: ["local:review"]), .skill("local:review"))
    }
}
