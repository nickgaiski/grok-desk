import Foundation

public struct RepositoryFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let state: String
    public var id: String { path }
    public var staged: Bool { state.first != " " && state.first != "?" }
}
public struct RepositorySnapshot: Equatable, Sendable {
    public var root: String
    public var branch: String
    public var commit: String
    public var isWorktree: Bool
    public var files: [RepositoryFile]
    public var additions: Int
    public var deletions: Int
    public var defaultBranch: String
    public var deployScript: String?
    public var label: String { branch.isEmpty ? "Detached · " + commit : branch }
}
public enum RepositoryAction: String, CaseIterable, Identifiable {
    case stage = "Stage selected", commit = "Commit", push = "Push", pullRequest = "Create draft PR", merge = "Merge branch", branch = "Create branch", deploy = "Deploy"
    public var id: String { rawValue }
}
public struct RepositoryPlan: Sendable {
    public let executable: String
    public let arguments: [String]
    public let root: String
    public let expectedCommit: String
    public var display: String { ([URL(fileURLWithPath:executable).lastPathComponent] + arguments).map { "'" + $0.replacingOccurrences(of:"'",with:"'\\''") + "'" }.joined(separator:" ") }
}
public enum RepositoryService {
    public static func executable(_ name:String)->String {
        let roots = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin","/usr/bin",FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return roots.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath:$0) } ?? "/usr/bin/" + name
    }
    public static func git(_ args:[String],cwd:String) async throws -> CommandResult {
        try await LiveRunner(binary:"/usr/bin/git",owned:OwnedProcesses(),cwd:URL(fileURLWithPath:cwd),timeout:30).run(args)
    }
    public static func parseStatus(_ text:String)->[RepositoryFile] {
        let entries=text.split(separator:"\0",omittingEmptySubsequences:true).map(String.init)
        var files:[RepositoryFile]=[], i=0
        while i<entries.count {
            let value=entries[i];i+=1
            guard value.count>=4 else {continue}
            let state=String(value.prefix(2));files.append(.init(path:String(value.dropFirst(3)),state:state))
            if state.contains("R") || state.contains("C") { i+=1 }
        }
        return files
    }
    public static func inspect(_ cwd:String) async throws -> RepositorySnapshot? {
        guard !cwd.isEmpty,FileManager.default.fileExists(atPath:cwd) else {return nil}
        let rootResult=try await git(["rev-parse","--show-toplevel"],cwd:cwd)
        if rootResult.status != 0 {
            guard cwd != FileManager.default.homeDirectoryForCurrentUser.path else { return nil }
            var candidates: [String] = []
            let excluded: Set<String> = ["node_modules", "dist", "build", "work", "graphify-out", "vendor"]
            func search(_ url: URL, depth: Int) {
                guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
                for child in children.prefix(100) where !excluded.contains(child.lastPathComponent) {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    if FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) { candidates.append(child.path) }
                    else { search(child, depth: depth - 1) }
                }
            }
            search(URL(fileURLWithPath: cwd), depth: 2)
            return candidates.count == 1 ? try await inspect(candidates[0]) : nil
        }
        let root=rootResult.stdout.trimmingCharacters(in:.whitespacesAndNewlines)
        async let branch=git(["symbolic-ref","--quiet","--short","HEAD"],cwd:root)
        async let commit=git(["rev-parse","--short","HEAD"],cwd:root)
        async let status=git(["status","--porcelain=v1","-z"],cwd:root)
        async let stats=git(["diff","--numstat","HEAD"],cwd:root)
        async let common=git(["rev-parse","--git-common-dir"],cwd:root)
        async let defaultRef=git(["symbolic-ref","--quiet","refs/remotes/origin/HEAD"],cwd:root)
        let (b,c,s,n,g,d)=try await (branch,commit,status,stats,common,defaultRef)
        var add=0,remove=0
        for row in n.stdout.split(separator:"\n") { let fields=row.split(separator:"\t");if fields.count>=2 {add+=Int(fields[0]) ?? 0;remove+=Int(fields[1]) ?? 0} }
        let commonPath=URL(fileURLWithPath:g.stdout.trimmingCharacters(in:.whitespacesAndNewlines),relativeTo:URL(fileURLWithPath:root,isDirectory:true)).standardizedFileURL
        var deploy:String?
        if let data=try? Data(contentsOf:URL(fileURLWithPath:root).appendingPathComponent("package.json")),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {deploy=(object["scripts"] as? [String:String])?["deploy"]}
        return .init(root:root,branch:b.status==0 ? b.stdout.trimmingCharacters(in:.whitespacesAndNewlines):"",commit:c.status==0 ? c.stdout.trimmingCharacters(in:.whitespacesAndNewlines):"unborn",isWorktree:commonPath.deletingLastPathComponent().resolvingSymlinksInPath().path != URL(fileURLWithPath:root).resolvingSymlinksInPath().path,files:parseStatus(s.stdout),additions:add,deletions:remove,defaultBranch:d.stdout.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"refs/remotes/origin/",with:""),deployScript:deploy)
    }
    public static func plan(_ action:RepositoryAction,snapshot:RepositorySnapshot,input:String,selected:Set<String> = []) throws -> RepositoryPlan {
        func fail(_ message:String)throws->Never {throw NSError(domain:"Repository",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        var binary="/usr/bin/git",args:[String]=[]
        switch action {
        case .stage:
            guard !selected.isEmpty,selected.isSubset(of:Set(snapshot.files.map(\.path))) else {try fail("Select changed files to stage.")}
            args=["add","--"]+selected.sorted()
        case .commit:
            guard !value.isEmpty,snapshot.files.contains(where:\.staged) else {try fail("Enter a commit message and stage files first.")};args=["commit","-m",value]
        case .push:
            guard !snapshot.branch.isEmpty else {try fail("Create a branch before pushing a detached commit.")};args=["push","--set-upstream","origin",snapshot.branch]
        case .pullRequest:
            guard !value.isEmpty,!snapshot.branch.isEmpty else {try fail("Enter a PR title on a named branch.")}
            binary=executable("gh");args=["pr","create","--draft","--title",value,"--body","Created from Grok Desk."]
            if !snapshot.defaultBranch.isEmpty {args += ["--base",snapshot.defaultBranch]}
        case .merge,.branch:
            guard !value.isEmpty,!value.hasPrefix("-"),!value.contains(where:\.isWhitespace) else {try fail("Enter a valid branch name.")}
            if action == .merge && !snapshot.files.isEmpty {try fail("Commit or stash your changes before merging.")}
            args=action == .merge ? ["merge","--no-edit","--",value]:["switch","-c",value]
        case .deploy:
            guard snapshot.deployScript != nil else {try fail("This repository needs a deploy script in package.json.")}
            binary=executable("npm");args=["run","deploy"]
        }
        return .init(executable:binary,arguments:args,root:snapshot.root,expectedCommit:snapshot.commit)
    }
    public static func execute(_ plan:RepositoryPlan) async throws -> CommandResult {
        guard let current=try await inspect(plan.root),current.commit==plan.expectedCommit else {throw NSError(domain:"Repository",code:2,userInfo:[NSLocalizedDescriptionKey:"HEAD changed. Refresh and review the action again."])}
        return try await LiveRunner(binary:plan.executable,owned:OwnedProcesses(),cwd:URL(fileURLWithPath:plan.root),timeout:300).run(plan.arguments)
    }
}
