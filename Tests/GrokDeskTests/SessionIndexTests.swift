import XCTest
@testable import GrokDeskCore

final class SessionIndexTests: XCTestCase {
    func testReadsSummaryAndSkipsTranscripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dir = root.appendingPathComponent("group/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summary = """
        {"info":{"id":"abc","cwd":"/tmp/repo"},"generated_title":"Fix the build","last_active_at":"2026-10-02T00:00:00Z"}
        """
        try summary.write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try "huge".write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)

        let sessions = loadSessions(root: root)
        XCTAssertEqual(sessions.map(\.id), ["abc"])
        XCTAssertEqual(sessions.map(\.title), ["Fix the build"])
        XCTAssertEqual(sessions.map(\.cwd), ["/tmp/repo"])
    }

    func testBlankTitleBecomesUntitled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dir = root.appendingPathComponent("group/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summary = #"{"info":{"id":"blank","cwd":"/tmp/repo"},"generated_title":"   "}"#
        try summary.write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(loadSessions(root: root).map(\.title), ["Untitled chat"])
    }

    func testResumeCommandQuotesTheCwd() {
        let command = terminalResumeCommand(sessionID: "abc", cwd: "/Users/example/My Repo")
        XCTAssertEqual(command, "grok --resume abc --cwd '/Users/example/My Repo'")
    }
}
