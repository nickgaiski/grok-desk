import Foundation
import Combine
import CryptoKit

public enum ProbeState: String, Codable, Sendable { case unchecked, checking, verified, failed, unknown }
public struct ConnectionHealth: Equatable, Sendable {
    public var probe: ProbeState = .unchecked
    public var checkedAt: Date?
    public var authorizedAt: Date?
    public var message = "Not checked"
    public init() {}
}
/// Shared evidence, scoped by project and effective configuration version. No credentials retained.
@MainActor public final class ConnectionHealthStore: ObservableObject {
    public static let shared = ConnectionHealthStore()
    @Published public private(set) var records: [String:ConnectionHealth] = [:]
    private let configURL: URL
    public init(configURL: URL = GrokPaths.config) { self.configURL=configURL }
    private func key(_ name:String,_ project:String) -> String {
        let project = URL(fileURLWithPath:project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path:project).standardizedFileURL.resolvingSymlinksInPath().path
        var bytes = (try? Data(contentsOf:configURL)) ?? Data()
        if !project.isEmpty { bytes.append((try? Data(contentsOf:URL(fileURLWithPath:project).appendingPathComponent(".grok/config.toml"))) ?? Data()) }
        let digest=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        return configURL.path + "|" + project + "|" + name + "|" + digest
    }
    public func health(name:String,project:String) -> ConnectionHealth { records[key(name,project)] ?? ConnectionHealth() }
    public func identity(name:String,project:String)->String {key(name,project)}
    @discardableResult public func beginProbe(name:String,project:String)->String {checking(name:name,project:project);return key(name,project)}
    public func checking(name:String,project:String) { update(name,project) { $0.probe = .checking; $0.message = "Checking…" } }
    public func recordProbe(name:String,project:String,verified:Bool?,message:String,expectedIdentity:String? = nil) {
        if let expectedIdentity, expectedIdentity != key(name,project) { return }
        update(name,project) { $0.probe = verified == true ? .verified : verified == false ? .failed : .unknown; $0.checkedAt = Date(); $0.message=message }
    }
    public func recordAuthorization(name:String,project:String,success:Bool,expectedIdentity:String? = nil) {
        if let expectedIdentity, expectedIdentity != key(name,project) { return }
        update(name,project) { if success { $0.authorizedAt=Date() }; $0.probe = .unchecked; $0.message = success ? "Authorized · connection not checked" : "Authorization did not complete" }
    }
    public func invalidate(name:String,project:String) { update(name,project) { $0.probe = .unchecked; $0.checkedAt=nil; $0.message="Connection not checked" } }
    private func update(_ name:String,_ project:String,_ mutate:(inout ConnectionHealth)->Void) {
        let id=key(name,project); var value=records[id] ?? ConnectionHealth(); mutate(&value);records[id]=value
    }
}

/// Schema verified against grok 1.0.46 with a disposable MCP server.
public func doctorConnectionResult(_ json:String, server:String) -> (verified:Bool?, message:String) {
    guard let root=try? JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any],let rows=root["servers"] as? [[String:Any]],let row=rows.first(where:{$0["name"] as? String == server}),let healthy=row["healthy"] as? Bool,let checks=row["checks"] as? [[String:Any]],!checks.isEmpty else {return(nil,"Doctor returned an unrecognized result; connection not verified.")}
    if !healthy {return(false,"Connection needs attention. " + String((checks.first(where:{$0["passed"] as? Bool == false})?["label"] as? String ?? "Doctor reported a failure.").prefix(120)))}
    guard checks.allSatisfy({$0["passed"] as? Bool == true}),checks.contains(where:{$0["label"] as? String == "handshake OK"}) else {return(nil,"Doctor did not confirm a successful MCP handshake.")}
    return(true,"MCP handshake and tool discovery verified.")
}
