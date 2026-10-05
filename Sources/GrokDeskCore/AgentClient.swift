import Darwin
import Foundation

public struct AgentCapabilities: Equatable, Sendable {
    public var images = false
    public var embeddedContext = false
    public var commands: [String] = []
    public var configurationIDs: Set<String> = []
    public var permissionModes: Set<String> = []
    public init() {}
    public static func parse(_ result: [String: Any]) -> Self {
        var value = Self()
        let caps = result["agentCapabilities"] as? [String: Any]
        let prompt = caps?["promptCapabilities"] as? [String: Any]
        value.images = prompt?["image"] as? Bool ?? false
        value.embeddedContext = prompt?["embeddedContext"] as? Bool ?? false
        let meta = result["_meta"] as? [String: Any]
        value.commands = (meta?["availableCommands"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        value.configurationIDs = configurationIDs(in: result)
        value.permissionModes = permissionModes(in: result)
        return value
    }

    public var runtimeSupport: RuntimeSupport {
        RuntimeSupport(commands: Set(commands), configurationIDs: configurationIDs, permissionModes: permissionModes)
    }

    fileprivate static func configurationIDs(in object: [String: Any]) -> Set<String> {
        let rows = object["configOptions"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { $0["id"] as? String })
    }

    fileprivate static func permissionModes(in object: [String: Any]) -> Set<String> {
        let modes = object["modes"] as? [String: Any] ?? [:]
        let rows = modes["availableModes"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { $0["id"] as? String })
    }
}

public struct PermissionChoice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
}

public func agentArguments(socket: String, model: String, effort: String, permission: String) -> [String] {
    var args = ["--permission-mode", permission, "agent", "--no-leader", "--leader-socket", socket]
    if !model.isEmpty { args += ["--model", model] }
    if !effort.isEmpty { args += ["--reasoning-effort", effort] }
    return args + ["stdio"]
}

public final class AgentClient: @unchecked Sendable {
    /// Legacy adapters retained while clients migrate to session-aware envelopes.
    public var onNotification: ((String, [String: Any]) -> Void)?
    public var onUpdate: (([String: Any]) -> Void)?
    public var onPermission: ((Int, String, [PermissionChoice]) -> Void)?
    public var onUpdateEnvelope: ((AgentUpdateEnvelope) -> Void)?
    public var onPermissionEnvelope: ((PermissionEnvelope) -> Void)?
    public var onProtocolIssue: ((String) -> Void)?
    private let binary: String
    private let leaderSocket: String
    private let owned: OwnedProcesses
    private let queue = DispatchQueue(label: "grok-desk.acp")
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var generation = UUID()

