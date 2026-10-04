import Foundation

public final class RoutineScheduler: @unchecked Sendable {
    public static let shared: RoutineScheduler = {
        let store = RoutineStore.applicationDefault()
        let executor = RoutineExecutor(store: store)
        return RoutineScheduler(store: store, executor: executor)
    }()

    public let store: RoutineStore
    public let executor: RoutineExecutor
    private let timerLock = NSLock()
    private let queue = DispatchQueue(label: "com.grokdesk.routines.scheduler", qos: .utility, attributes: .concurrent)
    private let operationQueue: OperationQueue
    private var timer: DispatchSourceTimer?

    public init(store: RoutineStore, executor: RoutineExecutor) {
        self.store = store
        self.executor = executor
        let operations = OperationQueue()
        operations.name = "com.grokdesk.routines.tick"
        operations.qualityOfService = .utility
        operations.maxConcurrentOperationCount = Self.maximumConcurrentRoutines
        operationQueue = operations
    }

    public func runNow(routineID: UUID, at now: Date = Date()) throws -> RoutineExecutionResult {
        let collector = RoutineTickCollector()
        let group = DispatchGroup()
        group.enter()
        operationQueue.addOperation { [executor] in
            defer { group.leave() }
            do { collector.append(index: 0, result: try executor.runNow(routineID: routineID, at: now)) }
            catch { collector.append(index: 0, error: error) }
        }
        group.wait()
        let (results, errors) = collector.values
        if let error = errors.first?.error { throw error }
        guard let result = results.first?.result else { return RoutineExecutionResult(disposition: .failed) }
        return result
    }

    @discardableResult
    public func tick(now fixedNow: Date? = nil) throws -> [RoutineExecutionResult] {
        let routines = try store.routines()
        let collector = RoutineTickCollector()
        let group = DispatchGroup()
        for (index, routine) in routines.enumerated() where routine.enabled {
            group.enter()
            operationQueue.addOperation { [store, executor] in
                defer { group.leave() }
                do {
                    // Re-read the clock when this bounded slot actually starts. This
                    // avoids dispatching an occurrence using a timestamp made stale
                    // while another due routine occupied the queue.
                    let dispatchTime = fixedNow ?? Date()
                    guard let current = try store.routine(id: routine.id), current.enabled else { return }
                    let schedule = try RoutineSchedule(cron: current.cron)
                    guard let due = try schedule.previous(onOrBefore: dispatchTime, timeZoneID: current.timeZoneID) else { return }
                    let isLate = dispatchTime.timeIntervalSince(due) >= 60
                    if isLate && !current.catchUp {
                        try executor.recoverInterruptedRun(routineID: current.id, now: dispatchTime)
                        if let skipped = try store.appendSkippedRun(routineID: current.id, scheduledAt: due, now: dispatchTime) {
                            collector.append(index: index, result: RoutineExecutionResult(disposition: .skipped, run: skipped))
                        }
                        return
                    }
                    let result = try executor.runScheduled(routineID: current.id, scheduledAt: due, now: dispatchTime)
                    collector.append(index: index, result: result)
                } catch {
                    collector.append(index: index, error: error)
                }
            }
        }
        group.wait()
        let (results, errors) = collector.values
        if let error = errors.sorted(by: { $0.index < $1.index }).first?.error { throw error }
        return results.sorted { $0.index < $1.index }.map(\.result)
    }

    /// Starts an app-open scheduler. The LaunchAgent helper uses one-shot `tick` calls instead.
    public func start(interval: TimeInterval = 60) {
        timerLock.lock(); defer { timerLock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: max(10, interval), leeway: .seconds(2))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                do { _ = try self.tick() }
                catch { fputs("Grok Desk routines tick failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        timer = source
        source.resume()
    }

    public func stop() {
        timerLock.lock(); defer { timerLock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private static let maximumConcurrentRoutines = 4
}

private final class RoutineTickCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [(index: Int, result: RoutineExecutionResult)] = []
    private var errors: [(index: Int, error: Error)] = []

    func append(index: Int, result: RoutineExecutionResult) {
        lock.lock(); results.append((index, result)); lock.unlock()
    }
    func append(index: Int, error: Error) {
        lock.lock(); errors.append((index, error)); lock.unlock()
    }
    var values: (results: [(index: Int, result: RoutineExecutionResult)], errors: [(index: Int, error: Error)]) {
        lock.lock(); defer { lock.unlock() }
        return (results, errors)
    }
}
