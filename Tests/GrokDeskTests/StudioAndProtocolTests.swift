import XCTest
@testable import GrokDeskCore

final class StudioAndProtocolTests: XCTestCase {
    func testImagineUsesTheCLICommands() {
        let image = StudioBoard()
        let video = StudioBoard(medium: "video")
        XCTAssertTrue(imagineCommand(board: image, outputFolder: URL(fileURLWithPath: "/tmp/media")).hasPrefix("/imagine "))
        let textToVideo = imagineCommand(board: video, outputFolder: URL(fileURLWithPath: "/tmp/media"))
        XCTAssertTrue(textToVideo.contains("Call image_to_video"))
        XCTAssertTrue(textToVideo.contains("image_gen once"))
        XCTAssertTrue(textToVideo.contains("resolution_name: 1080p"))
        XCTAssertTrue(textToVideo.contains("grok-imagine-video-1.5"))
        XCTAssertFalse(textToVideo.contains("Call reference_to_video"))
        XCTAssertFalse(imagineCommand(board: image, outputFolder: URL(fileURLWithPath: "/tmp/media")).contains("https://"))
    }
    func testBoardRoundTripAndBriefDoesNotLeakLocalPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = StudioLibrary(root: root)
        var board = StudioBoard(medium: "video")
        board.prompt = "A quiet desert at dusk"; board.startPath = "/private/frame.png"
        board.motion = "Slow push in"; board.references = ["/private/person.png"]
        try library.save(board)
        XCTAssertEqual(try library.boards(), [board])
        XCTAssertTrue(board.brief.contains("Slow push in"))
        XCTAssertFalse(board.brief.contains("/private"))
    }
    func testExistingBoardsDecodeAndCinemaLookChangesCLIRequest() throws {
        let original = StudioBoard()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "look")
        var restored = try JSONDecoder().decode(StudioBoard.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.look)
        var look = StudioLook(); look.focal = "85 mm"; look.aperture = "f/1.4"
        restored.look = look
        let command = imagineCommand(board: restored, outputFolder: URL(fileURLWithPath: "/tmp/media"))
        XCTAssertTrue(command.contains("85 mm"))
        XCTAssertTrue(command.contains("shallow depth of field"))
        XCTAssertEqual(try JSONDecoder().decode(StudioBoard.self, from: JSONEncoder().encode(restored)).look, look)
    }
    func testAssetImportsPreserveOriginalAndAvoidFilenameCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("example.png")
        let bytes = Data([1, 2, 3]); try bytes.write(to: source)
        let library = StudioLibrary(root: root.appendingPathComponent("library"))
        let first = try library.importAsset(source), second = try library.importAsset(source)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try library.assets().count, 2)
        XCTAssertThrowsError(try library.importAsset(root))
    }
    func testNestedACPUpdatesAndToolReplacement() {
        var blocks = applyChatUpdate([], update: ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hello"]]])
        blocks = applyChatUpdate(blocks, update: ["sessionUpdate": "agent_message_chunk", "content": ["text": " world"]])
        XCTAssertEqual(blocks.first?.text, "Hello world")
        blocks = applyChatUpdate(blocks, update: ["sessionUpdate": "tool_call", "toolCallId": "one", "title": "Read", "status": "in_progress"])
        blocks = applyChatUpdate(blocks, update: ["sessionUpdate": "tool_call_update", "toolCallId": "one", "status": "completed", "content": [["type": "content", "content": ["type": "text", "text": "Done"]]]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.last!.text.contains("Read · completed"))
        XCTAssertTrue(blocks.last!.text.contains("Done"))
    }
    func testSplitHistoryEnvelopeAndBoundedBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("project/session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let row: [String: Any] = ["params": ["update": ["sessionUpdate": "agent_message_chunk", "content": ["text": "Saved history"]]]]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: folder.appendingPathComponent("updates.jsonl"))
        XCTAssertEqual(sessionHistory(root: root, sessionID: "session").first?.text, "Saved history")
        let long = applyChatUpdate([], update: ["sessionUpdate": "agent_message_chunk", "content": String(repeating: "a", count: 200_000)])
        XCTAssertEqual(long.first?.text.count, 100_000)
    }
    func testAttachmentCapabilityAndRealContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("test.png"), text = folder.appendingPathComponent("test.txt")
        try Data([1, 2]).write(to: image); try Data("file body".utf8).write(to: text)
        var caps = AgentCapabilities()
        let fallback = try promptParts(text: "Hi", attachments: [image], capabilities: caps)
        XCTAssertTrue((fallback.last?["text"] as? String ?? "").contains("User-attached local image file: \(image.path)"))
        XCTAssertFalse((fallback.last?["text"] as? String ?? "").contains("data"))
        XCTAssertThrowsError(try promptParts(text: "Hi", attachments: [text], capabilities: caps))
        caps.embeddedContext = true
        let parts = try promptParts(text: "Hi", attachments: [text], capabilities: caps)
        XCTAssertEqual((parts.last?["resource"] as? [String: String])?["text"], "file body")
        caps.images = true
        XCTAssertEqual(try promptParts(text: "Hi", attachments: [image], capabilities: caps).last?["data"] as? String, Data([1, 2]).base64EncodedString())
    }
    func testPermissionFlagPrecedesAgentSubcommand() {
        let args = agentArguments(socket: "/tmp/test.sock", model: "discovered-model", effort: "low", permission: "plan")
        XCTAssertEqual(Array(args.prefix(3)), ["--permission-mode", "plan", "agent"])
        XCTAssertEqual(args.last, "stdio")
        XCTAssertTrue(args.contains("--no-leader"))
    }
    func testContextReadsRealPromptUsageMeta() {
        XCTAssertEqual(contextMeter(from: ["_meta": ["usage": ["inputTokens": 1234]]])?.used, 1234)
        XCTAssertNil(contextMeter(from: [:]))
    }
}

