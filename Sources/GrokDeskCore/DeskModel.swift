import Combine
import Foundation

@MainActor
public final class DeskModel: ObservableObject {
    @Published public private(set) var sessions: [DeskSession] = []
    @Published public private(set) var models: [GrokModel] = []
    @Published public private(set) var modelsStale = false
    @Published public private(set) var subscriptionAuthVerified = false
    @Published public private(set) var extensionsLoading = false
    @Published public private(set) var extensionsError: String?
    @Published public private(set) var updateTitle: String?
    @Published public private(set) var updateError: String?
    @Published public private(set) var updating = false
    @Published public private(set) var account = AccountProfile(ok: false, name: "Grok", email: "", initials: "?", message: "")
    @Published public private(set) var usage = UsageTotals(chats: 0, userMessages: 0, assistantMessages: 0, toolCalls: 0, models: [])
    @Published public private(set) var configText = ""
    @Published public private(set) var mcpItems: [ListedItem] = []
    @Published public private(set) var marketplacePlugins: [MarketplacePlugin] = []
    @Published public private(set) var marketplaceLoading = false
    @Published public private(set) var marketplaceError: String?
    @Published public private(set) var installingPlugin: String?
    @Published public private(set) var skillDirectory = ""
    @Published public private(set) var pluginActionMessage = ""
    @Published public private(set) var pluginItems: [ListedItem] = []
    @Published public private(set) var skillItems: [SkillRecord] = []
    @Published public private(set) var blocks: [ChatBlock] = []
    @Published public private(set) var busy = false
    @Published public private(set) var chatError: String?
    @Published public private(set) var permissionTitle: String?
    @Published public private(set) var permissionChoices: [PermissionChoice] = []
    @Published public private(set) var queuedPrompts: [QueuedPrompt] = []
    @Published public private(set) var runtimeSummaries: [RuntimeSummary] = []
    @Published public private(set) var connectionStatus = "Not connected"
    @Published public private(set) var capabilities = AgentCapabilities()
    @Published public private(set) var connecting = false
    @Published public var selectedModel = ""
    @Published public var effort = "high"
    /// Permission and Plan are independent. Plan remains an explicit TUI fallback
    /// until ACP advertises a verified native review operation.
    @Published public var permissionMode = "default"
    @Published public var planMode = false
    @Published public var allowSubagents = true
    @Published public private(set) var contextLabel = ""
    @Published public private(set) var imagineMessage = ""
    @Published public private(set) var imaginePath: String?
    @Published public private(set) var worktreeText = ""
    @Published public private(set) var subscriptionUpdatedAt: Date?
    @Published public private(set) var subscriptionRefreshing = false
    @Published public private(set) var subscriptionError: String?
    @Published public private(set) var pluginBusy = false
    @Published public private(set) var authorizingServer: String?
    private var authorizationClient: AgentClient?
    private var authorizationCancelled = false
    private var authorizingProject = ""
    @Published public private(set) var connectionStatusText = ""
    @Published public private(set) var installedPackages: [ListedItem] = []
    @Published public private(set) var subscription: SubscriptionSnapshot?

    private nonisolated(unsafe) let runner: CommandRunning
    private let leaderSocket: String
    private let sessionsRoot: URL
    private let binary: String
    private nonisolated let owned: OwnedProcesses
    private let runtimeRegistry: RuntimeRegistry
    private var selectedRuntime: SessionRuntime
    private var immediateSkillSnapshots: [UUID: [SkillRecord]] = [:]
    private var agent: AgentClient? {
        get { selectedRuntime.agent }
        set { selectedRuntime.agent = newValue }
    }
    private var liveSession: String { selectedRuntime.sessionID ?? "" }
    private var sessionCWD: String { selectedRuntime.cwd }
    private var sessionNeedsLoad: Bool {
        get { selectedRuntime.sessionNeedsLoad }
        set { selectedRuntime.sessionNeedsLoad = newValue }
    }
    private var loadingSession: Bool {
        get { selectedRuntime.loadingSession }
        set { selectedRuntime.loadingSession = newValue }
    }
    private var refreshing = false

    public var sessionsDirectory: URL { sessionsRoot }
    public var currentRuntimeID: String { selectedRuntime.id }
    public func result(forRuntimeID id: String) -> (sessionID: String?, blocks: [ChatBlock], error: String?)? {
        guard let runtime = runtimeRegistry.runtime(id: id) else { return nil }
        return (runtime.sessionID, runtime.blocks, runtime.chatError)
    }
    public var activeRuntimeID: String { selectedRuntime.id }
    public var activeSessionID: String? { selectedRuntime.sessionID }
    public var activeRuntimeSupport: RuntimeSupport { selectedRuntime.support }
    public var activeRuntimeState: RunState { selectedRuntime.state }
    public var activeRuntimeActivity: [AgentActivityEvent] { selectedRuntime.activity }
    public var runtimeActivity: [String: [AgentActivityEvent]] {
        Dictionary(uniqueKeysWithValues: runtimeRegistry.all.map { ($0.id, $0.activity) })
    }
    public var runtimePermissions: [String: PermissionEnvelope] {
        Dictionary(uniqueKeysWithValues: runtimeRegistry.all.compactMap { runtime in
            runtime.permission.map { (runtime.id, $0) }
        })
    }

