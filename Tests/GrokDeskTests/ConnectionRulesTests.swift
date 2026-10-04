import XCTest
@testable import GrokDeskCore
final class ConnectionRulesTests:XCTestCase {
    func testRulesConflictAndBackupReadback() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("AGENTS.md")
        var doc=try RulesDocument(url:url);doc.text="Use tests";try doc.save()
        doc.text="Use meaningful tests";try doc.save()
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),doc.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path).filter{$0.contains("backup-")}.count,1)
        try Data("External edit".utf8).write(to:url)
        doc.text="Do not overwrite";XCTAssertThrowsError(try doc.save())
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),"External edit")
    }
    func testStaleRuleDocumentCannotSaveUnderDifferentScopeLabel() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let project=root.appendingPathComponent("project-AGENTS.md"),global=root.appendingPathComponent("global-AGENTS.md")
        try Data("Original project rules".utf8).write(to:project)
        try Data([0xff,0xfe,0xff]).write(to:global)
        var stale=try RulesDocument(url:project)
        XCTAssertThrowsError(try RulesDocument(url:global))
        stale.text="Intended for global scope"
        XCTAssertThrowsError(try stale.save(expectedURL:global))
        XCTAssertEqual(try String(contentsOf:project,encoding:.utf8),"Original project rules")
    }
    @MainActor func testAuthorizationDoesNotImplyConnectedAndEvidenceIsProjectScoped() {
        let store=ConnectionHealthStore()
        store.recordAuthorization(name:"server",project:"/tmp/A",success:true)
        XCTAssertEqual(store.health(name:"server",project:"/tmp/A").probe,.unchecked)
        store.recordProbe(name:"server",project:"/tmp/A",verified:true,message:"Connected")
        XCTAssertEqual(store.health(name:"server",project:"/tmp/A").probe,.verified)
        XCTAssertEqual(store.health(name:"server",project:"/tmp/B").probe,.unchecked)
        store.invalidate(name:"server",project:"/tmp/A")
        XCTAssertNotNil(store.health(name:"server",project:"/tmp/A").authorizedAt)
        XCTAssertEqual(store.health(name:"server",project:"/tmp/A").probe,.unchecked)
    }
    @MainActor func testConfigChangedDuringProbeCannotInheritOldSuccess() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:file)}
        try Data("before".utf8).write(to:file)
        let store=ConnectionHealthStore(configURL:file)
        let identity=store.beginProbe(name:"server",project:"")
        try Data("after".utf8).write(to:file)
        store.recordProbe(name:"server",project:"",verified:true,message:"old server",expectedIdentity:identity)
        XCTAssertEqual(store.health(name:"server",project:"").probe,.unchecked)
        let current=store.beginProbe(name:"server",project:"")
        store.recordProbe(name:"server",project:"",verified:true,message:"new server",expectedIdentity:current)
        XCTAssertEqual(store.health(name:"server",project:FileManager.default.homeDirectoryForCurrentUser.path).probe,.verified)
    }
    func testDoctorRequiresMatchingServerAndHandshakeEvidence() {
        let healthy = #"{"servers":[{"name":"fixture","healthy":true,"checks":[{"label":"handshake OK","passed":true},{"label":"1 tools discovered","passed":true}]}]}"#
        XCTAssertEqual(doctorConnectionResult(healthy,server:"fixture").verified,true)
        XCTAssertNil(doctorConnectionResult(healthy,server:"different").verified)
        XCTAssertNil(doctorConnectionResult("{}",server:"fixture").verified)
        let failed = #"{"servers":[{"name":"fixture","healthy":false,"checks":[{"label":"handshake OK","passed":false}]}]}"#
        XCTAssertEqual(doctorConnectionResult(failed,server:"fixture").verified,false)
    }
    func testConfigPathHonorsBothOverrides() {
        XCTAssertEqual(GrokPaths.configURL(environment:["GROK_HOME":"/tmp/alternate"]).path,"/tmp/alternate/config.toml")
        XCTAssertEqual(GrokPaths.configURL(environment:["GROK_HOME":"/tmp/alternate","GROK_DESK_CONFIG_PATH":"/tmp/test.toml"]).path,"/tmp/test.toml")
    }
}
