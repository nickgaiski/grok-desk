import Foundation
import XCTest
@testable import GrokDeskCore

final class AgentRuntimeTests: XCTestCase {
    func testUpdatePermissionAndOpenMetadataRetainOwningSession() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let script = try executable(log: log)
        let client = AgentClient(binary: script.path, leaderSocket: "/tmp/runtime-test.sock", owned: OwnedProcesses())
        defer { client.stop() }

        let updateReceived = expectation(description: "session update envelope")
        let permissionReceived = expectation(description: "permission envelope")
        let issueReceived = expectation(description: "unknown and malformed messages reported")
        issueReceived.expectedFulfillmentCount = 2
        let received = ReceivedEvents()
        client.onUpdateEnvelope = { envelope in
            received.set(update: envelope)
            updateReceived.fulfill()
        }
        client.onPermissionEnvelope = { envelope in
            received.set(permission: envelope)
            permissionReceived.fulfill()
        }
        client.onProtocolIssue = { issue in
            received.add(issue: issue)
            issueReceived.fulfill()
        }

        try client.start(model: "model-one", effort: "high", permission: "default")
        let capabilities = try await client.initialize()
        XCTAssertEqual(capabilities.commands, ["help"])
        let opened = try await client.openSessionResult(cwd: "/tmp/workspace-one", sessionId: nil, model: "model-one", effort: "high")
        XCTAssertEqual(opened.sessionID, "session-fixture")
        XCTAssertEqual(opened.support.configurationIDs, ["model"])
        XCTAssertEqual(opened.support.permissionModes, ["default"])
        XCTAssertFalse(opened.support.supportsNativePlan)
        XCTAssertFalse(opened.support.supportsNativeSteer)

        try await client.prompt(sessionId: opened.sessionID, text: "run", capabilities: capabilities)
        await fulfillment(of: [updateReceived, permissionReceived, issueReceived], timeout: 5)
        let (update, permission, protocolIssues) = received.snapshot()
        XCTAssertEqual(update?.sessionID, "session-fixture")
        XCTAssertEqual(update?.update?["sessionUpdate"] as? String, "agent_message_chunk")
        XCTAssertEqual(permission?.sessionID, "session-fixture")
        XCTAssertEqual(permission?.requestID, 91)
        XCTAssertEqual(permission?.choices.map(\.id), ["allow-once", "deny"])
        XCTAssertEqual(protocolIssues.count, 2, "Optional provider notifications must not turn a successful turn into an error")
        XCTAssertTrue(protocolIssues.contains(where: { $0.contains("Unsupported ACP request") }))
        XCTAssertTrue(protocolIssues.contains(where: { $0.contains("without a session ID") }))
    }

    private func executable(log: URL) throws -> URL {
        let path = try pythonString(log.path)
        let body = #"""
import json,sys
LOG = \#(path)
SESSION = "session-fixture"
def send(obj):
 sys.stdout.write(json.dumps(obj)+"\n"); sys.stdout.flush()
for line in sys.stdin:
 r=json.loads(line)
 m=r.get("method")
 if m=="initialize":
  result={"agentCapabilities":{"promptCapabilities":{"embeddedContext":True}},"_meta":{"availableCommands":[{"name":"help"}]}}
 elif m=="session/new":
  result={"sessionId":SESSION,"configOptions":[{"id":"model"}],"modes":{"availableModes":[{"id":"default"}]}}
 elif m=="session/prompt":
  send({"jsonrpc":"2.0","method":"_x.ai/session_notification","params":{"sessionId":SESSION,"type":"metadata_updated"}})
  # A server request reusing this response ID must not resolve the pending prompt.
  send({"jsonrpc":"2.0","id":r["id"],"method":"provider/unsupported","params":{}})
  send({"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"malformed update"}}}})
  send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":SESSION,"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"hello"}}}})
  send({"jsonrpc":"2.0","method":"session/request_permission","id":91,"params":{"sessionId":SESSION,"toolCall":{"title":"Write file"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}})
  result={"stopReason":"end_turn"}
 else:
  result={}
 if "id" in r:
  send({"jsonrpc":"2.0","id":r["id"],"result":result})
"""#
        return try makeExecutable(body)
    }

    private func pythonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private func makeExecutable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-acp-fixture-" + UUID().uuidString)
        try Data(("#!/usr/bin/python3\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private final class ReceivedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var update: AgentUpdateEnvelope?
    private var permission: PermissionEnvelope?
    private var issues: [String] = []

    func set(update: AgentUpdateEnvelope) { lock.lock(); self.update = update; lock.unlock() }
    func set(permission: PermissionEnvelope) { lock.lock(); self.permission = permission; lock.unlock() }
    func add(issue: String) { lock.lock(); issues.append(issue); lock.unlock() }
    func snapshot() -> (AgentUpdateEnvelope?, PermissionEnvelope?, [String]) {
        lock.lock(); defer { lock.unlock() }
        return (update, permission, issues)
    }
}
