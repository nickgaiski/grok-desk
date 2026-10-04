import Darwin
import Foundation

public final class RoutineStore: @unchecked Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumHistoryCount = 5_000

    public let fileURL: URL
    private let lockURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        self.lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".lock")
    }

    public static func applicationDefault(fileManager: FileManager = .default) -> RoutineStore {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return RoutineStore(fileURL: support.appendingPathComponent("Grok Desk", isDirectory: true)
            .appendingPathComponent("routines-v1.json"))
    }

    public func routines() throws -> [Routine] {
        try withStoreLock { try readSnapshot().routines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    public func routine(id: UUID) throws -> Routine? {
        try withStoreLock { try readSnapshot().routines.first { $0.id == id } }
    }

    public func runs(for routineID: UUID) throws -> [RoutineRun] {
        try withStoreLock {
            try readSnapshot().runs.filter { $0.routineID == routineID }
                .sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func allRuns(limit: Int = 500) throws -> [RoutineRun] {
        try withStoreLock {
            Array(try readSnapshot().runs.sorted { $0.startedAt > $1.startedAt }.prefix(max(0, limit)))
        }
    }

    public func save(_ routine: Routine) throws {
        try routine.validate()
        try transaction { snapshot in
            if let index = snapshot.routines.firstIndex(where: { $0.id == routine.id }) {
                var saved = routine
                if RoutineContinuity(rawValue: saved.continuity) == .fresh {
                    saved.threadSessionID = nil
                } else if saved.threadSessionID == nil {
                    saved.threadSessionID = snapshot.routines[index].threadSessionID
                }
                snapshot.routines[index] = saved
            } else {
                snapshot.routines.append(routine)
            }
        }
    }

    public func setThreadSessionID(_ sessionID: String?, routineID: UUID) throws {
        try transaction { snapshot in
            guard let index = snapshot.routines.firstIndex(where: { $0.id == routineID }) else {
                throw RoutineStoreError.missingRoutine
            }
            snapshot.routines[index].threadSessionID = sessionID
        }
    }

    public func setEnabled(_ enabled: Bool, routineID: UUID) throws {
        try transaction { snapshot in
            guard let index = snapshot.routines.firstIndex(where: { $0.id == routineID }) else {
                throw RoutineStoreError.missingRoutine
            }
            if enabled {
                try snapshot.routines[index].validate()
            }
            snapshot.routines[index].enabled = enabled
        }
    }

    public func delete(routineID: UUID) throws {
        try transaction { snapshot in
            guard snapshot.routines.contains(where: { $0.id == routineID }) else { throw RoutineStoreError.missingRoutine }
            guard !snapshot.runs.contains(where: { $0.routineID == routineID && $0.state == .running }) else {
                throw RoutineStoreError.routineRunning
            }
            snapshot.routines.removeAll { $0.id == routineID }
            snapshot.runs.removeAll { $0.routineID == routineID }
        }
    }

    func claimRun(
        routineID: UUID,
        trigger: RoutineRunTrigger,
        scheduledAt: Date,
        now: Date,
        manualRequestID: UUID = UUID()
    ) throws -> RoutineRunClaim {
        try transaction { snapshot in
            guard let routine = snapshot.routines.first(where: { $0.id == routineID }) else { throw RoutineStoreError.missingRoutine }
            if trigger == .scheduled && !routine.enabled { return .paused }
            if trigger == .scheduled {
                let schedule = try RoutineSchedule(cron: routine.cron)
                let currentDue = try schedule.previous(onOrBefore: scheduledAt, timeZoneID: routine.timeZoneID)
                guard currentDue == scheduledAt else { return .scheduleChanged }
            }

            // The caller holds this routine's kernel lock. Any persisted running entry
            // therefore belongs to a process that exited before saving its result.
            if let interrupted = markInterruptedRuns(&snapshot, routineID: routineID, now: now).last {
                return .reviewRequired(interrupted)
            }

            let claimKey = trigger == .scheduled
                ? Self.scheduledClaimKey(routineID: routineID, scheduledAt: scheduledAt)
                : "manual:\(routineID.uuidString):\(manualRequestID.uuidString)"
            if snapshot.runs.contains(where: { $0.routineID == routineID && $0.claimKey == claimKey }) {
                return .alreadyClaimed
            }

            let runID = UUID()
            let run = RoutineRun(
                id: runID,
                routineID: routineID,
                scheduledAt: scheduledAt,
                startedAt: now,
                state: .running,
                trigger: trigger,
                sessionID: runID.uuidString,
                claimKey: claimKey
            )
            snapshot.runs.append(run)
            trimHistory(&snapshot)
            return .claimed(run)
        }
    }

    func appendSkippedRun(routineID: UUID, scheduledAt: Date, now: Date) throws -> RoutineRun? {
        try transaction { snapshot in
            guard snapshot.routines.contains(where: { $0.id == routineID }) else { throw RoutineStoreError.missingRoutine }
            let claimKey = Self.scheduledClaimKey(routineID: routineID, scheduledAt: scheduledAt)
            guard !snapshot.runs.contains(where: { $0.routineID == routineID && $0.claimKey == claimKey }) else { return nil }
            let run = RoutineRun(
                routineID: routineID,
                scheduledAt: scheduledAt,
                startedAt: now,
                finishedAt: now,
                state: .skipped,
                trigger: .scheduled,
                claimKey: claimKey,
                error: "Missed occurrence skipped by this routine's catch-up setting."
            )
            snapshot.runs.append(run)
            trimHistory(&snapshot)
            return run
        }
    }

    func finishRun(_ run: RoutineRun) throws {
        try transaction { snapshot in
            guard let index = snapshot.runs.firstIndex(where: { $0.id == run.id }) else { throw RoutineStoreError.missingRun }
            snapshot.runs[index] = run
        }
    }

    func recoverInterruptedRuns(routineID: UUID, now: Date) throws {
        try transaction { snapshot in
            _ = markInterruptedRuns(&snapshot, routineID: routineID, now: now)
        }
    }

    static func scheduledClaimKey(routineID: UUID, scheduledAt: Date) -> String {
        "schedule:\(routineID.uuidString):\(Int64(floor(scheduledAt.timeIntervalSince1970)))"
    }

    private func trimHistory(_ snapshot: inout RoutineStoreSnapshot) {
        guard snapshot.runs.count > Self.maximumHistoryCount else { return }
        snapshot.runs.sort { $0.startedAt > $1.startedAt }
        snapshot.runs.removeLast(snapshot.runs.count - Self.maximumHistoryCount)
    }

    private func markInterruptedRuns(_ snapshot: inout RoutineStoreSnapshot, routineID: UUID, now: Date) -> [RoutineRun] {
        var recovered: [RoutineRun] = []
        for index in snapshot.runs.indices where snapshot.runs[index].routineID == routineID && snapshot.runs[index].state == .running {
            snapshot.runs[index].state = .needsInput
            snapshot.runs[index].finishedAt = now
            snapshot.runs[index].error = "The helper stopped during this run. Review its Grok session before resuming; the CLI may have continued, so this routine is paused to prevent replay."
            recovered.append(snapshot.runs[index])
        }
        if !recovered.isEmpty, let index = snapshot.routines.firstIndex(where: { $0.id == routineID }) {
            snapshot.routines[index].enabled = false
        }
        return recovered
    }

    private func transaction<T>(_ body: (inout RoutineStoreSnapshot) throws -> T) throws -> T {
        try withStoreLock {
            var snapshot = try readSnapshot()
            let result = try body(&snapshot)
            try writeSnapshot(snapshot)
            return result
        }
    }

    private func readSnapshot() throws -> RoutineStoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return RoutineStoreSnapshot() }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(RoutineStoreSnapshot.self, from: data)
            guard snapshot.schemaVersion == Self.currentSchemaVersion else {
                throw RoutineStoreError.unsupportedSchema(snapshot.schemaVersion)
            }
            return snapshot
        } catch let error as RoutineStoreError {
            throw error
        } catch {
            throw RoutineStoreError.malformedStore(error.localizedDescription)
        }
    }

    private func writeSnapshot(_ snapshot: RoutineStoreSnapshot) throws {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = chmod(parent.path, mode_t(S_IRWXU))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try Self.atomicWrite(encoder.encode(snapshot), to: fileURL)
        } catch {
            if let error = error as? RoutineStoreError { throw error }
            throw RoutineStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        let parent = lockURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw RoutineStoreError.lockFailed(error.localizedDescription) }
        _ = chmod(parent.path, mode_t(S_IRWXU))
        let storeLock = try RoutinePOSIXLock.acquire(at: lockURL, wait: true)
        defer { storeLock?.release() }
        return try body()
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw RoutineStoreError.writeFailed(String(cString: strerror(errno))) }
        var writeError: Error?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = RoutineStoreError.writeFailed(String(cString: strerror(errno)))
                    return
                }
                offset += count
            }
        }
        if let writeError {
            close(descriptor)
            unlink(temporary.path)
            throw writeError
        }
        guard fsync(descriptor) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            unlink(temporary.path)
            throw RoutineStoreError.writeFailed(reason)
        }
        close(descriptor)
        guard rename(temporary.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw RoutineStoreError.writeFailed(reason)
        }
        let directoryFD = open(parent.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
    }
}

