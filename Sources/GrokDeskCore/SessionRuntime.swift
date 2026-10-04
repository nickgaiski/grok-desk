import Combine
import Foundation

@MainActor
public final class SessionRuntime: ObservableObject {
    public let id: String
    public private(set) var sessionID: String?
    public var cwd: String
    public var blocks: [ChatBlock] = []
    public var busy = false
    public var connecting = false
    public var chatError: String?
    public var permission: PermissionEnvelope?
    public var connectionStatus = "Not connected"
    public var capabilities = AgentCapabilities()
    public var support = RuntimeSupport()
    public var contextLabel = ""
    public var permissionMode: PermissionMode = .ask
    public var agent: AgentClient?
    public var sessionNeedsLoad = true
    public var loadingSession = false
    public var connectionEpoch = UUID()
    public var turnEpoch = UUID()
    public var lastRequest: QueuedPrompt?
    public var state: RunState = .idle
    public var activity: [AgentActivityEvent] = []
    public var explicitParentSessionID: String?
    public var observedChildSessionIDs: Set<String> = []
    public var isExternalObservedSession = false
    public var queue: [QueuedPrompt]
    public var queuePaused: Bool
    public var queuePauseReason: String?
    public var queueDrainActive = false
    public var activeQueuedPromptID: UUID?

    private let store: PromptQueueStore
    private let maxActivity = 500

    init(
        id: String,
        sessionID: String?,
        cwd: String,
        store: PromptQueueStore,
        queuedPrompts: [QueuedPrompt] = [],
        requiresReview: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.store = store
        self.queue = queuedPrompts.map { prompt in
            var prompt = prompt
            prompt.requiresReview = prompt.requiresReview || requiresReview
            return prompt
        }
        self.queuePaused = requiresReview || queuedPrompts.contains(where: \.requiresReview)
        self.queuePauseReason = requiresReview ? "Review queued prompts before sending." : nil
    }

    public var runtimeID: String { id }
    public var queuedPrompts: [QueuedPrompt] { queue }
    public var isNeedsInput: Bool { permission != nil }
    public var lastActivity: Date? { activity.last?.timestamp }
    public var currentAction: String? {
        guard let event = activity.last(where: { $0.kind == .toolStarted || $0.kind == .toolUpdated }) else { return nil }
        if let status = event.toolStatus, ["completed", "failed", "cancelled"].contains(status.lowercased()) { return nil }
        return event.title + (event.toolStatus.map { " · \($0)" } ?? "")
    }
    public var parentSessionID: String? { explicitParentSessionID ?? activity.reversed().compactMap(\.parentSessionID).first }

    public func summary() -> RuntimeSummary {
        RuntimeSummary(
            runtimeID: id,
            sessionID: sessionID,
            cwd: cwd,
            state: state,
            queuedCount: queue.count,
            needsInput: isNeedsInput,
            lastActivity: lastActivity,
            currentAction: currentAction,
            parentSessionID: parentSessionID,
            childSessionIDs: observedChildSessionIDs.sorted(),
            isExternalObservedSession: isExternalObservedSession,
            queuePaused: queuePaused,
            queueNeedsReview: queue.contains(where: \.requiresReview),
            queuePauseReason: queuePauseReason,
            activeQueuedPromptID: activeQueuedPromptID
        )
    }

    func adopt(providerSessionID: String, cwd: String) {
        sessionID = providerSessionID
        if self.cwd.isEmpty { self.cwd = cwd }
        for index in queue.indices { queue[index].sessionID = providerSessionID }
        persistQueue()
    }

    func appendActivity(_ event: AgentActivityEvent) {
        activity.append(event)
        if activity.count > maxActivity { activity.removeFirst(activity.count - maxActivity) }
    }

    func enqueue(_ prompt: QueuedPrompt) {
        queue.append(prompt)
        persistQueue()
    }

    func replaceQueue(_ prompts: [QueuedPrompt]) {
        queue = prompts
        persistQueue()
    }

    func removeQueuedPrompt(id: UUID) {
        queue.removeAll { $0.id == id }
        persistQueue()
    }

    func persistQueue() {
        do { try store.save(runtimeID: id, sessionID: sessionID, cwd: cwd, prompts: queue) }
        catch { queuePauseReason = "Could not save queued prompts: \(error.localizedDescription)"; queuePaused = true }
    }
}
