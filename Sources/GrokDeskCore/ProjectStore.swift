import Foundation

public struct DeskProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var cwd: String
    public var addedAt: String
}

/// Shares the existing Electron userData projects.json schema. No second project database.
public struct ProjectStore {
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Grok/projects.json")) { self.url = url }
    public func load() throws -> [DeskProject] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Container.self, from: Data(contentsOf: url)).projects
    }
    @discardableResult public func add(folder: URL, name: String? = nil) throws -> [DeskProject] {
        guard folder.isFileURL, (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let folder = folder.standardizedFileURL
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var projects = try load()
        if let index = projects.firstIndex(where: { URL(fileURLWithPath: $0.cwd).standardizedFileURL == folder }) {
            if let label, !label.isEmpty { projects[index].name = label }
            else { return projects }
        } else {
            projects.append(DeskProject(id: UUID().uuidString, name: label.flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent, cwd: folder.path, addedAt: ISO8601DateFormatter().string(from: Date())))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Container(projects: projects)).write(to: url, options: .atomic)
        return projects
    }
    private struct Container: Codable { var projects: [DeskProject] }
}