final class AgentTransportTests: XCTestCase {
    func fixture(_ body: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("grok-fixture-" + UUID().uuidString)
        try Data(("#!/usr/bin/python3\n" + body).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
    func testTransportDrainsLargeStderr() async throws {
        let script = try fixture(#"""
import sys,json,time
for line in sys.stdin:
 r=json.loads(line)
 if r.get('method')=='initialize':
  sys.stderr.write('x'*200000);sys.stderr.flush()
  result={'agentCapabilities':{'promptCapabilities':{'embeddedContext':True}}}
 else: result={}
 sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result})+'\n');sys.stdout.flush()
"""#)
        let owned = OwnedProcesses()
        let agent = AgentClient(binary: script.path, leaderSocket: "/tmp/test", owned: owned)
        defer { agent.stop() }
        try agent.start(model: "", effort: "", permission: "default")
        let caps = try await agent.initialize()
        XCTAssertTrue(caps.embeddedContext)
    }
    func testExitedAgentFailsPendingRequest() async throws {
        let script = try fixture("import sys\nsys.stdin.readline()\nsys.exit(3)\n")
        let agent = AgentClient(binary: script.path, leaderSocket: "/tmp/test", owned: OwnedProcesses())
        defer { agent.stop() }
        try agent.start(model: "", effort: "", permission: "default")
        do { _ = try await agent.initialize(); XCTFail("Expected process exit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exited")) }
    }
    func testCLIUntracksExitedChildrenAndDoesNotDeadlockOnPipes() async throws {
        let script = try fixture("import sys\nsys.stderr.write('x'*200000)\nsys.stdout.write('ok')\n")
        let owned = OwnedProcesses()
        let result = try await LiveRunner(binary: script.path, owned: owned).run([])
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertEqual(result.stderr.count, 16_000)
        XCTAssertTrue(owned.stopAll().isEmpty)
    }
}

final class ProjectStoreTests: XCTestCase {
    func testExistingElectronSchemaAndDuplicateFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore(url: folder.appendingPathComponent("projects.json"))
        let first = try store.add(folder: folder)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(try store.add(folder: folder), first)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        XCTAssertNotNil(object?["projects"])
    }
    func testNamedProjectEditKeepsIdentityAndFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore(url: folder.appendingPathComponent("projects.json"))
        let created = try store.add(folder: folder, name: "  My studio  ")[0]
        let edited = try store.add(folder: folder, name: "Film project")
        XCTAssertEqual(created.name, "My studio")
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited[0].id, created.id)
        XCTAssertEqual(edited[0].cwd, created.cwd)
        XCTAssertEqual(edited[0].name, "Film project")
        XCTAssertEqual(try store.load(), edited)
    }
    func testCorruptStoreIsNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore(url: folder.appendingPathComponent("projects.json"))
        let original = Data("broken existing store".utf8)
        try original.write(to: store.url)
        XCTAssertThrowsError(try store.add(folder: folder))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
}

@MainActor
final class ConversationLifecycleTests: XCTestCase {
    func testPlanToggleDoesNotChangePermissionsOrRestartTheSession() async throws {
        let helper = AgentTransportTests()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let body = #"""
import sys,json
for line in sys.stdin:
 r=json.loads(line)
 with open(LOG,'a') as f: f.write(json.dumps(r)+'\n')
 m=r.get('method')
 if m=='initialize': result={'agentCapabilities':{'promptCapabilities':{'embeddedContext':True}}}
 elif m=='session/new': result={'sessionId':'test-session'}
 elif m=='session/prompt':
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'test-session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Done'}}}})+'\n');sys.stdout.flush()
  result={'stopReason':'end_turn'}
 else: result={}
 if 'id' in r:
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result})+'\n');sys.stdout.flush()
"""#
        let script = try helper.fixture("LOG=" + String(data: try JSONEncoder().encode(log.path), encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/") + "\n" + body)
        let runner = ScriptedRunner([
            CommandResult(status: 0, stdout: "You are logged in with grok.com.\n  * discovered-model (default)\n", stderr: ""),
            CommandResult(status: 1, stdout: "", stderr: "")
        ])
        let model = DeskModel(runner: runner, leaderSocket: "/tmp/lifecycle.sock", sessionsRoot: log.deletingLastPathComponent().appendingPathComponent("no-sessions"), binary: script.path)
        await model.refresh()
        model.selectedModel = "discovered-model"
        defer { model.shutdown() }
        let first = await model.send(text: "First", cwd: "/tmp", resume: nil)
        let second = await model.send(text: "Second", cwd: "/tmp", resume: nil)
        model.planMode = true
        let third = await model.send(text: "Third", cwd: "/tmp", resume: nil)
        XCTAssertTrue(first && second && third, model.chatError ?? "No error reported")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/load" }.count, 0)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/prompt" }.count, 3)
        XCTAssertEqual(model.blocks.filter { $0.kind == "user" }.count, 3)
        XCTAssertFalse(model.activeRuntimeSupport.supportsNativePlan)
        for request in requests where request["method"] as? String == "session/set_config_option" {
            let params = request["params"] as? [String: Any]
            XCTAssertNotNil(params?["value"] as? String, "The installed ACP accepts a plain string, not a nested value object")
        }
    }

    func testStudioTurnFilesTheImageTheToolReturns() async throws {
        let helper = AgentTransportTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shot = root.appendingPathComponent("harbor.png")
        try Data([7, 7, 7]).write(to: shot)
        let log = root.appendingPathComponent("requests.jsonl")
        let library = root.appendingPathComponent("library")
        let body = #"""
