import SwiftUI
import GrokDeskCore
struct PromptQueueView:View {
    @ObservedObject var model:DeskModel
    @Environment(\.dismiss) private var dismiss
    private var activeID:UUID? { model.runtimeSummaries.first(where:{$0.runtimeID == model.currentRuntimeID})?.activeQueuedPromptID }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("Message queue").font(.system(size:20,weight:.medium));Spacer();Button("Done"){dismiss()}.buttonStyle(QuietButton())}
            Text("Follow-ups stay with this chat and workspace. They are sent in order after the active turn. A failure pauses the queue.").font(.system(size:12)).foregroundStyle(DeskColor.muted)
            if model.queuedPrompts.isEmpty {Text("No queued messages").foregroundStyle(DeskColor.muted).frame(maxWidth:.infinity,minHeight:120)}
            ScrollView {
                VStack(spacing:12) {
                    ForEach(model.queuedPrompts) { item in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {Text(item.createdAt.formatted(date:.omitted,time:.shortened));if item.id == activeID {Text("Running")} else if item.requiresReview {Text("Review required")};Spacer();Button {move(item.id,-1)} label:{Image(systemName:"arrow.up")};Button {move(item.id,1)} label:{Image(systemName:"arrow.down")};Button("Remove"){model.removeQueuedPrompt(id:item.id)}}.font(.system(size:11)).buttonStyle(QuietButton()).disabled(item.id == activeID)
                            TextField("Message",text:Binding(get:{model.queuedPrompts.first(where:{$0.id==item.id})?.text ?? item.text},set:{text in var changed=item;changed.text=text;model.editQueuedPrompt(changed)}),axis:.vertical).lineLimit(2...6).textFieldStyle(.plain).disabled(item.id == activeID)
                            Text(item.cwd).font(.system(size:10,design:.monospaced)).lineLimit(1).truncationMode(.middle)
                            if !item.attachmentPaths.isEmpty {Text("Attachments: " + item.attachmentPaths.map{URL(fileURLWithPath:$0).lastPathComponent}.joined(separator:", ")).font(.system(size:10))}
                        }.padding(12).background(DeskColor.row,in:RoundedRectangle(cornerRadius:12))
                    }
                }
            }
            HStack {Spacer();Button("Review complete & resume") {model.reviewQueuedPrompts();Task {await model.resumeQueue()}}.buttonStyle(DeskButtonStyle(prominent:true)).disabled(model.busy || model.queuedPrompts.isEmpty)}
        }.padding(24).frame(width:600,height:470).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
    }
    private func move(_ id:UUID,_ offset:Int) {var ids=model.queuedPrompts.map(\.id);guard let i=ids.firstIndex(of:id),ids.indices.contains(i+offset) else{return};ids.swapAt(i,i+offset);model.reorderQueuedPrompts(ids)}
}
