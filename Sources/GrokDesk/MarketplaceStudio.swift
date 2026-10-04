import AppKit
import GrokDeskCore
import SwiftUI

struct PluginLogo: View {
    var url: URL?
    var size: CGFloat = 36
    @State private var image: NSImage?
    @State private var background = Color.white.opacity(0.5)
    @MainActor private static let cache = NSCache<NSURL, NSImage>()
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(5) }
            else { Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.45, weight: .light)).foregroundStyle(DeskColor.muted) }
        }.frame(width: size, height: size).background(background, in: RoundedRectangle(cornerRadius: size * 0.25))
            .task(id: url) {
                image = nil
                guard let url, url.scheme == "https" else { return }
                if let cached = Self.cache.object(forKey: url as NSURL) { setImage(cached); return }
                guard let data = try? await PluginCatalog.data(url), data.count < 3_000_000, !Task.isCancelled,
                      let loaded = NSImage(data: data) else { return }
                Self.cache.setObject(loaded, forKey: url as NSURL); setImage(loaded)
            }
    }
    private func setImage(_ loaded: NSImage) {
        image = loaded
        guard let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var sum = 0.0, weight = 0.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 16)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 16)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                sum += Double((color.redComponent + color.greenComponent + color.blueComponent) / 3 * color.alphaComponent)
                weight += Double(color.alphaComponent)
            }
        }
        background = Color(white: weight > 0 && sum / weight > 0.75 ? 0.24 : 0.96)
    }
}

