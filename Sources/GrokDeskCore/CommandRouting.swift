import Foundation

public enum CommandRoute: Equatable, Sendable {
    case native(String), agent(String), terminal(String), skill(String), unsupported(String)
}
public func routeCommand(_ text: String, advertised: Set<String>, skills: Set<String>) -> CommandRoute? {
    guard text.hasPrefix("/") else { return nil }
    let name = String(text.dropFirst().split(whereSeparator: \.isWhitespace).first ?? "")
    if ["queue", "dashboard", "tasks", "settings", "config", "new", "clear", "home", "plugins", "mcps", "skills", "marketplace"].contains(name) { return .native(name) }
    if ["plan", "view-plan", "show-plan", "plan-view", "btw", "loop", "workflows", "create-workflow", "config-agents", "agents", "personas"].contains(name) { return .terminal(name) }
    if skills.contains(name) { return .skill(name) }
    if advertised.contains(name) { return .agent(name) }
    return .unsupported(name)
}
public struct TerminalLaunch: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    public var encoded: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
    public static func decode(_ value: String) -> Self? { try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) }
}
