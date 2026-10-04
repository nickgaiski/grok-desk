import Darwin
import Foundation

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func drain(_ handle: FileHandle, limit: Int) {
        while true {
            let data = handle.availableData
            if data.isEmpty { return }
            lock.lock()
            if bytes.count < limit { bytes.append(data.prefix(limit - bytes.count)) }
            lock.unlock()
        }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public final class LiveRunner: CommandRunning {
    private let binary: String
    private let owned: OwnedProcesses
    private let cwd: URL?
    private let timeoutOverride: Double?
    public init(binary: String, owned: OwnedProcesses, cwd: URL? = nil, timeout: Double? = nil) { self.binary = binary; self.owned = owned; self.cwd = cwd; self.timeoutOverride = timeout }
    public func run(_ arguments: [String]) async throws -> CommandResult {
        let binary = binary, owned = owned, cwd = cwd, timeout = timeoutOverride
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.execute(binary: binary, arguments: arguments, owned: owned, cwd: cwd, timeoutOverride: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func execute(binary: String, arguments: [String], owned: OwnedProcesses, cwd: URL?, timeoutOverride: Double?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments; process.currentDirectoryURL = cwd
        process.environment = grokEnvironment(ProcessInfo.processInfo.environment)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        owned.track(process)
        defer { owned.untrack(process.processIdentifier) }
        let out = PipeCapture(), err = PipeCapture(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { out.drain(stdout.fileHandleForReading, limit: 2_000_000); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { err.drain(stderr.fileHandleForReading, limit: 16_000); readers.leave() }
        let timeout: Double = timeoutOverride ?? ((arguments.first == "update" && !arguments.contains("--check")) || (arguments.first == "plugin" && arguments.contains("install")) ? 600 : 45)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw AgentClient.failure("Grok command timed out.")
        }
        _ = readers.wait(timeout: .now() + 2)
        return CommandResult(status: process.terminationStatus, stdout: out.text, stderr: err.text)
    }
}

public func stopOwned(_ owned: OwnedProcesses) {
    for child in owned.takeProcesses() where child.isRunning {
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}
