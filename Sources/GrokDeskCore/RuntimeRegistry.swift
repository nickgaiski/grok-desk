import Foundation

@MainActor
public final class RuntimeRegistry {
    private var runtimes: [String: SessionRuntime] = [:]
    private let store: PromptQueueStore

    public init(queueStore: PromptQueueStore = PromptQueueStore()) {
        self.store = queueStore
        for saved in queueStore.loadAll() {
            let runtime = SessionRuntime(
                id: saved.runtimeID,
                sessionID: saved.sessionID,
                cwd: saved.cwd,
                store: queueStore,
                queuedPrompts: saved.prompts,
                requiresReview: true
            )
            runtimes[runtime.id] = runtime
            runtime.persistQueue()
        }
    }

    public func newDraft(cwd: String = "") -> SessionRuntime {
        let runtime = SessionRuntime(id: "draft:\(UUID().uuidString)", sessionID: nil, cwd: cwd, store: store)
        runtimes[runtime.id] = runtime
        return runtime
    }

    public func runtime(for sessionID: String, cwd: String = "") -> SessionRuntime {
        if let existing = runtimes[sessionID] {
            if existing.cwd.isEmpty, !cwd.isEmpty { existing.cwd = cwd }
            return existing
        }
        if let existing = runtimes.values.first(where: { $0.sessionID == sessionID }) { return existing }
        let runtime = SessionRuntime(id: sessionID, sessionID: sessionID, cwd: cwd, store: store)
        runtimes[runtime.id] = runtime
        return runtime
    }

    public func runtime(id: String) -> SessionRuntime? { runtimes[id] }

    /// Retains child-session links only when the ACP envelope explicitly states
    /// the parent or child identity. Observed sessions have no invented control.
    public func observe(_ event: AgentActivityEvent, from owner: SessionRuntime) {
        if event.sessionID == owner.sessionID {
            if let parent = event.parentSessionID { owner.explicitParentSessionID = parent }
            guard let childID = event.childSessionID, let parentID = owner.sessionID else { return }
            owner.observedChildSessionIDs.insert(childID)
            let child = observedRuntime(sessionID: childID, parentSessionID: parentID)
            child.appendActivity(event)
            if let state = state(from: event) { child.state = state }
            return
        }
        if let parentID = event.parentSessionID, parentID == owner.sessionID {
            owner.observedChildSessionIDs.insert(event.sessionID)
        }
        let child = observedRuntime(sessionID: event.sessionID, parentSessionID: event.parentSessionID)
        child.appendActivity(event)
        if let state = state(from: event) { child.state = state }
    }

    public func observe(_ envelope: PermissionEnvelope, from owner: SessionRuntime) {
        let event = AgentActivityEvent.permission(envelope)
        if event.sessionID == owner.sessionID, event.childSessionID == nil {
            owner.permission = envelope
            owner.state = .needsInput
            owner.appendActivity(event)
            return
        }
        let childID = event.childSessionID ?? (event.parentSessionID == owner.sessionID ? event.sessionID : nil)
        guard let childID else {
            let unknown = observedRuntime(sessionID: event.sessionID, parentSessionID: event.parentSessionID)
            unknown.permission = envelope
            unknown.state = .needsInput
            unknown.appendActivity(event)
            return
        }
        let parentID = event.parentSessionID ?? owner.sessionID
        guard let parentID else { return }
        owner.observedChildSessionIDs.insert(childID)
        let child = observedRuntime(sessionID: childID, parentSessionID: parentID)
        child.permission = PermissionEnvelope(sessionID: childID, requestID: envelope.requestID, title: envelope.title, choices: envelope.choices, metadata: envelope.metadata)
        child.state = .needsInput
        child.appendActivity(event)
    }

    public var all: [SessionRuntime] {
        runtimes.values.sorted { lhs, rhs in
            (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
        }
    }

    public var summaries: [RuntimeSummary] { all.map { $0.summary() } }

    public func stopAll() {
        for runtime in runtimes.values {
            runtime.connectionEpoch = UUID()
            runtime.turnEpoch = UUID()
            runtime.agent?.stop()
            runtime.agent = nil
            runtime.busy = false
            runtime.connecting = false
            runtime.state = runtime.permission == nil ? .cancelled : .needsInput
            runtime.connectionStatus = "Stopped"
            runtime.sessionNeedsLoad = true
        }
    }

    private func observedRuntime(sessionID: String, parentSessionID: String?) -> SessionRuntime {
        let id = "observed:\(sessionID)"
        if let existing = runtimes[id] {
            if let parentSessionID { existing.explicitParentSessionID = parentSessionID }
            return existing
        }
        let runtime = SessionRuntime(id: id, sessionID: sessionID, cwd: "", store: store)
        runtime.explicitParentSessionID = parentSessionID
        runtime.isExternalObservedSession = true
        runtime.state = .unknown
        runtimes[id] = runtime
        return runtime
    }

    private func state(from event: AgentActivityEvent) -> RunState? {
        switch event.toolStatus?.lowercased() {
        case "in_progress", "running", "started": .working
        case "completed", "succeeded": .completed
        case "failed", "error": .failed
        case "cancelled", "canceled": .cancelled
        default: nil
        }
    }
}