    public init(
        runner: CommandRunning,
        leaderSocket: String,
        sessionsRoot: URL,
        owned: OwnedProcesses = OwnedProcesses(),
        binary: String = "",
        queueStore: PromptQueueStore = PromptQueueStore()
    ) {
        self.runner = runner
        self.leaderSocket = leaderSocket
        self.sessionsRoot = sessionsRoot
        self.owned = owned
        self.binary = binary
        let registry = RuntimeRegistry(queueStore: queueStore)
        runtimeRegistry = registry
        selectedRuntime = registry.newDraft()
        runtimeSummaries = registry.summaries
        project(selectedRuntime)
    }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        sessions = loadSessions(root: sessionsRoot)
        let catalog = ModelCatalogState(models: models, stale: modelsStale)
        let fetched = await fetch(catalog: catalog)
        models = fetched.models
        modelsStale = fetched.stale
        subscriptionAuthVerified = fetched.subscriptionAuth
        if !models.contains(where: { $0.id == selectedModel }) {
            selectedModel = models.first(where: \.isDefault)?.id ?? models.first?.id ?? ""
        }
        if fetched.didCheck {
            updateTitle = fetched.updateTitle
        }
    }

    public func installUpdate() async {
        guard !updating, !runtimeRegistry.all.contains(where: { $0.busy || $0.connecting }) else { return }
        runtimeRegistry.stopAll()
        newChat()
        updating = true
        updateError = nil
        let result = await install()
        if let result {
            updateError = result.error
            if result.error == nil {
                updateTitle = result.buttonTitle
            }
        }
        updating = false
    }

    private nonisolated func fetch(catalog: ModelCatalogState) async -> (models: [GrokModel], stale: Bool, didCheck: Bool, updateTitle: String?, subscriptionAuth: Bool) {
        let listed = try? await runner.run(grokArguments(leaderSocket: leaderSocket, user: ["models"]))
        let verified = listed?.status == 0 && listed?.stdout.contains("You are logged in with grok.com.") == true
        let next: ModelCatalogState
        if let listed, listed.status == 0, !listed.stderr.contains("Failed to fetch models"), !parseModels(listed.stdout).isEmpty {
            next = reduceCatalog(catalog, stdout: listed.stdout, failed: false)
        } else {
            next = reduceCatalog(catalog, stdout: nil, failed: true)
        }
        if let checked = try? await runner.run(
            grokArguments(leaderSocket: leaderSocket, user: ["update", "--check", "--json"])
        ), checked.status == 0, let decoded = try? decodeUpdateCheck(Data(checked.stdout.utf8)) {
            return (next.models, next.stale, true, updateButtonTitle(decoded), verified)
        }
        return (next.models, next.stale, false, nil, verified)
    }

    private nonisolated func install() async -> UpdateInstallResult? {
        let owned = owned
        return try? await installGrokUpdate(runner: runner, leaderSocket: leaderSocket) {
            stopOwned(owned)
        }
    }

    public func continueInTerminal(_ session: DeskSession) -> String {
        terminalResumeCommand(sessionID: session.id, cwd: session.cwd)
    }

    public func loadLocal() {
        account = loadAccount()
        usage = usageTotals(root: sessionsRoot)
        configText = readableConfig()
        if subscriptionUpdatedAt == nil { subscription = loadSubscription() }
    }

    public func reloadSkills(cwd: String = "") async {
        while extensionsLoading {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
        let discoveryFolder = cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : cwd
        extensionsLoading = true; extensionsError = nil
        defer { extensionsLoading = false }
        let mcp = await cli(["mcp", "list", "--json"])
        let plugins = await cli(["plugin", "list", "--json"])
        if let mcp, mcp.status == 0 { mcpItems = parseJsonList(mcp.stdout) }
        else { extensionsError = "Could not refresh MCP servers. The last loaded list is retained." }
        if let plugins, plugins.status == 0 { installedPackages = parseJsonList(plugins.stdout); pluginItems = installedPackages }
        else { extensionsError = "Could not refresh extensions. The last loaded list is retained." }
        if let trees = await cli(["worktree", "list"]) {
            worktreeText = trees.stdout.isEmpty ? trees.stderr : trees.stdout
        }
        if let inspected = await cli(["--cwd", discoveryFolder, "inspect", "--json"]),
           inspected.status == 0,
           let data = inspected.stdout.data(using: .utf8) {
            let catalog = parseInspectCatalog(data)
            skillItems = catalog.skills
            skillDirectory = discoveryFolder
            pluginItems = catalog.plugins.map { item in
                var item = item
                item.repository = installedPackages.first(where: { $0.name == item.name || $0.detail == item.detail })?.repository ?? ""
                return item
            }
            mcpItems = catalog.mcp
        }
    }

    public func refreshSubscription() async {
        guard !subscriptionRefreshing else { return }
        subscriptionRefreshing = true
        defer { subscriptionRefreshing = false }
        do { let result = try await fetchLiveSubscription(); subscription = result; subscriptionUpdatedAt = Date(); subscriptionError = nil }
        catch { if !Task.isCancelled { subscriptionError = error.localizedDescription } }
    }
    public func installedPlugin(_ plugin: MarketplacePlugin) -> ListedItem? {
        pluginItems.first { $0.name == plugin.name || (!$0.repository.isEmpty && pluginRepository($0.repository) == pluginRepository(plugin.installSource)) }
        ?? installedPackages.first { $0.name == plugin.name || (!$0.repository.isEmpty && pluginRepository($0.repository) == pluginRepository(plugin.installSource)) }
    }
    public func managePlugin(_ name:String, enabled:Bool) async {
        guard !pluginBusy, !busy else { return }; pluginBusy = true
        defer { pluginBusy = false }
        let result = await cli(["plugin",enabled ? "enable" : "disable",name])
        guard result?.status == 0 else { connectionStatusText = "Could not change plugin state: " + (result?.stderr ?? "CLI unavailable"); return }
        await reloadSkills(cwd:skillDirectory)
        agent?.stop();agent=nil;sessionNeedsLoad=true
        connectionStatusText = enabled ? "Plugin enabled; the next turn reconnects its tools." : "Plugin disconnected."
    }
    public func testBrowserConnection(cwd: String) async -> String {
        guard !busy, !pluginBusy else { return "Finish the current task first." }
        let project = normalizedCWD(cwd)
        let health = ConnectionHealthStore.shared
        let probeIdentity = health.beginProbe(name: BrowserIntegration.serverName, project: project)
        pluginBusy = true
        defer { pluginBusy = false }
        let result = await MCPBrowserProbe.checkResult()
        health.recordProbe(
            name: BrowserIntegration.serverName,
            project: project,
            verified: result.verified,
            message: result.verified ? "Browser handshake verified." : "Browser handshake failed or is not configured.",
            expectedIdentity: probeIdentity
        )
        return result.message
    }

    public func authorizeConnection(_ name: String, cwd: String) async {
        guard !pluginBusy, !busy, !connecting else { return }
        pluginBusy = true; authorizingServer = name; authorizationCancelled = false
        authorizingProject = normalizedCWD(cwd)
        let authorizationIdentity = ConnectionHealthStore.shared.identity(name:name,project:authorizingProject)
        connectionStatusText = "Opening browser authorization for \(name)… Complete consent in your browser."
        let client = AgentClient(binary: binary, leaderSocket: leaderSocket, owned: owned)
        authorizationClient = client
        defer { client.stop(); pluginBusy = false; authorizingServer = nil; authorizationClient = nil }
        do {
            try client.start(model: selectedModel, effort: effort, permission: "default")
            _ = try await client.initialize()
            let folder = authorizingProject
            let id = try await client.openSession(cwd: folder, sessionId: nil, model: selectedModel, effort: effort)
            _ = try await client.authorizeMCP(sessionID: id, serverName: name)
            ConnectionHealthStore.shared.recordAuthorization(name: name, project: folder, success: true, expectedIdentity:authorizationIdentity)
            connectionStatusText = "Authorized \(name). Its tools will reconnect on the next turn."
            agent?.stop(); agent = nil; sessionNeedsLoad = true
            await reloadSkills(cwd: folder)
        } catch {
            if !authorizationCancelled {
                ConnectionHealthStore.shared.recordAuthorization(name: name, project: authorizingProject, success: false, expectedIdentity:authorizationIdentity)
                connectionStatusText = "Authorization failed for \(name): " + error.localizedDescription
            }
        }
    }

    public func cancelAuthorization() {
        authorizationCancelled = true
        authorizationClient?.stop()
        if let authorizingServer { ConnectionHealthStore.shared.recordAuthorization(name: authorizingServer, project: authorizingProject, success: false) }
        connectionStatusText = "Authorization cancelled."
    }

    public func cuaDriverBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cua-driver").path
        if FileManager.default.isExecutableFile(atPath: home) { return home }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/cua-driver") { return "/usr/local/bin/cua-driver" }
        return nil
    }

    public var computerUseEnabled: Bool {
        mcpItems.contains { $0.name == "cua-driver" && $0.enabled }
    }

    public func setComputerUse(_ enabled: Bool) async -> String? {
        if enabled {
            guard let binary = cuaDriverBinary() else {
                return "Cua Driver is not installed."
            }
            if !mcpItems.contains(where: { $0.name == "cua-driver" }) {
                let added = await cli(["mcp", "add", "--scope", "user", "cua-driver", "--", binary, "mcp"])
                guard added?.status == 0 else {
                    let detail = added?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return detail?.isEmpty == false ? detail : "Could not register Cua Driver."
                }
            }
            let turnedOn = await cli(["mcp", "enable", "cua-driver"])
            guard turnedOn?.status == 0 else { return "Could not enable Cua Driver." }
        } else if mcpItems.contains(where: { $0.name == "cua-driver" }) {
            let turnedOff = await cli(["mcp", "disable", "cua-driver"])
            guard turnedOff?.status == 0 else { return "Could not turn off Cua Driver." }
        }
        agent?.stop()
        agent = nil
        sessionNeedsLoad = true
        await reloadSkills(cwd: skillDirectory)
        return nil
    }

    public func manageConnection(_ name:String, enabled:Bool) async {
        guard !pluginBusy, !busy else { return };pluginBusy=true
        defer { pluginBusy=false }
        let project = normalizedCWD(skillDirectory)
        let result=await cli(["--cwd",project,"mcp",enabled ? "enable":"disable",name])
        guard result?.status==0 else { connectionStatusText="Connection update failed: " + (result?.stderr ?? "Grok unavailable");return }
        ConnectionHealthStore.shared.invalidate(name: name, project: project)
        if enabled {
            let identity = ConnectionHealthStore.shared.beginProbe(name:name,project:project)
            let checked=await cli(["--cwd",project,"mcp","doctor",name,"--json"])
            let result = doctorConnectionResult(checked?.stdout ?? "",server:name)
            let message = result.message
            ConnectionHealthStore.shared.recordProbe(name: name, project: project, verified: result.verified, message: message, expectedIdentity:identity)
            connectionStatusText = message
        } else { connectionStatusText="Disconnected " + name }
        await reloadSkills(cwd:skillDirectory)
        agent?.stop();agent=nil;sessionNeedsLoad=true
    }

    public func checkPluginConnections(_ name:String) async {
        guard !pluginBusy, !busy else { return };pluginBusy=true
        defer { pluginBusy=false }
        let servers=mcpItems.filter { $0.pluginName == name }
        if servers.isEmpty { connectionStatusText="This plugin has no MCP connection to authorize; its skills are available when enabled.";return }
        var messages:[String]=[]
        let project = normalizedCWD(skillDirectory)
        for server in servers {
            let identity = ConnectionHealthStore.shared.beginProbe(name:server.name,project:project)
            let result = await cli(["--cwd",project,"mcp","doctor",server.name,"--json"])
            let evidence = doctorConnectionResult(result?.stdout ?? "",server:server.name)
            let message = evidence.message
            ConnectionHealthStore.shared.recordProbe(name: server.name, project: project, verified: evidence.verified, message: message, expectedIdentity:identity)
            messages.append(server.name + ": " + message)
        }
        connectionStatusText=messages.joined(separator:"\n")
    }

    public func loadMarketplace() async {
        guard !marketplaceLoading else { return }
        marketplaceLoading = true; marketplaceError = nil
        defer { marketplaceLoading = false }
        var loaded: [MarketplacePlugin] = [], errors: [String] = []
        do {
            let data = try await PluginCatalog.data(URL(string: "https://raw.githubusercontent.com/xai-org/plugin-marketplace/main/.grok-plugin/marketplace.json")!)
            loaded += try PluginCatalog.xai(data)
        } catch { errors.append("xAI catalog unavailable") }
        do {
            let data = try await PluginCatalog.data(URL(string: "https://cursor.com/marketplace")!)
            loaded += try PluginCatalog.cursor(String(decoding: data, as: UTF8.self))
        } catch { errors.append("Cursor catalog unavailable") }
        let cursor = loaded.filter { $0.marketplace == "Cursor" }
        for index in loaded.indices where loaded[index].logoURL == nil {
            loaded[index].logoURL = cursor.first(where: { $0.name == loaded[index].name })?.logoURL
        }
        if !loaded.isEmpty { marketplacePlugins = loaded }
        marketplaceError = errors.isEmpty ? nil : errors.joined(separator: ". ") + ". Try Refresh."
    }
    public func installPlugin(_ plugin: MarketplacePlugin) async {
        guard installingPlugin == nil, !busy else { return }
        installingPlugin = plugin.id; pluginActionMessage = ""
        defer { installingPlugin = nil }
        let result = await cli(["plugin", "install", plugin.installSource, "--trust"])
        if result?.status == 0 {
            await reloadSkills(cwd: skillDirectory)
            agent?.stop(); agent = nil; sessionNeedsLoad = true
            if let installed = installedPlugin(plugin) {
                pluginActionMessage = "Installed \(plugin.title) as \(installed.name). Open Manage to configure its tools."
            } else { pluginActionMessage = "Grok reported installation completed, but discovery has not found the package. Refresh to verify." }
        } else { pluginActionMessage = "Install failed: " + (result?.stderr ?? "Grok CLI unavailable") }
    }

    public func logout() async {
        runtimeRegistry.stopAll()
        stopOwned(owned)
        newChat()
        let result = await cli(["logout"])
        if result?.status == 0 { subscriptionAuthVerified = false; loadLocal() }
        else { chatError = "Sign out failed. Your existing login was not confirmed cleared." }
    }

    public func connect() async {
        await connect(runtime: selectedRuntime, model: selectedModel, effort: effort)
        if !selectedRuntime.busy && !selectedRuntime.queuePaused && !selectedRuntime.queue.isEmpty {
            await drainQueue(for: selectedRuntime)
        }
    }

    private func connect(runtime: SessionRuntime, model: String, effort: String) async {
        guard !runtime.connecting, runtime.agent == nil else { return }
        runtime.connecting = true
        let epoch = UUID(); runtime.connectionEpoch = epoch
        runtime.connectionStatus = "Connecting…"
        runtime.chatError = nil
        publish(runtime)
        defer {
            if runtime.connectionEpoch == epoch { runtime.connecting = false; publish(runtime) }
        }
        let client = AgentClient(binary: binary, leaderSocket: leaderSocket, owned: owned)
        client.onUpdateEnvelope = { [weak self, weak runtime] envelope in
            Task { @MainActor in
                guard let self, let runtime, runtime.connectionEpoch == epoch,
                      let update = envelope.update,
                      let event = AgentActivityEvent.update(from: envelope) else { return }
                if runtime.sessionID == nil { runtime.adopt(providerSessionID: envelope.sessionID, cwd: runtime.cwd) }
                guard runtime.sessionID == envelope.sessionID else {
                    self.runtimeRegistry.observe(event, from: runtime)
                    self.publish(runtime)
                    return
                }
                runtime.appendActivity(event)
                self.runtimeRegistry.observe(event, from: runtime)
                if !runtime.loadingSession && !(runtime.busy && update["sessionUpdate"] as? String == "user_message_chunk") {
                    runtime.blocks = applyChatUpdate(runtime.blocks, update: update)
                }
                if let meter = contextMeter(from: update) { runtime.contextLabel = meter.label }
                self.publish(runtime)
            }
        }
        client.onPermissionEnvelope = { [weak self, weak runtime] envelope in
            Task { @MainActor in
                guard let self, let runtime, runtime.connectionEpoch == epoch else { return }
                if runtime.sessionID == nil { runtime.adopt(providerSessionID: envelope.sessionID, cwd: runtime.cwd) }
                self.runtimeRegistry.observe(envelope, from: runtime)
                self.publish(runtime)
            }
        }
        client.onProtocolIssue = { [weak self, weak runtime] issue in
            Task { @MainActor in
                guard let self, let runtime, runtime.connectionEpoch == epoch else { return }
                runtime.chatError = issue
                if runtime.state == .working { runtime.state = .failed }
                self.publish(runtime)
            }
        }
        do {
            let permission = runtime.permissionMode.cliValue
            try client.start(model: model, effort: effort, permission: permission)
            runtime.agent = client
            let next = try await client.initialize()
            guard runtime.connectionEpoch == epoch else { client.stop(); return }
            runtime.capabilities = next
            runtime.support = next.runtimeSupport
            runtime.sessionNeedsLoad = true
            runtime.connectionStatus = "Connected to Grok Build"
            publish(runtime)
        } catch {
            client.stop()
            guard runtime.connectionEpoch == epoch else { return }
            runtime.agent = nil
            runtime.chatError = error.localizedDescription
            runtime.connectionStatus = "Connection failed"
            runtime.state = .failed
            publish(runtime)
        }
    }

    @discardableResult
    public func send(text: String, cwd: String, resume: String?, attachments: [URL] = [], skills: [SkillRecord] = []) async -> Bool {
        let requestedFolder = normalizedCWD(cwd)
        let runtime = resume.map { runtimeRegistry.runtime(for: $0, cwd: requestedFolder) } ?? selectedRuntime
        if runtime.cwd.isEmpty { runtime.cwd = requestedFolder }
        if runtime.sessionID != nil, !runtime.cwd.isEmpty, runtime.cwd != requestedFolder {
            runtime.chatError = "This session is bound to its original workspace: \(runtime.cwd)"
            publish(runtime)
            return false
        }
        let folder = runtime.cwd.isEmpty ? requestedFolder : runtime.cwd
        guard (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty),
              !pluginBusy, !selectedModel.isEmpty else {
            if selectedModel.isEmpty { runtime.chatError = "No model is available yet. Refresh models or check your Grok login." }
            else if pluginBusy { runtime.chatError = "Finish the connector action before sending this message." }
            publish(runtime)
            return false
        }
        guard subscriptionAuthVerified else {
            runtime.chatError = "Grok subscription login has not been verified. Sign in with grok login, then refresh the model list. API-key fallback is disabled."
            publish(runtime)
            return false
        }
        var selectedSkills: [SkillRecord]?
        if !skills.isEmpty, !runtime.busy, !runtime.connecting, !runtime.queueDrainActive {
            await reloadSkills(cwd: folder)
            guard skillDirectory == folder,
                  skills.allSatisfy({ selected in skillItems.contains(where: { $0.id == selected.id }) }) else {
                runtime.chatError = "A selected skill is no longer available in this project. Select it again."
                publish(runtime)
                return false
            }
            selectedSkills = skills.compactMap { selected in skillItems.first(where: { $0.id == selected.id }) }
        }
        let permission = PermissionMode(rawValue: permissionMode) ?? .ask
        let prompt = QueuedPrompt(
            sessionID: runtime.sessionID ?? runtime.id,
            cwd: folder,
            text: text,
            attachmentPaths: attachments.map { $0.standardizedFileURL.path },
            skillIDs: skills.map(\.id),
            modelID: selectedModel,
            effort: effort,
            permissionMode: permission
        )
        runtime.lastRequest = prompt
        if runtime.busy || runtime.connecting || runtime.queueDrainActive || runtime.queuePaused || !runtime.queue.isEmpty {
            runtime.enqueue(prompt)
            self.publish(runtime)
            return true
        }
        if let selectedSkills { immediateSkillSnapshots[prompt.id] = selectedSkills }
        let success = await dispatch(prompt, to: runtime)
        if success { await drainQueue(for: runtime) }
        return success
    }

    private func dispatch(_ prompt: QueuedPrompt, to runtime: SessionRuntime) async -> Bool {
        guard !runtime.busy else { return false }
        guard subscriptionAuthVerified else {
            runtime.chatError = "Grok subscription login has not been verified. Sign in with grok login, then refresh the model list. API-key fallback is disabled."
            runtime.state = .failed
            publish(runtime)
            return false
        }
        let folder = normalizedCWD(prompt.cwd)
        let attachments = prompt.attachments
        let epoch = UUID()
        runtime.turnEpoch = epoch
        runtime.lastRequest = prompt
        runtime.busy = true; runtime.state = .working; runtime.chatError = nil
        runtime.permission = nil
        let desiredMode = prompt.permissionMode
        if runtime.agent != nil && runtime.permissionMode != desiredMode {
            runtime.agent?.stop(); runtime.agent = nil; runtime.sessionNeedsLoad = true
        }
        runtime.permissionMode = desiredMode
        publish(runtime)
        defer {
            if runtime.turnEpoch == epoch {
                runtime.busy = false
                if runtime.state == .working { runtime.state = .idle }
                publish(runtime)
            }
        }
        do {
            guard prompt.modelID.isEmpty == false else { throw AgentClient.failure("No model is available yet.") }
            let skills: [SkillRecord]
            if let snapshot = immediateSkillSnapshots.removeValue(forKey: prompt.id) { skills = snapshot }
            else { skills = try await resolveSkills(prompt.skillIDs, cwd: folder) }
            var effectiveText = prompt.text
            if !skills.isEmpty { effectiveText = try selectedSkillPrompt(prompt.text, skills: skills) }
            let trimmed = effectiveText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard runtime.turnEpoch == epoch else { return false }
            if runtime.agent == nil { await connect(runtime: runtime, model: prompt.modelID, effort: prompt.effort) }
            guard let client = runtime.agent, runtime.turnEpoch == epoch else {
                throw AgentClient.failure(runtime.chatError ?? "Grok could not connect.")
            }
            _ = try promptParts(text: trimmed, attachments: attachments, capabilities: runtime.capabilities)
            if runtime.sessionNeedsLoad || runtime.sessionID == nil || runtime.cwd != folder {
                runtime.loadingSession = true
                defer { runtime.loadingSession = false }
                let existing = runtime.sessionID
                let opened = try await client.openSessionResult(cwd: folder, sessionId: existing, model: prompt.modelID, effort: prompt.effort)
                guard runtime.turnEpoch == epoch else { return false }
                runtime.adopt(providerSessionID: opened.sessionID, cwd: folder)
                runtime.support = RuntimeSupport(
                    commands: runtime.support.commands.union(opened.support.commands),
                    configurationIDs: runtime.support.configurationIDs.union(opened.support.configurationIDs),
                    permissionModes: runtime.support.permissionModes.union(opened.support.permissionModes)
                )
                runtime.sessionNeedsLoad = false
            }
            guard let sessionID = runtime.sessionID else { throw AgentClient.failure("The agent did not return a session ID.") }
            try await client.configure(sessionId: sessionID, model: prompt.modelID, effort: prompt.effort)
            guard runtime.turnEpoch == epoch else { return false }
            let display = prompt.text
                + (skills.isEmpty ? "" : "\nSkills requested: " + skills.map { "/" + $0.commandName }.joined(separator: ", "))
                + (attachments.isEmpty ? "" : "\n" + attachments.map(\.lastPathComponent).joined(separator: ", "))
            runtime.blocks.append(ChatBlock(id: UUID().uuidString, kind: "user", text: display))
            publish(runtime)
            try await client.prompt(sessionId: sessionID, text: trimmed, attachments: attachments, capabilities: runtime.capabilities)
            guard runtime.turnEpoch == epoch else { return false }
            runtime.state = .completed
            runtime.chatError = nil
            sessions = loadSessions(root: sessionsRoot)
            publish(runtime)
            return true
        } catch {
            guard runtime.turnEpoch == epoch else { return false }
            runtime.chatError = error.localizedDescription
            runtime.agent?.stop(); runtime.agent = nil; runtime.sessionNeedsLoad = true
            runtime.connectionStatus = "Reconnect needed"
            runtime.state = .failed
            if !runtime.queue.isEmpty { runtime.queuePaused = true; runtime.queuePauseReason = "A queued prompt failed. Review it, then resume the queue." }
            publish(runtime)
            return false
        }
    }

    private func drainQueue(for runtime: SessionRuntime) async {
        guard !runtime.queueDrainActive, !runtime.queuePaused else { return }
        runtime.queueDrainActive = true
        defer { runtime.queueDrainActive = false; publish(runtime) }
        while !runtime.queuePaused, !runtime.busy, let prompt = runtime.queue.first {
            if prompt.requiresReview {
                runtime.queuePaused = true
                runtime.queuePauseReason = "Review queued prompts before sending."
                break
            }
            do { try validateAttachments(prompt.attachments) }
            catch {
                runtime.chatError = error.localizedDescription
                runtime.queuePaused = true
                runtime.queuePauseReason = "A queued attachment is unavailable. Edit or remove that prompt before resuming."
                runtime.state = .failed
                publish(runtime)
                break
            }
            runtime.activeQueuedPromptID = prompt.id
            publish(runtime)
            let success = await dispatch(prompt, to: runtime)
            runtime.activeQueuedPromptID = nil
            if !success {
                runtime.queuePaused = true
                if runtime.queuePauseReason == nil { runtime.queuePauseReason = "A queued prompt failed. Review it, then resume the queue." }
                break
            }
            if let index = runtime.queue.firstIndex(where: { $0.id == prompt.id }) {
                runtime.queue.remove(at: index)
                runtime.persistQueue()
            }
            publish(runtime)
        }
    }

    private nonisolated func resolveSkills(_ ids: [String], cwd: String) async throws -> [SkillRecord] {
        guard !ids.isEmpty else { return [] }
        let result = try await runner.run(grokArguments(leaderSocket: leaderSocket, user: ["--cwd", cwd, "inspect", "--json"]))
        guard result.status == 0, let data = result.stdout.data(using: .utf8) else {
            throw AgentClient.failure("Could not revalidate selected skills in their original workspace.")
        }
        let available = parseInspectCatalog(data).skills
        let chosen = ids.compactMap { id in available.first(where: { $0.id == id }) }
        guard chosen.count == ids.count else {
            throw AgentClient.failure("A selected skill is no longer available in this project. Edit the queued prompt or remove the missing skill.")
        }
        return chosen
    }

    private func validateAttachments(_ attachments: [URL]) throws {
        for url in attachments {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw AgentClient.failure("Queued attachment is missing or is not a regular file: \(url.lastPathComponent)") }
        }
    }

    private func normalizedCWD(_ cwd: String) -> String {
        cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    private func select(_ runtime: SessionRuntime) {
        selectedRuntime = runtime
        project(runtime)
    }

    private func publish(_ runtime: SessionRuntime) {
        runtimeSummaries = runtimeRegistry.summaries
        if selectedRuntime === runtime { project(runtime) }
    }

    private func project(_ runtime: SessionRuntime) {
        blocks = runtime.blocks
        busy = runtime.busy
        connecting = runtime.connecting
        chatError = runtime.chatError
        permissionTitle = runtime.permission?.title
        permissionChoices = runtime.permission?.choices ?? []
        queuedPrompts = runtime.queue
        connectionStatus = runtime.connectionStatus
        capabilities = runtime.capabilities
        contextLabel = runtime.contextLabel
        permissionMode = runtime.permissionMode.rawValue
    }

    public func retry() async {
        let runtime = selectedRuntime
        guard let request = runtime.lastRequest,
              !runtime.busy, !runtime.connecting, !runtime.queueDrainActive else { return }
        if let index = runtime.queue.firstIndex(where: { $0.id == request.id }) {
            guard index == 0 else { return }
            guard !runtime.queue[index].requiresReview else {
                runtime.queuePaused = true
                runtime.queuePauseReason = "Review queued prompts before retrying."
                runtime.chatError = runtime.queuePauseReason
                publish(runtime)
                return
            }
            runtime.queuePaused = false
            runtime.queuePauseReason = nil
            await drainQueue(for: runtime)
            return
        }

        let success = await dispatch(request, to: runtime)
        if success, !runtime.queuePaused { await drainQueue(for: runtime) }
    }

    public func respondPermission(_ option: String?) {
        guard let permission = selectedRuntime.permission,
              permission.sessionID == selectedRuntime.sessionID else { return }
        guard let client = selectedRuntime.agent else {
            selectedRuntime.chatError = "This permission belongs to an observed child session. Continue it in the official Grok task surface."
            publish(selectedRuntime)
            return
        }
        client.respond(requestID: permission.requestID, optionID: option)
        selectedRuntime.permission = nil
        if selectedRuntime.state == .needsInput { selectedRuntime.state = .working }
        publish(selectedRuntime)
    }

    public func allowPermission() { respondPermission(permissionChoices.first(where: { $0.kind == "allow_once" })?.id) }

    /// Cancels only the selected runtime. Its queued prompts remain stored.
    public func cancel() {
        let runtime = selectedRuntime
        if let sessionID = runtime.sessionID { runtime.agent?.cancel(sessionId: sessionID) }
        if let permission = runtime.permission { runtime.agent?.respond(requestID: permission.requestID, optionID: nil) }
        runtime.permission = nil
        runtime.agent?.stop(); runtime.agent = nil
        runtime.sessionNeedsLoad = true
        runtime.connectionEpoch = UUID(); runtime.turnEpoch = UUID()
        runtime.busy = false; runtime.connecting = false
        runtime.state = .cancelled
        if !runtime.queue.isEmpty { runtime.queuePaused = true; runtime.queuePauseReason = "The active turn was cancelled. Queued prompts are retained; resume them when ready." }
        runtime.connectionStatus = "Stopped"; runtime.chatError = "Turn cancelled. Your draft is preserved."
        publish(runtime)
    }

    public func selectSession(_ session: DeskSession) {
        let runtime = runtimeRegistry.runtime(for: session.id, cwd: normalizedCWD(session.cwd))
        if runtime.blocks.isEmpty { runtime.blocks = sessionHistory(root: sessionsRoot, sessionID: session.id) }
        if runtime.cwd.isEmpty { runtime.cwd = session.cwd }
        if normalizedCWD(session.cwd) != normalizedCWD(runtime.cwd) {
            runtime.chatError = "This session belongs to its original workspace: \(runtime.cwd)"
        }
        runtime.sessionNeedsLoad = runtime.agent == nil
        select(runtime)
    }

    public func selectSession(sessionID: String, cwd: String) {
        let runtime = runtimeRegistry.runtime(for: sessionID, cwd: normalizedCWD(cwd))
        if runtime.blocks.isEmpty { runtime.blocks = sessionHistory(root: sessionsRoot, sessionID: sessionID) }
        if runtime.cwd.isEmpty { runtime.cwd = cwd }
        if normalizedCWD(cwd) != normalizedCWD(runtime.cwd) {
            runtime.chatError = "This session belongs to its original workspace: \(runtime.cwd)"
        }
        runtime.sessionNeedsLoad = runtime.agent == nil
        select(runtime)
    }

    @discardableResult
    public func chooseRuntime(id: String) -> Bool {
        guard let runtime = runtimeRegistry.runtime(id: id) else { return false }
        select(runtime)
        return true
    }

    /// Stop only the selected ACP process before opening the provider TUI.
    /// The canonical session ID, transcript and queue remain available.
    public func prepareTerminalHandoff() -> Bool {
        let runtime = selectedRuntime
        guard !runtime.busy, !runtime.connecting else { return false }
        runtime.connectionEpoch = UUID()
        runtime.agent?.stop(); runtime.agent = nil
        runtime.sessionNeedsLoad = true
        runtime.connectionStatus = "Ready to continue in the Grok terminal"
        publish(runtime)
        return true
    }

    public func newChat(cwd: String = "") {
        let runtime = runtimeRegistry.newDraft(cwd: cwd.isEmpty ? "" : normalizedCWD(cwd))
        runtime.permissionMode = PermissionMode(rawValue: permissionMode) ?? .ask
        select(runtime)
    }

    /// Kept as the legacy New Chat entry point; selection never stops other sessions.
    public func resetChat() { newChat() }

    public func editQueuedPrompt(_ edited: QueuedPrompt) {
        guard selectedRuntime.activeQueuedPromptID != edited.id else { return }
        guard let index = selectedRuntime.queue.firstIndex(where: { $0.id == edited.id }) else { return }
        var safeEdit = edited
        safeEdit.sessionID = selectedRuntime.queue[index].sessionID
        safeEdit.cwd = selectedRuntime.queue[index].cwd
        safeEdit.createdAt = selectedRuntime.queue[index].createdAt
        safeEdit.requiresReview = selectedRuntime.queue[index].requiresReview
        selectedRuntime.queue[index] = safeEdit
        selectedRuntime.persistQueue()
        publish(selectedRuntime)
    }

    public func reorderQueuedPrompts(_ orderedIDs: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: selectedRuntime.queue.map { ($0.id, $0) })
        guard orderedIDs.count == selectedRuntime.queue.count,
              Set(orderedIDs) == Set(byID.keys) else { return }
        if let active = selectedRuntime.activeQueuedPromptID, orderedIDs.first != active { return }
        selectedRuntime.replaceQueue(orderedIDs.compactMap { byID[$0] })
        publish(selectedRuntime)
    }

    public func removeQueuedPrompt(id: UUID) {
        guard selectedRuntime.activeQueuedPromptID != id else { return }
        selectedRuntime.removeQueuedPrompt(id: id)
        publish(selectedRuntime)
    }

    public func reviewQueuedPrompts() {
        let reviewed = selectedRuntime.queue.map { prompt -> QueuedPrompt in
            var prompt = prompt; prompt.requiresReview = false; return prompt
        }
        selectedRuntime.replaceQueue(reviewed)
        selectedRuntime.queuePauseReason = nil
        selectedRuntime.queuePaused = false
        publish(selectedRuntime)
    }

    public func resumeQueue() async {
        guard !selectedRuntime.busy, !selectedRuntime.connecting else { return }
        guard !selectedRuntime.queue.contains(where: \.requiresReview) else {
            selectedRuntime.queuePaused = true
            selectedRuntime.queuePauseReason = "Review queued prompts before sending."
            selectedRuntime.chatError = selectedRuntime.queuePauseReason
            publish(selectedRuntime)
            return
        }
        selectedRuntime.queuePaused = false
        selectedRuntime.queuePauseReason = nil
        await drainQueue(for: selectedRuntime)
    }

    public func reconnect() async {
        guard !selectedRuntime.busy else { return }
        selectedRuntime.agent?.stop(); selectedRuntime.agent = nil; selectedRuntime.sessionNeedsLoad = true
        await connect(runtime: selectedRuntime, model: selectedModel, effort: effort)
    }

    public func shutdown() {
        runtimeRegistry.stopAll()
        stopOwned(owned)
        publish(selectedRuntime)
    }

    /// A sibling shares the CLI/configuration/account context and uses isolated
    /// ACP runtimes/process ownership. Studio can never switch or stop Build chat.
    public func makeSibling() -> DeskModel {
        let studioQueueRoot = PromptQueueStore.defaultRoot().appendingPathComponent("Studio", isDirectory: true)
        let sibling = DeskModel(runner: runner, leaderSocket: leaderSocket, sessionsRoot: sessionsRoot, owned: OwnedProcesses(), binary: binary, queueStore: PromptQueueStore(root: studioQueueRoot))
        sibling.sessions = sessions
        sibling.models = models
        sibling.modelsStale = modelsStale
        sibling.subscriptionAuthVerified = subscriptionAuthVerified
        sibling.account = account
        sibling.configText = configText
        sibling.selectedModel = selectedModel
        sibling.effort = effort
        sibling.permissionMode = permissionMode
        sibling.allowSubagents = allowSubagents
        return sibling
    }

    public func runStudio(board: StudioBoard, outputFolder: URL, cwd: String = "") async -> (success: Bool, message: String) {
        let sibling = makeSibling()
        defer { sibling.shutdown() }
        do { try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true) }
        catch { return (false, error.localizedDescription) }
        let started = Date().addingTimeInterval(-2)
        let success = await sibling.send(
            text: imagineCommand(board: board, outputFolder: outputFolder),
            cwd: cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : cwd,
            resume: nil
        )
        let inputs = Set(([board.startPath, board.endPath].compactMap { $0 } + board.references).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let reported = sibling.blocks.filter { $0.kind == "assistant" || $0.kind == "tool" }.map(\.text).joined(separator: "\n")
        let session = sibling.activeSessionID.flatMap { sessionDirectory(root: sessionsRoot, id: $0) }
        var outputs = studioMediaURLs(in: reported, session: session)
        if let session { outputs += studioMedia(createdUnder: session, since: started) }
        _ = StudioLibrary(root: outputFolder).adopt(outputs, excluding: inputs)
        return (success, sibling.chatError ?? sibling.blocks.filter { $0.kind == "assistant" }.map(\.text).joined(separator: "\n"))
    }

    public func createWorktree(name: String) async {
        _ = await cli(["worktree", "create", name])
        await reloadSkills()
    }

    private nonisolated func cli(_ args: [String]) async -> CommandResult? {
        try? await runner.run(grokArguments(leaderSocket: leaderSocket, user: args))
    }
}
