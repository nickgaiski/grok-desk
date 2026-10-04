public func terminalResumeCommand(sessionID: String, cwd: String) -> String {
    let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "grok --resume \(sessionID) --cwd \(quoted)"
}

public func terminalAuthorizationCommand(binary: String, cwd: String) -> String {
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    return quote(binary) + " --cwd " + quote(cwd) + " /mcps"
}
