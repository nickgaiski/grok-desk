import XCTest
@testable import GrokDeskCore
final class WorktreeWorkflowTests:XCTestCase {
    func testTrackedCopyCheckoutReadbackAndParentAssociation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo=root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at:repo,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for args in [["init","-b","main"],["config","user.name","Fixture"],["config","user.email","fixture@example.test"]] {_ = try await RepositoryService.git(args,cwd:repo.path)}
        try Data("hello".utf8).write(to:repo.appendingPathComponent("a.txt"))
        _ = try await RepositoryService.git(["add","."],cwd:repo.path)
        _ = try await RepositoryService.git(["commit","-m","fixture"],cwd:repo.path)
        let cli=root.appendingPathComponent("grok-fixture")
        let script="""
        #!/usr/bin/python3
        import sys,json,pathlib,subprocess
        args=sys.argv[1:]; repo=pathlib.Path(args[1]); state=repo.parent/'state.json'
        if args[3]=='list':
            print(state.read_text() if state.exists() else '[]')
        elif args[3]=='create':
            target=repo.parent/args[4]
            result=subprocess.run(['git','clone','--quiet','--no-hardlinks',str(repo),str(target)])
            if result.returncode:sys.exit(result.returncode)
            state.write_text(json.dumps([{'id':'fixture','path':str(target),'source_repo':str(repo)}]))
            print(target)
        """
        try Data(script.utf8).write(to:cli);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let checkout=try await WorktreeService.create(repo:repo.path,name:"isolated",ref:"HEAD",binary:cli.path)
        XCTAssertEqual(try String(contentsOf:checkout.appendingPathComponent("a.txt"),encoding:.utf8),"hello")
        let associations=WorktreeAssociations(url:root.appendingPathComponent("map.json"));try associations.associate(checkout.path,with:repo.path)
        XCTAssertEqual(associations.load()[checkout.resolvingSymlinksInPath().path],repo.resolvingSymlinksInPath().path)
        do {_ = try await WorktreeService.create(repo:repo.path,name:"--bad",ref:"HEAD",binary:cli.path);XCTFail("Invalid names must be rejected")}catch{}
        do {_ = try await WorktreeService.create(repo:repo.path,name:"isolated",ref:"HEAD",binary:cli.path);XCTFail("Existing checkout must not be reused as new")}catch{}
    }
    func testSettingScopeAndPolicyPrecedence() {
        let field=SettingDescriptor("ui.permission_mode","Permissions",["ask","auto"],"ask",environment:"TEST_PERMISSION")
        XCTAssertFalse(field.projectWritable)
        XCTAssertEqual(field.effective(user:"[ui]\npermission_mode='auto'",requirements:"[ui]\npermission_mode='ask'",environment:["TEST_PERMISSION":"auto"]).value,"ask")
        XCTAssertEqual(field.effective(user:"[ui]\npermission_mode='ask'",environment:["TEST_PERMISSION":"auto"]).source,.environment)
    }
}
