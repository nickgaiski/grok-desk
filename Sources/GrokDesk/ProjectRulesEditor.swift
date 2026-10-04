import AppKit
import SwiftUI
import GrokDeskCore
struct ProjectRulesEditor:View {
    let project:String
    @State private var global=false
    @State private var loading=false
    @State private var saving=false
    @State private var loadID=UUID()
    @State private var document:RulesDocument?
    @State private var text=""
    @State private var preview=false
    @State private var error:String?
    @State private var notice=""
    @State private var pendingScope:Bool?
    private var url:URL { (global ? GrokPaths.home() : URL(fileURLWithPath:project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : project)).appendingPathComponent("AGENTS.md") }
    private var dirty:Bool { text != (document?.original ?? "") }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Project rules").font(.system(size:18,weight:.medium))
            Picker("Scope",selection:Binding(get:{global},set:{value in if dirty {pendingScope=value} else {global=value;load()} })) {
                Text("Selected project").tag(false);Text("Global Grok rules").tag(true)
            }.pickerStyle(.segmented).disabled(saving)
            Text(url.path).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
            Text("Grok loads global rules first, then project and nested rules. Deeper rules take precedence. Changes apply when the session loads rules again.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            Toggle("Preview Markdown",isOn:$preview).toggleStyle(.switch)
            if loading { HStack {ProgressView().controlSize(.small);Text("Loading rules…").font(.system(size:12))} }
            if preview {ScrollView{MarkdownMessage(text:text).frame(maxWidth:.infinity,alignment:.leading)}.frame(minHeight:240)}
            else {TextEditor(text:$text).disabled(document == nil || saving).font(.system(size:12,design:.monospaced)).frame(minHeight:240).scrollContentBackground(.hidden)}
            if let error {Text(error).font(.system(size:11)).foregroundStyle(DeskColor.danger)}
            Text(notice).font(.system(size:11)).foregroundStyle(DeskColor.muted)
            HStack {Button("Reload") {if dirty {pendingScope=global} else {load()} }.buttonStyle(QuietButton());Button("Choose rules file…") {chooseFile()}.buttonStyle(QuietButton());Spacer();Text(document == nil ? "Not loaded" : dirty ? "Unsaved changes":"Saved").font(.system(size:10));Button(saving ? "Saving…" : "Save rules") {Task { _ = await save() }}.buttonStyle(DeskButtonStyle(prominent:true)).disabled(!dirty || document == nil || saving)}
        }.onAppear{load()}.onDisappear{saveDraft();loadID=UUID();loading=false}.onChange(of:project){_,_ in if !global {saveDraft();load()} }
            .confirmationDialog("Save your rule changes?",isPresented:Binding(get:{pendingScope != nil},set:{if !$0 {pendingScope=nil}}),titleVisibility:.visible) {
                Button("Save and switch") {Task {if await save(),let next=pendingScope {global=next;pendingScope=nil;load()}}}
                Button("Discard changes",role:.destructive) {if let next=pendingScope {UserDefaults.standard.removeObject(forKey:draftKey);global=next;pendingScope=nil;load()}}
                Button("Cancel",role:.cancel) {pendingScope=nil}
            }
    }
    private var draftKey:String {"rules-draft:"+url.path}
    private func saveDraft(){guard let doc=document else{return};let key="rules-draft:"+doc.url.path;if text != doc.original {UserDefaults.standard.set(text,forKey:key)} else {UserDefaults.standard.removeObject(forKey:key)}}
    private func chooseFile() {
        let panel=NSOpenPanel();panel.directoryURL=url.deletingLastPathComponent();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.message="Choose the displayed AGENTS.md file to grant this app access."
        guard panel.runModal() == .OK,let selected=panel.url else{return}
        guard selected.standardizedFileURL == url.standardizedFileURL else {error="Choose the AGENTS.md file shown above.";return}
        if let bookmark=try? selected.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) {
            UserDefaults.standard.set(bookmark,forKey:"rules-bookmark:"+url.path)
        }
        load(authorizedURL:selected)
    }
    private func load(authorizedURL: URL? = nil) {
        document=nil;text="";notice="";error=nil;loading=true
        let target=authorizedURL ?? url, token=UUID();loadID=token
        let recovered=UserDefaults.standard.string(forKey:"rules-draft:"+target.path)
        let bookmark=UserDefaults.standard.data(forKey:"rules-bookmark:"+target.path)
        Task {
            let result = await Task.detached(priority:.userInitiated) {
                var accessible=target
                if let bookmark {
                    var stale=false
                    if let restored=try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale), restored.standardizedFileURL == target.standardizedFileURL {accessible=restored}
                }
                let scoped=accessible.startAccessingSecurityScopedResource();defer{if scoped {accessible.stopAccessingSecurityScopedResource()}}
                return Result { try RulesDocument(url:accessible) }
            }.value
            guard loadID==token else{return};loading=false
            switch result {
            case .success(let doc):document=doc;text=recovered ?? doc.text;notice=text != doc.original ? "Recovered unsaved draft. Review before saving.":""
            case .failure(let failure):error=failure.localizedDescription
            }
        }
        Task {
            try? await Task.sleep(for:.seconds(10))
            guard loadID==token,loading else{return}
            loadID=UUID();loading=false;error="The file is taking too long to open. Use Choose rules file to grant access, then try again."
        }
    }
    @discardableResult private func save() async -> Bool {
        guard !saving,var doc=document else{return false}
        doc.text=text;let target=url;let submitted=doc;saving=true
        defer{saving=false}
        let result=await Task.detached(priority:.userInitiated) { () -> Result<RulesDocument,Error> in
            do {let scoped=submitted.url.startAccessingSecurityScopedResource();defer{if scoped {submitted.url.stopAccessingSecurityScopedResource()}};var saved=submitted;try saved.save(expectedURL:target);return .success(saved)} catch {return .failure(error)}
        }.value
        switch result {
        case .success(let saved):
            guard url==target else{return true}
            document=saved;UserDefaults.standard.removeObject(forKey:"rules-draft:"+target.path)
            notice="Rules saved. Start or reload a Grok session to apply them.";error=nil;return true
        case .failure(let failure):error=failure.localizedDescription;return false
        }
    }
}
