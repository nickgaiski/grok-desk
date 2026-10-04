import SwiftUI
import GrokDeskCore
struct AgentSettings:View {
    @State private var source=""
    @State private var original=""
    @State private var requirements=""
    @State private var managed=""
    @State private var systemRequirements=""
    @State private var edits:[String:String]=[:]
    @State private var error:String?
    @State private var notice=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Agent behavior").font(.system(size:18,weight:.medium))
            Text("Grok CLI defaults · user scope").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            Text("These defaults apply to new Grok processes. Session controls can override them. Environment and administrator requirements are shown separately.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            ForEach(SettingDescriptor.all) { field in
                let effective=field.effective(user:source,requirements:requirements,systemRequirements:systemRequirements,managed:managed)
                VStack(alignment:.leading,spacing:5) {
                    HStack {Text(field.title).font(.system(size:12));Spacer();Text(effective.source.rawValue.capitalized).font(.system(size:10)).foregroundStyle(DeskColor.muted)}
                    Picker(field.title,selection:Binding(get:{edits[field.id] ?? effective.value},set:{edits[field.id]=$0})) {
                        ForEach(Array(Set(field.choices+[effective.value])).sorted(),id:\.self) {Text($0).tag($0).disabled(!field.choices.contains($0))}
                    }.labelsHidden().disabled(effective.source == .requirements || effective.source == .environment)
                }
            }
            if let error {Text(error).font(.system(size:11)).foregroundStyle(DeskColor.danger)}
            Text(notice).font(.system(size:11)).foregroundStyle(DeskColor.muted)
            HStack {Button("Reload"){load()}.buttonStyle(QuietButton());Spacer();Button("Save defaults") {save()}.buttonStyle(DeskButtonStyle(prominent:true)).disabled(edits.isEmpty)}
            Text(GrokPaths.config.path).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
        }.onAppear{load()}
    }
    private func load(){do {source=(try? String(contentsOf:GrokPaths.config,encoding:.utf8)) ?? "";original=source;edits=[:];error=nil
        requirements=(try? String(contentsOf:GrokPaths.home().appendingPathComponent("requirements.toml"),encoding:.utf8)) ?? ""
        systemRequirements=(try? String(contentsOf:URL(fileURLWithPath:"/etc/grok/requirements.toml"),encoding:.utf8)) ?? ""
        managed=(try? String(contentsOf:GrokPaths.home().appendingPathComponent("managed_config.toml"),encoding:.utf8)) ?? ""
        _ = try ConfigDocument(text:source)
    }catch{self.error=error.localizedDescription}}
    private func save(){do {var document=try ConfigDocument(text:source);for field in SettingDescriptor.all {if let value=edits[field.id] {try document.set(path:field.path,literal:field.literal(value))}};try document.save(to:GrokPaths.config,expected:original);load();notice="Saved. Restart Grok Desk to apply these defaults to new agent processes."}catch{self.error=error.localizedDescription}}
}
