import XCTest
@testable import GrokDeskCore

final class PanelRepositoryTests:XCTestCase {
    func testGitDetectionStagingCommitAndDetachedHead() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        _ = try await RepositoryService.git(["init","-b","main"],cwd:root.path)
        _ = try await RepositoryService.git(["config","user.name","Fixture"],cwd:root.path)
        _ = try await RepositoryService.git(["config","user.email","fixture@example.test"],cwd:root.path)
        try Data("one\n".utf8).write(to:root.appendingPathComponent("a file.txt"))
        let first=try await RepositoryService.inspect(root.path)
        let repo=try XCTUnwrap(first)
        XCTAssertEqual(repo.branch,"main");XCTAssertEqual(repo.files.first?.path,"a file.txt")
        let stage=try RepositoryService.plan(.stage,snapshot:repo,input:"",selected:["a file.txt"])
        let staged=try await RepositoryService.execute(stage);XCTAssertEqual(staged.status,0)
        let afterStage=try await RepositoryService.inspect(root.path)
        let commit=try RepositoryService.plan(.commit,snapshot:try XCTUnwrap(afterStage),input:"Fixture commit")
        let committed=try await RepositoryService.execute(commit);XCTAssertEqual(committed.status,0)
        _ = try await RepositoryService.git(["checkout","--detach"],cwd:root.path)
        let detached=try await RepositoryService.inspect(root.path)
        XCTAssertEqual(detached?.branch,"");XCTAssertNotEqual(detached?.commit,"unborn")
        XCTAssertThrowsError(try RepositoryService.plan(.push,snapshot:try XCTUnwrap(detached),input:""))
        do {_ = try await RepositoryService.execute(commit);XCTFail("Must reject stale HEAD")}catch{}
    }
    func testFileEditorRefusesToOverwriteExternalChanges() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".txt")
        defer {try? FileManager.default.removeItem(at:file)}
        try Data("original".utf8).write(to:file)
        var doc=try PanelFileDocument(url:file);doc.text="edited"
        try Data("external".utf8).write(to:file)
        XCTAssertThrowsError(try doc.save())
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"external")
    }
    func testBrowserBridgeConfigPreservesOtherConnectionsAndRequiresApproval() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let file=dir.appendingPathComponent("config.toml")
        try Data("# retained\n[mcp_servers.existing]\nurl = 'https://example.test/mcp'\n".utf8).write(to:file)
        try BrowserIntegration.configure(at:file,npx:"/usr/bin/true")
        let text=try String(contentsOf:file,encoding:.utf8)
        XCTAssertTrue(text.contains("# retained"));XCTAssertTrue(text.contains("existing"))
        XCTAssertTrue(text.contains("--extension"));XCTAssertFalse(text.contains("EXTENSION_TOKEN"))
        XCTAssertThrowsError(try BrowserIntegration.configure(at:file,npx:"/usr/bin/true"))
    }
}
