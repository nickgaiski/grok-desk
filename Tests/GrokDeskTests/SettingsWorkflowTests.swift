import XCTest
@testable import GrokDeskCore

final class SettingsWorkflowTests: XCTestCase {
    func testComplexFormValuesRoundTripAndAddingConnectionKeepsComments() throws {
        let original = "# Preserve me\n[[marketplace.sources]]\nname = 'Official'\ngit = 'https://example.test/repo'\n[ui]\nlabel = 'A string with \"quotes\"'\n"
        var document = try ConfigDocument(text:original)
        for field in document.fields { try document.set(path:field.path,literal:field.literal) }
        XCTAssertEqual(try ConfigDocument(text:document.text).fields.count,2)
        try document.addConnection(name:"test-server",target:"https://example.test/mcp",transport:"http",arguments:[])
        XCTAssertTrue(document.text.contains("# Preserve me"))
        XCTAssertTrue(document.fields.contains { $0.path == ["mcp_servers","test-server","url"] })
        XCTAssertThrowsError(try document.addConnection(name:"test-server",target:"https://example.test/mcp",transport:"http",arguments:[]))
    }
    func testRepositoryIdentityRecognizesRenamedInstalledPlugin() {
        XCTAssertEqual(pluginRepository("https://github.com/netlify/context-and-tools.git@abc#plugin"), pluginRepository("https://github.com/netlify/context-and-tools.git"))
    }
    func testLiveBillingUsesCreditPercentAndRejectsMissingQuota() throws {
        let live = try decodeLiveSubscription(Data(#"{"config":{"creditUsagePercent":12.5,"currentPeriod":{"end":"2026-10-08"}}}"#.utf8), plan: "Heavy")
        XCTAssertEqual(live.percentLeft,87.5)
        XCTAssertThrowsError(try decodeLiveSubscription(Data(#"{"config":{"used":{"val":0},"monthlyLimit":{"val":0}}}"#.utf8), plan:"Heavy"))
    }
    func testConfigEditsPreserveUnknownKeysAndSaveDetectsConcurrentChange() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("config.toml"), original="# keep this comment\n[ui]\ncompact_mode = false\n[custom]\nvalue = 'leave me'\n"
        try Data(original.utf8).write(to:url)
        var doc=try ConfigDocument(text:original)
        try doc.set(path:["ui","compact_mode"], literal:"true")
        XCTAssertTrue(doc.text.contains("# keep this comment")); XCTAssertTrue(doc.text.contains("value = 'leave me'"))
        try doc.save(to:url,expected:original)
        XCTAssertTrue(try String(contentsOf:url,encoding:.utf8).contains("compact_mode = true"))
        XCTAssertThrowsError(try doc.save(to:url,expected:original))
        XCTAssertThrowsError(try ConfigDocument(text:"[broken"))
    }
}

@MainActor
final class PluginInstallStateTests: XCTestCase {
    func testAliasRemainsInstalledAfterInspectUsesDifferentName() async {
        let runner=ScriptedRunner([
            .init(status:0,stdout:"[]",stderr:""),
            .init(status:0,stdout:#"[{"name":"netlify-skills","path":"/tmp/netlify","source":"https://github.com/netlify/context-and-tools.git"}]"#,stderr:""),
            .init(status:0,stdout:"",stderr:""),
            .init(status:0,stdout:#"{"plugins":[{"name":"netlify-skills","path":"/tmp/netlify","enabled":true}]}"#,stderr:"")
        ])
        let model=DeskModel(runner:runner,leaderSocket:"/tmp/plugin-test",sessionsRoot:URL(fileURLWithPath:"/tmp/no-sessions"))
        await model.reloadSkills(cwd:"/tmp")
        let catalog=MarketplacePlugin(name:"netlify",title:"Netlify",summary:"",marketplace:"xAI",installSource:"https://github.com/netlify/context-and-tools.git@abc",logoURL:nil,webpage:nil,publisher:"Netlify")
        XCTAssertEqual(model.installedPlugin(catalog)?.name,"netlify-skills")
    }
    func testAuthorizationCommandQuotesNamesAndPaths() {
        XCTAssertEqual(terminalAuthorizationCommand(binary:"/tmp/grok",cwd:"/tmp/O'Brien"),"'/tmp/grok' --cwd '/tmp/O'\\''Brien' /mcps")
    }
}
