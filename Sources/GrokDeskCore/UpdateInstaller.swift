import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: AnyObject {
    func run(_ arguments: [String]) async throws -> CommandResult
}

public struct UpdateInstallResult: Equatable, Sendable {
    public var buttonTitle: String?
    public var currentVersion: String?
    public var error: String?
}

public func installGrokUpdate(
    runner: CommandRunning,
    leaderSocket: String,
    stopOwned: () -> Void
) async throws -> UpdateInstallResult {
    stopOwned()
    let install = try await runner.run(grokArguments(leaderSocket: leaderSocket, user: ["update"]))
    guard install.status == 0 else {
        let message = install.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateInstallResult(buttonTitle: nil, currentVersion: nil, error: String(message.prefix(4000)))
    }
    let check = try await runner.run(
        grokArguments(leaderSocket: leaderSocket, user: ["update", "--check", "--json"])
    )
    let decoded = try decodeUpdateCheck(Data(check.stdout.utf8))
    return UpdateInstallResult(
        buttonTitle: updateButtonTitle(decoded),
        currentVersion: decoded.currentVersion,
        error: nil
    )
}
