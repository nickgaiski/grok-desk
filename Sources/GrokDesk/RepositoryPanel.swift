import GrokDeskCore
import SwiftUI

@MainActor
final class RepositoryModel: ObservableObject {
    @Published var snapshot: RepositorySnapshot?
    @Published var error: String?
    private var requested=""
    func refresh(_ cwd:String) async {
        requested=cwd
        do {let next=try await RepositoryService.inspect(cwd);guard requested==cwd else{return};snapshot=next;error=nil}
        catch {if requested==cwd {self.error=error.localizedDescription;snapshot=nil}}
    }
}
struct RepositoryBar:View {
    @ObservedObject var model:RepositoryModel
    var cwd:String
    var busy:Bool
    @State private var action:RepositoryAction?
    @State private var showChanges=false
    var body:some View {
        Group {
            if let repo=model.snapshot {
                HStack(spacing:10) {
                    Label(repo.label,systemImage:repo.isWorktree ? "square.stack.3d.up":"arrow.triangle.branch")
                        .font(.system(size:11,weight:.medium)).lineLimit(1).help(repo.root + "\nCommit " + repo.commit)
                    Text(repo.commit).font(.system(size:10,design:.monospaced)).foregroundStyle(DeskColor.muted)
                    Spacer(minLength:4)
                    Button {showChanges=true} label: {
                        HStack(spacing:4) {Text("Changes \(repo.files.count)");Text("+\(repo.additions)").foregroundStyle(.green);Text("−\(repo.deletions)").foregroundStyle(DeskColor.danger)}
                    }.buttonStyle(QuietButton())
                    Menu("Repository actions") {
                        ForEach(RepositoryAction.allCases) {value in Button(value.rawValue) {action=value}.disabled(value == .deploy && repo.deployScript == nil)}
                    }.menuStyle(.borderlessButton).fixedSize().font(.system(size:11)).disabled(busy)
                }.padding(.horizontal,12).padding(.vertical,5).background(DeskColor.row.opacity(0.4),in:Capsule())
            } else if let error=model.error {Text(error).font(.system(size:10)).foregroundStyle(DeskColor.danger)}
        }
        .sheet(item:$action) {value in if let repo=model.snapshot {RepositoryActionView(action:value,snapshot:repo) {Task {await model.refresh(cwd)}}} }
        .sheet(isPresented:$showChanges) {if let repo=model.snapshot {RepositoryActionView(action:.stage,snapshot:repo) {Task {await model.refresh(cwd)}}} }
    }
}
private struct RepositoryActionView:View {
    let action:RepositoryAction
    let snapshot:RepositorySnapshot
    let changed:()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var input=""
    @State private var files=Set<String>()
    @State private var running=false
    @State private var result=""
    @State private var diff=""
    @State private var error:String?
    private var plan:RepositoryPlan? {try? RepositoryService.plan(action,snapshot:snapshot,input:input,selected:files)}
    var body:some View {
        VStack(alignment:.leading,spacing:15) {
            HStack {Text(action.rawValue).font(.system(size:21,weight:.medium));Spacer();Button("Done") {dismiss()}.buttonStyle(QuietButton()).disabled(running)}
            Text(snapshot.root).font(.system(size:11)).foregroundStyle(DeskColor.muted).textSelection(.enabled)
            Label(snapshot.label + " · " + snapshot.commit,systemImage:"arrow.triangle.branch").font(.system(size:12))
            if action == .stage {
                ScrollView {VStack(alignment:.leading,spacing:8) {ForEach(snapshot.files) {file in
                    Toggle(isOn:Binding(get:{files.contains(file.path)},set:{if $0 {files.insert(file.path)} else {files.remove(file.path)}})) {Text(file.state + "  " + file.path).font(.system(size:11,design:.monospaced))}
                } } }.frame(height:180)
            } else if [.commit,.pullRequest,.merge,.branch].contains(action) {
                TextField(action == .commit ? "Commit message" : action == .pullRequest ? "Pull request title" : "Branch name",text:$input).textFieldStyle(.roundedBorder)
            }
            if action == .commit {Text("Commits staged files only. Use Stage selected to choose files first.").font(.system(size:12)).foregroundStyle(DeskColor.muted)}
            if action == .deploy {Text("Deployment script: " + (snapshot.deployScript ?? "Unavailable")).font(.system(size:12)).textSelection(.enabled)}
            if !diff.isEmpty { ScrollView([.horizontal,.vertical]) { Text(diff).font(.system(size:10,design:.monospaced)).textSelection(.enabled).padding(8) }.frame(maxHeight:160).background(DeskColor.row,in:RoundedRectangle(cornerRadius:8)) }
            if let plan {Text(plan.display).font(.system(size:11,design:.monospaced)).textSelection(.enabled).padding(12).background(DeskColor.row,in:RoundedRectangle(cornerRadius:10))}
            if let error {Text(error).font(.system(size:12)).foregroundStyle(DeskColor.danger)}
            if !result.isEmpty {ScrollView {Text(result).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:160)}
            HStack {Text("Review the repository and command before running.").font(.system(size:11)).foregroundStyle(DeskColor.muted);Spacer();Button(running ? "Running…":"Run \(action.rawValue.lowercased())") {run()}.buttonStyle(DeskButtonStyle(prominent:true)).disabled(running || plan == nil)}
        }.padding(24).frame(width:650).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
            .task {
                if action == .commit || action == .stage {
                    let response = try? await RepositoryService.git(["diff", "--no-ext-diff", "--color=never"] + (action == .commit ? ["--cached"] : []), cwd: snapshot.root)
                    diff = String((response?.stdout ?? "").prefix(60000))
                }
            }
    }
    private func run() {
        guard let plan else{return};running=true;error=nil
        Task {defer {running=false};do {let response=try await RepositoryService.execute(plan);result=response.stdout+response.stderr;if response.status != 0 {error="Command exited with status \(response.status)."};changed()}catch{self.error=error.localizedDescription}}
    }
}
