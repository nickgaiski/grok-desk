import AppKit
import Darwin
import GrokDeskCore
import SwiftUI
import WebKit

struct ChatWebPane: View {
    @Binding var tabs: [ChatBrowserTab]
    @Binding var activeID: String
    var workspacePath: String
    var skills: [SkillRecord]
    var connections: [ListedItem]
    var onSelectConnection: (ListedItem) -> Void
    var onSelectSkill: (SkillRecord) -> Void
    var onBrowserSettings: () -> Void
    var sessionKey: String
    @AppStorage("browserSearchEngine") private var searchEngine = "Google"
    @State private var addressDraft = ""
    @FocusState private var addressFocused: Bool
    @State private var showCloseTerminal = false
    @State private var pendingClose: String?
    var onClose: () -> Void
    var onChange: () -> Void
    @ObservedObject var book: TabbedPages

    private var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            browserChrome
            if active.kind == .web && active.url.isEmpty {
                NewTabHome(workspaceName: workspaceName, suggestions: suggestions, tools: skills, connections: connections, selectConnection: onSelectConnection, selectTool: onSelectSkill, browserSettings: onBrowserSettings) { action in
                    switch action {
                    case .search(let text):
                        setKind(.web, title: "New tab", url: text)
                        page.load(ChatBrowserStore.address(from: text, searchEngine: searchEngine))
                    case .files: setKind(.files, title: "Open file")
                    case .terminal: setKind(.terminal, title: "Terminal")
                    case .page: setKind(.page, title: "Untitled page")
                    }
                }
            } else if active.kind == .files {
                WorkspaceFilesPanel(root: workspacePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workspacePath) { url in
                    let tab = ChatBrowserTab(url: url.absoluteString, title: url.lastPathComponent, kind: .file)
                    tabs.append(tab); activeID = tab.id; onChange()
                }
            } else if active.kind == .file, let url = URL(string: active.url), url.isFileURL {
                WorkspaceFilePreview(url: url)
            } else if active.kind == .terminal {
                EmbeddedTerminal(terminal: book.terminal(for: activeID), cwd: workspacePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workspacePath, launch: TerminalLaunch.decode(active.body))
            } else if active.kind == .page {
                PageEditor(text: bodyBinding)
            } else {
                if page.loading || page.failure != nil {
                    HStack {
                        if page.loading { ProgressView().controlSize(.small) }
                        Text(page.failure ?? "Loading")
                            .font(.system(size: 11))
                            .foregroundStyle(page.failure == nil ? DeskColor.muted : DeskColor.danger)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(DeskColor.sidebar)
                }
                let tabID = activeID
                ChatWebView(page: page) { url, title in
                    updateTab(tabID, url: url, title: title)
                }
                .id(activeID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DeskColor.window.opacity(0.35))
        .onAppear { ensureActive(); addressDraft = active.url; loadIfEmpty() }
        .onChange(of: activeID) { _, _ in addressDraft = active.kind == .web ? active.url : ""; loadIfEmpty() }
        .onChange(of: sessionKey) { _, _ in ensureActive(); addressDraft = active.url; loadIfEmpty() }
        .confirmationDialog("Close this terminal? Its shell process will stop.", isPresented: $showCloseTerminal) {
            Button("Close terminal", role: .destructive) { if let id = pendingClose { close(id) }; pendingClose = nil }
        }
    }

    private var browserChrome: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { ForEach(tabs) { tab in tabButton(tab) } } }
                Button { addTab() } label: { Image(systemName: "plus") }.buttonStyle(QuietButton()).help("New tab")
                Button { onBrowserSettings() } label: { Image(systemName: "puzzlepiece.extension") }.buttonStyle(QuietButton()).help("Browser connections and extensions")
                chromeIcon("xmark", enabled: true) { onClose() }
            }
            if active.kind == .web {
            HStack(spacing: 6) {
                chromeIcon("chevron.left", enabled: active.kind == .web && page.canGoBack) { page.goBack() }
                chromeIcon("chevron.right", enabled: active.kind == .web && page.canGoForward) { page.goForward() }
                chromeIcon("arrow.clockwise", enabled: active.kind == .web && !active.url.isEmpty) { page.reload() }
                HStack(spacing: 7) {
                    Image(systemName: active.kind == .web ? "globe" : active.kind == .terminal ? "terminal" : "doc").foregroundStyle(DeskColor.muted)
                    TextField("Search or enter a URL", text: $addressDraft).textFieldStyle(.plain).focused($addressFocused).onSubmit { submitAddress() }
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32).deskGlass(radius: 18)
                Menu {
                    Button("Copy page screenshot") { page.copySnapshot() }.disabled(active.kind != .web || active.url.isEmpty)
                    Button("Open in external browser") { page.openOutside() }.disabled(active.kind != .web || active.url.isEmpty)
                    Divider()
                    Button("Browser settings") { onBrowserSettings() }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: active.kind == .terminal ? "folder" : "doc.text")
                    Text(active.kind == .terminal || active.kind == .files ? workspacePath : active.kind == .file ? (URL(string: active.url)?.path ?? active.title) : "Workspace notes")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(DeskColor.muted).padding(.horizontal, 4).frame(height: 24)
            }
        }.padding(10).background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Rectangle().fill(DeskColor.hairline).frame(height: 0.5) }
    }

    private func chromeIcon(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? DeskColor.ink : DeskColor.muted.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(DeskColor.composer, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func submitAddress() {
        let raw = addressDraft
        guard let url = ChatBrowserStore.address(from: raw, searchEngine: searchEngine) else { return }
        setKind(.web, title: url.host ?? "Web", url: url.absoluteString)
        page.load(url)
    }

    private var page: ChatWebPage { book.page(for: activeID) }
    private var active: ChatBrowserTab { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : ChatBrowserTab() }
    private var workspaceName: String { URL(fileURLWithPath: workspacePath).lastPathComponent }
    private var suggestions: [String] {
        tabs.filter { $0.kind == .web && !$0.url.isEmpty }.map(\.url)
    }
    private var bodyBinding: Binding<String> {
        Binding(
            get: { tabs.indices.contains(activeIndex) ? tabs[activeIndex].body : "" },
            set: { value in
                guard tabs.indices.contains(activeIndex) else { return }
                tabs[activeIndex].body = value
                onChange()
            }
        )
    }

    private func setKind(_ kind: ChatBrowserKind, title: String, url: String = "") {
        guard tabs.indices.contains(activeIndex) else { return }
        tabs[activeIndex].kind = kind
        tabs[activeIndex].title = title
        tabs[activeIndex].url = url
        addressDraft = kind == .web ? url : ""
        onChange()
    }

    private func tabButton(_ tab: ChatBrowserTab) -> some View {
        let selected = tab.id == activeID
        return HStack(spacing: 5) {
            Image(systemName: tab.kind == .web ? "globe" : tab.kind == .terminal ? "terminal" : tab.kind == .files ? "folder" : "doc.text").font(.system(size: 10)).foregroundStyle(DeskColor.muted)
            Button { activeID = tab.id; onChange() } label: {
                Text(tab.title.isEmpty ? "New tab" : tab.title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? DeskColor.ink : DeskColor.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .buttonStyle(.plain)
            if tabs.count > 1 {
                Button { if tab.kind == .terminal { pendingClose = tab.id; showCloseTerminal = true } else { close(tab.id) } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18) }
                    .buttonStyle(.plain)
                    .foregroundStyle(DeskColor.muted)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(selected ? DeskColor.composer : Color.clear, in: Capsule())
        .overlay(Capsule().stroke(selected ? DeskColor.hairline : Color.clear, lineWidth: 1))
    }

    private func addTab() {
        let tab = ChatBrowserTab()
        tabs.append(tab)
        activeID = tab.id
        onChange()
    }

    private func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        book.drop(id)
        if tabs.isEmpty { tabs = [ChatBrowserTab()] }
        if activeID == id { activeID = tabs[min(index, tabs.count - 1)].id }
        onChange()
    }

    private func ensureActive() {
        if tabs.isEmpty { tabs = [ChatBrowserTab()] }
        if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs[0].id }
    }

    private func loadIfEmpty() {
        ensureActive()
        guard tabs[activeIndex].kind == .web else { return }
        let current = page
        guard current.webView.url == nil else { return }
        current.load(ChatBrowserStore.address(from: tabs[activeIndex].url))
    }

    private func updateTab(_ id: String, url: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].url = url
        let host = URL(string: url)?.host ?? title
        tabs[index].title = title.isEmpty ? host : title
        if activeID == id && !addressFocused { addressDraft = url }
        onChange()
    }
}

@MainActor
final class TabbedPages: ObservableObject {
    private var pages: [String: ChatWebPage] = [:]
    private var terminals: [String: PanelTerminal] = [:]
    func terminal(for id: String) -> PanelTerminal { if let existing = terminals[id] { return existing }; let created = PanelTerminal(); terminals[id] = created; return created }
    func reset() { for page in pages.values { page.webView.stopLoading() }; for terminal in terminals.values { terminal.stop() }; pages = [:]; terminals = [:] }
    func page(for id: String) -> ChatWebPage {
        if let existing = pages[id] { return existing }
        let created = ChatWebPage()
        pages[id] = created
        return created
    }
    func drop(_ id: String) { pages[id]?.webView.stopLoading(); pages[id] = nil; terminals[id]?.stop(); terminals[id] = nil }
}

@MainActor
final class ChatWebPage: ObservableObject {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var failure: String?

    init() {
        let config = WKWebViewConfiguration()
        if UserDefaults.standard.bool(forKey: "privateEmbeddedBrowser") { config.websiteDataStore = .nonPersistent() }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
    }

    func load(_ url: URL?) {
        guard let url else { return }
        failure = nil
        loading = true
        webView.load(URLRequest(url: url))
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { failure = nil; webView.reload() }

    func copySnapshot() {
        webView.takeSnapshot(with: nil) { image, _ in
            guard let image else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
    }

    func openOutside() {
        guard let url = webView.url else { return }
        BrowserApplications.open(url)
    }
}

private struct ChatWebView: NSViewRepresentable {
    @ObservedObject var page: ChatWebPage
    var onNavigate: (String, String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        page.webView.navigationDelegate = context.coordinator
        return page.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.onNavigate = onNavigate }

    func makeCoordinator() -> Coordinator { Coordinator(page: page, onNavigate: onNavigate) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let page: ChatWebPage
        var onNavigate: (String, String) -> Void
        private var back: NSKeyValueObservation?
        private var forward: NSKeyValueObservation?

        init(page: ChatWebPage, onNavigate: @escaping (String, String) -> Void) {
            self.page = page
            self.onNavigate = onNavigate
            super.init()
            back = page.webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.page.canGoBack = view.canGoBack }
            }
            forward = page.webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.page.canGoForward = view.canGoForward }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? ""
            let title = webView.title ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.page.loading = false
                self?.page.failure = nil
                self?.onNavigate(url, title)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { [weak self] in
                self?.page.loading = false
                self?.page.failure = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            if cancelled { return }
            DispatchQueue.main.async { [weak self] in
                self?.page.loading = false
                self?.page.failure = error.localizedDescription
            }
        }
    }
}

private enum NewTabAction { case search(String), files, terminal, page }

private struct NewTabHome: View {
    var workspaceName: String
    var suggestions: [String]
    var tools: [SkillRecord]
    var connections: [ListedItem]
    var selectConnection: (ListedItem) -> Void
    var selectTool: (SkillRecord) -> Void
    var browserSettings: () -> Void
    var perform: (NewTabAction) -> Void
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Search or enter a URL", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { perform(.search(query)) }
                Text("Tools").font(.system(size: 12, weight: .medium)).foregroundStyle(DeskColor.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    tool("Files", "folder") { perform(.files) }
                    tool("Terminal", "terminal") { perform(.terminal) }
                    tool("New page", "doc") { perform(.page) }
                    Menu {
                        if tools.isEmpty { Text("No plugins installed") }
                        Section("Installed skills") { ForEach(tools) { skill in Button("/" + skill.commandName) { selectTool(skill) } } }
                        Section("MCP connections") { ForEach(connections.filter(\.enabled)) { connection in Button(connection.name) { selectConnection(connection) } } }
                        Divider()
                        Button("Browser connections…") { browserSettings() }
                    } label: { toolLabel("More tools", "square.grid.2x2") }
                    .menuStyle(.borderlessButton)
                }
                if !suggestions.isEmpty {
                    Text("Suggested").font(.system(size: 12, weight: .medium)).foregroundStyle(DeskColor.muted)
                    ForEach(suggestions.prefix(4), id: \.self) { url in
                        Button { perform(.search(url)) } label: {
                            Text(URL(string: url)?.host ?? url).font(.system(size: 12)).foregroundStyle(DeskColor.ink)
                        }.buttonStyle(.plain)
                    }
                }
                if !workspaceName.isEmpty {
                    Text("Workspace \(workspaceName)").font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                }
            }
            .padding(28).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(DeskColor.window.opacity(0.2))
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, icon) }.buttonStyle(.plain)
    }
    private func toolLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 16)
            Text(title).font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(DeskColor.ink)
        .padding(.horizontal, 12).frame(height: 44)
        .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 10))
    }
}


private struct PageEditor: View {
    @Binding var text: String
    var body: some View { TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(20).foregroundStyle(DeskColor.ink) }
}
