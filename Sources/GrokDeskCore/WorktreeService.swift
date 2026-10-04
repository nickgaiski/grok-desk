import Foundation
public enum WorktreeService {
    public static func paths(_ porcelain:String)->Set<String> {
        Set(porcelain.split(separator:"\n").filter{$0.hasPrefix("worktree ")}.map{String($0.dropFirst(9))})
    }
    public static func create(repo:String,name:String,ref:String,binary:String? = nil) async throws -> URL {
        guard name.range(of:#"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,options:.regularExpression) != nil else {throw fail("Use a worktree name with letters, digits, dashes or underscores.")}
        guard !ref.hasPrefix("-"),!ref.contains("\n") else {throw fail("Enter a branch, tag or commit ref.")}
        let root=try await RepositoryService.git(["rev-parse","--show-toplevel"],cwd:repo)
        guard root.status==0 else {throw fail("Choose a Git repository first.")}
        let source=root.stdout.trimmingCharacters(in:.whitespacesAndNewlines)
        let runner=LiveRunner(binary:binary ?? GrokPaths.binary,owned:OwnedProcesses(),cwd:URL(fileURLWithPath:source),timeout:120)
        let before=try await runner.run(["--cwd",source,"worktree","list","--json"])
        guard before.status==0, let beforeRows=try? JSONSerialization.jsonObject(with:Data(before.stdout.utf8)) as? [[String:Any]] else {throw fail("Could not inspect Grok's existing worktrees.")}
        var args=["--cwd",source,"worktree","create",name]
        if !ref.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {args += ["--ref",ref]}
        let result=try await runner.run(args)
        guard result.status==0 else {throw fail("Worktree creation failed. " + String((result.stderr.isEmpty ? result.stdout:result.stderr).prefix(1000)))}
        let after=try await runner.run(["--cwd",source,"worktree","list","--json"])
        guard after.status==0,let rows=try? JSONSerialization.jsonObject(with:Data(after.stdout.utf8)) as? [[String:Any]] else {throw fail("Created a checkout but could not read Grok's worktree metadata. Inspect it before retrying.")}
        let existing=Set(beforeRows.compactMap{$0["id"] as? String})
        let added=rows.filter { row in
            guard let id=row["id"] as? String,let parent=row["source_repo"] as? String else{return false}
            return !existing.contains(id) && URL(fileURLWithPath:parent).resolvingSymlinksInPath()==URL(fileURLWithPath:source).resolvingSymlinksInPath()
        }
        guard added.count==1,let path=added.first?["path"] as? String else {throw fail("Grok returned success but the new checkout could not be identified. Inspect worktrees before retrying.")}
        let check=try await RepositoryService.git(["rev-parse","--show-toplevel"],cwd:path)
        guard check.status==0,URL(fileURLWithPath:check.stdout.trimmingCharacters(in:.whitespacesAndNewlines)).resolvingSymlinksInPath()==URL(fileURLWithPath:path).resolvingSymlinksInPath() else {throw fail("The new checkout failed Git verification.")}
        return URL(fileURLWithPath:path)
    }
    private static func fail(_ text:String)->NSError {NSError(domain:"Worktree",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
}
