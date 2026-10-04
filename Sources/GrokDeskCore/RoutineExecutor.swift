import Darwin
import Foundation

public struct RoutineCommand: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var currentDirectoryURL: URL?
    public var timeout: TimeInterval
    public var environment: [String: String]

    public init(executableURL: URL, arguments: [String], currentDirectoryURL: URL?, timeout: TimeInterval, environment: [String: String]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.environment = environment
    }
}

public struct RoutineCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol RoutineCommandRunning: Sendable {
    func run(_ command: RoutineCommand) throws -> RoutineCommandResult
}

public final class ProcessRoutineCommandRunner: RoutineCommandRunning, @unchecked Sendable {
    public static let maximumCapturedBytes = 256 * 1024
    private let maximumCapturedBytes: Int

    public init(maximumCapturedBytes: Int = ProcessRoutineCommandRunner.maximumCapturedBytes) {
        self.maximumCapturedBytes = max(4_096, maximumCapturedBytes)
    }

    public func run(_ command: RoutineCommand) throws -> RoutineCommandResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.environment = grokEnvironment(command.environment)
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = RoutineOutputBuffer(limit: maximumCapturedBytes)
        let stderr = RoutineOutputBuffer(limit: maximumCapturedBytes)
        let drainGroup = DispatchGroup()
        drainPipe(stdoutPipe.fileHandleForReading, into: stdout, group: drainGroup)
        drainPipe(stderrPipe.fileHandleForReading, into: stderr, group: drainGroup)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() }
        catch { throw RoutineCommandError.launchFailed(error.localizedDescription) }
        let processID = process.processIdentifier
        // `Process.run()` can return after exec, making setpgid fail with EACCES even
        // when Foundation already placed the child in its own group. Verify the
        // observed group instead of treating the setpgid return code as ownership.
        _ = setpgid(processID, processID)
        let observedGroupID = getpgid(processID)
        let ownedProcessGroupID = observedGroupID == processID && observedGroupID != getpgrp()
            ? observedGroupID
            : nil
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let timeout = max(0.1, command.timeout)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                if let ownedProcessGroupID { _ = kill(-ownedProcessGroupID, SIGTERM) }
                else { process.terminate() }
                let graceDeadline = Date().addingTimeInterval(1.5)
                while Date() < graceDeadline {
                    let groupAlive = ownedProcessGroupID.map(processGroupIsAlive) ?? false
                    if !process.isRunning && !groupAlive { break }
                    Thread.sleep(forTimeInterval: 0.025)
                }
                // The shell leader may exit on TERM while a child ignores it. Keep
                // cleaning the owned group after the leader has gone away.
                if let ownedProcessGroupID, processGroupIsAlive(ownedProcessGroupID) {
                    _ = kill(-ownedProcessGroupID, SIGKILL)
                }
                if process.isRunning { _ = kill(processID, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        _ = drainGroup.wait(timeout: .now() + 2)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return RoutineCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout.string,
            stderr: stderr.string,
            timedOut: timedOut
        )
    }

    private func drainPipe(_ handle: FileHandle, into output: RoutineOutputBuffer, group: DispatchGroup) {
        group.enter()
        let finished = RoutineOneShot()
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                if finished.take() { group.leave() }
            } else {
                output.append(data)
            }
        }
    }

    private func processGroupIsAlive(_ processGroupID: Int32) -> Bool {
        guard processGroupID > 0, processGroupID != getpgrp() else { return false }
        if kill(-processGroupID, 0) == 0 { return true }
        return errno != ESRCH
    }
}

public enum RoutineCommandError: LocalizedError, Equatable {
    case launchFailed(String)
    case invalidResult(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "Grok could not be started: \(reason)"
        case .invalidResult(let reason): "Grok returned an invalid result: \(reason)"
        }
    }
}

