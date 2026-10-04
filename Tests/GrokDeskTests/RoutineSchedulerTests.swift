import XCTest
@testable import GrokDeskCore

final class RoutineSchedulerTests: XCTestCase {
    func testCronValidationPresetsAndMinimumGranularity() throws {
        XCTAssertNoThrow(try RoutineSchedule(cron: "* * * * *"))
        XCTAssertEqual(RoutineSchedule.presets.first?.cron, "* * * * *")
        XCTAssertThrowsError(try RoutineSchedule(cron: "@hourly"))
        XCTAssertThrowsError(try RoutineSchedule(cron: "60 * * * *"))
        XCTAssertThrowsError(try RoutineSchedule(cron: "*/0 * * * *"))
        XCTAssertThrowsError(try RoutineSchedule(cron: "* * * *"))
    }

    func testNextRunUsesTheRoutineTimeZoneAndSkipsTheSpringDSTGap() throws {
        let schedule = try RoutineSchedule(cron: "30 2 * * *")
        let beforeGap = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T06:00:00Z"))
        let next = try XCTUnwrap(schedule.next(after: beforeGap, timeZoneID: "America/New_York"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T06:30:00Z"))
        XCTAssertEqual(next, expected)
    }

    func testRepeatedFallDSTHourHasTwoDistinctScheduledMinutes() throws {
        let schedule = try RoutineSchedule(cron: "30 1 * * *")
        let firstFold = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T08:35:00Z"))
        let repeatedOneThirty = try XCTUnwrap(schedule.next(after: firstFold, timeZoneID: "America/Los_Angeles"))
        XCTAssertEqual(repeatedOneThirty, ISO8601DateFormatter().date(from: "2026-11-01T09:30:00Z"))
    }

    func testInvalidTimeZoneIsRejectedBeforeScheduling() throws {
        let schedule = try RoutineSchedule(cron: "0 9 * * 1-5")
        XCTAssertThrowsError(try schedule.next(after: Date(), timeZoneID: "Mars/Olympus"))
    }

    func testDuplicateHelperTicksDispatchTheScheduledOccurrenceOnlyOnce() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let routine = fixture.routine(cron: "* * * * *")
        try fixture.store.save(routine)
        let runner = RecordingRoutineCommandRunner()
        let scheduler = RoutineScheduler(store: fixture.store, executor: fixture.executor(commandRunner: runner))
        let now = Date(timeIntervalSince1970: 1_798_957_215)

        _ = try scheduler.tick(now: now)
        _ = try scheduler.tick(now: now)

        XCTAssertEqual(try fixture.store.runs(for: routine.id).count, 1)
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testPauseResumeAndDeleteReadBackFromTheSharedStore() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let routine = fixture.routine(cron: "* * * * *")
        try fixture.store.save(routine)
        let scheduler = RoutineScheduler(store: fixture.store, executor: fixture.executor(commandRunner: RecordingRoutineCommandRunner()))
        let firstMinute = Date(timeIntervalSince1970: 1_798_957_200)
        _ = try scheduler.tick(now: firstMinute)

        try fixture.store.setEnabled(false, routineID: routine.id)
        XCTAssertFalse(try XCTUnwrap(fixture.store.routine(id: routine.id)).enabled)
        XCTAssertTrue(try scheduler.tick(now: firstMinute.addingTimeInterval(60)).isEmpty)

        try fixture.store.setEnabled(true, routineID: routine.id)
        XCTAssertTrue(try XCTUnwrap(fixture.store.routine(id: routine.id)).enabled)
        _ = try scheduler.tick(now: firstMinute.addingTimeInterval(60))
        XCTAssertEqual(try fixture.store.runs(for: routine.id).count, 2)

        try fixture.store.delete(routineID: routine.id)
        XCTAssertNil(try fixture.store.routine(id: routine.id))
        XCTAssertTrue(try fixture.store.runs(for: routine.id).isEmpty)
    }

    func testInterruptedClaimPausesForReviewWithoutReplayingAmbiguousWork() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let routine = fixture.routine(cron: "* * * * *")
        let due = Date(timeIntervalSince1970: 1_798_957_200)
        let abandoned = RoutineRun(
            id: UUID(),
            routineID: routine.id,
            scheduledAt: due,
            startedAt: due,
            state: .running,
            trigger: .scheduled,
            sessionID: UUID().uuidString,
            claimKey: RoutineStore.scheduledClaimKey(routineID: routine.id, scheduledAt: due)
        )
        let snapshot = RoutineStoreSnapshot(routines: [routine], runs: [abandoned])
        try JSONEncoder().encode(snapshot).write(to: fixture.store.fileURL)

        let commandRunner = RecordingRoutineCommandRunner()
        let result = try fixture.executor(commandRunner: commandRunner).runScheduled(routineID: routine.id, scheduledAt: due, now: due.addingTimeInterval(600))

        XCTAssertEqual(result.disposition, .needsInput)
        XCTAssertTrue(commandRunner.commands.isEmpty)
        let recovered = try XCTUnwrap(fixture.store.runs(for: routine.id).first)
        XCTAssertEqual(recovered.state, .needsInput)
        XCTAssertTrue(recovered.error?.contains("routine is paused") == true)
        XCTAssertFalse(try XCTUnwrap(fixture.store.routine(id: routine.id)).enabled)
    }

