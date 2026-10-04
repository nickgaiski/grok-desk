import AppKit
import WebKit
import GrokDeskCore
import SwiftUI

struct BrowserSettings:View {
    @ObservedObject var model:DeskModel
    var cwd:String
    @AppStorage("externalBrowser") private var externalBrowser="Comet"
    @AppStorage("browserPlacement") private var placement="Side"
    @AppStorage("terminalFontSize") private var terminalFontSize=12.0
    @AppStorage("privateEmbeddedBrowser") private var privateBrowsing=false
    @AppStorage("browserSearchEngine") private var searchEngine="Google"
    @State private var clearData=false
    @State private var confirm=false
    @State private var message=""
    @State private var testing=false
    private var configured:Bool {model.mcpItems.contains{$0.name==BrowserIntegration.serverName}}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Browser & panels").font(.system(size:18,weight:.medium))
            Picker("Panel position",selection:$placement) {Text("Side").tag("Side");Text("Bottom").tag("Bottom")}.pickerStyle(.segmented)
            Picker("Open external pages in",selection:$externalBrowser) {Text("Chrome").tag("Chrome");Text("Comet").tag("Comet");Text("Default browser").tag("Default")}
            Picker("Search engine",selection:$searchEngine) {Text("Google").tag("Google");Text("DuckDuckGo").tag("DuckDuckGo")}
            Toggle("Private embedded browsing",isOn:$privateBrowsing).toggleStyle(.switch)
            Text("Applies to new embedded tabs. External browsers keep their own profiles.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            Button("Clear embedded cookies and website data") {clearData=true}.buttonStyle(QuietButton())
            HStack {Text("Terminal text size");Slider(value:$terminalFontSize,in:10...20,step:1);Text("\(Int(terminalFontSize)) pt").monospacedDigit()}.font(.system(size:12))
            Divider()
            Label("Browser extension connection",systemImage:"puzzlepiece.extension").font(.system(size:14,weight:.medium))
            Text("The embedded panel stays a WebView. The Playwright extension connects Grok to your external browser. Its approval can grant browser-wide access, including signed-in sessions.").font(.system(size:12)).foregroundStyle(DeskColor.muted)
            HStack {
                Button("Install extension") {BrowserApplications.open(BrowserIntegration.extensionURL,in:externalBrowser)}.buttonStyle(DeskButtonStyle())
                Button(configured ? "Configured":"Configure Grok") {confirm=true}.buttonStyle(DeskButtonStyle(prominent:true)).disabled(configured || model.busy)
            }
            ConnectionHealthBadge(name: BrowserIntegration.serverName, project: cwd, enabled: model.mcpItems.first(where: { $0.name == BrowserIntegration.serverName })?.enabled ?? false)
            Text(configured ? "MCP connection configured. Browser access still requires the extension’s connection approval." : "Not configured. Install the extension, then configure Grok.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            Text("Comet is targeted through its installed browser executable. Use Test browser connection to verify the extension handshake.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            HStack {
                Button("Test browser connection") {test()}.buttonStyle(DeskButtonStyle()).disabled(!configured || testing || model.busy)
                Button("Manage extensions") {BrowserApplications.open(URL(string:"chrome://extensions")!,in:externalBrowser)}.buttonStyle(QuietButton())
            }
            if !message.isEmpty {Text(message).font(.system(size:12)).textSelection(.enabled)}
            Text("This setup stores no automatic-access token. The extension may remember approvals; review and revoke access in the extension when needed.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            Link("Extension setup documentation",destination:URL(string:"https://github.com/microsoft/playwright/tree/main/packages/extension#readme")!).font(.system(size:11))
        }.foregroundStyle(DeskColor.ink)
            .confirmationDialog("Clear embedded website data?",isPresented:$clearData,titleVisibility:.visible) {
                Button("Clear website data",role:.destructive) {
                    WKWebsiteDataStore.default().removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast) {message="Embedded website data cleared. External browser data was not changed."}
                }
            } message: {Text("This signs you out of websites in the embedded browser. Chrome and Comet are unaffected.")}
            .confirmationDialog("Configure Grok’s browser connection?",isPresented:$confirm,titleVisibility:.visible) {
                Button("Configure extension bridge") {configure()}
            } message: {Text("Adds a local Playwright MCP server to Grok's config. The extension asks for connection approval and may grant browser-wide access. Existing settings are backed up and preserved.")}
    }
    private func configure(){do {try BrowserIntegration.configure(browser:externalBrowser);message="Configured. Restart Grok Desk to load the browser tools.";Task{await model.reloadSkills(cwd:cwd)}}catch{message=error.localizedDescription}}
    private func test(){testing=true;message="Checking the bridge… Approve the browser connection if the extension asks.";Task {message=await model.testBrowserConnection(cwd:cwd);testing=false}}
}
enum BrowserApplications {
    static func open(_ url:URL,in name:String = UserDefaults.standard.string(forKey:"externalBrowser") ?? "Comet") {
        let path=name == "Comet" ? "/Applications/Comet.app" : "/Applications/Google Chrome.app"
        if name != "Default",FileManager.default.fileExists(atPath:path) {NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:path),configuration:NSWorkspace.OpenConfiguration())}
        else {NSWorkspace.shared.open(url)}
    }
}
