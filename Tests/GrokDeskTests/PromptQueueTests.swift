import Foundation
import XCTest
@testable import GrokDeskCore

@MainActor
final class PromptQueueTests: XCTestCase {
    func testSwitchingChatsKeepsRuntimeAndDrainsItsEditedQueueInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("requests.jsonl")
        let entered = root.appendingPathComponent("entered-a")
        let release = root.appendingPathComponent("release-a")
        let queueEntered = root.appendingPathComponent("entered-queued-a1")
        let queueRelease = root.appendingPathComponent("release-queued-a1")
        let attachment = root.appendingPathComponent("brief.txt")
        try Data("retained attachment content".utf8).write(to: attachment)
        let attachedImage = root.appendingPathComponent("reference.png")
        try Data([1, 2, 3]).write(to: attachedImage)
        let skillFile = root.appendingPathComponent("queue-skill/SKILL.md")
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Follow the queue skill instructions.".utf8).write(to: skillFile)
        let script = try executable(log: log, entered: entered, release: release, queueEntered: queueEntered, queueRelease: queueRelease)
        let inspect = try JSONSerialization.data(withJSONObject: ["skills": [["name": "queue-skill", "source": ["path": skillFile.path]]]])
        let runner = authenticatedRunner(extra: [CommandResult(status: 0, stdout: String(decoding: inspect, as: UTF8.self), stderr: "")])
        let model = DeskModel(
            runner: runner,
            leaderSocket: "/tmp/queue-test.sock",
            sessionsRoot: root.appendingPathComponent("sessions"),
            binary: script.path,
            queueStore: PromptQueueStore(root: root.appendingPathComponent("queues"))
        )
        await model.refresh()
        defer { model.shutdown() }

