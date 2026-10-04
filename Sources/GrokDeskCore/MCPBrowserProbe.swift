import Foundation
import TOMLKit

/// A read-only, bounded MCP handshake and browser_tabs call. No LLM interpretation
/// or browser navigation is used to decide whether the extension connected.
public struct BrowserProbeResult: Sendable {
    public let verified: Bool
    public let message: String
}
public enum MCPBrowserProbe {
    public static func check(configURL:URL = BrowserIntegration.configURL) async -> String {
        await checkResult(configURL: configURL).message
    }
    public static func checkResult(configURL: URL = BrowserIntegration.configURL) async -> BrowserProbeResult {
        await Task.detached(priority:.userInitiated) { () -> BrowserProbeResult in
            do {
                let config=try TOMLTable(string:String(contentsOf:configURL,encoding:.utf8))
                guard let server=config["mcp_servers"]?.tomlValue.table?[BrowserIntegration.serverName]?.tomlValue.table,
                      let command=server["command"]?.tomlValue.string,
                      let args=server["args"]?.tomlValue.array?.compactMap({$0.string}) else {return BrowserProbeResult(verified: false, message: "Browser bridge is not configured.")}
                let transport=ProbeTransport()
                try transport.start(command:command,args:args)
                defer {transport.stop()}
                _ = try transport.request("initialize",["protocolVersion":"2025-03-26","clientInfo":["name":"Grok Desk browser check","version":"0.7.0"],"capabilities":[:]])
                try transport.notify("notifications/initialized",[:])
                let listed=try transport.request("tools/list",[:])
                guard (listed["tools"] as? [[String:Any]])?.contains(where:{$0["name"] as? String == "browser_tabs"})==true else {return BrowserProbeResult(verified: false, message: "The configured server does not expose browser_tabs.")}
                let response=try transport.request("tools/call",["name":"browser_tabs","arguments":["action":"list"]],timeout:90)
                let text=(response["content"] as? [[String:Any]] ?? []).compactMap{$0["text"] as? String}.joined(separator:"\n")
                guard !text.isEmpty else { return BrowserProbeResult(verified: false, message: "The bridge responded without a tab-list result. Connection not verified.") }
                if response["isError"] as? Bool == true {return BrowserProbeResult(verified: false, message: "Browser connection failed:\n"+text)}
                return BrowserProbeResult(verified: true, message: "Browser extension verified. The bridge returned:\n"+text)
            }catch{return BrowserProbeResult(verified: false, message: "Browser connection failed: "+error.localizedDescription)}
        }.value
    }
}
private final class ProbeTransport:@unchecked Sendable {
    private let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
    private let lock=NSLock(),ready=DispatchSemaphore(value:0)
    private var nextID=0,expectedID=0
    private var response:[String:Any]?
    private var buffer=Data()
    func start(command:String,args:[String]) throws {
        process.executableURL=URL(fileURLWithPath:command);process.arguments=args
        var environment=ProcessInfo.processInfo.environment
        environment.removeValue(forKey:"PLAYWRIGHT_MCP_EXTENSION_TOKEN")
        process.environment=environment
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        output.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            guard !data.isEmpty else{return}
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler={ handle in _ = handle.availableData }
        process.terminationHandler={ [weak self] _ in self?.ready.signal() }
        try process.run()
    }
    func stop(){try? input.fileHandleForWriting.close();output.fileHandleForReading.readabilityHandler=nil;errors.fileHandleForReading.readabilityHandler=nil;if process.isRunning {process.terminate()}}
    func request(_ method:String,_ params:[String:Any],timeout:Double=30)throws->[String:Any] {
        lock.lock();nextID+=1;expectedID=nextID;response=nil;let id=nextID;lock.unlock()
        try write(["jsonrpc":"2.0","id":id,"method":method,"params":params])
        guard ready.wait(timeout:.now()+timeout) == .success else {throw failure("The extension did not connect in time. Check Comet’s extension approval tab and retry.")}
        lock.lock();let reply=response;lock.unlock()
        guard let reply else {throw failure("The browser bridge exited before responding.")}
        if let error=reply["error"] as? [String:Any] {throw failure(error["message"] as? String ?? "MCP request failed")}
        return reply["result"] as? [String:Any] ?? [:]
    }
    func notify(_ method:String,_ params:[String:Any])throws {try write(["jsonrpc":"2.0","method":method,"params":params])}
    private func write(_ object:[String:Any])throws {try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:object)+Data([10]))}
    private func receive(_ data:Data) {
        lock.lock();defer{lock.unlock()}
        buffer.append(data)
        if buffer.count>4_000_000 {buffer.removeAll();ready.signal();return}
        while let newline=buffer.firstIndex(of:10) {
            let line=buffer[..<newline];buffer.removeSubrange(...newline)
            guard let object=try? JSONSerialization.jsonObject(with:line) as? [String:Any],object["id"] as? Int==expectedID else{continue}
            response=object;ready.signal()
        }
    }
    private func failure(_ message:String)->NSError {NSError(domain:"BrowserProbe",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
