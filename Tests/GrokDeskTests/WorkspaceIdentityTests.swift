import XCTest
@testable import GrokDeskCore

final class WorkspaceIdentityTests: XCTestCase {
    func testRegisteredWorkspaceOwnsChildChatsWithoutPrefixCollisions() {
        XCTAssertEqual(workspaceRoot("/tmp/repo/src",registered:["/tmp/repo"]),"/tmp/repo")
        XCTAssertEqual(workspaceRoot("/tmp/repo-other",registered:["/tmp/repo"]),"/tmp/repo-other")
        XCTAssertEqual(workspaceRoot("/tmp/work/.worktrees/task-7",registered:["/tmp/work/app"]),"/tmp/work/app")
    }
    func testGitSubfoldersAndWorktreesShareWorkspace() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo=root.appendingPathComponent("repo"), worktree=root.appendingPathComponent("branch")
        let metadata=repo.appendingPathComponent(".git/worktrees/branch")
        for folder in [metadata,repo.appendingPathComponent("src"),worktree] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        }
        try Data("../..\n".utf8).write(to:metadata.appendingPathComponent("commondir"))
        try Data(("gitdir: " + metadata.path + "\n").utf8).write(to:worktree.appendingPathComponent(".git"))
        XCTAssertEqual(workspaceRoot(repo.appendingPathComponent("src").path),repo.resolvingSymlinksInPath().path)
        XCTAssertEqual(workspaceRoot(worktree.path),repo.resolvingSymlinksInPath().path)
    }
    func testOAuthDispatchUsesNativeExtensionAndReturnsFailures() async throws {
        let script=try AgentTransportTests().fixture(#"""
import sys,json
for line in sys.stdin:
 r=json.loads(line);p=r.get('params',{})
 if r.get('method')=='_x.ai/mcp/auth_trigger' and p.get('session_id')=='s' and p.get('server_name')=='example':
  result={'result':{'status':'success'}}
 else: result={'result':{'status':'failed','error':'Server does not support OAuth'}}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
"""#)
        defer { try? FileManager.default.removeItem(at:script) }
        let client=AgentClient(binary:script.path,leaderSocket:"/tmp/oauth-test",owned:OwnedProcesses())
        defer { client.stop() }
        try client.start(model:"",effort:"",permission:"default")
        let status=try await client.authorizeMCP(sessionID:"s",serverName:"example")
        XCTAssertEqual(status,"success")
        do { _ = try await client.authorizeMCP(sessionID:"s",serverName:"other");XCTFail("Must surface an auth error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("does not support OAuth")) }
    }
}
