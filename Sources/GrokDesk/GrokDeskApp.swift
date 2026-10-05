import AppKit
import GrokDeskCore
import SwiftUI
import UserNotifications

enum DeskWorkspace: String, CaseIterable {
    case build = "Chats", cinema = "Cinema Studio", library = "Library", agents = "Agents", routines = "Routines"
    var icon: String {
        switch self { case .build: "bubble.left.and.bubble.right"; case .cinema: "film"; case .library: "square.grid.2x2"; case .agents: "person.2.wave.2"; case .routines: "clock.arrow.circlepath" }
    }
}

enum DeskSheet: String, Identifiable {
    case settings, skills, imagine
    var id: String { rawValue }
}

struct GrokDeskApp: App {
    @StateObject private var model: DeskModel

    init() {
        let owned = OwnedProcesses()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socket = home
            .appendingPathComponent("Library/Application Support/Grok Desk/leader.sock")
            .path
        let binary = resolveGrokBinary(home: home)
        _model = StateObject(wrappedValue: DeskModel(
            runner: LiveRunner(binary: binary, owned: owned),
            leaderSocket: socket,
            sessionsRoot: GrokPaths.home().appendingPathComponent("sessions"),
            owned: owned,
            binary: binary
        ))
    }

    var body: some Scene {
        Window("Grok Desk", id: "main") {
            DeskView(model: model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}

private struct ComposerDraft {
    var text: String
    var attachments: [URL]
    var skills: [SkillRecord]
}

private struct ProjectGroup: Identifiable {
    var cwd: String
    var name: String
    var sessions: [DeskSession]
    var id: String { cwd }
}

private let starters = [
    "Explore and understand code",
    "Build a new feature",
    "Review recent work",
    "Fix what is failing",
]

struct DeskView: View {
    @ObservedObject var model: DeskModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("interfaceMotion") private var interfaceMotion = true
    @FocusState private var sheetHasFocus: Bool
    @Namespace private var navigationHighlight
    @State private var glassSceneSize = CGSize(width: 1280, height: 800)
    @State private var refreshTask: Task<Void, Never>?
    @State private var query = ""
    @State private var draft = ""
    @State private var drafts: [String:ComposerDraft] = [:]
    @State private var selectedSkills: [SkillRecord] = []
    @State private var contextTab="Files"
    @State private var contextSearch=""
    @State private var selectedID: String?
    @State private var collapsed: Set<String> = []
    @State private var showAll: Set<String> = []
    @State private var accountOpen = false
    @State private var sheet: DeskSheet?
    @State private var settingsSection = "General"
    @State private var skillsTab = "MCP"
    @State private var imaginePrompt = ""
    @State private var worktreeName = ""
    @State private var attachments: [URL] = []
    @State private var recentAttachments: [URL] = []
    @StateObject private var repository = RepositoryModel()
    @StateObject private var browserBook = TabbedPages()
    @AppStorage("browserPlacement") private var browserPlacement = "Side"
    @State private var browserOpen = false
    @State private var browserTabs = [ChatBrowserTab()]
    @State private var browserActive = ""
    @State private var browserSession = "draft"
    @State private var composerError: String?
    @StateObject private var studio = StudioModel()
    @StateObject private var studioAgent: DeskModel
    @State private var queueOpen = false
    init(model: DeskModel) {
        self.model = model
        _studioAgent = StateObject(wrappedValue: model.makeSibling())
    }
    @State private var workspace: DeskWorkspace = .build
    @AppStorage("selectedWorkspace") private var projectFolder = ""
    @State private var projects: [DeskProject] = []
    @State private var projectError: String?
    @State private var projectEditor = false
    @State private var worktreeEditor = false
    @State private var draftCWD: String?
    @State private var editingProjectName = ""
    @State private var editingProjectPath = ""
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("projectSort") private var projectSort = "Recent"
    @State private var sidebarInitialized = false
    @FocusState private var searchFocused: Bool
    @AppStorage("showSuggestedPrompts") private var showSuggestedPrompts = true
    @AppStorage("notifyWhenBackground") private var notifyWhenBackground = false

    private func projectName(_ cwd: String) -> String {
        projects.first(where: { $0.cwd == cwd })?.name ?? fallbackProjectName(cwd)
    }

    private var groups: [ProjectGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = model.sessions.filter { session in
            needle.isEmpty
                || session.title.lowercased().contains(needle)
                || projectName(workspaceRoot(session.cwd, registered: projects.map(\.cwd))).lowercased().contains(needle)
        }
        var grouped = Dictionary(grouping: matched) { workspaceRoot($0.cwd, registered: projects.map(\.cwd)) }
        for project in projects where needle.isEmpty || project.name.localizedCaseInsensitiveContains(needle) {
            let root = workspaceRoot(project.cwd, registered: projects.map(\.cwd))
            if grouped[root] == nil { grouped[root] = [] }
        }
        return grouped.map { cwd, sessions in
            ProjectGroup(
                cwd: cwd,
                name: projectName(cwd),
                sessions: sessions.sorted { $0.updatedAt > $1.updatedAt }
            )
        }
        .sorted { lhs, rhs in
            if projectSort == "Name" { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            let left = lhs.sessions.first?.updatedAt ?? projects.first(where: { $0.cwd == lhs.cwd })?.addedAt ?? ""
            let right = rhs.sessions.first?.updatedAt ?? projects.first(where: { $0.cwd == rhs.cwd })?.addedAt ?? ""
            return left == right ? lhs.name < rhs.name : left > right
        }
    }

    private var selected: DeskSession? {
        model.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                sidebar
                if workspace == .build { stage }
                else if workspace == .agents {
                    AgentDashboard(model: model, studio: studioAgent, open: { id, cwd, media in
                        if media {
                            if studio.generating && studioAgent.activeSessionID != id { studio.error="The Studio agent is working. Stop its active turn before opening a different Studio session.";workspace = .cinema;return }
                            studioAgent.selectSession(sessionID:id,cwd:cwd);studio.session.sessionID=id;studio.session.cwd=cwd;studio.session.mode = .agent;workspace = .cinema}
                        else {selectChat(id:id,cwd:cwd)}
                    }, official: { command in openGrokTerminal(command:command,title:"Grok · " + command,dashboard:command=="dashboard") })
                }
                else if workspace == .routines {
                    RoutinesView(workspace: projectFolder, openSession: { id, cwd in selectChat(id:id,cwd:cwd) })
                }
                else {
                    ImagineStudio(model: studioAgent, studio: studio, libraryOnly: workspace == .library, workspaceFolder: projectFolder, openCustomize: { sheet = .skills }) { url in
                        attachments.append(url); workspace = .build
                    }
                }
            }
            if accountOpen {
                Color.black.opacity(0.001).onTapGesture { accountOpen = false }
                accountMenu.padding(.leading, 12).padding(.bottom, 64)
                    .transition(DeskMotion.reveal(reduced: reduceMotion, enabled: interfaceMotion, anchor: .bottomLeading))
            }
            if let sheet { sheetView(sheet) }
        }
        .background { LiquidField().ignoresSafeArea(.container, edges: .top) }
        .animation(DeskMotion.presentation(reduced: reduceMotion, enabled: interfaceMotion), value: accountOpen)
        .animation(DeskMotion.presentation(reduced: reduceMotion, enabled: interfaceMotion), value: sheet != nil)
        .coordinateSpace(name: "glassScene")
        .environment(\.glassSceneSize, glassSceneSize)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { glassSceneSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in glassSceneSize = size }
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : .light)
        .background(WindowChrome(dark: appearance == "dark"))
        .onAppear {
            model.loadLocal()
            recentAttachments = (UserDefaults.standard.stringArray(forKey:"recentAttachments") ?? []).map { URL(fileURLWithPath:$0) }.filter { FileManager.default.fileExists(atPath:$0.path) }
            studioAgent.loadLocal()
            Task { await studioAgent.refresh(); await studioAgent.reloadSkills(cwd: projectFolder) }
            if let saved = UserDefaults.standard.string(forKey: "grokDesk.permissionMode"), PermissionMode(rawValue: saved) != nil {
                model.permissionMode = saved
            }
            model.planMode = false
            do { projects = try ProjectStore().load() } catch { projectError = error.localizedDescription }
            RoutineScheduler.shared.start()
            startRefreshLoop()
            Task { await model.reloadSkills(cwd: projectFolder); await model.loadMarketplace() }
            if CommandLine.arguments.contains("--open-usage") {
                settingsSection = "Usage"
                sheet = .settings
            }
            if CommandLine.arguments.contains("--open-skills") {
                sheet = .skills
            }
            if CommandLine.arguments.contains("--open-imagine") {
                workspace = .cinema
            }
        }
        .sheet(isPresented: $queueOpen) { PromptQueueView(model:model) }
        .sheet(isPresented: $worktreeEditor) {
            WorktreePicker(repo: repository.snapshot?.root ?? projectFolder) { folder in
                newChat(); draftCWD = folder.path
            }
        }
        .sheet(isPresented: $projectEditor) {
            ProjectEditor(name: editingProjectName, path: editingProjectPath) { name, folder in
                projects = try ProjectStore().add(folder: folder, name: name)
                collapsed.remove(folder.path)
                openProject(folder.path)
            }
        }
        .alert("Project folders", isPresented: Binding(get: { projectError != nil }, set: { if !$0 { projectError = nil } })) {
            Button("OK") { projectError = nil }
        } message: { Text(projectError ?? "") }
        .onExitCommand { sheet = nil; accountOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown(); studioAgent.shutdown(); browserBook.reset() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.loadLocal(); Task { await model.refresh() }
        }
        .background(keyboardActions)
        .onChange(of: projectFolder) { _, folder in
            Task { await model.reloadSkills(cwd: folder) }
        }
        .onChange(of: model.sessions.count) { _, count in
            if count > 0 && !sidebarInitialized {
                collapsed = Set(groups.dropFirst(2).map(\.cwd)); sidebarInitialized = true
            }
        }
        .onDisappear {
            model.shutdown(); browserBook.reset()
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 10)
            HStack(spacing: 8) {
                Text("Grok")
                    .font(.system(size: 23, weight: .semibold)).tracking(-0.8)
                    .foregroundStyle(DeskColor.ink)
                Text("DESKTOP").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(DeskColor.muted)
                Spacer()
                Button { showProjectEditor() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain).foregroundStyle(DeskColor.muted).help("Create project")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            sidebarButton("New chat", systemImage: "square.and.pencil") { newChat() }
                .padding(.bottom, 6)
            ForEach(DeskWorkspace.allCases, id: \.self) { item in
                Button { workspace = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).font(.system(size: 14, weight: .light)).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 12, weight: workspace == item ? .medium : .regular))
                        Spacer()

                    }
                    .foregroundStyle(workspace == item ? DeskColor.ink : DeskColor.muted)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background {
                        if workspace == item {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DeskColor.row)
                                .matchedGeometryEffect(id: "workspace", in: navigationHighlight, properties: reduceMotion || !interfaceMotion ? [] : .frame)
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).deskHover(radius: 9).padding(.horizontal, 10)
                    .animation(DeskMotion.selection(reduced: reduceMotion, enabled: interfaceMotion), value: workspace)
            }
            sidebarButton("Customize", systemImage: "slider.horizontal.3") { sheet = .skills }
                .padding(.top, 2).padding(.bottom, 14)
            searchField

