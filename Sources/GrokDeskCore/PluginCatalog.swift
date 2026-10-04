import Foundation

public struct MarketplacePlugin: Identifiable, Equatable, Sendable {
    public var id: String { marketplace + ":" + name }
    public var name: String
    public var title: String
    public var summary: String
    public var marketplace: String
    public var installSource: String
    public var logoURL: URL?
    public var webpage: URL?
    public var publisher: String = ""
    public init(name:String,title:String,summary:String,marketplace:String,installSource:String,logoURL:URL?,webpage:URL?,publisher:String = "") {
        self.name=name;self.title=title;self.summary=summary;self.marketplace=marketplace;self.installSource=installSource;self.logoURL=logoURL;self.webpage=webpage;self.publisher=publisher
    }
}

public enum PluginCatalog {
    public static func xai(_ data: Data) throws -> [MarketplacePlugin] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["plugins"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let source = row["source"] as? [String: Any] ?? [:]
            let raw = source["url"] as? String ?? "https://github.com/xai-org/plugin-marketplace.git"
            guard let url = URL(string: raw), url.scheme == "https" else { return nil }
            let ref = source["sha"] as? String ?? source["ref"] as? String
            let path = source["path"] as? String ?? (row["source"] as? String)
            let install = raw + (ref.map { "@" + $0 } ?? "") + (path.map { "#" + $0 } ?? "")
            return MarketplacePlugin(name: name, title: name.replacingOccurrences(of: "-", with: " ").capitalized,
                summary: row["description"] as? String ?? "", marketplace: "xAI", installSource: install,
                logoURL: (row["logo"] as? String).flatMap(URL.init(string:)), webpage: (row["homepage"] as? String).flatMap(URL.init(string:)), publisher: (row["author"] as? [String:Any])?["name"] as? String ?? URL(string: raw)?.path.split(separator: "/").first.map(String.init) ?? "Publisher not listed")
        }
    }
    /// Cursor publishes the catalog as Next's JSON flight payload. Decode JSON; never execute page scripts.
    public static func cursor(_ html: String) throws -> [MarketplacePlugin] {
        let regex = try NSRegularExpression(pattern: #"self\.__next_f\.push\((\[.*?\])\)</script>"#, options: [.dotMatchesLineSeparators])
        var results: [MarketplacePlugin] = [], seen = Set<String>()
        func walk(_ value: Any) {
            if let row = value as? [String: Any] {
                if let name = row["name"] as? String, row["isPublished"] as? Bool == true,
                   let repo = row["gitUrl"] as? String ?? row["repositoryUrl"] as? String,
                   URL(string: repo)?.scheme == "https", seen.insert(name).inserted {
                    let ref = row["gitRef"] as? String, path = row["gitPath"] as? String
                    let publisher = row["publisher"] as? [String: Any]
                    let logo = row["logoUrl"] as? String ?? publisher?["logoUrl"] as? String
                    results.append(MarketplacePlugin(name: name, title: row["displayName"] as? String ?? name,
                        summary: row["description"] as? String ?? "", marketplace: "Cursor",
                        installSource: repo + (ref.map { "@" + $0 } ?? "") + (path.flatMap { $0.isEmpty ? nil : "#" + $0 } ?? ""),
                        logoURL: logo.flatMap(URL.init(string:)), webpage: URL(string: "https://cursor.com/marketplace/" + (publisher?["name"] as? String ?? "") + "/" + name), publisher: publisher?["displayName"] as? String ?? publisher?["name"] as? String ?? "Publisher not listed"))
                }
                for value in row.values { walk(value) }
            } else if let values = value as? [Any] { for value in values { walk(value) } }
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let array = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [Any],
                  array.count > 1, let payload = array[1] as? String else { continue }
            for line in payload.split(separator: "\n") {
                guard let separator = line.firstIndex(of: ":"),
                      let object = try? JSONSerialization.jsonObject(with: Data(line[line.index(after: separator)...].utf8), options: [.fragmentsAllowed]) else { continue }
                walk(object)
            }
        }
        if results.isEmpty { throw CocoaError(.fileReadCorruptFile) }
        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public static func data(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count < 12_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
}

public func selectedSkillPrompt(_ text: String, skills: [SkillRecord]) throws -> String {
    guard !skills.isEmpty else { return text }
    var sections: [String] = []
    for skill in skills {
        let url = URL(fileURLWithPath: skill.source)
        guard url.lastPathComponent == "SKILL.md" else { throw CocoaError(.fileReadUnsupportedScheme) }
        let data = try Data(contentsOf: url)
        guard data.count < 100_000, let body = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadTooLarge) }
        sections.append("Selected installed skill /\(skill.commandName) (source: \(skill.source)):\n\(body)")
    }
    return "Apply the following skills explicitly selected by the user for this request. Their relative file references resolve from the source file's directory.\n\n" + sections.joined(separator: "\n\n") + "\n\nUser request:\n" + text
}

public func trailingSkillQuery(_ text: String) -> (query: String, prefix: String)? {
    guard let slash = text.lastIndex(of: "/"),
          slash == text.startIndex || text[text.index(before: slash)].isWhitespace else { return nil }
    let query = String(text[text.index(after: slash)...])
    guard !query.contains(where: \.isWhitespace) else { return nil }
    return (query, String(text[..<slash]))
}

public func pluginRepository(_ source: String) -> String {
    let clean = source.components(separatedBy: "#")[0]
    let base = clean.components(separatedBy: "@")[0]
    let normalized=base.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    return normalized.hasSuffix(".git") ? String(normalized.dropLast(4)) : normalized
}
