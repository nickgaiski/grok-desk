import Foundation

public enum RoutineRunState: String, Codable, CaseIterable, Equatable, Sendable {
    case running
    case needsInput = "needs-input"
    case completed
    case failed
    case skipped
}

public enum RoutineRunTrigger: String, Codable, Sendable {
    case scheduled
    case manual
}

public enum RoutineContinuity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Later runs pass `--resume` for this routine's Grok session.
    case thread
    /// Every run passes a new `--session-id`.
    case fresh

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .thread: "Continue the previous run"
        case .fresh: "New session every run"
        }
    }
    public var explanation: String {
        switch self {
        case .thread: "The next run resumes this routine’s Grok session, so it can see the earlier turns. A prompt line can send that run to a different chat instead."
        case .fresh: "Every run starts a new Grok session. A prompt line can still name an existing chat to resume."
        }
    }
}

public enum RoutinePermissionProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Headless runs never grant a tool approval. A denied request is reported as Needs input.
    case needsInput = "needs-input"

    public var id: String { rawValue }
    public var title: String { "Needs input for unapproved tools" }
    public var explanation: String {
        "Scheduled runs never approve tools automatically. A tool that needs confirmation stops the run and appears as Needs input."
    }
}

public struct Routine: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var cwd: String
    public var prompt: String
    public var timeZoneID: String
    public var cron: String
    public var modelID: String
    public var permissionProfile: String
    public var maxTurns: Int
    public var enabled: Bool
    public var catchUp: Bool
    /// `thread` resumes `threadSessionID` after the first run. `fresh` always creates a session.
    public var continuity: String
    /// Grok session created or last resumed for this routine, when continuity is `thread`.
    public var threadSessionID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        cwd: String,
        prompt: String,
        timeZoneID: String = TimeZone.current.identifier,
        cron: String = "0 9 * * 1-5",
        modelID: String = "",
        permissionProfile: String = RoutinePermissionProfile.needsInput.rawValue,
        maxTurns: Int = 5,
        enabled: Bool = false,
        catchUp: Bool = true,
        continuity: String = RoutineContinuity.thread.rawValue,
        threadSessionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.prompt = prompt
        self.timeZoneID = timeZoneID
        self.cron = cron
        self.modelID = modelID
        self.permissionProfile = permissionProfile
        self.maxTurns = maxTurns
        self.enabled = enabled
        self.catchUp = catchUp
        self.continuity = continuity
        self.threadSessionID = threadSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, prompt, timeZoneID, cron, modelID, permissionProfile, maxTurns, enabled, catchUp, continuity, threadSessionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        cwd = try c.decode(String.self, forKey: .cwd)
        prompt = try c.decode(String.self, forKey: .prompt)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        cron = try c.decode(String.self, forKey: .cron)
        modelID = try c.decode(String.self, forKey: .modelID)
        permissionProfile = try c.decode(String.self, forKey: .permissionProfile)
        maxTurns = try c.decode(Int.self, forKey: .maxTurns)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        catchUp = try c.decode(Bool.self, forKey: .catchUp)
        continuity = try c.decodeIfPresent(String.self, forKey: .continuity) ?? RoutineContinuity.thread.rawValue
        threadSessionID = try c.decodeIfPresent(String.self, forKey: .threadSessionID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(timeZoneID, forKey: .timeZoneID)
        try c.encode(cron, forKey: .cron)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(permissionProfile, forKey: .permissionProfile)
        try c.encode(maxTurns, forKey: .maxTurns)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(catchUp, forKey: .catchUp)
        try c.encode(continuity, forKey: .continuity)
        try c.encodeIfPresent(threadSessionID, forKey: .threadSessionID)
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RoutineValidationError.emptyName }
        guard name.count <= 120 else { throw RoutineValidationError.nameTooLong }
        guard cwd.hasPrefix("/") else { throw RoutineValidationError.invalidWorkspace }
        guard FileManager.default.fileExists(atPath: cwd) else { throw RoutineValidationError.workspaceMissing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw RoutineValidationError.workspaceNotDirectory }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RoutineValidationError.emptyPrompt }
        guard prompt.utf8.count <= 40_000 else { throw RoutineValidationError.promptTooLong }
        guard TimeZone(identifier: timeZoneID) != nil else { throw RoutineValidationError.invalidTimeZone }
        _ = try RoutineSchedule(cron: cron)
        guard (1...25).contains(maxTurns) else { throw RoutineValidationError.invalidMaxTurns }
        guard RoutinePermissionProfile(rawValue: permissionProfile) != nil else { throw RoutineValidationError.unsupportedPermissionProfile }
        guard RoutineContinuity(rawValue: continuity) != nil else { throw RoutineValidationError.unsupportedContinuity }
    }
}

/// How one routine fire maps onto `grok --single`.
public struct RoutineLaunch: Equatable, Sendable {
    public var prompt: String
    /// Passed to `--resume` when set. A UUID is always a session id. Any other value is a title in the routine's workspace.
    public var resumeTarget: String?
    /// Passed to `--session-id` only when `resumeTarget` is nil.
    public var createsSessionID: String?
    public var handsOff: Bool
}