public final class RoutineExecutor: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 15 * 60
    public static let maximumTimeout: TimeInterval = 30 * 60

    private let store: RoutineStore
    private let grokExecutableURL: URL
    private let commandRunner: RoutineCommandRunning
    private let timeout: TimeInterval
    private let environment: [String: String]

    public init(
        store: RoutineStore,
        grokExecutableURL: URL = RoutineGrokCLI.discover(),
        commandRunner: RoutineCommandRunning = ProcessRoutineCommandRunner(),
        timeout: TimeInterval = RoutineExecutor.defaultTimeout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.grokExecutableURL = grokExecutableURL
        self.commandRunner = commandRunner
        self.timeout = max(0.1, min(timeout, Self.maximumTimeout))
        self.environment = grokEnvironment(environment)
    }

    public func runNow(routineID: UUID, at now: Date = Date()) throws -> RoutineExecutionResult {
        try execute(routineID: routineID, trigger: .manual, scheduledAt: now, now: now, manualRequestID: UUID())
    }

    public func runScheduled(routineID: UUID, scheduledAt: Date, now: Date = Date()) throws -> RoutineExecutionResult {
        try execute(routineID: routineID, trigger: .scheduled, scheduledAt: scheduledAt, now: now, manualRequestID: nil)
    }

    func recoverInterruptedRun(routineID: UUID, now: Date) throws {
        let lockURL = executionLockURL(routineID: routineID)
        guard let executionLock = try RoutineExecutionLock.acquire(at: lockURL) else { return }
        defer { executionLock.release() }
        try store.recoverInterruptedRuns(routineID: routineID, now: now)
    }

    public func deleteRoutine(routineID: UUID, now: Date = Date()) throws {
        guard let executionLock = try RoutineExecutionLock.acquire(at: executionLockURL(routineID: routineID)) else {
            throw RoutineStoreError.routineRunning
        }
        defer { executionLock.release() }
        try store.recoverInterruptedRuns(routineID: routineID, now: now)
        try store.delete(routineID: routineID)
    }

    private func execute(
        routineID: UUID,
        trigger: RoutineRunTrigger,
        scheduledAt: Date,
        now: Date,
        manualRequestID: UUID?
    ) throws -> RoutineExecutionResult {
        guard let routine = try store.routine(id: routineID) else { throw RoutineStoreError.missingRoutine }
        if trigger == .scheduled && !routine.enabled { return RoutineExecutionResult(disposition: .paused) }

        let executionLock: RoutineExecutionLock
        do {
            guard let acquired = try RoutineExecutionLock.acquire(at: executionLockURL(routineID: routineID)) else {
                return RoutineExecutionResult(disposition: .alreadyRunning)
            }
            executionLock = acquired
        } catch {
            throw RoutineStoreError.lockFailed(error.localizedDescription)
        }
        defer { executionLock.release() }

        let claim = try store.claimRun(
            routineID: routineID,
            trigger: trigger,
            scheduledAt: scheduledAt,
            now: now,
            manualRequestID: manualRequestID ?? UUID()
        )
        guard case .claimed(var run) = claim else {
            switch claim {
            case .claimed: fatalError("unreachable")
            case .alreadyClaimed: return RoutineExecutionResult(disposition: .alreadyClaimed)
            case .alreadyRunning: return RoutineExecutionResult(disposition: .alreadyRunning)
            case .paused: return RoutineExecutionResult(disposition: .paused)
            case .scheduleChanged: return RoutineExecutionResult(disposition: .scheduleChanged)
            case .reviewRequired(let interrupted): return RoutineExecutionResult(disposition: .needsInput, run: interrupted)
            }
        }

        do {
            try routine.validate()
            var launch = routineLaunch(for: routine, runSessionID: run.sessionID ?? run.id.uuidString)
            var command = Self.command(for: routine, launch: launch, executableURL: grokExecutableURL, timeout: timeout, environment: environment)
            var result = try commandRunner.run(command)
            if launch.resumeTarget != nil, !launch.handsOff, Self.missingSession(result) {
                try store.setThreadSessionID(nil, routineID: routineID)
                launch = RoutineLaunch(prompt: launch.prompt, resumeTarget: nil, createsSessionID: run.id.uuidString, handsOff: false)
                command = Self.command(for: routine, launch: launch, executableURL: grokExecutableURL, timeout: timeout, environment: environment)
                result = try commandRunner.run(command)
            }
            run.output = Self.limited(result.stdout)
            run.error = Self.optionalLimited(result.stderr)
            run.finishedAt = Date()
            if let reported = grokSessionID(fromHeadlessOutput: result.stdout) {
                run.sessionID = reported
            } else if let created = launch.createsSessionID {
                run.sessionID = created
            } else if let resume = launch.resumeTarget, UUID(uuidString: resume) != nil {
                run.sessionID = resume
            }
            if !launch.handsOff, RoutineContinuity(rawValue: routine.continuity) != .fresh, let sessionID = run.sessionID, !result.timedOut {
                try store.setThreadSessionID(sessionID, routineID: routineID)
            }
            if result.exitCode == 0 && !result.timedOut {
                run.state = .completed
            } else if Self.needsInput(result) {
                run.state = .needsInput
                if run.error == nil { run.error = "A tool needs user approval; scheduled runs never approve it automatically." }
            } else {
                run.state = .failed
                if result.timedOut {
                    run.error = Self.join(run.error, "Grok exceeded the \(Int(timeout)) second run limit and was stopped.")
                } else if run.error == nil {
                    run.error = "Grok exited with status \(result.exitCode)."
                }
            }
        } catch {
            run.state = .failed
            run.finishedAt = Date()
            run.error = Self.limited(error.localizedDescription)
        }

        try store.finishRun(run)
        return RoutineExecutionResult(disposition: Self.disposition(for: run.state), run: run)
    }

    private func executionLockURL(routineID: UUID) -> URL {
        store.fileURL.deletingLastPathComponent()
            .appendingPathComponent("routine-claims", isDirectory: true)
            .appendingPathComponent("\(routineID.uuidString).lock")
    }

    public static func arguments(for routine: Routine, sessionID: String) -> [String] {
        command(for: routine, launch: routineLaunch(for: routine, runSessionID: sessionID), executableURL: URL(fileURLWithPath: "/usr/bin/grok"), timeout: 1, environment: [:]).arguments
    }

    private static func command(for routine: Routine, launch: RoutineLaunch, executableURL: URL, timeout: TimeInterval, environment: [String: String]) -> RoutineCommand {
        var arguments = ["--single", launch.prompt, "--cwd", routine.cwd]
        if let resume = launch.resumeTarget {
            arguments += ["--resume", resume]
        } else {
            arguments += ["--session-id", launch.createsSessionID ?? UUID().uuidString]
        }
        arguments += [
            "--max-turns", String(routine.maxTurns),
            "--output-format", "json",
            // No headless approval UI exists. The CLI refuses unapproved tools, and
            // the persisted run reports the refusal as Needs input.
            "--permission-mode", "dontAsk",
        ]
        if !routine.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--model", routine.modelID]
        }
        return RoutineCommand(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: routine.cwd, isDirectory: true),
            timeout: timeout,
            environment: environment
        )
    }

    private static func missingSession(_ result: RoutineCommandResult) -> Bool {
        guard result.exitCode != 0 || result.timedOut else { return false }
        let text = (result.stdout + "\n" + result.stderr).lowercased()
        let missing = ["no session", "not found", "does not exist", "doesn't exist", "could not find", "couldn't find", "unknown session", "cannot resume", "can't resume"]
        return text.contains("session") && missing.contains(where: text.contains)
    }

    private static func needsInput(_ result: RoutineCommandResult) -> Bool {
        let text = (result.stdout + "\n" + result.stderr).lowercased()
        let explicit = ["approval required", "requires approval", "permission denied", "permission request", "needs input", "requires input", "denied by policy", "tool was denied", "tool approval"]
        if explicit.contains(where: text.contains) { return true }
        guard result.exitCode != 0 || result.timedOut else { return false }
        return ["permission", "approval"]
            .contains(where: text.contains)
    }

    private static func disposition(for state: RoutineRunState) -> RoutineExecutionDisposition {
        switch state {
        case .completed: .completed
        case .needsInput: .needsInput
        case .failed: .failed
        case .skipped: .skipped
        case .running: .failed
        }
    }

    private static func limited(_ value: String) -> String { String(value.prefix(64_000)) }
    private static func optionalLimited(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : limited(trimmed)
    }
    private static func join(_ left: String?, _ right: String) -> String {
        [left, right].compactMap { $0 }.joined(separator: "\n")
    }
}

public enum RoutineGrokCLI {
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let candidates = [
            environment["GROK_BINARY"],
            homeDirectory.appendingPathComponent(".grok/bin/grok").path,
            environment["PATH"]?.split(separator: ":").map(String.init).map { URL(fileURLWithPath: $0).appendingPathComponent("grok").path }.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
            "/usr/bin/grok",
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "/usr/bin/grok")
    }
}

private final class RoutineExecutionLock: @unchecked Sendable {
    private let lock: RoutinePOSIXLock

    private init(lock: RoutinePOSIXLock) { self.lock = lock }

    static func acquire(at url: URL) throws -> RoutineExecutionLock? {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = chmod(directory.path, mode_t(S_IRWXU))
        guard let lock = try RoutinePOSIXLock.acquire(at: url, wait: false) else { return nil }
        return RoutineExecutionLock(lock: lock)
    }

    func release() { lock.release() }
}

private final class RoutineOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    init(limit: Int) { self.limit = limit }

    func append(_ newData: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - data.count
        if remaining > 0 { data.append(newData.prefix(remaining)) }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class RoutineOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
