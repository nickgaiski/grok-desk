import Foundation

public enum StudioMode: String, Codable, CaseIterable, Sendable { case image, video, agent }
/// Only UI associations live here; provider transcripts stay in Grok's session store.
public struct StudioSessionState: Codable, Equatable, Sendable {
    public var canvasID: UUID? = UUID()
    public var title: String? = "Agent canvas"
    public var updatedAt: Date?
    public var mode: StudioMode = .image
    public var sessionID: String?
    public var cwd = ""
    public var agentPrompt = ""
    public var attachments: [String] = []
    public var assetPaths: [String] = []
    public init() {}
    public func submissionWorkspace(requested: String, whileRunning: Bool) -> String {
        if (sessionID != nil || whileRunning) && !cwd.isEmpty { return cwd }
        return requested
    }
    public func isCurrentCanvas(_ other: Self) -> Bool { canvasID != nil && canvasID == other.canvasID }
    public func validateSubmission(workspace: String, whileRunning: Bool) throws {
        guard !whileRunning || cwd.isEmpty || URL(fileURLWithPath: cwd).standardizedFileURL == URL(fileURLWithPath: workspace).standardizedFileURL else {
            throw NSError(domain: "Studio", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Studio agent is still working in " + cwd + ". Return to that workspace to queue a follow-up, or stop the active turn before starting in another workspace. Your draft is preserved."])
        }
    }
    public static func load(from url: URL) -> Self { (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? Self() }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
