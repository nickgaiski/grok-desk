import Foundation

/// The desktop delegates media work to the installed Grok Build agent.
/// No API endpoint, browser handoff, or second credential is involved.
/// Stills use `/imagine` plus `image_gen` or `image_edit`. A prompt or a single
/// start frame uses `image_to_video` on grok-imagine-video-1.5, which includes
/// native 1080p. References, an end frame, or a preset voice use
/// `reference_to_video`, which stops at 720p.
public func imagineCommand(board: StudioBoard, outputFolder: URL) -> String {
    let aspect = studioAspect(for: board)
    var prompt = board.medium == "video" || !board.references.isEmpty ? board.brief : "/imagine " + board.brief
    if board.medium == "video" {
        let duration = min(15, max(1, board.duration))
        let resolution = studioResolution(for: board)
        let voices = (board.audioEnabled ? board.voices : []).filter { ["ara", "eve", "leo", "rex"].contains($0) }.prefix(3)
        let references = board.references.prefix(14)
        let textOnly = references.isEmpty && board.startPath == nil && board.endPath == nil && voices.isEmpty
        let startOnly = board.startPath != nil && board.endPath == nil && references.isEmpty && voices.isEmpty
        if textOnly || startOnly {
            prompt += "\nCall image_to_video once on grok-imagine-video-1.5."
            prompt += "\nresolution_name: \(resolution)\nduration: \(duration)"
            prompt += "\nSuperGrok Heavy includes native 1080p for this shot. Pass the resolution above and do not downgrade it."
            if textOnly {
                prompt += "\nFirst call image_gen once with aspect_ratio \(aspect), using the scene description as the opening frame, and pass that saved file as the image argument."
            } else if let path = board.startPath {
                prompt += "\nimage: " + path
            }
            prompt += "\nDo not call reference_to_video."
        } else {
            prompt += "\nCall reference_to_video once on grok-imagine-video-1.5. Keep identity references separate from pinned frames."
            prompt += "\nThis mode stops at 720p. Do not call image_to_video."
            prompt += "\naspect_ratio: \(aspect)\nduration: \(duration)\nresolution_name: \(resolution)"
            if let path = board.startPath { prompt += "\nfirst_frame: " + path }
            if let path = board.endPath { prompt += "\nlast_frame: " + path }
            let imageIndex = board.startPath == nil ? 0 : 1
            for (index, path) in references.enumerated() {
                prompt += "\nimages[\(index)] <IMAGE_\(index + imageIndex)>: " + path
            }
            for (index, voice) in voices.enumerated() { prompt += "\nvoices[\(index)] <AUDIO_\(index)>: " + voice }
        }
        if !board.audioEnabled {
            prompt += "\ngenerate_audio: false"
            prompt += "\nIf the tool has no audio switch, do not invent another argument. The desktop removes any remaining audio from its saved copy."
        }
    } else if !board.references.isEmpty {
        let references = Array(board.references.prefix(14))
        prompt += "\nCall image_edit once. Pass these absolute paths as the image array, in this order:\n" + references.joined(separator: "\n")
        if references.count > 1 {
            prompt += "\naspect_ratio: \(aspect)"
        } else {
            prompt += "\nOne source image: omit aspect_ratio so the edit keeps the source frame."
        }
    } else {
        prompt += "\nCall image_gen once.\naspect_ratio: \(aspect)"
    }
    prompt += "\nUse the existing Grok login and built-in Imagine tools only. Do not configure API keys, switch providers, or open a browser. If a tool or entitlement is unavailable, report that and stop. Leave each finished file where the tool saved it and include its absolute path in your reply."
    return prompt
}

/// Prompt-only and single-start shots can be 1080p. References, an end frame, and preset voices cannot.
public func studioUsesReferenceVideo(_ board: StudioBoard) -> Bool {
    !board.references.isEmpty || board.endPath != nil || (board.audioEnabled && !board.voices.isEmpty)
}

public func capReferenceResolution(_ board: inout StudioBoard) {
    if studioUsesReferenceVideo(board), board.resolution == "1080p" {
        board.resolution = "720p"
    }
}

public func studioResolution(for board: StudioBoard) -> String {
    var copy = board
    capReferenceResolution(&copy)
    if studioUsesReferenceVideo(copy) {
        return copy.resolution == "480p" ? "480p" : "720p"
    }
    return ["480p", "720p", "1080p"].contains(copy.resolution) ? copy.resolution : "1080p"
}

/// Ratios the installed Imagine tools accept. Anything else becomes 16:9.
public func studioAspect(for board: StudioBoard) -> String {
    let stills = ["1:1", "16:9", "9:16", "3:2", "2:3"]
    let allowed = board.medium == "video" ? stills + ["4:3", "3:4"] : stills
    return allowed.contains(board.aspect) ? board.aspect : "16:9"
}

/// Absolute media paths, plus `images/` and `videos/` paths relative to a Grok session.
public func studioMediaURLs(in text: String, session: URL? = nil) -> [URL] {
    let ext = "png|jpe?g|webp|heic|tiff|gif|mp4|mov|m4v"
    let pattern = #"[\"'](/[^\"']+?\.(?:\#(ext)))[\"']|(?<![\w/])(/(?:[^\s\"'<>|])+?\.(?:\#(ext)))\b|(?<![\w/])((?:images|videos)/[^\s\"'<>|]+?\.(?:\#(ext)))\b"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var seen = Set<String>()
    var urls: [URL] = []
    for match in expression.matches(in: text, range: range) {
        if let slice = Range(match.range(at: 1), in: text), match.range(at: 1).location != NSNotFound {
            let path = String(text[slice])
            if seen.insert(path).inserted { urls.append(URL(fileURLWithPath: path)) }
        } else if let slice = Range(match.range(at: 2), in: text), match.range(at: 2).location != NSNotFound {
            let path = String(text[slice])
            if seen.insert(path).inserted { urls.append(URL(fileURLWithPath: path)) }
        } else if let session, let slice = Range(match.range(at: 3), in: text), match.range(at: 3).location != NSNotFound {
            let url = session.appendingPathComponent(String(text[slice]))
            if seen.insert(url.path).inserted { urls.append(url) }
        }
    }
    return urls
}

