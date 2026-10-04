import Foundation

public struct UpdateCheck: Decodable, Equatable, Sendable {
    public var currentVersion: String
    public var latestVersion: String
    public var updateAvailable: Bool
    public var error: String?
}

public func decodeUpdateCheck(_ data: Data) throws -> UpdateCheck {
    try JSONDecoder().decode(UpdateCheck.self, from: data)
}

public func updateButtonTitle(_ check: UpdateCheck) -> String? {
    guard check.updateAvailable, check.error == nil else { return nil }
    return "Update Grok to \(check.latestVersion)"
}
