import Foundation
public struct WorktreeAssociations {
    public var url:URL
    public init(url:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Grok Desk/worktree-projects.json")) {self.url=url}
    public func load()->[String:String] {(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))) ?? [:]}
    public func associate(_ checkout:String,with project:String) throws {
        var items=load();items[URL(fileURLWithPath:checkout).resolvingSymlinksInPath().path]=URL(fileURLWithPath:project).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(items).write(to:url,options:.atomic)
    }
}