        let workspaceA = root.appendingPathComponent("workspace-a", isDirectory: true)
        let workspaceB = root.appendingPathComponent("workspace-b", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        model.newChat(cwd: workspaceA.path)
        let runtimeA = model.currentRuntimeID
        let firstTurn = Task { await model.send(text: "Hold A", cwd: workspaceA.path, resume: nil) }
        let reachedHeldTurn = await waitForFile(entered)
        XCTAssertTrue(reachedHeldTurn)
        let sessionA = try XCTUnwrap(model.activeSessionID)

        let queuedSkill = SkillRecord(name: "queue-skill", detail: "Queue skill test", source: skillFile.path)
        let acceptedA1 = await model.send(text: "A1", cwd: workspaceA.path, resume: sessionA, attachments: [attachment, attachedImage], skills: [queuedSkill])
        let acceptedA2 = await model.send(text: "A2", cwd: workspaceA.path, resume: sessionA)
        XCTAssertTrue(acceptedA1)
        XCTAssertTrue(acceptedA2)
        var firstQueued = try XCTUnwrap(model.queuedPrompts.first)
        firstQueued.text = "A1 edited"
        model.editQueuedPrompt(firstQueued)
        let ids = model.queuedPrompts.map(\.id)
        model.reorderQueuedPrompts(Array(ids.reversed()))
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["A2", "A1 edited"])
        let discarded = model.queuedPrompts[0].id
        model.removeQueuedPrompt(id: discarded)
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["A1 edited"])
        // Put both prompts back in the intended order for the transport assertion.
        let acceptedA2Again = await model.send(text: "A2", cwd: workspaceA.path, resume: sessionA)
        XCTAssertTrue(acceptedA2Again)
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["A1 edited", "A2"])

        model.newChat(cwd: workspaceB.path)
        let runtimeB = model.currentRuntimeID
        XCTAssertNotEqual(runtimeA, runtimeB)
        let completedB = await model.send(text: "B", cwd: workspaceB.path, resume: nil)
        XCTAssertTrue(completedB)
        XCTAssertEqual(model.activeRuntimeID, runtimeB)
        XCTAssertEqual(model.runtimeSummaries.first(where: { $0.id == runtimeA })?.state, .working)

        try Data().write(to: release)
        let reachedQueuedTurn = await waitForFile(queueEntered)
        XCTAssertTrue(reachedQueuedTurn)
        XCTAssertTrue(model.chooseRuntime(id: runtimeA))
        let activeID = try XCTUnwrap(model.runtimeSummaries.first(where: { $0.id == runtimeA })?.activeQueuedPromptID)
        var attemptedEdit = try XCTUnwrap(model.queuedPrompts.first)
        attemptedEdit.text = "should not replace active queue item"
        model.editQueuedPrompt(attemptedEdit)
        model.removeQueuedPrompt(id: activeID)
        model.reorderQueuedPrompts(Array(model.queuedPrompts.map(\.id).reversed()))
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["A1 edited", "A2"])
        try Data().write(to: queueRelease)
        let completedA = await firstTurn.value
        XCTAssertTrue(completedA)
        let entries = try readLog(log)
        let aEntries = entries.filter { $0["sessionID"] as? String == sessionA }
        XCTAssertEqual(aEntries.compactMap { $0["userText"] as? String }, ["Hold A", "A1 edited", "A2"])
        let skilledEntry = try XCTUnwrap(aEntries.first(where: { $0["userText"] as? String == "A1 edited" }))
        let attachmentParts = try XCTUnwrap(skilledEntry["prompt"] as? [[String: Any]])
        XCTAssertTrue(attachmentParts.contains { ($0["resource"] as? [String: Any])?["text"] as? String == "retained attachment content" })
        XCTAssertTrue(attachmentParts.contains { ($0["text"] as? String ?? "").contains("User-attached local image file: \(attachedImage.path)") })
        XCTAssertTrue((skilledEntry["text"] as? String ?? "").contains("Follow the queue skill instructions."))
        XCTAssertFalse(entries.contains { ($0["text"] as? String ?? "").hasPrefix("A") && $0["sessionID"] as? String != sessionA })
        XCTAssertTrue(model.chooseRuntime(id: runtimeA))
        XCTAssertTrue(model.queuedPrompts.isEmpty)
    }

    func testFailedQueuePausesAndRestartRequiresReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("requests.jsonl")
        let entered = root.appendingPathComponent("entered-a")
        let release = root.appendingPathComponent("release-a")
        let script = try executable(log: log, entered: entered, release: release, failText: "Fail A1")
        let storeRoot = root.appendingPathComponent("queues")
        let model = DeskModel(
            runner: authenticatedRunner(),
            leaderSocket: "/tmp/queue-failure.sock",
            sessionsRoot: root.appendingPathComponent("sessions"),
            binary: script.path,
            queueStore: PromptQueueStore(root: storeRoot)
        )
        await model.refresh()
        defer { model.shutdown() }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        model.newChat(cwd: workspace.path)
        let runtimeID = model.currentRuntimeID
        let firstTurn = Task { await model.send(text: "Hold A", cwd: workspace.path, resume: nil) }
        let reachedHeldTurn = await waitForFile(entered)
        XCTAssertTrue(reachedHeldTurn, model.chatError ?? "State: \(model.activeRuntimeState)")
        guard let sessionID = model.activeSessionID else {
            model.cancel()
            _ = await firstTurn.value
            return
        }
        let acceptedFail = await model.send(text: "Fail A1", cwd: workspace.path, resume: sessionID)
        let acceptedTail = await model.send(text: "A2 remains", cwd: workspace.path, resume: sessionID)
        XCTAssertTrue(acceptedFail)
        XCTAssertTrue(acceptedTail)
        try Data().write(to: release)
        let completedA = await firstTurn.value
        XCTAssertTrue(completedA)
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["Fail A1", "A2 remains"])
        XCTAssertEqual(model.activeRuntimeState, .failed)

        let recovered = DeskModel(
            runner: authenticatedRunner(),
            leaderSocket: "/tmp/queue-reopen.sock",
            sessionsRoot: root.appendingPathComponent("sessions"),
            binary: script.path,
            queueStore: PromptQueueStore(root: storeRoot)
        )
        defer { recovered.shutdown() }
        XCTAssertTrue(recovered.chooseRuntime(id: runtimeID))
        XCTAssertEqual(recovered.queuedPrompts.map(\.text), ["Fail A1", "A2 remains"])
        XCTAssertTrue(recovered.queuedPrompts.allSatisfy(\.requiresReview))
        XCTAssertEqual(recovered.runtimeSummaries.first(where: { $0.id == runtimeID })?.queuedCount, 2)
        recovered.reviewQueuedPrompts()
        XCTAssertTrue(recovered.queuedPrompts.allSatisfy { !$0.requiresReview })
        guard let first = recovered.queuedPrompts.first else { XCTFail("Expected reviewed queue entry"); return }
        recovered.removeQueuedPrompt(id: first.id)
        XCTAssertEqual(recovered.queuedPrompts.map(\.text), ["A2 remains"])
    }

    func testCancelStopsOnlyTheSelectedRuntimeAndRetainsItsQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("requests.jsonl")
        let entered = root.appendingPathComponent("entered")
        let release = root.appendingPathComponent("release")
        let script = try executable(log: log, entered: entered, release: release)
        let model = DeskModel(
            runner: authenticatedRunner(),
            leaderSocket: "/tmp/queue-cancel.sock",
            sessionsRoot: root.appendingPathComponent("sessions"),
            binary: script.path,
            queueStore: PromptQueueStore(root: root.appendingPathComponent("queues"))
        )
        await model.refresh()
        defer { model.shutdown() }

        let workspaceA = root.appendingPathComponent("workspace-a", isDirectory: true)
        let workspaceB = root.appendingPathComponent("workspace-b", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        model.newChat(cwd: workspaceA.path)
        let runtimeA = model.currentRuntimeID
        let taskA = Task { await model.send(text: "Hold A", cwd: workspaceA.path, resume: nil) }
        let aStarted = await waitForFile(entered)
        XCTAssertTrue(aStarted)
        try FileManager.default.removeItem(at: entered)

        model.newChat(cwd: workspaceB.path)
        let runtimeB = model.currentRuntimeID
        let taskB = Task { await model.send(text: "Hold A", cwd: workspaceB.path, resume: nil) }
        let bStarted = await waitForFile(entered)
        XCTAssertTrue(bStarted)
        let sessionB = try XCTUnwrap(model.activeSessionID)
        let queued = await model.send(text: "B tail", cwd: workspaceB.path, resume: sessionB)
        XCTAssertTrue(queued)

        model.cancel()
        let cancelledB = await taskB.value
        XCTAssertFalse(cancelledB)
        XCTAssertEqual(model.activeRuntimeState, .cancelled)
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["B tail"])
        XCTAssertEqual(model.runtimeSummaries.first(where: { $0.id == runtimeA })?.state, .working)

        XCTAssertTrue(model.chooseRuntime(id: runtimeA))
        try Data().write(to: release)
        let completedA = await taskA.value
        XCTAssertTrue(completedA)
        XCTAssertEqual(model.activeRuntimeID, runtimeA)
    }

    func testRetryRemovesFailedQueueItemBeforeResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("requests.jsonl")
        let entered = root.appendingPathComponent("entered-a")
        let release = root.appendingPathComponent("release-a")
        let failOnceMarker = root.appendingPathComponent("failed-once")
        let script = try executable(log: log, entered: entered, release: release, failOnceText: "Retry A1", failOnceMarker: failOnceMarker)
        let model = DeskModel(
            runner: authenticatedRunner(),
            leaderSocket: "/tmp/queue-retry.sock",
            sessionsRoot: root.appendingPathComponent("sessions"),
            binary: script.path,
            queueStore: PromptQueueStore(root: root.appendingPathComponent("queues"))
        )
        await model.refresh()
        defer { model.shutdown() }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        model.newChat(cwd: workspace.path)
        let firstTurn = Task { await model.send(text: "Hold A", cwd: workspace.path, resume: nil) }
        let reachedHeldTurn = await waitForFile(entered)
        XCTAssertTrue(reachedHeldTurn)
        let sessionID = try XCTUnwrap(model.activeSessionID)
        let acceptedRetry = await model.send(text: "Retry A1", cwd: workspace.path, resume: sessionID)
        let acceptedTail = await model.send(text: "A2", cwd: workspace.path, resume: sessionID)
        XCTAssertTrue(acceptedRetry)
        XCTAssertTrue(acceptedTail)
        try Data().write(to: release)
        let firstCompleted = await firstTurn.value
        XCTAssertTrue(firstCompleted)
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["Retry A1", "A2"])
        XCTAssertEqual(model.activeRuntimeState, .failed)

        await model.retry()
        XCTAssertTrue(model.queuedPrompts.isEmpty)
        await model.resumeQueue()
        let entries = try readLog(log).filter { $0["sessionID"] as? String == sessionID }
        XCTAssertEqual(entries.compactMap { $0["userText"] as? String }, ["Hold A", "Retry A1", "Retry A1", "A2"])
    }

    private func authenticatedRunner(extra: [CommandResult] = []) -> ScriptedRunner {
        ScriptedRunner([
            CommandResult(status: 0, stdout: "You are logged in with grok.com.\n  * model-one (default)\n", stderr: ""),
            CommandResult(status: 0, stdout: #"{"currentVersion":"1.0.46","latestVersion":"1.0.46","updateAvailable":false,"error":null}"#, stderr: "")
        ] + extra)
    }

    private func executable(log: URL, entered: URL, release: URL, failText: String = "", failOnceText: String = "", failOnceMarker: URL? = nil, queueEntered: URL? = nil, queueRelease: URL? = nil) throws -> URL {
        let logLiteral = try pythonString(log.path)
        let enteredLiteral = try pythonString(entered.path)
        let releaseLiteral = try pythonString(release.path)
        let failLiteral = try pythonString(failText)
        let failOnceLiteral = try pythonString(failOnceText)
        let failOnceMarkerLiteral = try pythonString(failOnceMarker?.path ?? "")
        let queueEnteredLiteral = try pythonString(queueEntered?.path ?? "")
        let queueReleaseLiteral = try pythonString(queueRelease?.path ?? "")
        let body = #"""
import json,os,sys,time
LOG = \#(logLiteral)
ENTERED = \#(enteredLiteral)
RELEASE = \#(releaseLiteral)
FAIL_TEXT = \#(failLiteral)
FAIL_ONCE_TEXT = \#(failOnceLiteral)
FAIL_ONCE_MARKER = \#(failOnceMarkerLiteral)
QUEUE_ENTERED = \#(queueEnteredLiteral)
QUEUE_RELEASE = \#(queueReleaseLiteral)
SESSION = "session-" + str(os.getpid())
def send(obj):
 sys.stdout.write(json.dumps(obj)+"\n"); sys.stdout.flush()
for line in sys.stdin:
 r=json.loads(line)
 m=r.get("method")
 if m=="initialize":
  result={"agentCapabilities":{"promptCapabilities":{"embeddedContext":True}},"_meta":{"availableCommands":[]}}
 elif m in ("session/new","session/load"):
  result={"sessionId":SESSION,"configOptions":[{"id":"model"}]}
 elif m=="session/prompt":
  params=r.get("params",{})
  parts=params.get("prompt",[])
  txt=parts[0].get("text","") if parts else ""
  userText=txt.split("User request:\n",1)[1] if "User request:\n" in txt else txt
  with open(LOG,"a") as f: f.write(json.dumps({"sessionID":params.get("sessionId"),"text":txt,"userText":userText,"prompt":parts})+"\n")
  if txt=="Hold A":
   open(ENTERED,"w").close()
   deadline=time.time()+20
   while not os.path.exists(RELEASE) and time.time()<deadline: time.sleep(0.02)
  if "A1 edited" in txt and QUEUE_ENTERED:
   open(QUEUE_ENTERED,"w").close()
   deadline=time.time()+20
   while not os.path.exists(QUEUE_RELEASE) and time.time()<deadline: time.sleep(0.02)
  if txt==FAIL_TEXT or (txt==FAIL_ONCE_TEXT and FAIL_ONCE_MARKER and not os.path.exists(FAIL_ONCE_MARKER)):
   if txt==FAIL_ONCE_TEXT and FAIL_ONCE_MARKER: open(FAIL_ONCE_MARKER,"w").close()
   send({"jsonrpc":"2.0","id":r["id"],"error":{"code":-32000,"message":"fixture failure"}})
   continue
  send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":params.get("sessionId"),"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"Done: "+txt}}}})
  result={"stopReason":"end_turn"}
 else:
  result={}
 if "id" in r: send({"jsonrpc":"2.0","id":r["id"],"result":result})
"""#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-queue-fixture-" + UUID().uuidString)
        try Data(("#!/usr/bin/python3\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func pythonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private func waitForFile(_ url: URL) async -> Bool {
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func readLog(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