public func studioMedia(createdUnder session: URL, since: Date) -> [URL] {
    ["images", "videos"].flatMap { name -> [URL] in
        let folder = session.appendingPathComponent(name, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { file in
            StudioLibrary.supported(file) && ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
    }
}

public struct StudioBoard: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var title = "Untitled board"
    public var prompt = ""
    public var medium = "image"
    public var aspect = "16:9"
    public var camera = "Natural perspective"
    public var motion = "Locked camera"
    public var startPath: String?
    public var endPath: String?
    public var references: [String] = []
    public var voices: [String] = []
    public var audioEnabled = true
    public var duration = 6
    public var resolution = "1080p"
    public var presetName: String?
    public var look: StudioLook?
    public var updatedAt = Date()
    public init(medium: String = "image") { self.medium = medium }
    enum CodingKeys: String, CodingKey { case id, title, prompt, medium, aspect, camera, motion, startPath, endPath, references, look, updatedAt, voices, duration, resolution, presetName, audioEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title); prompt = try c.decode(String.self, forKey: .prompt)
        medium = try c.decode(String.self, forKey: .medium); aspect = try c.decode(String.self, forKey: .aspect)
        camera = try c.decode(String.self, forKey: .camera); motion = try c.decode(String.self, forKey: .motion)
        startPath = try c.decodeIfPresent(String.self, forKey: .startPath); endPath = try c.decodeIfPresent(String.self, forKey: .endPath)
        references = try c.decode([String].self, forKey: .references); look = try c.decodeIfPresent(StudioLook.self, forKey: .look)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        audioEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
        voices = try c.decodeIfPresent([String].self, forKey: .voices) ?? []
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 6
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? "720p"
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName)
    }
    public var brief: String {
        var lines = [prompt.trimmingCharacters(in: .whitespacesAndNewlines), "Composition: \(studioAspect(for: self))."]
        if let presetName { lines.append("Style preset: \(presetName).") }
        if let look { lines.append(look.direction) }
        else { lines.append("Camera: \(camera).") }
        if medium == "video" { lines.append("Movement: \(motion).") }
        if startPath != nil { lines.append("Use the attached start frame as the opening composition.") }
        if endPath != nil { lines.append("Use the attached end frame as the closing composition.") }
        if !references.isEmpty { lines.append("Use the \(references.count) attached references for visual consistency.") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Creative direction passed to Grok, not hardware or provider API settings.
public struct StudioLook: Codable, Equatable, Sendable {
    public var camera = "Full-frame digital"
    public var lens = "Cinema prime"
    public var focal = "35 mm"
    public var aperture = "f/4"
    public var treatment: String?
    public init() {}
    public var direction: String {
        let depth: String
        switch aperture {
        case "f/1.4", "f/2", "f/2.8": depth = "shallow depth of field with soft bokeh"
        case "f/8", "f/11": depth = "deep focus from foreground to background"
        default: depth = "balanced depth of field"
        }
        return "Cinematic look: \(camera), \(lens), \(focal), \(aperture); \(depth)." + (treatment.map { " " + $0 } ?? "")
    }
}

public struct StudioAsset: Identifiable, Equatable, Sendable {
    public var url: URL
    public var modified: Date
    public var id: String { url.path }
    public var isVideo: Bool { ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

public enum StudioLibraryLocation {
    public static let defaultsKey = "grokDesk.imagineLibrary"
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Grok Desk/imagine", isDirectory: true)
    }
    public static func current(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let path = defaults.string(forKey: defaultsKey), !path.isEmpty else { return defaultRoot(home: home) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    public static func choose(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.standardizedFileURL.path, forKey: defaultsKey)
    }
    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

public struct StudioLibrary: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func assets() throws -> [StudioAsset] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { Self.supported($0) }
            .map { StudioAsset(url: $0, modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }
    public static func supported(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "webp", "heic", "tiff", "gif", "mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
    public func importAsset(_ source: URL) throws -> URL {
        guard source.isFileURL, Self.supported(source), (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(8) + "." + source.pathExtension)
        try FileManager.default.copyItem(at: source, to: target)
        var names = importedNames(); names.insert(target.lastPathComponent)
        try JSONEncoder().encode(names).write(to: root.appendingPathComponent(".uploads.json"), options: .atomic)
        return target
    }
    /// Copies tool outputs into the studio library. Files already in the library, and the board's own inputs, stay put.
    public func adopt(_ sources: [URL], excluding: Set<String> = []) -> [URL] {
        let library = root.standardizedFileURL.path
        var seen = Set<String>()
        var saved: [URL] = []
        for source in sources {
            let path = source.standardizedFileURL.path
            if path == library || path.hasPrefix(library + "/") || excluding.contains(path) || !seen.insert(path).inserted { continue }
            if let copy = try? importAsset(source) { saved.append(copy) }
        }
        return saved
    }
    public func importedNames() -> Set<String> {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".uploads.json")) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }
    public func save(_ board: StudioBoard) throws {
        let folder = root.appendingPathComponent("boards", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(board).write(to: folder.appendingPathComponent(board.id.uuidString + ".json"), options: .atomic)
    }
    public func boards() throws -> [StudioBoard] {
        let folder = root.appendingPathComponent("boards", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(StudioBoard.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
