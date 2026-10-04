import Foundation

/// A notification routed to the runtime that owns the ACP session.
public struct AgentUpdateEnvelope: Equatable, Sendable {
    public let sessionID: String
    /// JSON-encoded `params.update` (or the params object for older providers).
    public let payload: Data
    /// JSON-encoded original `params`, retained for explicitly supplied metadata.
    public let metadata: Data

    public init(sessionID: String, payload: Data, metadata: Data) {
        self.sessionID = sessionID
        self.payload = payload
        self.metadata = metadata
    }

    public var update: [String: Any]? {
        try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    public var params: [String: Any]? {
        try? JSONSerialization.jsonObject(with: metadata) as? [String: Any]
    }
}

/// A permission request remains tied to the ACP session that issued it.
public struct PermissionEnvelope: Equatable, Sendable {
    public let sessionID: String
    public let requestID: Int
    public let title: String
    public let choices: [PermissionChoice]
    public let metadata: Data

    public init(sessionID: String, requestID: Int, title: String, choices: [PermissionChoice], metadata: Data = Data()) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.title = title
        self.choices = choices
        self.metadata = metadata
    }

    public var params: [String: Any]? { try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] }
}

/// ACP extensions that have evidence in initialize/session-open responses.
/// An absent capability always means unsupported; slash commands are not RPCs.
public struct RuntimeSupport: Equatable, Sendable {
    public var commands: Set<String>
    public var configurationIDs: Set<String>
    public var permissionModes: Set<String>
    public var supportsNativePlan: Bool
    public var supportsNativeSteer: Bool
    public var supportsTaskControl: Bool

    public init(
        commands: Set<String> = [],
        configurationIDs: Set<String> = [],
        permissionModes: Set<String> = [],
        supportsNativePlan: Bool = false,
        supportsNativeSteer: Bool = false,
        supportsTaskControl: Bool = false
    ) {
        self.commands = commands
        self.configurationIDs = configurationIDs
        self.permissionModes = permissionModes
        self.supportsNativePlan = supportsNativePlan
        self.supportsNativeSteer = supportsNativeSteer
        self.supportsTaskControl = supportsTaskControl
    }
}

/// The unmodified session-open response is retained for capability readback.
public struct SessionOpenResult: Equatable, Sendable {
    public let sessionID: String
    public let support: RuntimeSupport
    public let metadata: Data

    public init(sessionID: String, support: RuntimeSupport, metadata: Data) {
        self.sessionID = sessionID
        self.support = support
        self.metadata = metadata
    }
}

public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case ask = "default"
    case auto
    case alwaysApprove = "bypassPermissions"

    /// Values accepted by the existing Grok CLI process flag.
    public var cliValue: String {
        switch self {
        case .ask: "default"
        case .auto: "auto"
        case .alwaysApprove: "bypassPermissions"
        }
    }
}

public enum RunState: String, Codable, Sendable {
    case unknown
    case idle
    case working
    case needsInput
    case failed
    case completed
    case cancelled
}

public struct RuntimeSummary: Equatable, Identifiable, Sendable {
    public var id: String { runtimeID }
    public let runtimeID: String
    public let sessionID: String?
    public let cwd: String
    public let state: RunState
    public let queuedCount: Int
    public let needsInput: Bool
    public let lastActivity: Date?
    public let currentAction: String?
    public let parentSessionID: String?
    public let childSessionIDs: [String]
    public let isExternalObservedSession: Bool
    public let queuePaused: Bool
    public let queueNeedsReview: Bool
    public let queuePauseReason: String?
    public let activeQueuedPromptID: UUID?

    public init(
        runtimeID: String,
        sessionID: String?,
        cwd: String,
        state: RunState,
        queuedCount: Int,
        needsInput: Bool,
        lastActivity: Date?,
        currentAction: String?,
        parentSessionID: String?,
        childSessionIDs: [String] = [],
        isExternalObservedSession: Bool = false,
        queuePaused: Bool = false,
        queueNeedsReview: Bool = false,
        queuePauseReason: String? = nil,
        activeQueuedPromptID: UUID? = nil
    ) {
        self.runtimeID = runtimeID
        self.sessionID = sessionID
        self.cwd = cwd
        self.state = state
        self.queuedCount = queuedCount
        self.needsInput = needsInput
        self.lastActivity = lastActivity
        self.currentAction = currentAction
        self.parentSessionID = parentSessionID
        self.childSessionIDs = childSessionIDs
        self.isExternalObservedSession = isExternalObservedSession
        self.queuePaused = queuePaused
        self.queueNeedsReview = queueNeedsReview
        self.queuePauseReason = queuePauseReason
        self.activeQueuedPromptID = activeQueuedPromptID
    }
}
