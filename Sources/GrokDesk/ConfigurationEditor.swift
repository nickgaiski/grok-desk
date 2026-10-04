import AppKit
import GrokDeskCore
import SwiftUI
import TOMLKit

struct ConfigurationEditor: View {
    var busy: Bool
    @State private var source = ""
    @State private var original = ""
    @State private var fields: [ConfigField] = []
    @State private var edits: [String:String] = [:]
    @State private var code = false
    @State private var error: String?
    @State private var loaded = false
    @State private var saved = false
    @State private var adding = false
    @State private var connectionName = ""
    @State private var target = ""
    @State private var transport = "http"
    @State private var arguments = ""
    private var url: URL { GrokPaths.config }
    private var sections: [String] { Array(Set(fields.map(\.section))).sorted() }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("Grok Build configuration").font(.system(size:16,weight:.medium))
                Spacer()
                Picker("View",selection:Binding(get:{code},set:{ next in
                    do { try materialize(); code=next; error=nil } catch { self.error=error.localizedDescription }
                })) { Text("Form").tag(false);Text("Code").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width:130)
            }
            Text("Changes are saved only when you click Save. Session controls can override these defaults.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            if let error { Text(error).font(.system(size:11)).foregroundStyle(DeskColor.danger).textSelection(.enabled) }
            if code {
                TextEditor(text:$source).font(.system(size:11,design:.monospaced)).frame(minHeight:300)
                    .scrollContentBackground(.hidden).padding(8).background(DeskColor.composer,in:RoundedRectangle(cornerRadius:10))
            } else {
                ForEach(sections,id:\.self) { section in
                    DisclosureGroup(section.isEmpty ? "General" : section.replacingOccurrences(of:"_",with:" ").capitalized) {
                        VStack(alignment:.leading,spacing:12) {
                            ForEach(fields.filter{$0.section==section}) { field in editor(field) }
                        }.padding(.vertical,10)
                    }.font(.system(size:12,weight:.medium)).padding(12).background(DeskColor.row,in:RoundedRectangle(cornerRadius:10))
                }
                if fields.isEmpty && loaded { Text("No overrides yet. Add a connection or use Code to set other Grok defaults.").font(.system(size:12)).foregroundStyle(DeskColor.muted) }
                Button { adding.toggle() } label: { Label("Add connection",systemImage:"plus.circle") }.buttonStyle(DeskButtonStyle())
                if adding { connectionForm }
            }
            HStack {
                Button("Reload") { reload() }.buttonStyle(QuietButton())
                Spacer()
                Button("Save configuration") { save() }.buttonStyle(DeskButtonStyle(prominent:true)).disabled(!loaded || busy)
            }
        }.foregroundStyle(DeskColor.ink).onAppear { if !loaded { reload() } }
            .alert("Configuration saved",isPresented:$saved) {
                Button("Restart now") { restart() }.disabled(busy)
                Button("Later",role:.cancel) {}
            } message: { Text("The config was validated and saved. Restart Grok Desk to load the changes. A backup of the previous file was kept.") }
    }
    @ViewBuilder private func editor(_ field:ConfigField) -> some View {
        if field.kind == "bool" {
            Toggle(field.label,isOn:Binding(get:{(edits[field.id] ?? field.literal)=="true"},set:{edits[field.id]=$0 ? "true":"false"})).toggleStyle(.switch)
        } else {
            VStack(alignment:.leading,spacing:4) {
                Text(field.label).font(.system(size:11)).foregroundStyle(DeskColor.muted)
                if field.secret { SecureField(field.label,text:value(field)).textFieldStyle(.roundedBorder) }
                else { TextField(field.label,text:value(field),axis:.vertical).textFieldStyle(.roundedBorder).font(.system(size:12)).lineLimit(1...5) }
            }
        }
    }
    private func value(_ field:ConfigField) -> Binding<String> {
        Binding(get:{
            let literal=edits[field.id] ?? field.literal
            if field.kind=="string" { return (try? TOMLTable(string:"value = "+literal)["value"]?.tomlValue.string) ?? literal }
            return literal
        },set:{edits[field.id]=field.kind=="string" ? ConfigDocument.quoted($0):$0})
    }
    private var connectionForm: some View {
        VStack(alignment:.leading,spacing:10) {
            TextField("Connection name",text:$connectionName)
            Picker("Transport",selection:$transport) { Text("HTTP").tag("http");Text("Local process").tag("stdio") }
            TextField(transport=="http" ? "https://server.example/mcp":"Executable (for example npx)",text:$target)
            if transport=="stdio" { TextField("Arguments, one per line",text:$arguments,axis:.vertical).lineLimit(2...5) }
            Button("Add to draft") {
                do {
                    try materialize();var document=try ConfigDocument(text:source)
                    try document.addConnection(name:connectionName,target:target,transport:transport,arguments:arguments.split(separator:"\n").map(String.init))
                    source=document.text;fields=document.fields;adding=false;connectionName="";target="";arguments="";error=nil
                } catch { self.error=error.localizedDescription }
            }.buttonStyle(DeskButtonStyle())
        }.textFieldStyle(.roundedBorder).font(.system(size:12)).padding(12).background(DeskColor.row,in:RoundedRectangle(cornerRadius:10))
    }
    private func materialize() throws {
        var document=try ConfigDocument(text:source)
        for field in fields { if let literal=edits[field.id] { try document.set(path:field.path,literal:literal) } }
        source=document.text;fields=document.fields;edits=[:]
    }
    private func reload() {
        do {
            source=FileManager.default.fileExists(atPath:url.path) ? try String(contentsOf:url,encoding:.utf8):""
            original=source;edits=[:];loaded=true
            do { fields=try ConfigDocument(text:source).fields;error=nil }
            catch { fields=[];code=true;self.error="The config needs repair. Correct the TOML in Code view before saving. " + error.localizedDescription }
        } catch { self.error=error.localizedDescription }
    }
    private func save() {
        do { try materialize(); try ConfigDocument(text:source).save(to:url,expected:original);original=source;saved=true;error=nil }
        catch { self.error=error.localizedDescription }
    }
    private func restart() {
        let configuration=NSWorkspace.OpenConfiguration();configuration.createsNewApplicationInstance=true
        NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:configuration) { _,error in
            DispatchQueue.main.async {
                if error==nil { NSApp.terminate(nil) } else { self.error="Could not restart. Quit and reopen Grok Desk to apply the saved changes." }
            }
        }
    }
}
