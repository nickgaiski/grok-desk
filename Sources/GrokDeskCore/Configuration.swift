import Foundation
import TOMLKit

public struct ConfigField: Identifiable {
    public var path: [String]
    public var literal: String
    public var kind: String
    public var id: String { path.joined(separator: ".") }
    public var label: String { path.last!.replacingOccurrences(of: "_", with: " ").capitalized }
    public var section: String { path.dropLast().joined(separator: " / ") }
    public var secret: Bool { ["token","secret","password","api_key","authorization","cookie","credential"].contains { id.lowercased().replacingOccurrences(of:"-",with:"_").contains($0) } }
}

public struct ConfigDocument {
    public private(set) var text: String
    public init(text: String) throws {
        do { _ = try TOMLTable(string: text); self.text = text }
        catch let error as TOMLParseError { throw NSError(domain:"Configuration",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid TOML at line \(error.source.begin.line), column \(error.source.begin.column): \(error.description)"]) }
    }
    public var fields: [ConfigField] {
        guard let root = try? TOMLTable(string: text) else { return [] }
        var result: [ConfigField] = []
        func walk(_ table: TOMLTable, _ prefix: [String]) {
            for key in table.keys.sorted() {
                guard let value = table[key]?.tomlValue else { continue }
                if let child = value.table { walk(child, prefix + [key]) }
                else {
                    let literal = value.string.map(Self.quoted) ?? value.debugDescription
                    result.append(ConfigField(path: prefix + [key], literal: literal, kind: value.bool != nil ? "bool" : value.string != nil ? "string" : "value"))
                }
            }
        }
        walk(root, []); return result
    }
    public mutating func set(path: [String], literal: String) throws {
        guard let key = path.last else { return }
        let parsed = try TOMLTable(string: "value = " + literal)
        guard parsed.keys == ["value"], let value = parsed["value"] else { throw failure("Enter one valid TOML value.") }
        let root = try TOMLTable(string: text)
        var table = root
        for component in path.dropLast() {
            if let child = table[component]?.tomlValue.table { table = child }
            else { let child = TOMLTable(); table[component] = child; table = child }
        }
        if table[key]?.tomlValue == value.tomlValue { return }
        table[key] = value
        // Preserve layout/comments for ordinary scalar assignments. Use the parser's
        // full serializer only for complex multiline/inline structures it must normalize.
        let section = path.dropLast().joined(separator: ".")
        var current = "", lines = text.components(separatedBy: "\n"), replaced = false
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { current = String(line.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]")); continue }
            if current == section, let equal = line.firstIndex(of: "="), line[..<equal].trimmingCharacters(in: .whitespaces) == key,
               !line.contains("\"\"\""), !line.contains("'''"), !literal.contains("\n") {
                lines[index] = key + " = " + literal; replaced = true; break
            }
        }
        let candidate = replaced ? lines.joined(separator: "\n") : root.convert(to: .toml) + "\n"
        // Comparing parsed structures catches a scalar matcher accidentally hitting
        // text inside multiline strings, arrays, or quoted table names.
        if let checked = try? TOMLTable(string: candidate), checked == root { text = candidate }
        else { text = root.convert(to: .toml) + "\n" }
    }
    public mutating func addConnection(name: String, target: String, transport: String, arguments: [String]) throws {
        guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw failure("Use letters, digits, dashes or underscores for the connection name.") }
        guard !fields.contains(where: { $0.path.starts(with: ["mcp_servers",name]) }) else { throw failure("A connection with this name already exists.") }
        if transport == "http" { guard let url = URL(string: target), ["https","http"].contains(url.scheme ?? ""), url.host != nil else { throw failure("Enter a valid HTTP or HTTPS URL.") } }
        else if target.trimmingCharacters(in:.whitespaces).isEmpty { throw failure("Enter the server executable.") }
        let block = "\n[mcp_servers." + Self.quoted(name) + "]\n" + (transport == "http" ? "url" : "command") + " = " + Self.quoted(target) + "\n"
            + (transport == "http" ? "" : "args = [" + arguments.map(Self.quoted).joined(separator: ", ") + "]\n") + "enabled = true\n"
        let candidate = text + block
        _ = try TOMLTable(string: candidate)
        text = candidate

    }
    public func save(to url: URL, expected: String) throws {
        _ = try TOMLTable(string: text)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let current = exists ? try String(contentsOf: url, encoding: .utf8) : ""
        guard current == expected else { throw failure("The config changed outside this editor. Reload before saving to avoid overwriting it.") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if exists {
            let backup = url.deletingLastPathComponent().appendingPathComponent("config-backup-" + UUID().uuidString + ".toml")
            try Data(current.utf8).write(to:backup,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
        }
        try Data(text.utf8).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public static func quoted(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") }
    private func failure(_ message: String) -> NSError { NSError(domain:"Configuration",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
