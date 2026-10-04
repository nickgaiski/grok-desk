import Foundation

public struct PanelFileDocument {
    public let url:URL
    public let original:Data
    public var text:String
    public init(url:URL) throws {
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile==true,(values.fileSize ?? 0)<2_000_000 else {throw CocoaError(.fileReadTooLarge)}
        let data=try Data(contentsOf:url)
        guard let text=String(data:data,encoding:.utf8),!data.contains(0) else {throw CocoaError(.fileReadInapplicableStringEncoding)}
        self.url=url;original=data;self.text=text
    }
    public func save() throws {
        guard try Data(contentsOf:url)==original else {throw NSError(domain:"Files",code:1,userInfo:[NSLocalizedDescriptionKey:"The file changed on disk. Reload before saving."])}
        try Data(text.utf8).write(to:url,options:.atomic)
    }
}