public func routineHandoff(in prompt: String) -> (target: String, prompt: String)? {
    let pattern = #"(?im)^[ \t]*(?:resume session|hand[ -]?off(?: to)? session|handoff session)[ \t]*:[ \t]*(.+?)[ \t]*$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(prompt.startIndex..., in: prompt)
    guard let match = expression.firstMatch(in: prompt, range: range),
          let targetRange = Range(match.range(at: 1), in: prompt),
          let lineRange = Range(match.range, in: prompt) else { return nil }
    var target = String(prompt[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    if target.count >= 2, let first = target.first, let last = target.last, first == last, first == "\"" || first == "'" {
        target = String(target.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !target.isEmpty else { return nil }
    var remaining = prompt
    remaining.removeSubrange(lineRange)
    remaining = remaining.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    return (target, remaining.trimmingCharacters(in: .whitespacesAndNewlines))
}

public func routineLaunch(for routine: Routine, runSessionID: String) -> RoutineLaunch {
    if let handoff = routineHandoff(in: routine.prompt) {
        let prompt = handoff.prompt.isEmpty ? "Continue this session." : handoff.prompt
        return RoutineLaunch(prompt: prompt, resumeTarget: handoff.target, createsSessionID: nil, handsOff: true)
    }
    if RoutineContinuity(rawValue: routine.continuity) == .fresh {
        return RoutineLaunch(prompt: routine.prompt, resumeTarget: nil, createsSessionID: runSessionID, handsOff: false)
    }
    if let thread = routine.threadSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !thread.isEmpty {
        return RoutineLaunch(prompt: routine.prompt, resumeTarget: thread, createsSessionID: nil, handsOff: false)
    }
    return RoutineLaunch(prompt: routine.prompt, resumeTarget: nil, createsSessionID: runSessionID, handsOff: false)
}

public func grokSessionID(fromHeadlessOutput stdout: String) -> String? {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let value = (object["sessionId"] as? String) ?? (object["session_id"] as? String)
    let session = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return session.isEmpty ? nil : session
}

public struct RoutineRun: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var routineID: UUID
    public var scheduledAt: Date
    public var startedAt: Date
    public var finishedAt: Date?
    public var state: RoutineRunState
    public var trigger: RoutineRunTrigger
    public var sessionID: String?
    public var claimKey: String
    public var output: String
    public var error: String?

    public init(
        id: UUID = UUID(),
        routineID: UUID,
        scheduledAt: Date,
        startedAt: Date,
        finishedAt: Date? = nil,
        state: RoutineRunState,
        trigger: RoutineRunTrigger,
        sessionID: String? = nil,
        claimKey: String,
        output: String = "",
        error: String? = nil
    ) {
        self.id = id
        self.routineID = routineID
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.trigger = trigger
        self.sessionID = sessionID
        self.claimKey = claimKey
        self.output = output
        self.error = error
    }
}

public enum RoutineValidationError: LocalizedError, Equatable {
    case emptyName, nameTooLong, invalidWorkspace, workspaceMissing, workspaceNotDirectory
    case emptyPrompt, promptTooLong, invalidTimeZone, invalidMaxTurns, unsupportedPermissionProfile, unsupportedContinuity

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a routine name."
        case .nameTooLong: "Routine names must be 120 characters or fewer."
        case .invalidWorkspace: "Choose an absolute workspace folder."
        case .workspaceMissing: "The selected workspace folder no longer exists."
        case .workspaceNotDirectory: "The selected workspace path is not a folder."
        case .emptyPrompt: "Enter a prompt for this routine."
        case .promptTooLong: "Routine prompts must be 40,000 bytes or fewer."
        case .invalidTimeZone: "Choose a valid IANA time zone."
        case .invalidMaxTurns: "Maximum turns must be from 1 through 25."
        case .unsupportedPermissionProfile: "This permission profile is not supported by the installed Grok CLI."
        case .unsupportedContinuity: "Choose whether this routine continues its Grok session or starts a new one."
        }
    }
}

public enum RoutineExecutionDisposition: Equatable, Sendable {
    case completed
    case needsInput
    case failed
    case skipped
    case alreadyRunning
    case alreadyClaimed
    case paused
    case scheduleChanged
}

public struct RoutineExecutionResult: Equatable, Sendable {
    public var disposition: RoutineExecutionDisposition
    public var run: RoutineRun?

    public init(disposition: RoutineExecutionDisposition, run: RoutineRun? = nil) {
        self.disposition = disposition
        self.run = run
    }
}

public enum RoutineHelperStatus: Equatable, Sendable {
    case notInstalled
    case installed(helperPath: String)
    case repairRequired(installedPath: String, currentPath: String)
}

public enum RoutineStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case malformedStore(String)
    case lockFailed(String)
    case writeFailed(String)
    case missingRoutine
    case missingRun
    case routineRunning

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Routine store schema \(version) is not supported."
        case .malformedStore(let reason): "Routine store could not be read: \(reason)"
        case .lockFailed(let reason): "Routine store is temporarily unavailable: \(reason)"
        case .writeFailed(let reason): "Routine store could not be saved: \(reason)"
        case .missingRoutine: "The routine no longer exists."
        case .missingRun: "The run history entry no longer exists."
        case .routineRunning: "Wait for this routine's active run to finish before deleting it."
        }
    }
}

public struct RoutineStoreSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var routines: [Routine]
    public var runs: [RoutineRun]

    public init(schemaVersion: Int = RoutineStore.currentSchemaVersion, routines: [Routine] = [], runs: [RoutineRun] = []) {
        self.schemaVersion = schemaVersion
        self.routines = routines
        self.runs = runs
    }
}