    public init(binary: String, leaderSocket: String, owned: OwnedProcesses) {
        self.binary = binary; self.leaderSocket = leaderSocket; self.owned = owned
    }
    public func start(model: String, effort: String, permission: String) throws {
        stop()
        try queue.sync {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = agentArguments(socket: leaderSocket, model: model, effort: effort, permission: permission)
            process.environment = grokEnvironment(ProcessInfo.processInfo.environment)
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let epoch = UUID(); generation = epoch
            process.terminationHandler = { [weak self] process in
                self?.owned.untrack(process.processIdentifier)
                self?.queue.async { [weak self] in
                    guard let self, self.generation == epoch else { return }
                    self.failAll("The Grok agent exited (\(process.terminationStatus)). Reconnect to continue.")
                    self.stdin = nil
                }
            }
            try process.run()
            owned.track(process)
            self.process = process; stdin = input.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let handle = output.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == epoch else { return }
                        self.consume(data)
                    }
                }
            }
            // Drain stderr concurrently so a verbose agent cannot deadlock its stdout.
            DispatchQueue.global(qos: .utility).async {
                while !errors.fileHandleForReading.availableData.isEmpty {}
            }
        }
    }
    public func stop() {
        queue.sync {
            generation = UUID()
            if let child = process, child.isRunning {
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
            process = nil; stdin = nil; buffer.removeAll()
            failAll("Agent stopped.")
        }
    }
    private func failAll(_ message: String) {
        let waiting = pending; pending.removeAll()
        for waiter in waiting.values { waiter.resume(throwing: Self.failure(message)) }
    }
    public static func failure(_ message: String) -> NSError {
        NSError(domain: "GrokDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    public func initialize() async throws -> AgentCapabilities {
        let result = try await request(method: "initialize", params: ["protocolVersion": 1, "clientInfo": ["name": "grok-desk", "version": "0.2.0"], "clientCapabilities": [:]])
        return AgentCapabilities.parse(Self.object(result))
    }
    public func openSessionResult(cwd: String, sessionId: String?, model: String, effort: String) async throws -> SessionOpenResult {
        var params: [String: Any] = ["cwd": cwd, "mcpServers": []]
        if let sessionId { params["sessionId"] = sessionId }
        let result = try await request(method: sessionId == nil ? "session/new" : "session/load", params: params)
        let object = Self.object(result)
        guard let id = sessionId ?? object["sessionId"] as? String, !id.isEmpty else {
            throw Self.failure("The agent did not return a session ID.")
        }
        let metadata = try JSONSerialization.data(withJSONObject: object)
        let initial = AgentCapabilities.parse(object).runtimeSupport
        let support = RuntimeSupport(
            commands: initial.commands,
            configurationIDs: initial.configurationIDs,
            permissionModes: initial.permissionModes
        )
        return SessionOpenResult(sessionID: id, support: support, metadata: metadata)
    }
    public func openSession(cwd: String, sessionId: String?, model: String, effort: String) async throws -> String {
        try await openSessionResult(cwd: cwd, sessionId: sessionId, model: model, effort: effort).sessionID
    }
    public func setSessionMode(sessionId: String, modeId: String) async throws {
        _ = try await request(method: "session/set_mode", params: ["sessionId": sessionId, "modeId": modeId])
    }
    public func configure(sessionId: String, model: String, effort: String) async throws {
        for (id, value) in [("model", model), ("reasoning_effort", effort)] where !value.isEmpty {
            _ = try await request(method: "session/set_config_option", params: ["sessionId": sessionId, "configId": id, "value": value])
        }
    }
    public func authorizeMCP(sessionID: String, serverName: String) async throws -> String {
        let response = try await request(method: "_x.ai/mcp/auth_trigger", params: ["session_id": sessionID, "server_name": serverName], timeout: 300)
        let envelope = Self.object(response)
        let result = envelope["result"] as? [String: Any] ?? envelope
        if let error = result["error"] as? String { throw Self.failure(error) }
        let status = result["status"] as? String ?? "unknown"
        guard ["success", "authenticated", "connected", "ok"].contains(status) else {
            throw Self.failure("Authorization returned \(status). Check the provider window and retry.")
        }
        return status
    }
    public func prompt(sessionId: String, text: String, attachments: [URL] = [], capabilities: AgentCapabilities, timeout: Double = 1800) async throws {
        let parts = try promptParts(text: text, attachments: attachments, capabilities: capabilities)
        _ = try await request(method: "session/prompt", params: ["sessionId": sessionId, "prompt": parts], timeout: timeout)
    }
    public func cancel(sessionId: String) {
        notify(method: "session/cancel", params: ["sessionId": sessionId])
    }
    public func respond(requestID: Int, optionID: String?) {
        let outcome: [String: String] = optionID.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "result": ["outcome": outcome]])
        queue.async { [weak self] in if let data { try? self?.write(data) } }
    }
    private func notify(method: String, params: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params])
        queue.async { [weak self] in if let data { try? self?.write(data) } }
    }
    private func request(method: String, params: [String: Any], timeout: Double = 45) async throws -> String {
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let id = self.nextID; self.nextID += 1
                do {
                    guard self.process?.isRunning == true else { throw Self.failure("Grok is disconnected.") }
                    let params = try JSONSerialization.jsonObject(with: paramsData)
                    let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                    self.pending[id] = continuation
                    try self.write(data)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.pending.removeValue(forKey: id)?.resume(throwing: Self.failure("Grok timed out. Reconnect before retrying."))
                    }
                } catch {
                    self.pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func write(_ data: Data) throws {
        guard let stdin else { throw Self.failure("Grok is disconnected.") }
        try stdin.write(contentsOf: data + Data([10]))
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 8_000_000 else {
            buffer.removeAll(); failAll("The agent exceeded the response buffer limit."); process?.terminate(); return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                onProtocolIssue?("Ignored malformed ACP JSON-RPC message.")
                continue
            }
            handle(object)
        }
    }
    private func handle(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            guard let params = object["params"] as? [String: Any] else {
                onProtocolIssue?("Ignored \(method) message with malformed params.")
                if let id = object["id"] as? Int { respondUnsupported(id: id) }
                return
            }
            if method == "session/update" {
                guard let sessionID = params["sessionId"] as? String, !sessionID.isEmpty else {
                    onProtocolIssue?("Ignored session/update without a session ID.")
                    return
                }
                let update = params["update"] as? [String: Any] ?? params
                guard let updateKind = update["sessionUpdate"] as? String, !updateKind.isEmpty else {
                    onProtocolIssue?("Ignored session/update without a sessionUpdate kind.")
                    return
                }
                guard let payload = try? JSONSerialization.data(withJSONObject: update),
                      let metadata = try? JSONSerialization.data(withJSONObject: params) else {
                    onProtocolIssue?("Ignored session/update with an invalid payload.")
                    return
                }
                onUpdateEnvelope?(AgentUpdateEnvelope(sessionID: sessionID, payload: payload, metadata: metadata))
                onUpdate?(update)
            } else if method == "session/request_permission", let id = object["id"] as? Int {
                guard let sessionID = params["sessionId"] as? String, !sessionID.isEmpty else {
                    onProtocolIssue?("Ignored session/request_permission without a session ID.")
                    respondUnsupported(id: id)
                    return
                }
                let tool = params["toolCall"] as? [String: Any]
                let choices = (params["options"] as? [[String: Any]] ?? []).compactMap { row -> PermissionChoice? in
                    guard let id = row["optionId"] as? String else { return nil }
                    return PermissionChoice(id: id, name: row["name"] as? String ?? id, kind: row["kind"] as? String ?? "")
                }
                guard let metadata = try? JSONSerialization.data(withJSONObject: params) else {
                    onProtocolIssue?("Ignored session/request_permission with invalid metadata.")
                    respondUnsupported(id: id)
                    return
                }
                let envelope = PermissionEnvelope(sessionID: sessionID, requestID: id, title: tool?["title"] as? String ?? "Permission requested", choices: choices, metadata: metadata)
                onPermissionEnvelope?(envelope)
                onPermission?(id, envelope.title, choices)
            } else if let id = object["id"] as? Int {
                onProtocolIssue?("Unsupported ACP request from provider: \(method).")
                respondUnsupported(id: id)
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let id = object["id"] as? Int, let waiter = pending[id] else { return }
        if let error = object["error"] as? [String: Any] {
            pending.removeValue(forKey: id)
            waiter.resume(throwing: Self.failure(error["message"] as? String ?? "ACP request failed."))
        } else if let result = object["result"], JSONSerialization.isValidJSONObject(result),
                  let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) {
            pending.removeValue(forKey: id)
            waiter.resume(returning: text)
        } else {
            onProtocolIssue?("Ignored malformed ACP response for request \(id).")
        }
    }
    private func respondUnsupported(id: Int) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client method"]]) else { return }
        try? write(data)
    }
    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }
}

