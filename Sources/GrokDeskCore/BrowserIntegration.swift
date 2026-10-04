import Foundation

public enum BrowserIntegration {
    public static let serverName="grok-desk-browser"
    public static let package="@playwright/mcp@0.0.83"
    public static let extensionURL=URL(string:"https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm")!
    public static let arguments=["-y",package,"--extension","--caps","vision"]
    public static var configURL:URL {GrokPaths.config}
    public static func arguments(for browser:String) -> [String] {
        browser == "Comet" ? arguments + ["--executable-path", "/Applications/Comet.app/Contents/MacOS/Comet"] : arguments
    }
    public static func configure(at url:URL = configURL,npx:String = RepositoryService.executable("npx"),browser:String = "Chrome") throws {
        guard FileManager.default.isExecutableFile(atPath:npx) else {throw NSError(domain:"Browser",code:1,userInfo:[NSLocalizedDescriptionKey:"Install Node.js (with npx) before connecting the extension."])}
        let original=FileManager.default.fileExists(atPath:url.path) ? try String(contentsOf:url,encoding:.utf8):""
        var doc=try ConfigDocument(text:original)
        try doc.addConnection(name:serverName,target:npx,transport:"stdio",arguments:arguments(for:browser))
        try doc.save(to:url,expected:original)
    }
}