enum RoutineRunClaim {
    case claimed(RoutineRun)
    case alreadyClaimed
    case alreadyRunning
    case paused
    case scheduleChanged
    case reviewRequired(RoutineRun)
}

final class RoutinePOSIXLock: @unchecked Sendable {
    private static let registry = RoutineLockRegistry()
    private let descriptor: Int32
    private let processLock: NSRecursiveLock
    private let stateLock = NSLock()
    private var released = false

    private init(descriptor: Int32, processLock: NSRecursiveLock) {
        self.descriptor = descriptor
        self.processLock = processLock
    }

    static func acquire(at url: URL, wait: Bool) throws -> RoutinePOSIXLock? {
        let processLock = registry.lock(for: url.standardizedFileURL.path)
        if wait {
            processLock.lock()
        } else if !processLock.try() {
            return nil
        }
        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            processLock.unlock()
            throw RoutineStoreError.lockFailed(String(cString: strerror(errno)))
        }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        let operation = wait ? F_SETLKW : F_SETLK
        var status: Int32
        repeat { status = fcntl(descriptor, operation, &fileLock) } while status < 0 && errno == EINTR
        guard status == 0 else {
            let code = errno
            close(descriptor)
            processLock.unlock()
            if !wait && (code == EACCES || code == EAGAIN) { return nil }
            throw RoutineStoreError.lockFailed(String(cString: strerror(code)))
        }
        return RoutinePOSIXLock(descriptor: descriptor, processLock: processLock)
    }

    func release() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !released else { return }
        released = true
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        _ = fcntl(descriptor, F_SETLK, &fileLock)
        close(descriptor)
        processLock.unlock()
    }

    deinit { release() }
}

private final class RoutineLockRegistry: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func lock(for path: String) -> NSRecursiveLock {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSRecursiveLock()
        locks[path] = created
        return created
    }
}
