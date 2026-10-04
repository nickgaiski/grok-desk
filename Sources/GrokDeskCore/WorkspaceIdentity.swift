import Foundation

/// Sidebar identity is the workspace; session cwd remains untouched for correct resume behavior.
public func workspaceRoot(_ path: String, registered: [String] = []) -> String {
    func canonical(_ path:String)->String { URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path }
    let cwd=canonical(path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path:path)
    if let association=WorktreeAssociations().load().filter({ cwd == $0.key || cwd.hasPrefix($0.key+"/") }).max(by:{$0.key.count<$1.key.count}) {return association.value}
    let home=FileManager.default.homeDirectoryForCurrentUser.path
    let roots=registered.map(canonical)
    if let match=roots.filter({ cwd == $0 || ($0 != home && cwd.hasPrefix($0+"/")) }).max(by:{$0.count<$1.count}) { return match }
    var directory=URL(fileURLWithPath:cwd)
    while directory.path != "/" {
        let git=directory.appendingPathComponent(".git")
        var isDirectory:ObjCBool=false
        if FileManager.default.fileExists(atPath:git.path,isDirectory:&isDirectory) {
            if isDirectory.boolValue { return directory.path }
            if let text=try? String(contentsOf:git,encoding:.utf8),text.hasPrefix("gitdir:") {
                let gitPath=text.dropFirst(7).trimmingCharacters(in:.whitespacesAndNewlines)
                let metadata=URL(fileURLWithPath:gitPath,relativeTo:directory).standardizedFileURL
                if let common=try? String(contentsOf:metadata.appendingPathComponent("commondir"),encoding:.utf8) {
                    let shared=URL(fileURLWithPath:common.trimmingCharacters(in:.whitespacesAndNewlines),relativeTo:metadata).standardizedFileURL
                    if shared.lastPathComponent == ".git" { return shared.deletingLastPathComponent().path }
                }
            }
            return directory.path
        }
        directory.deleteLastPathComponent()
    }
    // Retain grouping for removed child worktrees when a single registered repository
    // remains next to their container. Never combine unrelated sibling repositories.
    for marker in ["/.worktrees/", "/worktrees/"] {
        if let range=cwd.range(of:marker) {
            let parent=String(cwd[..<range.lowerBound])
            let candidates=roots.filter { $0==parent || $0.hasPrefix(parent+"/") }
            if candidates.count==1 { return candidates[0] }
            return parent
        }
    }
    return cwd
}
