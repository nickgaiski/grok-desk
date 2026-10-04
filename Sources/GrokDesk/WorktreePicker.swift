import SwiftUI
import GrokDeskCore
struct WorktreePicker:View {
    let repo:String
    let created:(URL)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var ref=""
    @State private var busy=false
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("New worktree").font(.system(size:20,weight:.medium))
            Text(repo).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
            TextField("Worktree name",text:$name).textFieldStyle(.roundedBorder)
            TextField("Base ref (optional)",text:$ref).textFieldStyle(.roundedBorder)
            Text(ref.isEmpty ? "Starts at current HEAD, including local changes. Your current checkout stays in place." : "Creates a clean checkout of this ref; local changes are not copied.").font(.system(size:12)).foregroundStyle(DeskColor.muted)
            Text("The chat stays under its parent workspace. Closing it won't remove the worktree.").font(.system(size:11)).foregroundStyle(DeskColor.muted)
            if let error {Text(error).foregroundStyle(DeskColor.danger).font(.system(size:12))}
            HStack {Button("Cancel"){dismiss()}.disabled(busy);Spacer();if busy {ProgressView().controlSize(.small)};Button("Create and use") {busy=true;Task {do {let url=try await WorktreeService.create(repo:repo,name:name,ref:ref);try WorktreeAssociations().associate(url.path,with:repo);created(url);dismiss()}catch{self.error=error.localizedDescription};busy=false}}.buttonStyle(DeskButtonStyle(prominent:true)).disabled(busy || name.isEmpty)}
        }.padding(24).frame(width:460).deskPopup(radius: 22)
    }
}
