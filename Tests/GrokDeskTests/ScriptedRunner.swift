import XCTest
@testable import GrokDeskCore

final class ScriptedRunner: CommandRunning {
    var calls: [[String]] = []
    var scripts: [CommandResult]
    init(_ scripts: [CommandResult]) { self.scripts = scripts }
    func run(_ arguments: [String]) async throws -> CommandResult {
        calls.append(arguments)
        return scripts.removeFirst()
    }
}