            HStack {
                Text("Projects")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeskColor.muted.opacity(0.85))
                Spacer()
                Menu {
                    ForEach(["Recent", "Name"], id: \.self) { sort in
                        Button { projectSort = sort } label: {
                            if projectSort == sort { Label(sort == "Recent" ? "Recent activity" : "Name", systemImage: "checkmark") }
                            else { Text(sort == "Recent" ? "Recent activity" : "Name") }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(DeskColor.muted).help("Sort projects").accessibilityLabel("Sort projects")
                Button { showProjectEditor() } label: { Image(systemName: "plus").font(.system(size: 13, weight: .light)) }
                    .buttonStyle(.plain).help("Create project").accessibilityLabel("Create project")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text(query.isEmpty ? "No chats yet" : "No matches")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DeskColor.muted)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    ForEach(groups) { group in
                        projectBlock(group)
                    }
                }
                .padding(.bottom, 12)
            }

            footer
        }
        .frame(width: 248)
        .deskGlass(radius: 18)
        .padding(10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(DeskColor.muted)
            TextField("Search  ⌘K", text: $query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DeskColor.ink)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(DeskColor.row, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private func sidebarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .light))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(DeskColor.ink.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).deskHover()
        .padding(.horizontal, 8)
    }

    private func projectBlock(_ group: ProjectGroup) -> some View {
        let isOpen = !collapsed.contains(group.cwd)
        let visible = showAll.contains(group.cwd) ? group.sessions : Array(group.sessions.prefix(6))
        return VStack(alignment: .leading, spacing: 1) {
            ProjectHeaderButton(name: group.name, path: group.cwd, count: group.sessions.count, isOpen: isOpen, selected: projectFolder == group.cwd && selectedID == nil && workspace == .build, enabled: !model.busy,
                action: { openProject(group.cwd) },
                toggle: {
                    withAnimation(reduceMotion || !interfaceMotion ? nil : DeskMotion.selection(reduced: false, enabled: true)) {
                        if isOpen { collapsed.insert(group.cwd) } else { collapsed.remove(group.cwd) }
                    }
                },
                newChat: { openProject(group.cwd) },
                edit: { showProjectEditor(name: group.name, path: group.cwd) })
                .padding(.horizontal, 6)
                .contextMenu {
                    Button("New chat") { openProject(group.cwd) }
                    Button("Edit project") { showProjectEditor(name: group.name, path: group.cwd) }
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.cwd) }
                }

            if isOpen {
                if visible.isEmpty {
                    Button("New chat") { openProject(group.cwd) }.buttonStyle(.plain).font(.system(size: 12))
                        .foregroundStyle(DeskColor.muted).padding(.leading, 40).frame(height: 28).disabled(model.busy)
                }
                ForEach(visible) { session in
                    sessionRow(session)
                }
                if group.sessions.count > 6 && !showAll.contains(group.cwd) {
                    Button("Show \(group.sessions.count - 6) more") {
                        showAll.insert(group.cwd)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(DeskColor.muted)
                    .padding(.leading, 42)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func currentRepositoryContext(for session: DeskSession) -> String? {
        guard let repo = repository.snapshot,
              workspaceRoot(session.cwd, registered: projects.map(\.cwd)) == workspaceRoot(projectFolder, registered: projects.map(\.cwd)) else { return nil }
        return "Current workspace · " + repo.label + " · " + repo.commit + (repo.isWorktree ? " · Worktree" : "")
    }

    private func sessionRow(_ session: DeskSession) -> some View {
        let on = session.id == selectedID
        return SessionRowButton(title: session.title, time: relativeTime(session.updatedAt), selected: on, repositoryContext: session.repositoryContext ?? currentRepositoryContext(for: session)) {
            stashDraft()
            selectedID = session.id
            projectFolder = workspaceRoot(session.cwd, registered: projects.map(\.cwd))
            workspace = .build
            model.selectSession(session)
            restoreDraft()
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .help(session.title)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let title = model.updateTitle {
                Button {
                    Task { await model.installUpdate() }
                } label: {
                    Text(model.updating ? "Updating…" : title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskColor.inkOnBrass)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(DeskColor.brass, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(model.updating)
                if let updateError = model.updateError, !updateError.isEmpty {
                    Text(updateError)
                        .font(.system(size: 11))
                        .foregroundStyle(DeskColor.danger)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button {
                accountOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(DeskColor.row)
                        .frame(width: 23, height: 23)
                        .overlay(Text(model.account.initials).font(.system(size: 11, weight: .semibold)).foregroundStyle(DeskColor.ink))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.account.name)
                            .font(.system(size: 13))
                            .foregroundStyle(DeskColor.ink)
                            .lineLimit(1)

                    }
                    Spacer()
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(DeskColor.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(DeskColor.hairline).frame(height: 1) }
    }

    private var stage: some View {
        GeometryReader { geometry in
            Group {
                if browserOpen {
                    if browserPlacement == "Bottom" || geometry.size.width < 900 {
                        VSplitView { conversation.frame(minHeight: 210); browserPanel.frame(minHeight: 220) }
                    } else {
                        HSplitView { conversation.frame(minWidth: 360); browserPanel.frame(minWidth: 420) }
                    }
                } else { conversation }
            }
        }
        .onAppear { restoreBrowser(for: browserID(selectedID)) }
        .onChange(of: selectedID) { _, id in restoreBrowser(for: browserID(id)) }
        .task(id: selected?.cwd ?? projectFolder) {
            while !Task.isCancelled {
                await repository.refresh(selected?.cwd ?? projectFolder)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    private var browserPanel: some View {
        ChatWebPane(tabs: $browserTabs, activeID: $browserActive, workspacePath: projectFolder,
            skills: model.skillItems, connections: model.mcpItems, onSelectConnection: { connection in
                draft += (draft.isEmpty ? "" : "\n") + "Use the " + connection.name + " MCP connection to "
            }, onSelectSkill: { skill in
                if !selectedSkills.contains(where: { $0.id == skill.id }) { selectedSkills.append(skill) }
            }, onBrowserSettings: { settingsSection = "Browser & panels"; sheet = .settings }, sessionKey: browserSession,
            onClose: { setBrowser(false) }, onChange: { rememberBrowser() }, book: browserBook)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            if model.blocks.isEmpty && selected == nil {
                Spacer(minLength: 0)
                VStack(spacing: 13) {
                    Text("What’s on your mind?")
                        .font(.system(size: 40, weight: .light)).tracking(-1.6)
                        .multilineTextAlignment(.center).foregroundStyle(DeskColor.ink)
                    Text(projectFolder.isEmpty ? "A place to think, build, and explore." : "Working in \(projectName(projectFolder))")
                        .font(.system(size: 13)).foregroundStyle(DeskColor.muted)
                    if showSuggestedPrompts {
                        HStack(spacing: 10) {
                            starterButton("Explore code", detail: "Find your bearings", icon: "magnifyingglass")
                            starterButton("Build a feature", detail: "Bring an idea to life", icon: "hammer")
                            starterButton("Review changes", detail: "A fresh set of eyes", icon: "checkmark.bubble")
                        }.padding(.top, 19)
                    }
                }.padding(.horizontal, 32).frame(maxWidth: 760)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if model.blocks.isEmpty {
                                Text("This conversation has no readable history in the current window. Send a message to resume through Grok Build.")
                                    .font(.system(size: 13)).foregroundStyle(DeskColor.muted).padding(.top, 30)
                            }
                            ForEach(model.blocks) { block in
                                ConversationBlock(block: block)
                            }
                            if model.busy {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Grok is working…").font(.system(size: 12)).foregroundStyle(DeskColor.muted) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                    }
                    .onAppear { reader.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: selectedID) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.blocks.last?.text) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if let permission = model.permissionTitle {
                PermissionRequestCard(title: permission, choices: model.permissionChoices, deny: { model.respondPermission(nil) }, choose: { model.respondPermission($0) })
                    .padding(.horizontal, 26)
                    .padding(.bottom, 8)
            }
            if let chatError = model.chatError {
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(DeskColor.danger)
                    Text(chatError).font(.system(size: 12)).foregroundStyle(DeskColor.danger).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    Button("Retry turn") { Task { await model.retry() } }.buttonStyle(DeskButtonStyle()).disabled(model.busy)
                    Button("Reconnect") { Task { await model.reconnect() } }.buttonStyle(DeskButtonStyle()).disabled(model.busy)
                }.padding(.vertical, 10)
            }
            RepositoryBar(model: repository, cwd: selected?.cwd ?? projectFolder, busy: model.busy).padding(.horizontal, 26).padding(.bottom, 6)
            composer.padding(.horizontal, 26)
            HStack(spacing: 8) {
                ComposerPopover("Workspace",value:projectFolder) {
                    Label(projectFolder.isEmpty ? "Choose workspace" : projectName(workspaceRoot(projectFolder,registered:projects.map(\.cwd))),systemImage:"folder").lineLimit(1)
                } content: {dismiss in
                    VStack(spacing:8) {
                        Button {dismiss();DispatchQueue.main.async{chooseProject()}} label:{Label("Choose or add folders…",systemImage:"folder.badge.plus")}.buttonStyle(DeskMenuRowStyle())
                        Divider()
                        ComposerChoices(choices:groups.map{ComposerChoice(id:$0.cwd,title:$0.name,detail:$0.cwd,symbol:"folder")},selected:projectFolder) {switchWorkspace($0);dismiss()}
                    }.frame(width:280)
                }.disabled(model.busy || model.connecting).help("Choose the workspace for a new chat, or add folders")
                Spacer()
                Text(model.contextLabel.isEmpty ? (model.modelsStale ? "Model list may be stale" : "Grok Build") : model.contextLabel)
            }
            .font(.system(size: 10)).foregroundStyle(DeskColor.muted.opacity(0.8))
            .frame(maxWidth: 736).padding(.horizontal, 38).frame(height: 29)
        }
        .padding(.bottom, 8)
    }

    private func browserID(_ id: String?) -> String { id ?? "draft:" + (projectFolder.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : projectFolder) }

    private func rememberBrowser() {
        let active = browserTabs.first { $0.id == browserActive } ?? browserTabs.first
        ChatBrowserStore.save(browserSession, ChatBrowserState(open: browserOpen, url: active?.url ?? "", tabs: browserTabs, activeTabID: active?.id))
    }

    private func restoreBrowser(for id: String) {
        if id != browserSession { rememberBrowser() }
        let state = ChatBrowserStore.load(id)
        browserSession = id
        browserOpen = state.open
        browserTabs = state.tabs
        browserActive = state.activeTabID
    }

    private func setBrowser(_ open: Bool) {
        browserOpen = open
        rememberBrowser()
    }

    private func starterButton(_ title: String, detail: String, icon: String) -> some View {
        Button { draft = title } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .light)).foregroundStyle(DeskColor.brass)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(DeskColor.ink)
            }.padding(.horizontal, 15).padding(.vertical, 10)
                .background(DeskColor.composer.opacity(0.24), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selected?.title ?? "New chat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DeskColor.ink)
                    .lineLimit(1)
                if let selected {
                    Text(projectName(selected.cwd))
                        .font(.system(size: 11))
                        .foregroundStyle(DeskColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { chooseProject() } label: {
                Label(projectFolder.isEmpty ? "Choose folder" : URL(fileURLWithPath: projectFolder).lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }.buttonStyle(DeskButtonStyle()).disabled(model.busy).help(projectFolder)
            Button(browserOpen ? "Hide browser" : "Browser") { setBrowser(!browserOpen) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(browserOpen ? DeskColor.ink : DeskColor.brass)
            if let selected {
                Button("Open in Terminal") {
                    openInTerminal(selected)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DeskColor.brass)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(DeskColor.hairline).frame(height: 1) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !selectedSkills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(selectedSkills) { skill in
                            HStack(spacing: 6) {
                                PluginLogo(url: model.marketplacePlugins.first { $0.name == skill.pluginName }?.logoURL, size: 22)
                                Text("/" + skill.commandName).font(.system(size: 11, weight: .medium))
                                Button { selectedSkills.removeAll { $0.id == skill.id } } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
                                    .accessibilityLabel("Remove skill " + skill.name)
                            }.padding(6).deskGlass(radius: 14).help("Selected skill · instructions will be included with this request")
                        }
                    }.padding(2)
                }
            }
            if trailingSkillQuery(draft) != nil {
                slashSuggestions
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.path) { url in
                            HStack(spacing: 4) {
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Button { attachments.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(DeskColor.ink)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(DeskColor.row, in: Capsule())
                        }
                    }
                }
            }
            if !model.queuedPrompts.isEmpty { Button { queueOpen=true } label: { Label("\(model.queuedPrompts.count) queued · Review",systemImage:"text.line.first.and.arrowtriangle.forward") }.buttonStyle(QuietButton()) }
            if let composerError { Text(composerError).font(.system(size: 11)).foregroundStyle(DeskColor.danger) }
            ComposerInput(text: $draft, placeholder: "Ask Grok, or / for commands", canSubmit: !model.connecting && !model.pluginBusy && !model.models.isEmpty,
                submit: sendDraft, attach: addAttachments, reportError: { composerError = $0 })
                .padding(.horizontal, 4).padding(.top, 3)
            HStack(spacing: 6) {
                contextControl
                buildControl.disabled(model.busy)
                permissionControl.disabled(model.busy)
                Spacer(minLength: 4)
                modelControl.disabled(model.busy || model.connecting)
                if model.busy { Button { model.cancel() } label: { Image(systemName:"stop.fill").frame(width:24,height:24) }.buttonStyle(QuietButton()).help("Stop active turn") }
                Button { sendDraft() } label: {
                    Image(systemName: model.busy ? "text.line.first.and.arrowtriangle.forward" : "arrow.up")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 29, height: 29)
                        .foregroundStyle(DeskColor.inkOnBrass).background(DeskColor.brass, in: Circle())
                }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.pluginBusy || model.connecting || model.models.isEmpty || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    .help(model.busy ? "Queue follow-up" : "Send · Enter (Shift+Enter for a new line)").accessibilityLabel(model.busy ? "Queue message" : "Send message")
            }
        }
        .padding(12)
        .deskGlass(radius: 20)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var slashSuggestions: some View {
        let query = trailingSkillQuery(draft)?.query.lowercased() ?? ""
        let candidates = model.skillItems.filter { query.isEmpty || $0.commandName.lowercased().contains(query) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Skills for this project").font(.system(size: 10, weight: .medium)).foregroundStyle(DeskColor.muted)
                Spacer()
                Button("Browse plugins") { sheet = .skills }.buttonStyle(QuietButton())
            }
            if candidates.isEmpty { Text(model.extensionsLoading ? "Loading skills…" : "No matching installed skills").font(.system(size: 11)).foregroundStyle(DeskColor.muted) }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(candidates.prefix(12)) { skill in
                        Button {
                            if !selectedSkills.contains(where: { $0.id == skill.id }) { selectedSkills.append(skill) }
                            draft = trailingSkillQuery(draft)?.prefix ?? draft
                        } label: {
                            HStack(spacing: 8) {
                                PluginLogo(url: model.marketplacePlugins.first { $0.name == skill.pluginName }?.logoURL, size: 25)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/" + skill.commandName).font(.system(size: 11, weight: .medium))
                                    Text(skill.detail).font(.system(size: 10)).foregroundStyle(DeskColor.muted).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(DeskColor.muted)
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Select skill " + skill.commandName)
                    }
                }
            }.frame(maxHeight: 160)
        }.padding(10).background(DeskColor.composer.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            await model.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await model.refresh()
            }
        }
    }

    private var accountMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.account.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DeskColor.ink)
                Text(model.account.email.isEmpty ? "Not signed in" : model.account.email)
                    .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            }
            .padding(10)
            menuRow("Usage") { settingsSection = "Usage"; sheet = .settings; accountOpen = false }
            menuRow("Settings") { settingsSection = "General"; sheet = .settings; accountOpen = false }
            menuRow("Skills and Connectors") { sheet = .skills; accountOpen = false }
            Divider().padding(.horizontal, 8).padding(.vertical, 3)
            menuRow(model.account.ok ? "Sign out" : "Sign in") {
                accountOpen = false
                if model.account.ok {
                    Task { await model.logout() }
                } else {
                    openLogin()
                }
            }
        }
        .frame(width: 244)
        .padding(6)
        .deskPopup(elevated: true)
    }

    private func menuRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: title == "Usage" ? "chart.bar" : title == "Settings" ? "gearshape" : title == "Skills and Connectors" ? "puzzlepiece.extension" : "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 11)).frame(width: 16).foregroundStyle(DeskColor.muted)
                Text(title).foregroundStyle(title == "Sign out" ? DeskColor.danger : DeskColor.ink)
            }
        }
        .buttonStyle(DeskMenuRowStyle())
    }

    private func sheetView(_ sheet: DeskSheet) -> some View {
        ZStack {
            Color.black.opacity(appearance == "dark" ? 0.3 : 0.18).ignoresSafeArea().onTapGesture { self.sheet = nil }.transition(.opacity)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(sheet == .settings ? "Settings" : sheet == .skills ? "Customize" : "Imagine")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(DeskColor.ink)
                    Spacer()
                    Button("Close") { self.sheet = nil }.buttonStyle(QuietButton()).focusable().focused($sheetHasFocus)
                }
                if sheet == .settings { settingsBody }
                if sheet == .skills { MarketplaceStudio(model: model, cwd: selected?.cwd ?? projectFolder, openConfiguration: { settingsSection = "Configuration"; self.sheet = .settings }) { skill in
                    if !selectedSkills.contains(where: { $0.id == skill.id }) { selectedSkills.append(skill) }
                    self.sheet = nil; workspace = .build
                } }
                if sheet == .imagine { ImagineStudio(model: studioAgent, studio: studio) }
            }
            .padding(20)
            .frame(width: 780, height: 560)
            .deskPopup(radius: 22, elevated: true)
            .transition(DeskMotion.reveal(reduced: reduceMotion, enabled: interfaceMotion))
            .accessibilityAddTraits(.isModal)
            .onAppear {
                accountOpen = false
                DispatchQueue.main.async { sheetHasFocus = true }
            }
            .onDisappear { sheetHasFocus = false }
        }
    }

    private var settingsBody: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(["General", "Appearance", "Browser & panels", "Agent behavior", "Project rules", "Usage", "Profile", "Configuration"], id: \.self) { section in
                    Button { settingsSection = section } label: {
                        Text(section)
                            .font(.system(size: 13, weight: settingsSection == section ? .semibold : .regular))
                            .foregroundStyle(settingsSection == section ? DeskColor.ink : DeskColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(settingsSection == section ? DeskColor.row : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 168)
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if settingsSection == "Usage" {
                        usagePane
                    } else if settingsSection == "Appearance" {
                        GlassSettings()
                    } else if settingsSection == "Browser & panels" {
                        BrowserSettings(model: model, cwd: selected?.cwd ?? projectFolder)
                    } else if settingsSection == "Agent behavior" {
                        AgentSettings()
                    } else if settingsSection == "Project rules" {
                        ProjectRulesEditor(project: selected?.cwd ?? projectFolder)
                    } else if settingsSection == "General" {
                        generalPane
                    } else if settingsSection == "Profile" {
                        profilePane
                    } else if settingsSection == "Worktrees" {
                        worktreePane
                    } else {
                        ConfigurationEditor(busy: model.busy || model.connecting)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private var usagePane: some View {
        let used = model.subscriptionUpdatedAt == nil ? 0 : model.subscription?.percentUsed ?? 0
        let left = model.subscriptionUpdatedAt == nil ? nil : model.subscription?.percentLeft
        return VStack(alignment: .leading, spacing: 16) {
            Text(model.subscription?.plan ?? "Grok")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeskColor.select)
            Text(left.map { "\($0.formatted())% left" } ?? "Usage unavailable")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(DeskColor.ink)
            Text(model.subscriptionUpdatedAt.map { "Live service · Updated " + $0.formatted(date: .omitted, time: .standard) + " · Resets " + (model.subscription?.resetsAt ?? "") } ?? "Connecting to live usage…")
                .font(.system(size: 12))
                .foregroundStyle(DeskColor.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DeskColor.row)
                    Capsule().fill(DeskColor.select).frame(width: max(4, geo.size.width * used / 100))
                }
            }
            .frame(height: 8)
            Text(model.subscriptionUpdatedAt == nil ? "Waiting for the live credit allowance" : "\(used.formatted())% used · Refreshes every 30 seconds while open")
                .font(.system(size: 12))
                .foregroundStyle(DeskColor.muted)
            if let error = model.subscriptionError { Text("Refresh failed: " + error).font(.system(size: 11)).foregroundStyle(DeskColor.danger) }
            Button(model.subscriptionRefreshing ? "Refreshing…" : "Refresh now") { Task { await model.refreshSubscription() } }
                .buttonStyle(QuietButton()).disabled(model.subscriptionRefreshing)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                stat("Chats", "\(model.usage.chats)")
                stat("Your messages", "\(model.usage.userMessages)")
                stat("Grok messages", "\(model.usage.assistantMessages)")
                stat("Tool calls", "\(model.usage.toolCalls)")
            }
        }.task {
            while !Task.isCancelled {
                await model.refreshSubscription(); model.loadLocal()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            Text(value).font(.system(size: 18, weight: .medium)).foregroundStyle(DeskColor.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 12))
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                settingRow("Notify when a turn finishes", "Only when this window is in the background", key: "notifyWhenBackground")
                settingRow("Suggested prompts", "Shown on a new chat", key: "showSuggestedPrompts")
                Text("Plan review is available from the composer’s Build menu in Grok’s terminal. Tool permissions are controlled separately.").font(.system(size:11)).foregroundStyle(DeskColor.muted).padding(14)
            }
            .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 12))
            computerUsePane
            libraryLocationPane
        }
    }

    private var computerUsePane: some View {
        ComputerUseSetting(model: model)
    }

    private var libraryLocationPane: some View {
        let path = studio.library.root.standardizedFileURL.path
        let isDefault = path == StudioLibraryLocation.defaultRoot().standardizedFileURL.path
        return VStack(alignment: .leading, spacing: 10) {
            Text("Image and video library")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeskColor.ink)
            Text("Finished generations and imported references are saved in this folder. Choosing another folder leaves the current files where they are.")
                .font(.system(size: 11))
                .foregroundStyle(DeskColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DeskColor.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Choose folder") { studio.chooseLibraryFolder() }
                    .buttonStyle(DeskButtonStyle())
                Button("Reset to default") { studio.resetLibraryFolder() }
                    .buttonStyle(QuietButton())
                    .disabled(isDefault)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 12))
    }

    private struct ComputerUseSetting: View {
        @ObservedObject var model: DeskModel
        @State private var busy = false
        @State private var message = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Computer use")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskColor.ink)
                        Text("Lets Grok click, type, and read other apps through Cua Driver. It applies to the next message. macOS may ask Cua Driver for Accessibility access.")
                            .font(.system(size: 11))
                            .foregroundStyle(DeskColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Computer use", isOn: Binding(
                        get: { model.computerUseEnabled },
                        set: { value in
                            busy = true
                            message = ""
                            Task {
                                message = await model.setComputerUse(value) ?? ""
                                busy = false
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(busy || (model.cuaDriverBinary() == nil && !model.computerUseEnabled))
                }
                if model.cuaDriverBinary() == nil {
                    Text("Cua Driver is not installed.")
                        .font(.system(size: 11))
                        .foregroundStyle(DeskColor.danger)
                } else if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(DeskColor.danger)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func settingRow(_ title: String, _ detail: String, key: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(DeskColor.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: key) as? Bool ?? (key == "showSuggestedPrompts") },
                set: { UserDefaults.standard.set($0, forKey: key) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var profilePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.account.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(DeskColor.ink)
            Text(model.account.email.isEmpty ? "Not signed in" : model.account.email)
                .font(.system(size: 13)).foregroundStyle(DeskColor.muted)
            Text(model.subscription?.plan ?? "Grok")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskColor.inkOnBrass)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DeskColor.brass, in: Capsule())
        }
    }

    private var worktreePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.worktreeText.isEmpty ? "No worktrees listed." : model.worktreeText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DeskColor.ink)
            TextField("Name", text: $worktreeName).textFieldStyle(.roundedBorder)
            Button("Create worktree") { Task { await model.createWorktree(name: worktreeName) } }
                .buttonStyle(.plain)
                .foregroundStyle(DeskColor.inkOnBrass)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DeskColor.brass, in: Capsule())
        }
    }

    private var skillsBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Marketplace")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DeskColor.ink)
                Spacer()
                Text("\(model.pluginItems.count + model.mcpItems.count) installed")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskColor.muted)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DeskColor.muted)
                TextField("Search plugins", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(DeskColor.ink)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DeskColor.row, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                marketplaceSection("Installed plugins", model.pluginItems)
                marketplaceSection("MCP servers", model.mcpItems)
            }
        }
    }

    private func marketplaceSection(_ title: String, _ items: [ListedItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DeskColor.ink)
            if items.isEmpty {
                Text("None installed.").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DeskColor.select.opacity(0.2))
                            .frame(width: 32, height: 32)
                            .overlay(Text(String(item.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(DeskColor.select))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DeskColor.ink).lineLimit(1)
                            Text(item.detail.isEmpty ? item.scope : item.detail)
                                .font(.system(size: 11)).foregroundStyle(DeskColor.muted).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(item.enabled ? "Added" : "Off")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(item.enabled ? Color(red: 0.55, green: 0.82, blue: 0.62) : DeskColor.muted)
                    }
                    .padding(10)
                    .background(DeskColor.row, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var keyboardActions: some View {
        Group {
            Button("New conversation") { newChat() }.keyboardShortcut("n", modifiers: .command)
            Button("Search") { searchFocused = true }.keyboardShortcut("k", modifiers: .command)
            Button("Conversation") { workspace = .build }.keyboardShortcut("1", modifiers: .command)
            Button("Image studio") { studio.video = false; workspace = .cinema }.keyboardShortcut("2", modifiers: .command)
            Button("Video studio") { studio.video = true; workspace = .cinema }.keyboardShortcut("3", modifiers: .command)
            Button("Asset library") { workspace = .library }.keyboardShortcut("4", modifiers: .command)
            Button("Settings") { sheet = .settings }.keyboardShortcut(",", modifiers: .command)
        }.hidden()
    }
    private func stashDraft() { drafts[model.currentRuntimeID] = ComposerDraft(text:draft,attachments:attachments,skills:selectedSkills) }
    private func restoreDraft() { let saved=drafts[model.currentRuntimeID];draft=saved?.text ?? "";attachments=saved?.attachments ?? [];selectedSkills=saved?.skills ?? [] }
    private func selectChat(id:String,cwd:String) {
        stashDraft();model.selectSession(sessionID:id,cwd:cwd);selectedID=id
        projectFolder=workspaceRoot(cwd,registered:projects.map(\.cwd));workspace = .build;restoreDraft()
    }
    private func newChat() {
        stashDraft()
        draftCWD = nil
        selectedID = nil; draft = ""; attachments = []; selectedSkills = []; workspace = .build
        model.resetChat(); model.planMode = false
    }
    private func showProjectEditor(name: String = "", path: String = "") {
        editingProjectName = name; editingProjectPath = path; projectEditor = true
    }
    private func openProject(_ path: String) {
        newChat(); projectFolder = path; collapsed.remove(path)
    }
    private func switchWorkspace(_ path: String) {
        let pendingDraft = draft, files = attachments
        openProject(path)
        draft = pendingDraft; attachments = files
    }
    private func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = "Add workspace"
        if panel.runModal() == .OK, let folder = panel.urls.first {
            do {
                for selectedFolder in panel.urls { projects = try ProjectStore().add(folder: selectedFolder) }
                switchWorkspace(folder.path)
            } catch { projectError = "Could not save these folders: " + error.localizedDescription }
        }
    }
    private var contextControl: some View {
        ComposerPopover("Add context") {Image(systemName:"plus").frame(width:18,height:18)} content:{dismiss in
            VStack(alignment:.leading,spacing:10) {
                Picker("Context",selection:$contextTab) {ForEach(["Files","Skills","Connections"],id:\.self){Text($0)}}.pickerStyle(.segmented)
                if contextTab != "Files" {TextField("Search "+contextTab.lowercased(),text:$contextSearch).textFieldStyle(.roundedBorder)}
                ScrollView {
                    VStack(spacing:2) {
                        if contextTab == "Files" {
                            Button {dismiss();DispatchQueue.main.async{attachFiles()}} label:{Label("Upload file…",systemImage:"square.and.arrow.up")}.buttonStyle(DeskMenuRowStyle())
                            ForEach(recentAttachments,id:\.path) {file in
                                Button {addAttachments([file]);dismiss()} label:{Label(file.lastPathComponent,systemImage:"doc").lineLimit(1)}.buttonStyle(DeskMenuRowStyle())
                            }
                            Divider().padding(6)
                            Button {dismiss();DispatchQueue.main.async{chooseProject()}} label:{Label("Choose workspace…",systemImage:"folder")}.buttonStyle(DeskMenuRowStyle())
                            Button {dismiss();worktreeEditor=true} label:{Label("New worktree…",systemImage:"arrow.triangle.branch")}.buttonStyle(DeskMenuRowStyle()).disabled(repository.snapshot == nil)
                        } else if contextTab == "Skills" {
                            ForEach(model.skillItems.filter{contextSearch.isEmpty || $0.commandName.localizedCaseInsensitiveContains(contextSearch)}) {skill in
                                Button {if !selectedSkills.contains(where:{$0.id==skill.id}) {selectedSkills.append(skill)};dismiss()} label:{Label(skill.commandName,systemImage:"sparkles").lineLimit(2)}.buttonStyle(DeskMenuRowStyle(selected:selectedSkills.contains(where:{$0.id==skill.id})))
                            }
                            if model.skillItems.isEmpty {Text("No skills available in this workspace.").font(.system(size:12)).foregroundStyle(DeskColor.muted).padding(10)}
                        } else {
                            ForEach(model.mcpItems.filter{contextSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(contextSearch)}) {item in
                                Button {draft += (draft.isEmpty ? "":"\n") + "Use the \(item.name) MCP connection to ";dismiss()} label:{HStack{Label(item.name,systemImage:"link");Spacer();Text(item.enabled ? "":"Disabled").font(.system(size:10))}}.buttonStyle(DeskMenuRowStyle()).disabled(!item.enabled)
                            }
                            Button {dismiss();sheet = .skills} label:{Label("Manage connections…",systemImage:"slider.horizontal.3")}.buttonStyle(DeskMenuRowStyle())
                        }
                    }
                }.frame(height:contextTab=="Files" ? min(CGFloat(recentAttachments.count+3)*36+16,300):280)
            }.frame(width:310).onChange(of:contextTab){_,_ in contextSearch=""}
        }
    }
    private var buildControl: some View {
        let title = model.planMode ? "Plan" : "Build"
        return ComposerPopover("Work mode",value:title) {Label(title,systemImage:model.planMode ? "list.bullet.clipboard" : "hammer")} content:{dismiss in
            ComposerChoices(choices:[ComposerChoice(id:"build",title:"Build",detail:"Work directly on your request",symbol:"hammer"),ComposerChoice(id:"plan",title:"Plan",detail:"Plan in this chat before writing code",symbol:"list.bullet.clipboard"),ComposerChoice(id:"review",title:"Review saved plan",detail:"Show the saved plan here",symbol:"doc.text.magnifyingglass")],selected:model.planMode ? "plan" : "build") {choice in
                dismiss()
                if choice=="review" { model.revealSavedPlan(); return }
                model.planMode = choice=="plan"
                Task { await model.applyPlanMode() }
            }
        }
    }
    private var permissionControl: some View {
        ComposerPopover("Permissions",value:model.permissionMode=="auto" ? "Auto":model.permissionMode=="bypassPermissions" ? "Always approve":"Ask") {Label(model.permissionMode=="auto" ? "Auto":model.permissionMode=="bypassPermissions" ? "Always approve":"Ask",systemImage:"shield.lefthalf.filled")} content:{dismiss in
            ComposerChoices(choices:[ComposerChoice(id:"default",title:"Ask",detail:"Confirm tool calls that need approval"),ComposerChoice(id:"auto",title:"Auto",detail:"Grok evaluates calls; some still need approval"),ComposerChoice(id:"bypassPermissions",title:"Always approve",detail:"Approve tool calls unless rules deny them")],selected:model.permissionMode) {model.permissionMode=$0;UserDefaults.standard.set($0,forKey:"grokDesk.permissionMode");dismiss()}
        }
    }
    private var modelControl: some View {
        ComposerPopover("Model & reasoning",value:model.selectedModel+" · "+model.effort) {Text((model.models.first(where:{$0.id==model.selectedModel})?.label ?? "Choose model")+" · "+model.effort.capitalized)} content:{dismiss in
            VStack(alignment:.leading,spacing:10) {
                ComposerChoices(choices:model.models.map{ComposerChoice(id:$0.id,title:$0.label)},selected:model.selectedModel) {model.selectedModel=$0;dismiss()}
                Divider()
                Text("Reasoning effort").font(.system(size:11,weight:.medium)).foregroundStyle(DeskColor.muted).padding(.horizontal,10)
                Picker("Reasoning effort",selection:$model.effort) {ForEach(["low","medium","high","xhigh"],id:\.self){Text($0=="xhigh" ? "Extra high":$0.capitalized).tag($0)}}.pickerStyle(.segmented).controlSize(.small)
                Button("Refresh models") {Task{await model.refresh()}}.buttonStyle(QuietButton())
            }.frame(width:280)
        }
    }
    private func openGrokTerminal(command: String, title: String, dashboard: Bool = false) {
        if !dashboard && !model.prepareTerminalHandoff() { composerError = "Finish or stop this turn before opening it in Grok's terminal."; return }
        let cwd = selected?.cwd ?? (projectFolder.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : projectFolder)
        var args = ["--cwd", cwd]
        if dashboard { args.append("dashboard") }
        else { if let id = selectedID ?? model.activeSessionID { args += ["--resume", id] }; args.append(command) }
        let launch = TerminalLaunch(executable: resolveGrokBinary(home: FileManager.default.homeDirectoryForCurrentUser), arguments: args)
        var tab = ChatBrowserTab(title: title, kind: .terminal); tab.body = launch.encoded
        browserTabs.append(tab); browserActive = tab.id; browserOpen = true; workspace = .build
        rememberBrowser()
    }
    private func commandBody(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func sendDraft() {
        if let route=routeCommand(draft,advertised:Set(model.capabilities.commands),skills:Set(model.skillItems.map(\.commandName))) {
            switch route {
            case .native(let name):
                if name=="plan" {
                    model.planMode = true
                    let body = commandBody(draft)
                    draft = ""
                    let cwd = selected?.cwd ?? draftCWD ?? projectFolder
                    let resume = selectedID
                    Task {
                        await model.applyPlanMode()
                        if !body.isEmpty { _ = await model.send(text: body, cwd: cwd, resume: resume) }
                    }
                    return
                }
                if ["view-plan","show-plan","plan-view"].contains(name) { model.revealSavedPlan(); draft=""; return }
                if name=="queue" {queueOpen=true}
                else if name=="dashboard" || name=="tasks" {workspace = .agents}
                else if name=="new" || name=="clear" || name=="home" {newChat()}
                else {sheet = ["settings","config"].contains(name) ? .settings : .skills}
                draft="";return
            case .terminal(let name):
                guard !model.busy else {composerError="Finish or stop this turn before opening the same session in Grok's terminal.";return}
                openGrokTerminal(command:draft,title:"Grok · " + name);draft="";return
            case .unsupported(let name):composerError="/" + name + " is not available here. Open Grok tools for terminal-only commands.";return
            case .agent,.skill:break
            }
        }
        let text=draft,files=attachments,skills=selectedSkills
        let cwd=selected?.cwd ?? draftCWD ?? projectFolder,resume=selectedID
        let origin=model.currentRuntimeID
        draft="";attachments=[];selectedSkills=[];composerError=nil
        Task {
            let sent=await model.send(text:text,cwd:cwd,resume:resume,attachments:files,skills:skills)
            guard model.currentRuntimeID==origin else{return}
            if sent {
                if selectedID==nil,let id=model.activeSessionID {
                    ChatBrowserStore.save(id,ChatBrowserState(open:browserOpen,tabs:browserTabs,activeTabID:browserActive))
                }
                selectedID=model.activeSessionID
                notifyIfHidden()
            } else if draft.isEmpty {draft=text;attachments=files;selectedSkills=skills}
        }
    }

    private func addAttachments(_ urls: [URL]) {
        let newFiles = urls.filter { !attachments.contains($0) }
        guard attachments.count + newFiles.count <= 14 else { composerError = "Attach up to 14 files per message."; return }
        attachments.append(contentsOf: newFiles); composerError = nil
        var recent = newFiles + recentAttachments.filter { !newFiles.contains($0) }
        if recent.count > 12 {recent=Array(recent.prefix(12))}
        recentAttachments=recent;UserDefaults.standard.set(recent.map(\.path),forKey:"recentAttachments")
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addAttachments(panel.urls) }
    }

    private func openLogin() {
        let source = "tell application \"Terminal\" to do script \"grok login\""
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }

    private func notifyIfHidden() {
        guard notifyWhenBackground, !NSApp.isActive else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Grok Desk"
            content.body = "A turn finished."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func openInTerminal(_ session: DeskSession) {
        let command = model.continueInTerminal(session)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\" to do script \"\(escaped)\""
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }
}

private func fallbackProjectName(_ cwd: String) -> String {
    let name = URL(fileURLWithPath: cwd).lastPathComponent
    return name.isEmpty ? cwd : name
}

private func relativeTime(_ iso: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return "" }
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86400))d"
}

