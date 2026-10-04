import Foundation

public struct RulesDocument: Sendable {
    public let url:URL
    public private(set) var original:String
    public var text:String
    private let existed:Bool
    public init(url:URL) throws {
        self.url=url; existed=FileManager.default.fileExists(atPath:url.path)
        original=existed ? try String(contentsOf:url,encoding:.utf8):"";text=original
    }
    public var dirty:Bool { text != original }
    public mutating func save(expectedURL: URL? = nil) throws {
        if let expectedURL, expectedURL.standardizedFileURL != url.standardizedFileURL {
            throw NSError(domain:"Rules",code:2,userInfo:[NSLocalizedDescriptionKey:"The selected rules file changed. Reload it before saving."])
        }
        let exists=FileManager.default.fileExists(atPath:url.path)
        let current=exists ? try String(contentsOf:url,encoding:.utf8):""
        guard exists==existed,current==original else {throw NSError(domain:"Rules",code:1,userInfo:[NSLocalizedDescriptionKey:"This file changed outside Grok Desk. Reload before saving."])}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if exists {try Data(current.utf8).write(to:url.appendingPathExtension("backup-"+UUID().uuidString),options:.atomic)}
        try Data(text.utf8).write(to:url,options:.atomic)
        self=try Self(url:url)
    }
}