struct MarketplaceStudio: View {
    @ObservedObject var model: DeskModel
    @State private var query = ""
    @State private var tab = "Discover"
    @State private var source = "All"
    @State private var managing: MarketplacePlugin?
    @State private var reviewing: MarketplacePlugin?
    var cwd = ""
    var openConfiguration: (() -> Void)? = nil
    var selectSkill: ((SkillRecord) -> Void)?
    private var plugins: [MarketplacePlugin] {
        model.marketplacePlugins.filter {
            (source == "All" || $0.marketplace == source) &&
            (query.isEmpty || ($0.name + $0.title + $0.summary).localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("Section", selection: $tab) {
                    ForEach(["Discover", "Installed", "Skills", "Connectors"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
                Spacer()
                Button { Task { await model.reloadSkills(cwd: cwd); await model.loadMarketplace() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuietButton()).help("Refresh catalog")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(DeskColor.muted)
                TextField("Search plugins and skills", text: $query).textFieldStyle(.plain)
                if tab == "Discover" { Picker("Catalog", selection: $source) { Text("All").tag("All"); Text("xAI").tag("xAI"); Text("Cursor").tag("Cursor") }.labelsHidden().frame(width: 110) }
            }.font(.system(size: 12)).padding(10).background(DeskColor.row, in: RoundedRectangle(cornerRadius: 12))
            if let error = model.marketplaceError { Text(error).font(.system(size: 11)).foregroundStyle(DeskColor.danger) }
            if !model.pluginActionMessage.isEmpty { Text(model.pluginActionMessage).font(.system(size: 11)).textSelection(.enabled) }
            if model.marketplaceLoading && model.marketplacePlugins.isEmpty { ProgressView("Loading official catalogs…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    if tab == "Skills" { skills }
                    else if tab == "Connectors" {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Connections in this project").font(.system(size: 13, weight: .medium));Spacer();if let openConfiguration { Button("Add connection") { openConfiguration() }.buttonStyle(DeskButtonStyle()) } }
                            if !model.connectionStatusText.isEmpty { Text(model.connectionStatusText).font(.system(size: 11)).foregroundStyle(DeskColor.muted) }
                            if model.authorizingServer != nil { Button("Cancel authorization") { model.cancelAuthorization() }.buttonStyle(DeskButtonStyle()) }
                            ForEach(model.mcpItems) { item in
                                VStack(alignment: .leading,spacing: 10) {
                                    HStack { Image(systemName: "link");Text(item.name);Spacer();ConnectionHealthBadge(name:item.name,project:cwd,enabled:item.enabled) }
                                    HStack {
                                        Button("Reconnect") { Task { await model.manageConnection(item.name,enabled:true) } }
                                        Button("Disconnect") { Task { await model.manageConnection(item.name,enabled:false) } }.disabled(!item.enabled)
                                        Spacer()
                                        Button("Authorize") { Task { await model.authorizeConnection(item.name,cwd:cwd) } }.help("Open this server’s browser authorization through Grok")
                                    }.buttonStyle(QuietButton()).disabled(model.pluginBusy || model.busy)
                                }.font(.system(size: 12)).padding(12).background(DeskColor.row, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if model.mcpItems.isEmpty { Text("No MCP connectors configured.").foregroundStyle(DeskColor.muted) }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                            ForEach(plugins.filter { plugin in tab != "Installed" || model.installedPlugin(plugin) != nil }) { plugin in card(plugin) }
                        }
                        if tab == "Installed" {
                            ForEach(localPlugins) { item in localPluginRow(item) }

                        }
                    }
                }.scrollIndicators(.hidden)
            }
            Text("Catalogs: xAI Official · Cursor Marketplace. Logos come from published metadata. Skills are discovered for the selected project.")
                .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
        }.foregroundStyle(DeskColor.ink)
            .task { await model.reloadSkills(cwd: cwd); if model.marketplacePlugins.isEmpty { await model.loadMarketplace() } }
            .sheet(item: $managing) { plugin in management(plugin) }
            .sheet(item: $reviewing) { plugin in
                VStack(alignment: .leading, spacing: 18) {
                    HStack { PluginLogo(url: plugin.logoURL, size: 48); Text(plugin.title).font(.system(size: 22, weight: .medium)) }
                    Text(plugin.summary).font(.system(size: 13))
                    Text("By " + plugin.publisher + " · " + plugin.marketplace + " catalog").font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                    Text(plugin.installSource).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeskColor.muted).textSelection(.enabled)
                    Text("Installing trusts this plugin in Grok Build. Plugins can include tools and executable hooks. Review its source before installing.").font(.system(size: 12))
                    if plugin.marketplace == "Cursor" { Text("Grok discovers standard skill directories. Cursor-specific manifest settings may require configuration; available skills appear after discovery.").font(.system(size: 11)).foregroundStyle(DeskColor.muted) }
                    HStack {
                        if let url = plugin.webpage { Link("View source", destination: url).font(.system(size: 12)) }
                        Spacer()
                        Button("Cancel") { reviewing = nil }.buttonStyle(QuietButton())
                        Button("Trust and install") { reviewing = nil; Task { await model.installPlugin(plugin) } }.buttonStyle(DeskButtonStyle(prominent: true))
                    }
                }.padding(24).frame(width: 480).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
            }
    }
    private var localPlugins: [ListedItem] {
        model.pluginItems.filter { installed in
            !model.marketplacePlugins.contains { model.installedPlugin($0)?.name == installed.name }
        }
    }
    private func localPluginRow(_ item: ListedItem) -> some View {
        let plugin = MarketplacePlugin(name:item.name,title:item.name,summary:"",marketplace:"Local",installSource:item.repository,logoURL:nil,webpage:nil,publisher:"Local installation")
        return HStack {
            PluginLogo();Text(item.name);Spacer()
            Text(item.enabled ? "Available":"Disabled").foregroundStyle(DeskColor.muted)
            Button { managing = plugin } label: { Image(systemName:"gearshape") }
                .buttonStyle(QuietButton()).help("Manage " + item.name)
        }.font(.system(size:12)).padding(10)
    }

    private func management(_ plugin: MarketplacePlugin) -> some View {
        let installation = model.installedPlugin(plugin)
        let name = installation?.name ?? plugin.name
        let servers = model.mcpItems.filter { $0.pluginName == name }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                PluginLogo(url: plugin.logoURL,size: 44)
                VStack(alignment: .leading,spacing: 4) {
                    Text(plugin.title).font(.system(size: 20,weight: .medium))
                    Text("By " + plugin.publisher).font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                }
                Spacer()
                Button("Done") { managing = nil }.buttonStyle(QuietButton())
            }
            Text(installation?.enabled == false ? "Disconnected" : "Installed and enabled").font(.system(size: 12))
            ForEach(servers) { server in HStack { Label(server.name,systemImage: "link"); Spacer(); ConnectionHealthBadge(name:server.name,project:cwd,enabled:server.enabled) }.font(.system(size:12)) }
            if servers.isEmpty { Text("This plugin provides local skills. No MCP authorization is required.").font(.system(size: 12)).foregroundStyle(DeskColor.muted) }
            if !model.connectionStatusText.isEmpty { Text(model.connectionStatusText).font(.system(size: 11)).textSelection(.enabled) }
            Text("Disconnect disables tools; it does not revoke the provider’s authorization grant.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            HStack {
                Button("Reconnect") { Task { await model.managePlugin(name,enabled: true);await model.checkPluginConnections(name) } }.buttonStyle(DeskButtonStyle())
                Button("Disconnect") { Task { await model.managePlugin(name,enabled: false) } }.buttonStyle(DeskButtonStyle()).disabled(installation?.enabled == false)
                Spacer()
                if servers.count == 1, let server = servers.first {
                    Button("Authorize") { Task { await model.authorizeConnection(server.name,cwd:cwd) } }.buttonStyle(DeskButtonStyle(prominent:true))
                } else {
                    Menu("Authorize") {
                        ForEach(servers) { server in Button(server.name) { Task { await model.authorizeConnection(server.name,cwd:cwd) } } }
                    }.disabled(servers.isEmpty)
                }
            }.disabled(model.pluginBusy || model.busy)
            if model.authorizingServer != nil { Button("Cancel authorization") { model.cancelAuthorization() }.buttonStyle(DeskButtonStyle()) }
            if !servers.isEmpty {
                Text("Authorize asks Grok to open your browser for this server. Complete consent there; credentials remain managed by Grok.").font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            }
        }.padding(24).frame(width: 500).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
    }
    private func card(_ plugin: MarketplacePlugin) -> some View {
        let installation = model.installedPlugin(plugin)
        let installed = installation != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                PluginLogo(url: plugin.logoURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(plugin.publisher).font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                    Text(plugin.marketplace + " catalog").font(.system(size: 9)).foregroundStyle(DeskColor.muted.opacity(0.8))
                }
                Spacer()
            }
            Text(plugin.summary).font(.system(size: 11)).foregroundStyle(DeskColor.muted).lineLimit(3).frame(height: 44, alignment: .top)
            HStack {
                if installed {
                    Label(installation?.enabled == false ? "Disconnected" : "Installed", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                    Spacer()
                    Button("Skills") { tab = "Skills"; query = installation?.name ?? plugin.name }.buttonStyle(QuietButton())
                    Button { managing = plugin } label: { Image(systemName: "gearshape") }.buttonStyle(QuietButton()).help("Manage " + plugin.title).accessibilityLabel("Manage " + plugin.title)
                } else {
                    Spacer()
                    Button(model.installingPlugin == plugin.id ? "Installing…" : "Review install") { reviewing = plugin }
                        .buttonStyle(DeskButtonStyle()).disabled(model.installingPlugin != nil || model.busy)
                }
            }
        }.padding(14).background(DeskColor.composer.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
    private var skills: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.skillItems.filter { query.isEmpty || ($0.commandName + $0.detail).localizedCaseInsensitiveContains(query) }) { skill in
                HStack(spacing: 12) {
                    PluginLogo(url: model.marketplacePlugins.first { $0.name == skill.pluginName }?.logoURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("/" + skill.commandName).font(.system(size: 12, weight: .medium))
                        Text(skill.detail).font(.system(size: 11)).foregroundStyle(DeskColor.muted).lineLimit(2)
                    }
                    Spacer()
                    if let selectSkill { Button("Use") { selectSkill(skill) }.buttonStyle(DeskButtonStyle()) }
                }.padding(10).background(DeskColor.row, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