import sys,json
for line in sys.stdin:
 r=json.loads(line)
 with open(LOG,'a') as f: f.write(json.dumps(r)+'\n')
 m=r.get('method')
 if m=='initialize': result={'agentCapabilities':{'promptCapabilities':{'embeddedContext':True}}}
 elif m=='session/new': result={'sessionId':'studio-session'}
 elif m=='session/prompt':
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'studio-session','update':{'sessionUpdate':'tool_call_update','toolCallId':'img','title':'image_gen','status':'completed','content':[{'type':'text','text':'Saved '+PATH}]}}})+'\n');sys.stdout.flush()
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'studio-session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Finished.'}}}})+'\n');sys.stdout.flush()
  result={'stopReason':'end_turn'}
 else: result={}
 if 'id' in r:
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result})+'\n');sys.stdout.flush()
"""#
        func pyString(_ value: String) throws -> String {
            String(data: try JSONEncoder().encode(value), encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
        }
        let script = try helper.fixture("LOG=" + (try pyString(log.path)) + "\nPATH=" + (try pyString(shot.path)) + "\n" + body)
        let runner = ScriptedRunner([
            CommandResult(status: 0, stdout: "You are logged in with grok.com.\n  * discovered-model (default)\n", stderr: ""),
            CommandResult(status: 1, stdout: "", stderr: "")
        ])
        let model = DeskModel(runner: runner, leaderSocket: "/tmp/studio.sock", sessionsRoot: root.appendingPathComponent("sessions"), binary: script.path)
        await model.refresh()
        model.selectedModel = "discovered-model"
        defer { model.shutdown() }
        var board = StudioBoard()
        board.prompt = "A quiet harbor"; board.aspect = "16:9"
        CameraPreset.all[5].apply(to: &board)
        let result = await model.runStudio(board: board, outputFolder: library, cwd: root.path)
        XCTAssertTrue(result.success, result.message)
        XCTAssertTrue(result.message.contains("Finished."))
        let saved = try StudioLibrary(root: library).assets()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: saved[0].url), Data([7, 7, 7]))
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let prompt = requests.first { $0["method"] as? String == "session/prompt" }
        let text = ((prompt?["params"] as? [String: Any])?["prompt"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("/imagine "))
        XCTAssertTrue(text.contains("aspect_ratio: 16:9"))
        XCTAssertTrue(text.contains("85 mm"))
        XCTAssertTrue(text.contains("shallow depth of field"))
        XCTAssertTrue(text.contains("Editorial portrait"))
    }
}
