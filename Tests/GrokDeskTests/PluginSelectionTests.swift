import XCTest
@testable import GrokDeskCore

final class PluginSelectionTests: XCTestCase {
    func testSlashSelectionPreservesExistingDraftAndIgnoresFilePaths() {
        XCTAssertEqual(trailingSkillQuery("Review this feature /vercel")?.prefix, "Review this feature ")
        XCTAssertEqual(trailingSkillQuery("/vercel:deploy")?.query, "vercel:deploy")
        XCTAssertNil(trailingSkillQuery("Read /tmp/project/file.swift"))
        XCTAssertNil(trailingSkillQuery("No command here"))
    }

    func testSelectedSkillActuallyAddsInstructionContentsAndMissingFileFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("SKILL.md")
        try Data("Inspect the deployment before changing its configuration.".utf8).write(to: url)
        let skill = SkillRecord(name: "deploy", detail: "", source: url.path, pluginName: "vercel")
        let prompt = try selectedSkillPrompt("Check this project", skills: [skill])
        XCTAssertTrue(prompt.contains(try String(contentsOf: url, encoding: .utf8)))
        XCTAssertTrue(prompt.hasSuffix("Check this project"))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try selectedSkillPrompt("Check this project", skills: [skill]))
    }
    func testCursorPublicMetadataPreservesRealLogoAndPinnedInstallLocation() throws {
        let row: [String: Any] = ["name": "demo", "displayName": "Demo", "isPublished": true,
            "repositoryUrl": "https://github.com/vendor/plugins", "gitRef": "abc123", "gitPath": "plugins/demo",
            "logoUrl": "https://cursor-cdn.com/demo.png"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["plugins": [row]]), as: UTF8.self)
        let push = String(decoding: try JSONSerialization.data(withJSONObject: [1, "0:" + json + "\n"]), as: UTF8.self)
        let catalog = try PluginCatalog.cursor("<script>self.__next_f.push(\(push))</script>")
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0].installSource, "https://github.com/vendor/plugins@abc123#plugins/demo")
        XCTAssertEqual(catalog[0].logoURL?.host, "cursor-cdn.com")
        XCTAssertThrowsError(try PluginCatalog.cursor("<html>Temporary failure</html>"))
    }
    func testLiveCatalogFixtureWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["GROK_LIVE_CURSOR_FIXTURE"] else { throw XCTSkip("Set GROK_LIVE_CURSOR_FIXTURE to a saved Cursor marketplace response") }
        let plugins = try PluginCatalog.cursor(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertGreaterThan(plugins.count, 100)
        XCTAssertGreaterThan(plugins.filter { $0.logoURL != nil }.count, 100)
        print("Live Cursor catalog decoded: \(plugins.count) plugins, \(plugins.filter { $0.logoURL != nil }.count) published logos")
    }
}

@MainActor
final class PluginDispatchTests: XCTestCase {
    func testSelectedSkillReachesACPAndIsScopedToProject() async throws {
        let helper = AgentTransportTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("SKILL.md")
        try Data("Return the diagnostic marker SELECTED_SKILL_ACTIVE.".utf8).write(to: path)
        let log = root.appendingPathComponent("request.json")
        let body = #"""
import sys,json
for line in sys.stdin:
 r=json.loads(line);m=r.get('method')
 if m=='initialize': result={'agentCapabilities':{'promptCapabilities':{'embeddedContext':True}}}
 elif m=='session/new': result={'sessionId':'skill-test'}
 elif m=='session/prompt':
  with open(LOG,'w') as f: json.dump(r,f)
  result={'stopReason':'end_turn'}
 else: result={}
 if 'id' in r:
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result})+'\n');sys.stdout.flush()
"""#
        let script = try helper.fixture("LOG=" + String(decoding: try JSONEncoder().encode(log.path), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") + "\n" + body)
        defer { try? FileManager.default.removeItem(at: script) }
        let inspect = String(decoding: try JSONSerialization.data(withJSONObject: ["skills": [["name": "probe", "source": ["type": "plugin", "plugin_name": "fixture", "path": path.path], "userInvocable": true]]]), as: UTF8.self)
        let runner = ScriptedRunner([
            .init(status: 0, stdout: "You are logged in with grok.com.\n * discovered-model (default)\n", stderr: ""),
            .init(status: 1, stdout: "", stderr: ""),
            .init(status: 0, stdout: "[]", stderr: ""), .init(status: 0, stdout: "[]", stderr: ""),
            .init(status: 0, stdout: "", stderr: ""), .init(status: 0, stdout: inspect, stderr: "")
        ])
        let model = DeskModel(runner: runner, leaderSocket: "/tmp/skill-test.sock", sessionsRoot: root.appendingPathComponent("sessions"), binary: script.path)
        defer { model.shutdown() }
        await model.refresh(); model.selectedModel = "discovered-model"
        let skill = SkillRecord(name: "probe", detail: "", source: path.path, pluginName: "fixture")
        let sent = await model.send(text: "Check the project", cwd: root.path, resume: nil, skills: [skill])
        XCTAssertTrue(sent, model.chatError ?? "No error")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("SELECTED_SKILL_ACTIVE"))
        XCTAssertTrue(runner.calls.contains { $0.contains("--cwd") && $0.contains(root.path) && $0.contains("inspect") })
        XCTAssertFalse(model.blocks.first?.text.contains("Return the diagnostic marker") ?? true)
    }
}
