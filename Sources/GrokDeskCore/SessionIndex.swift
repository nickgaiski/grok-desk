import Foundation

public struct DeskSession: Equatable, Sendable, Identifiable {
    public var id: String
    public var cwd: String
    public var title: String
    public var updatedAt: String
    public var branch: String? = nil
    public var commit: String? = nil
    public var gitRoot: String? = nil
    public var repositoryContext: String? {
        if let branch, !branch.isEmpty { return "At chat creation · " + branch + (commit.map { " · " + String($0.prefix(8)) } ?? "") }
        return commit.map { "At chat creation · commit " + String($0.prefix(8)) }
    }
}

public func loadSessions(root: URL) -> [DeskSession] {
    guard let groups = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var found: [DeskSession] = []
    for group in groups {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: group,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for child in children {
            let summaryURL = child.appendingPathComponent("summary.json")
            guard let data = try? Data(contentsOf: summaryURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = object["info"] as? [String: Any],
                  let id = info["id"] as? String
            else { continue }
            if object["num_chat_messages"] as? Int == 0 { continue }
            let cwd = (info["cwd"] as? String) ?? ""
            let rawTitle = (object["generated_title"] as? String)
                ?? (object["session_summary"] as? String)
                ?? ""
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? "Untitled chat" : trimmed
            let updated = (object["last_active_at"] as? String)
                ?? (object["updated_at"] as? String)
                ?? ""
            found.append(DeskSession(id: id, cwd: cwd, title: title, updatedAt: updated, branch: object["head_branch"] as? String, commit: object["head_commit"] as? String, gitRoot: object["git_root_dir"] as? String))
        }
    }
    return found.sorted { $0.updatedAt > $1.updatedAt }
}

public func sessionDirectory(root: URL, id: String) -> URL? {
    guard !id.isEmpty, let groups = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
    for group in groups {
        let child = group.appendingPathComponent(id, isDirectory: true)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: child.path, isDirectory: &directory), directory.boolValue { return child }
    }
    return nil
}
