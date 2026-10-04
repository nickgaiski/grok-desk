import Foundation

public struct ChatBlock: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var text: String
    public init(id: String, kind: String, text: String) { self.id = id; self.kind = kind; self.text = text }
}

public func applyChatUpdate(_ blocks: [ChatBlock], update raw: [String: Any]) -> [ChatBlock] {
    let update = raw["update"] as? [String: Any] ?? raw
    var next = blocks
    let kind = update["sessionUpdate"] as? String ?? ""
    let text = chunkText(update["content"])
    switch kind {
    case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
        let blockKind = kind == "user_message_chunk" ? "user" : kind == "agent_thought_chunk" ? "thought" : "assistant"
        if let last = next.last, last.kind == blockKind {
            next[next.count - 1].text = String((last.text + text).suffix(100_000))
        } else if !text.isEmpty { next.append(ChatBlock(id: UUID().uuidString, kind: blockKind, text: String(text.suffix(100_000)))) }
    case "tool_call", "tool_call_update":
        let id = update["toolCallId"] as? String ?? UUID().uuidString
        let previous = next.first { $0.id == id }
        let title = update["title"] as? String ?? previous?.text.components(separatedBy: " · ").first ?? "Tool"
        let status = update["status"] as? String ?? "running"
        let body = title + " · " + status + (text.isEmpty ? "" : "\n" + String(text.prefix(8000)))
        if let index = next.firstIndex(where: { $0.id == id }) { next[index].text = body }
        else { next.append(ChatBlock(id: id, kind: "tool", text: body)) }
    case "plan":
        let entries = update["entries"] as? [[String: Any]] ?? []
        let body = entries.map { "\(($0["status"] as? String == "completed") ? "✓" : "○") \($0["content"] as? String ?? "")" }.joined(separator: "\n")
        if let index = next.firstIndex(where: { $0.id == "active-plan" }) { next[index].text = body }
        else { next.append(ChatBlock(id: "active-plan", kind: "plan", text: body)) }
    default: break
    }
    return Array(next.suffix(240))
}

private func chunkText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    if let array = content as? [[String: Any]] { return array.map { chunkText($0) }.joined(separator: "\n") }
    guard let object = content as? [String: Any] else { return "" }
    if object["type"] as? String == "diff" {
        return "\(object["path"] as? String ?? "File")\n\(object["oldText"] as? String ?? "")\n→\n\(object["newText"] as? String ?? "")"
    }
    var parts: [String] = []
    if let text = object["text"] as? String, !text.isEmpty { parts.append(text) }
    if let nested = object["content"] {
        let inner = chunkText(nested)
        if !inner.isEmpty { parts.append(inner) }
    }
    for key in ["path", "uri", "file_path"] {
        if let path = object[key] as? String, path.contains(".") { parts.append(path) }
    }
    return parts.joined(separator: "\n")
}

public struct ContextMeter: Equatable, Sendable { public var used: Int; public var label: String }
public func contextMeter(from update: [String: Any]) -> ContextMeter? {
    let meta = update["_meta"] as? [String: Any] ?? [:]
    let usage = (meta["usage"] as? [String: Any]) ?? (update["usage"] as? [String: Any]) ?? update
    guard let used = usage["inputTokens"] as? Int ?? usage["input_tokens"] as? Int ?? usage["contextTokensUsed"] as? Int else { return nil }
    return ContextMeter(used: used, label: "\(used.formatted()) tokens in context")
}

/// File-backed, bounded history. Never creates another transcript store.
public func sessionHistory(root: URL, sessionID: String, byteLimit: UInt64 = 1_000_000) -> [ChatBlock] {
    guard let groups = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
    for group in groups {
        let url = group.appendingPathComponent(sessionID).appendingPathComponent("updates.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > byteLimit ? size - byteLimit : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 10)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines.reduce([]) { blocks, line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return blocks }
            return applyChatUpdate(blocks, update: object["params"] as? [String: Any] ?? object)
        }
    }
    return []
}
