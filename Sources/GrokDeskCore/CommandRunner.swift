import Foundation

public func grokArguments(leaderSocket: String, user: [String]) -> [String] {
    user + ["--leader-socket", leaderSocket]
}

public let grokChildEnvironment: [String: String] = [
    "GROK_DISABLE_AUTOUPDATER": "1",
]

public final class OwnedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<Int32> = []
    private var processes: [Int32: Process] = [:]

    public init() {}

    public func track(_ pid: Int32) {
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    public func track(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(process.processIdentifier)
        processes[process.processIdentifier] = process
    }
    public func takeProcesses() -> [Process] {
        lock.lock(); defer { lock.unlock() }
        let children = Array(processes.values)
        processes.removeAll(); pids.removeAll()
        return children
    }
    public func untrack(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
        processes.removeValue(forKey: pid)
    }

    public func stopAll() -> [Int32] {
        lock.lock()
        let owned = Array(pids)
        pids.removeAll()
        lock.unlock()
        return owned
    }
}

/// Keep this subscription client from silently falling back to paid API credentials.
public func grokEnvironment(_ inherited: [String: String]) -> [String: String] {
    var environment = inherited
    environment.removeValue(forKey: "XAI_API_KEY")
    environment.removeValue(forKey: "GROK_API_KEY")
    return environment.merging(grokChildEnvironment) { _, new in new }
}
