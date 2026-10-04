import Foundation

public struct AccountProfile: Equatable, Sendable {
    public var ok: Bool
    public var name: String
    public var email: String
    public var initials: String
    public var message: String
}

public func parseAccount(_ data: Data) -> AccountProfile {
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return AccountProfile(ok: false, name: "Grok", email: "", initials: "?", message: "Could not read the Grok account.")
    }
    let entries = raw.values.compactMap { $0 as? [String: Any] }
    guard let entry = entries.first(where: { $0["email"] is String }) ?? entries.first else {
        return AccountProfile(ok: false, name: "Grok", email: "", initials: "?", message: "Grok is not signed in.")
    }
    let email = entry["email"] as? String ?? ""
    let given = (entry["first_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = displayAccountName(given: given, email: email)
    return AccountProfile(ok: true, name: name, email: email, initials: initials(for: name, email: email), message: "")
}

public func loadAccount(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AccountProfile {
    let url = home.appendingPathComponent(".grok/auth.json")
    guard let data = try? Data(contentsOf: url) else {
        return AccountProfile(ok: false, name: "Grok", email: "", initials: "?", message: "Grok is not signed in.")
    }
    return parseAccount(data)
}

func displayAccountName(given: String, email: String) -> String {
    if !given.isEmpty { return given }
    let local = email.split(separator: "@").first.map(String.init) ?? ""
    if local.isEmpty { return "Grok" }
    if local.contains(".") {
        return local.split(separator: ".").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }
    return local.prefix(1).uppercased() + local.dropFirst()
}

func initials(for name: String, email: String) -> String {
    let parts = name.split(separator: " ")
    if parts.count >= 2 { return (parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
    if name.count >= 2 { return String(name.prefix(2)).uppercased() }
    return String(email.prefix(1)).uppercased()
}

public struct UsageTotals: Equatable, Sendable {
    public var chats: Int
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int
    public var models: [String]
}

public func usageTotals(root: URL) -> UsageTotals {
    var totals = UsageTotals(chats: 0, userMessages: 0, assistantMessages: 0, toolCalls: 0, models: [])
    guard let groups = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return totals
    }
    var models = Set<String>()
    for group in groups {
        guard let children = try? FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
        for child in children {
            let summary = child.appendingPathComponent("summary.json")
            guard FileManager.default.fileExists(atPath: summary.path) else { continue }
            totals.chats += 1
            guard let data = try? Data(contentsOf: child.appendingPathComponent("signals.json")),
                  let signals = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            totals.userMessages += signals["userMessageCount"] as? Int ?? 0
            totals.assistantMessages += signals["assistantMessageCount"] as? Int ?? 0
            totals.toolCalls += signals["toolCallCount"] as? Int ?? 0
            if let used = signals["modelsUsed"] as? [String] { used.forEach { models.insert($0) } }
            if let primary = signals["primaryModelId"] as? String { models.insert(primary) }
        }
    }
    totals.models = models.sorted()
    return totals
}

public struct SkillRecord: Equatable, Sendable, Identifiable {
    public var id: String { name + source }
    public var name: String
    public var detail: String
    public var source: String
    public var pluginName: String = ""
    public var commandName: String { pluginName.isEmpty ? name : pluginName + ":" + name }
}

public func parseInspectCatalog(_ data: Data) -> (skills: [SkillRecord], plugins: [ListedItem], mcp: [ListedItem]) {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ([], [], [])
    }
    let skills = (root["skills"] as? [[String: Any]] ?? []).compactMap { row -> SkillRecord? in
        let name = row["name"] as? String ?? ""
        guard !name.isEmpty, row["userInvocable"] as? Bool != false else { return nil }
        let source = row["source"] as? [String: Any]
        return SkillRecord(name: name, detail: row["description"] as? String ?? "", source: source?["path"] as? String ?? row["source"] as? String ?? "", pluginName: source?["plugin_name"] as? String ?? "")
    }
    let plugins = (root["plugins"] as? [[String: Any]] ?? []).compactMap { row -> ListedItem? in
        let name = row["name"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        return ListedItem(name: name, detail: row["path"] as? String ?? "", enabled: row["enabled"] as? Bool ?? true, scope: row["scope"] as? String ?? "")
    }
    let mcp = (root["mcpServers"] as? [[String: Any]] ?? []).compactMap { row -> ListedItem? in
        let name = row["name"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let source = row["source"] as? [String:Any] ?? [:]
        return ListedItem(name: name, detail: row["target"] as? String ?? "", enabled: row["disabled"] as? Bool != true, scope: source["type"] as? String ?? "", pluginName: source["plugin_name"] as? String ?? "")
    }
    return (skills, plugins, mcp)
}

public struct ListedItem: Equatable, Sendable, Identifiable {
    public var id: String { name + scope }
    public var name: String
    public var detail: String
    public var enabled: Bool
    public var scope: String
    public var repository: String = ""
    public var pluginName: String = ""
}

public func parseJsonList(_ stdout: String, nameKey: String = "name") -> [ListedItem] {
    guard let data = stdout.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        let name = row[nameKey] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let detail = (row["url"] as? String) ?? (row["command"] as? String) ?? (row["path"] as? String) ?? (row["description"] as? String) ?? ""
        let enabled = row["enabled"] as? Bool ?? true
        let scope = row["scope"] as? String ?? "user"
        return ListedItem(name: name, detail: detail, enabled: enabled, scope: scope, repository: row["source"] as? String ?? "")
    }
}

public func readableConfig(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
    let url = home.appendingPathComponent(".grok/config.toml")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "No config.toml yet." }
    let secret = ["token", "secret", "password", "api_key", "apikey"]
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
        let lower = line.lowercased()
        return !secret.contains { lower.contains($0) }
    }
    return lines.prefix(80).joined(separator: "\n")
}