public func promptParts(text: String, attachments: [URL], capabilities: AgentCapabilities) throws -> [[String: Any]] {
    var parts: [[String: Any]] = [["type": "text", "text": text]]
    guard attachments.count <= 14 else { throw AgentClient.failure("Attach at most 14 files.") }
    for url in attachments {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw AgentClient.failure("Attach regular files, or use Choose workspace for folders.") }
        let binaryTypes = ["pdf", "zip", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "mp4", "mov", "wav", "mp3", "m4a", "heic", "tiff"]
        if (values.fileSize ?? Int.max) > 10_000_000 || binaryTypes.contains(url.pathExtension.lowercased()) {
            parts.append(["type": "text", "text": "User-attached local file: " + url.path + "\nUse your file tools to inspect this specific file as needed. Do not claim to have read it before inspecting it."])
            continue
        }
        let ext = url.pathExtension.lowercased()
        let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"][ext]
        let data = try Data(contentsOf: url)
        if let mime {
            if capabilities.images {
                parts.append(["type": "image", "data": data.base64EncodedString(), "mimeType": mime])
            } else {
                parts.append(["type": "text", "text": "User-attached local image file: \(url.path)\nThis ACP session does not advertise inline image input. Use your file tools to inspect this specific image before describing it; do not claim to have seen it before opening it."])
            }
        } else {
            guard capabilities.embeddedContext, let text = String(data: data, encoding: .utf8) else { throw AgentClient.failure("This agent accepts UTF-8 text attachments only. Your file has been kept.") }
            parts.append(["type": "resource", "resource": ["uri": url.absoluteString, "mimeType": "text/plain", "text": text]])
        }
    }
    return parts
}
