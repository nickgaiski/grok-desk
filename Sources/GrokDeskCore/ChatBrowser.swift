import Foundation

public enum ChatBrowserKind: String, Codable, Sendable {
    case web, files, file, terminal, page
}

public struct ChatBrowserTab: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var kind: ChatBrowserKind
    public var body: String
    public init(id: String = UUID().uuidString, url: String = "", title: String = "New tab", kind: ChatBrowserKind = .web, body: String = "") {
        self.id = id
        self.url = url
        self.title = title
        self.kind = kind
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New tab"
        kind = try container.decodeIfPresent(ChatBrowserKind.self, forKey: .kind) ?? .web
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, url, title, kind, body }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(body, forKey: .body)
    }
}

public struct ChatBrowserState: Equatable, Sendable, Codable {
    public var open: Bool
    public var url: String
    public var tabs: [ChatBrowserTab]
    public var activeTabID: String

    public init(open: Bool = false, url: String = "", tabs: [ChatBrowserTab]? = nil, activeTabID: String? = nil) {
        self.open = open
        self.url = url
        if let tabs, !tabs.isEmpty {
            self.tabs = tabs
            self.activeTabID = activeTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs[0].id
        } else {
            let tab = ChatBrowserTab(url: url, title: url.isEmpty ? "New tab" : url)
            self.tabs = [tab]
            self.activeTabID = tab.id
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let open = try container.decodeIfPresent(Bool.self, forKey: .open) ?? false
        let url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        let tabs = try container.decodeIfPresent([ChatBrowserTab].self, forKey: .tabs)
        let active = try container.decodeIfPresent(String.self, forKey: .activeTabID)
        self.init(open: open, url: url, tabs: tabs, activeTabID: active)
    }

    private enum CodingKeys: String, CodingKey { case open, url, tabs, activeTabID }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(open, forKey: .open)
        try container.encode(url, forKey: .url)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(activeTabID, forKey: .activeTabID)
    }
}

public enum ChatBrowserStore {
    public static func key(for sessionID: String) -> String { "grokDesk.browser." + sessionID }

    public static func load(_ sessionID: String, defaults: UserDefaults = .standard) -> ChatBrowserState {
        guard let data = defaults.data(forKey: key(for: sessionID)),
              let state = try? JSONDecoder().decode(ChatBrowserState.self, from: data) else {
            return ChatBrowserState()
        }
        return state
    }

    public static func save(_ sessionID: String, _ state: ChatBrowserState, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(for: sessionID))
    }

    public static func address(from raw: String, searchEngine: String = "Google") -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            return url
        }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let local = host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.0.0.1") || host.hasSuffix(".local")
        if local || (host.contains(".") && !trimmed.contains(" ")) {
            return URL(string: (local ? "http://" : "https://") + trimmed)
        }
        var search = URLComponents(string: searchEngine == "DuckDuckGo" ? "https://duckduckgo.com/" : "https://www.google.com/search")
        search?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return search?.url
    }
}
