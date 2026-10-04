import SwiftUI
import GrokDeskCore
struct AgentDashboard:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var studio:DeskModel
    let open:(String,String,Bool)->Void
    let official:(String)->Void
    @State private var filter="All"
    private var rows:[(RuntimeSummary,Bool)] { (model.runtimeSummaries.map{($0,false)} + studio.runtimeSummaries.map{($0,true)}).filter { filter=="All" || (filter=="Needs input" ? $0.0.needsInput : filter=="Working" ? $0.0.state == .working : $0.0.state != .working && !$0.0.needsInput) } }
    private var children:[AgentActivityEvent] {
        let all=Array(model.runtimeActivity.values).flatMap{$0}+Array(studio.runtimeActivity.values).flatMap{$0}
        var latest:[String:AgentActivityEvent]=[:]
        for event in all where event.childSessionID != nil {
            let key=event.childSessionID!
            if latest[key] == nil || latest[key]!.timestamp < event.timestamp {latest[key]=event}
        }
        return latest.values.sorted{$0.timestamp > $1.timestamp}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agents").font(.system(size: 26, weight: .medium))
                    Text("Live work in Grok Desk").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                }
                Spacer()
                Menu("Grok tools") {
                    Button("All Grok sessions…") { official("dashboard") }
                    Button("Background tasks…") { official("/tasks") }
                    Button("Workflows…") { official("/workflows") }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Picker("Filter",selection:$filter){ForEach(["All","Needs input","Working","History"],id:\.self){Text($0)}}.pickerStyle(.segmented).frame(maxWidth:460)
            if rows.isEmpty {Text("No agents in this view").foregroundStyle(DeskColor.muted).padding(.vertical,30)}
            ScrollView {
                LazyVStack(spacing:10) {
                    if !children.isEmpty {
                        DisclosureGroup("Subagent activity · \(children.count)") {
                            ForEach(children) { event in
                                HStack(alignment:.top) {
                                    Image(systemName:"arrow.triangle.branch")
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(event.title).font(.system(size:12,weight:.medium))
                                        Text("Child " + (event.childSessionID ?? "") + " · Parent " + (event.parentSessionID ?? event.sessionID)).font(.system(size:10)).lineLimit(1)
                                        Text("Last reported: " + (event.toolStatus ?? "observed") + " · " + event.timestamp.formatted()).font(.system(size:10)).foregroundStyle(DeskColor.muted)
                                    }
                                    Spacer()
                                }.padding(10)
                            }
                        }.padding(12).background(DeskColor.row,in:RoundedRectangle(cornerRadius:12))
                    }
                    ForEach(rows,id:\.0.runtimeID) { row,isStudio in
                        Button {if row.isExternalObservedSession {official("dashboard")} else if let id=row.sessionID {open(id,row.cwd,isStudio)}} label:{
                            HStack(alignment:.top,spacing:12) {
                                Image(systemName:row.parentSessionID == nil ? (isStudio ? "film":"terminal") : "arrow.triangle.branch").frame(width:24)
                                VStack(alignment:.leading,spacing:6) {
                                    Text(row.currentAction ?? (isStudio ? "Studio agent":"Workspace agent")).font(.system(size:13,weight:.medium)).lineLimit(2)
                                    Text(row.cwd.isEmpty ? "New chat":row.cwd).font(.system(size:10)).foregroundStyle(DeskColor.muted).lineLimit(1).truncationMode(.middle)
                                    if let parent=row.parentSessionID {Text("Child of " + parent).font(.system(size:10)).foregroundStyle(DeskColor.muted)}
                                }
                                Spacer()
                                VStack(alignment:.trailing,spacing:6) {
                                    Text(row.needsInput ? "Needs input":row.state.rawValue.capitalized).font(.system(size:11,weight:.medium))
                                    if row.isExternalObservedSession {Text("Open in Grok").font(.system(size:10)).foregroundStyle(DeskColor.muted)}
                                    if row.queuedCount>0 {Text("\(row.queuedCount) queued").font(.system(size:10))}
                                    if let when=row.lastActivity {Text(when,style:.relative).font(.system(size:10)).foregroundStyle(DeskColor.muted)}
                                }
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(DeskColor.composer.opacity(0.65),in:RoundedRectangle(cornerRadius:16))
                        }.buttonStyle(.plain).disabled(row.sessionID == nil)
                    }
                }
            }
            Text("Provider-wide sessions and background processes are available in Grok tools. Historical transcripts alone are not treated as running agents.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
        }.padding(28).foregroundStyle(DeskColor.ink)
    }
}