private struct WindowChrome: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        // AppKit menus and native popover windows must follow the app's chosen theme too.
        if NSApp.appearance?.name != name { NSApp.appearance = NSAppearance(named: name) }
        nsView.window?.appearance = NSAppearance(named: name)
        nsView.window?.backgroundColor = .clear
        nsView.window?.isOpaque = false
    }
}

private final class ChromeView: NSView {
    private var didConfigure = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didConfigure else { return }
        didConfigure = true
        window.title = "Grok Desk"
        window.contentMinSize = NSSize(width: 960, height: 640)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
    }
}

struct PermissionRequestCard: View {
    let title: String
    let choices: [PermissionChoice]
    let deny: () -> Void
    let choose: (String) -> Void

    var body: some View {
        let once = choices.filter { $0.kind == "allow_once" }
        let more = choices.filter { $0.kind != "allow_once" }
        VStack(alignment: .leading, spacing: 10) {
            Text("Permission").font(.system(size: 11, weight: .medium)).foregroundStyle(DeskColor.muted)
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DeskColor.ink)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(DeskColor.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button("Deny", action: deny).buttonStyle(DeskButtonStyle())
                Spacer(minLength: 8)
                ForEach(once) { choice in
                    Button(choice.name) { choose(choice.id) }.buttonStyle(DeskButtonStyle(prominent: true))
                }
            }
            if !more.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(more) { choice in
                        Button(choice.name) { choose(choice.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(DeskColor.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(DeskColor.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 736)
        .frame(maxWidth: .infinity)
        .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DeskColor.hairline))
    }
}
