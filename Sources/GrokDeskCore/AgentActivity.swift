import Foundation

public enum AgentActivityKind: String, Codable, Sendable {
    case assistantMessage
    case thought
    case toolStarted
    case toolUpdated
    case permissionRequested
    case subagent
    case other
}

/// One observed ACP event. Parent/child links are populated only from explicit
/// protocol metadata; prose and similar session titles are never inspected.
public struct AgentActivityEvent: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let timestamp: Date
    public let kind: AgentActivityKind
    public let title: String
    public let detail: String
    public let toolCallID: String?
    public let toolStatus: String?
    public let parentSessionID: String?
    public let childSessionID: String?

    public init(
        id: UUID = UUID(),
        sessionID: String,
        timestamp: Date = Date(),
        kind: AgentActivityKind,
        title: String,
        detail: String = "",
        toolCallID: String? = nil,
        toolStatus: String? = nil,
        parentSessionID: String? = nil,
        childSessionID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.toolCallID = toolCallID
        self.toolStatus = toolStatus
        self.parentSessionID = parentSessionID
        self.childSessionID = childSessionID
    }

    public static func update(from envelope: AgentUpdateEnvelope, at timestamp: Date = Date()) -> Self? {
        guard let update = envelope.update else { return nil }
        let params = envelope.params ?? [:]
        let meta = (update["_meta"] as? [String: Any]) ?? (params["_meta"] as? [String: Any]) ?? [:]
        let updateKind = update["sessionUpdate"] as? String ?? ""
        let parent = explicitString([params, meta, update], keys: ["parentSessionId", "parent_session_id"])
        let child = explicitString([params, meta, update], keys: ["subagentSessionId", "subagent_session_id", "childSessionId", "child_session_id"])
        let status = update["status"] as? String
        let title = update["title"] as? String ?? update["toolName"] as? String ?? ""
        let toolID = update["toolCallId"] as? String
        let detail = activityText(update["content"])

        if child != nil {
            return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .subagent, title: title.isEmpty ? "Subagent" : title, detail: detail, toolCallID: toolID, toolStatus: status, parentSessionID: parent, childSessionID: child)
        }
        switch updateKind {
        case "agent_message_chunk":
            return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .assistantMessage, title: "Assistant", detail: detail, parentSessionID: parent)
        case "agent_thought_chunk":
            return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .thought, title: "Thought", detail: detail, parentSessionID: parent)
        case "tool_call":
            return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .toolStarted, title: title.isEmpty ? "Tool" : title, detail: detail, toolCallID: toolID, toolStatus: status ?? "in_progress", parentSessionID: parent)
        case "tool_call_update":
            return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .toolUpdated, title: title.isEmpty ? "Tool" : title, detail: detail, toolCallID: toolID, toolStatus: status, parentSessionID: parent)
        default:
            guard !updateKind.isEmpty || !detail.isEmpty else { return nil }
            return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .other, title: updateKind.isEmpty ? "ACP update" : updateKind, detail: detail, parentSessionID: parent)
        }
    }

    public static func permission(_ envelope: PermissionEnvelope, at timestamp: Date = Date()) -> Self {
        let params = envelope.params ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let parent = explicitString([params, meta], keys: ["parentSessionId", "parent_session_id"])
        let child = explicitString([params, meta], keys: ["subagentSessionId", "subagent_session_id", "childSessionId", "child_session_id"])
        return Self(sessionID: envelope.sessionID, timestamp: timestamp, kind: .permissionRequested, title: envelope.title, detail: "Permission request \(envelope.requestID)", parentSessionID: parent, childSessionID: child)
    }

    private static func explicitString(_ sources: [[String: Any]], keys: [String]) -> String? {
        for source in sources {
            for key in keys {
                if let value = source[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func activityText(_ value: Any?) -> String {
        if let text = value as? String { return String(text.prefix(4000)) }
        if let rows = value as? [[String: Any]] {
            return String(rows.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(4000))
        }
        if let object = value as? [String: Any] { return String((object["text"] as? String ?? "").prefix(4000)) }
        return ""
    }
}
