import Foundation

/// A pending user submission. Paths and skill identities are kept as supplied so
/// the original workspace can revalidate them immediately before dispatch.
public struct QueuedPrompt: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Provider session ID, or the draft runtime ID before a provider session exists.
    public var sessionID: String
    public var cwd: String
    public var text: String
    public var attachmentPaths: [String]
    public var skillIDs: [String]
    public var createdAt: Date
    public var modelID: String
    public var effort: String
    public var permissionMode: PermissionMode
    /// Relaunch recovery marks unsent items for an explicit user review.
    public var requiresReview: Bool

    public init(
        id: UUID = UUID(),
        sessionID: String,
        cwd: String,
        text: String,
        attachmentPaths: [String] = [],
        skillIDs: [String] = [],
        createdAt: Date = Date(),
        modelID: String = "",
        effort: String = "high",
        permissionMode: PermissionMode = .ask,
        requiresReview: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.skillIDs = skillIDs
        self.createdAt = createdAt
        self.modelID = modelID
        self.effort = effort
        self.permissionMode = permissionMode
        self.requiresReview = requiresReview
    }

    public var attachments: [URL] { attachmentPaths.map(URL.init(fileURLWithPath:)) }
}

private struct QueueDocument: Codable {
    var version: Int
    var runtimeID: String
    var providerSessionID: String?
    var cwd: String
    var prompts: [QueuedPrompt]
}

/// Local UI metadata only; ACP transcripts remain in Grok's canonical store.
public final class PromptQueueStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(root: URL = PromptQueueStore.defaultRoot()) {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Grok Desk/Runtime Queues", isDirectory: true)
    }

    public func save(runtimeID: String, sessionID: String?, cwd: String, prompts: [QueuedPrompt]) throws {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(runtimeID: runtimeID)
        if prompts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = QueueDocument(version: 1, runtimeID: runtimeID, providerSessionID: sessionID, cwd: cwd, prompts: prompts)
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    public func loadAll() -> [(runtimeID: String, sessionID: String?, cwd: String, prompts: [QueuedPrompt])] {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(QueueDocument.self, from: data),
                  document.version == 1,
                  !document.runtimeID.isEmpty,
                  !document.prompts.isEmpty else { return nil }
            return (document.runtimeID, document.providerSessionID, document.cwd, document.prompts)
        }
    }

    private func fileURL(runtimeID: String) -> URL {
        // URL-safe base64 avoids path traversal while retaining stable identifiers.
        let stem = Data(runtimeID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return root.appendingPathComponent(stem + ".json")
    }
}
