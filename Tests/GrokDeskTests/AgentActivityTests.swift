import Foundation
import XCTest
@testable import GrokDeskCore

@MainActor
final class AgentActivityTests: XCTestCase {
    func testOnlyExplicitSessionMetadataCreatesSubagentLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let registry = RuntimeRegistry(queueStore: PromptQueueStore(root: root))
        let parent = registry.runtime(for: "parent-session", cwd: "/tmp/project")

        let childUpdate: [String: Any] = [
            "sessionUpdate": "tool_call_update",
            "toolCallId": "child-task",
            "title": "Build media",
            "status": "in_progress"
        ]
        let childEnvelope = try envelope(sessionID: "child-session", params: [
            "sessionId": "child-session",
            "parentSessionId": "parent-session",
            "update": childUpdate
        ], update: childUpdate)
        let childEvent = try XCTUnwrap(AgentActivityEvent.update(from: childEnvelope))
        registry.observe(childEvent, from: parent)

        let child = try XCTUnwrap(registry.summaries.first(where: { $0.sessionID == "child-session" }))
        XCTAssertEqual(child.state, .working)
        XCTAssertEqual(child.parentSessionID, "parent-session")
        XCTAssertTrue(child.isExternalObservedSession)
        XCTAssertEqual(parent.summary().childSessionIDs, ["child-session"])
        XCTAssertEqual(registry.runtime(id: "observed:child-session")?.activity.last?.toolCallID, "child-task")

        let proseOnly: [String: Any] = ["sessionUpdate": "agent_message_chunk", "content": ["text": "subagent child-session is working"]]
        let unrelatedEnvelope = try envelope(sessionID: "unlinked-session", params: ["sessionId": "unlinked-session", "update": proseOnly], update: proseOnly)
        let unrelatedEvent = try XCTUnwrap(AgentActivityEvent.update(from: unrelatedEnvelope))
        registry.observe(unrelatedEvent, from: parent)
        let unknown = try XCTUnwrap(registry.summaries.first(where: { $0.sessionID == "unlinked-session" }))
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertNil(unknown.parentSessionID)
        XCTAssertFalse(parent.summary().childSessionIDs.contains("unlinked-session"))

        let namedTool: [String: Any] = ["sessionUpdate": "tool_call", "toolCallId": "ordinary-tool", "title": "subagent", "status": "in_progress"]
        let namedEnvelope = try envelope(sessionID: "parent-session", params: ["sessionId": "parent-session", "update": namedTool], update: namedTool)
        let namedEvent = try XCTUnwrap(AgentActivityEvent.update(from: namedEnvelope))
        registry.observe(namedEvent, from: parent)
        XCTAssertEqual(parent.summary().childSessionIDs, ["child-session"])
    }

    private func envelope(sessionID: String, params: [String: Any], update: [String: Any]) throws -> AgentUpdateEnvelope {
        AgentUpdateEnvelope(
            sessionID: sessionID,
            payload: try JSONSerialization.data(withJSONObject: update),
            metadata: try JSONSerialization.data(withJSONObject: params)
        )
    }
}