    func testHelperTicksClaimOneRunPersistItsSessionAndDoNotOverlap() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let routine = fixture.routine(cron: "* * * * *")
        try fixture.store.save(routine)
        let due = Date(timeIntervalSince1970: 1_798_957_200) // an exact UTC minute
        let commandRunner = BlockingRoutineCommandRunner()
        let executorA = fixture.executor(commandRunner: commandRunner)
        let executorB = fixture.executor(commandRunner: commandRunner, separateStore: true)

        let firstResult = LockedBox<RoutineExecutionResult?>(nil)
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            firstResult.set(try! executorA.runScheduled(routineID: routine.id, scheduledAt: due, now: due))
            firstFinished.signal()
        }
        XCTAssertEqual(commandRunner.started.wait(timeout: .now() + 3), .success)

        let overlapping = try executorB.runScheduled(routineID: routine.id, scheduledAt: due, now: due)
        XCTAssertEqual(overlapping.disposition, .alreadyRunning)
        commandRunner.release.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(firstResult.get()?.disposition, .completed)

        let duplicate = try executorB.runScheduled(routineID: routine.id, scheduledAt: due, now: due)
        XCTAssertEqual(duplicate.disposition, .alreadyClaimed)

        let reopened = RoutineStore(fileURL: fixture.store.fileURL)
        let history = try reopened.runs(for: routine.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.state, .completed)
        XCTAssertEqual(history.first?.sessionID, history.first?.id.uuidString)
    }

    func testHeldRoutineDoesNotDelayOtherRoutinesOrTheirNextOccurrence() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        var held = fixture.routine(cron: "* * * * *")
        held.name = "A held routine"
        held.prompt = "hold-first"
        var independent = fixture.routine(cron: "* * * * *")
        independent.name = "B independent routine"
        independent.prompt = "quick-second"
        try fixture.store.save(held)
        try fixture.store.save(independent)
        let runner = SelectiveBlockingRoutineCommandRunner()
        let scheduler = RoutineScheduler(store: fixture.store, executor: fixture.executor(commandRunner: runner))
        let firstMinute = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))
        let firstTickFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try! scheduler.tick(now: firstMinute)
            firstTickFinished.signal()
        }
        XCTAssertEqual(runner.heldStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(runner.independentStarted.wait(timeout: .now() + 3), .success)

        let secondTickFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try! scheduler.tick(now: firstMinute.addingTimeInterval(60))
            secondTickFinished.signal()
        }
        XCTAssertEqual(runner.independentStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(secondTickFinished.wait(timeout: .now() + 3), .success)
        runner.releaseHeld.signal()
        XCTAssertEqual(firstTickFinished.wait(timeout: .now() + 3), .success)

        XCTAssertEqual(try fixture.store.runs(for: held.id).filter { $0.state == .completed }.count, 1)
        XCTAssertEqual(try fixture.store.runs(for: independent.id).filter { $0.state == .completed }.count, 2)
    }

    func testHeadlessRunUsesExistingCLIAuthAndTurnsApprovalIntoNeedsInput() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let routine = fixture.routine(cron: "* * * * *")
        try fixture.store.save(routine)
        let executable = fixture.makeMockCLI(script: "printf 'tool approval required by policy\\n' >&2\nexit 1\n")
        let runner = RecordingRoutineCommandRunner()
        let executor = RoutineExecutor(
            store: fixture.store,
            grokExecutableURL: executable,
            commandRunner: runner,
            timeout: 1,
            environment: ["PATH": "/usr/bin:/bin", "GROK_API_KEY": "fixture", "XAI_API_KEY": "fixture"]
        )

        let result = try executor.runNow(routineID: routine.id, at: Date(timeIntervalSince1970: 1_798_957_200))
        XCTAssertEqual(result.disposition, .needsInput)
        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.currentDirectoryURL?.path, routine.cwd)
        XCTAssertTrue(command.arguments.contains("--session-id"))
        XCTAssertTrue(command.arguments.contains("--max-turns"))
        XCTAssertTrue(command.arguments.contains("--permission-mode"))
        XCTAssertTrue(command.arguments.contains("dontAsk"))
        XCTAssertFalse(command.arguments.contains("--always-approve"))
        XCTAssertNil(command.environment["GROK_API_KEY"])
        XCTAssertNil(command.environment["XAI_API_KEY"])

        let saved = try fixture.store.runs(for: routine.id)
        XCTAssertEqual(saved.first?.state, .needsInput)
        XCTAssertNotNil(saved.first?.sessionID)
        XCTAssertTrue(saved.first?.error?.localizedCaseInsensitiveContains("approval") == true)
    }

    func testLaterRunResumesTheRoutineSessionAndAPromptCanNameAnotherChat() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let routine = fixture.routine(cron: "* * * * *")
        try fixture.store.save(routine)
        let runner = RecordingRoutineCommandRunner()
        let executor = fixture.executor(commandRunner: runner)
        XCTAssertEqual(try executor.runNow(routineID: routine.id).disposition, .completed)
        XCTAssertEqual(try executor.runNow(routineID: routine.id).disposition, .completed)
        let created = try XCTUnwrap(argument("--session-id", in: runner.commands[0].arguments))
        XCTAssertEqual(argument("--resume", in: runner.commands[1].arguments), created)
        XCTAssertFalse(runner.commands[1].arguments.contains("--session-id"))
        XCTAssertEqual(try fixture.store.routine(id: routine.id)?.threadSessionID, created)

        var handoff = routine
        handoff.prompt = "Check the deploy.\nHand off to session: \"login bug\""
        try fixture.store.save(handoff)
        _ = try executor.runNow(routineID: routine.id)
        let sent = runner.commands[2].arguments
        XCTAssertEqual(argument("--resume", in: sent), "login bug")
        XCTAssertFalse(sent.contains("--session-id"))
        XCTAssertTrue(argument("--single", in: sent)?.contains("Check the deploy.") == true)
        XCTAssertFalse(argument("--single", in: sent)?.contains("Hand off") == true)

        var fresh = routine
        fresh.continuity = RoutineContinuity.fresh.rawValue
        fresh.prompt = "Check this disposable fixture."
        try fixture.store.save(fresh)
        _ = try executor.runNow(routineID: routine.id)
        _ = try executor.runNow(routineID: routine.id)
        XCTAssertNotNil(argument("--session-id", in: runner.commands[3].arguments))
        XCTAssertNotNil(argument("--session-id", in: runner.commands[4].arguments))
        XCTAssertNotEqual(
            argument("--session-id", in: runner.commands[3].arguments),
            argument("--session-id", in: runner.commands[4].arguments)
        )
    }

    func testSavedRoutinesWithoutContinuityKeepWorking() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let id = UUID()
        let raw = """
        {"schemaVersion":1,"routines":[{"id":"\(id.uuidString)","name":"Legacy","cwd":"\(fixture.cwd.path)","prompt":"Look around.","timeZoneID":"UTC","cron":"0 9 * * 1-5","modelID":"","permissionProfile":"needs-input","maxTurns":5,"enabled":false,"catchUp":true}],"runs":[]}
        """
        try Data(raw.utf8).write(to: fixture.store.fileURL)
        let loaded = try XCTUnwrap(try fixture.store.routine(id: id))
        XCTAssertEqual(loaded.continuity, RoutineContinuity.thread.rawValue)
        XCTAssertNil(loaded.threadSessionID)
    }

    func testHeadlessProcessHasAHardTimeoutAndStopsItsChildProcessGroup() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let executable = fixture.makeMockCLI(script: "sleep 5\n")
        let command = RoutineCommand(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: fixture.cwd,
            timeout: 0.15,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let started = Date()

        let result = try ProcessRoutineCommandRunner().run(command)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testHeadlessTimeoutKillsTermIgnoringChildEvenAfterLeaderExits() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("child-still-running.txt")
        let pidFile = fixture.root.appendingPathComponent("child.pid")
        let script = """
        attempt=0
        pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
        while [ "$pgid" != "$$" ] && [ "$attempt" -lt 100 ]; do
          sleep 0.01
          pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
          attempt=$((attempt + 1))
        done
        [ "$pgid" = "$$" ] || exit 19
        sh -c 'trap "" TERM; while :; do printf x >> "$1"; sleep 0.02; done' routine-child '\(marker.path)' &
        child=$!
        printf '%s\\n' "$child" > '\(pidFile.path)'
        wait "$child"
        """
        let executable = fixture.makeMockCLI(script: script)
        let command = RoutineCommand(
            executableURL: executable,
            arguments: [],
            currentDirectoryURL: fixture.cwd,
            timeout: 0.5,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let result = try ProcessRoutineCommandRunner().run(command)
        let before = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: marker.path)[.size] as? NSNumber)?.intValue)
        Thread.sleep(forTimeInterval: 0.15)
        let after = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: marker.path)[.size] as? NSNumber)?.intValue)

        XCTAssertTrue(result.timedOut)
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(after, before, "A timeout must stop an owned child group even after its shell leader exits.")
    }

    func testCatchUpCoalescesWhileDisabledAndSkipPolicyRecordsMissedRun() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let due = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z"))
        let late = due.addingTimeInterval(4 * 60 * 60)
        let runner = RecordingRoutineCommandRunner()

        var catchUp = fixture.routine(cron: "0 9 * * *", catchUp: true)
        try fixture.store.save(catchUp)
        let firstSchedule = RoutineScheduler(store: fixture.store, executor: fixture.executor(commandRunner: runner))
        _ = try firstSchedule.tick(now: late)
        XCTAssertEqual(try fixture.store.runs(for: catchUp.id).filter { $0.state == .completed }.count, 1)

        catchUp.enabled = false
        try fixture.store.save(catchUp)
        let countBeforePause = try fixture.store.runs(for: catchUp.id).count
        _ = try firstSchedule.tick(now: late.addingTimeInterval(60))
        XCTAssertEqual(try fixture.store.runs(for: catchUp.id).count, countBeforePause)

        let skipRoutine = fixture.routine(cron: "0 9 * * *", catchUp: false)
        try fixture.store.save(skipRoutine)
        let secondSchedule = RoutineScheduler(store: fixture.store, executor: fixture.executor(commandRunner: runner))
        _ = try secondSchedule.tick(now: late)
        XCTAssertEqual(try fixture.store.runs(for: skipRoutine.id).map(\.state), [.skipped])
    }

    func testLaunchAgentIsAReversibleAppOwnedHelperDefinition() throws {
        let fixture = try RoutineFixture()
        defer { fixture.remove() }
        let helper = fixture.makeMockCLI(script: "exit 0\n")
        let manager = RoutineLaunchAgentManager(
            storeURL: fixture.store.fileURL,
            launchAgentURL: fixture.root.appendingPathComponent("com.example.test-routines.plist"),
            helperLabel: "com.example.test-routines",
            launchctlURL: URL(fileURLWithPath: "/bin/launchctl"),
            commandRunner: RecordingRoutineCommandRunner()
        )

        let plistData = try manager.propertyList(helperURL: helper, grokURL: helper)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.example.test-routines")
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNil(plist["StartInterval"])
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.first, helper.path)
        XCTAssertTrue(arguments.contains(fixture.store.fileURL.path))
        XCTAssertEqual(manager.status(expectedHelperURL: helper), .notInstalled)
    }
}

