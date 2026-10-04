public func displayName(for id: String) -> String {
    var rest = id
    if rest.hasPrefix("grok-") {
        rest.removeFirst(5)
    }
    if rest.hasSuffix("-build-fast") {
        rest.removeLast("-build-fast".count)
        return "Grok \(rest) Fast"
    }
    return "Grok \(rest)"
}