private func argument(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private struct RoutineFixture {
    let root: URL
    let cwd: URL
    let store: RoutineStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-routine-tests-\(UUID().uuidString)", isDirectory: true)
        cwd = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
    }

    func routine(cron: String, catchUp: Bool = true) -> Routine {
        Routine(name: "Fixture routine", cwd: cwd.path, prompt: "Check this disposable fixture.", timeZoneID: "UTC", cron: cron, enabled: true, catchUp: catchUp)
    }

    func executor(commandRunner: RoutineCommandRunning, separateStore: Bool = false) -> RoutineExecutor {
        RoutineExecutor(
            store: separateStore ? RoutineStore(fileURL: store.fileURL) : store,
            grokExecutableURL: makeMockCLI(script: "printf 'fixture completed\\n'\nexit 0\n"),
            commandRunner: commandRunner,
            timeout: 5,
            environment: ["PATH": "/usr/bin:/bin"]
        )
    }

    func makeMockCLI(script: String) -> URL {
        let executable = root.appendingPathComponent("mock-grok-\(UUID().uuidString)")
        let contents = "#!/bin/sh\n" + script
        try! Data(contents.utf8).write(to: executable)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class RecordingRoutineCommandRunner: RoutineCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RoutineCommand] = []
    var commands: [RoutineCommand] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ command: RoutineCommand) throws -> RoutineCommandResult {
        lock.lock(); recorded.append(command); lock.unlock()
        return try ProcessRoutineCommandRunner().run(command)
    }
}

private final class BlockingRoutineCommandRunner: RoutineCommandRunning, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func run(_ command: RoutineCommand) throws -> RoutineCommandResult {
        started.signal()
        _ = release.wait(timeout: .now() + 3)
        return RoutineCommandResult(exitCode: 0, stdout: "fixture completed", stderr: "", timedOut: false)
    }
}

private final class SelectiveBlockingRoutineCommandRunner: RoutineCommandRunning, @unchecked Sendable {
    let heldStarted = DispatchSemaphore(value: 0)
    let independentStarted = DispatchSemaphore(value: 0)
    let releaseHeld = DispatchSemaphore(value: 0)

    func run(_ command: RoutineCommand) throws -> RoutineCommandResult {
        if command.arguments.contains("hold-first") {
            heldStarted.signal()
            _ = releaseHeld.wait(timeout: .now() + 5)
        } else {
            independentStarted.signal()
        }
        return RoutineCommandResult(exitCode: 0, stdout: "fixture completed", stderr: "", timedOut: false)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
