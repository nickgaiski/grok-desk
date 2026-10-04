import AppKit
import Quartz
import GrokDeskCore
import SwiftUI

struct WorkspaceFilesPanel: View {
    let root:String
    let open:(URL)->Void
    @State private var folder=""
    @State private var query=""
    @State private var entries:[URL]=[]
    @State private var error:String?
    private var current:URL {URL(fileURLWithPath:folder.isEmpty ? root:folder)}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Button {folder=current.deletingLastPathComponent().path;reload()} label:{Image(systemName:"arrow.up")}.buttonStyle(QuietButton()).disabled(current.path==root)
                Text(current.lastPathComponent).font(.system(size:13,weight:.medium));Spacer()
                Button("Open file…") {let panel=NSOpenPanel();panel.directoryURL=current;panel.canChooseDirectories=false;if panel.runModal() == .OK,let url=panel.url {open(url)}}.buttonStyle(QuietButton())
                Button {reload()} label:{Image(systemName:"arrow.clockwise")}.buttonStyle(QuietButton())
            }
            TextField("Filter files",text:$query).textFieldStyle(.plain).padding(10).background(DeskColor.row,in:Capsule())
            if let error {Text(error).font(.system(size:11)).foregroundStyle(DeskColor.danger)}
            ScrollView {
                LazyVStack(spacing:2) {
                    ForEach(entries.filter {query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query)},id:\.path) {url in
                        let directory=(try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true
                        Button {if directory {folder=url.path;reload()} else {open(url)}} label:{
                            HStack(spacing:10) {Image(systemName:directory ? "folder":"doc.text").frame(width:20).foregroundStyle(DeskColor.muted);Text(url.lastPathComponent).lineLimit(1);Spacer();Image(systemName:directory ? "chevron.right":"arrow.up.right").font(.system(size:9)).foregroundStyle(DeskColor.muted)}
                                .font(.system(size:12)).padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text(current.path).font(.system(size:10)).foregroundStyle(DeskColor.muted).lineLimit(1).truncationMode(.middle)
        }.padding(16).foregroundStyle(DeskColor.ink).onAppear{reload()}.onChange(of:root){_,_ in folder="";reload()}
    }
    private func reload() {
        do {entries=try FileManager.default.contentsOfDirectory(at:current,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles]).sorted {
            let a=(try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true,b=(try? $1.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true
            return a != b ? a:$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        };error=nil} catch {self.error=error.localizedDescription;entries=[]}
    }
}
struct WorkspaceFilePreview:View {
    let url:URL
    @State private var document:PanelFileDocument?
    @State private var text=""
    @State private var editing=false
    @State private var error:String?
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text(url.lastPathComponent).font(.system(size:12,weight:.medium));Spacer()
                Button("Reveal") {NSWorkspace.shared.activateFileViewerSelecting([url])}.buttonStyle(QuietButton())
                if document != nil {
                    Button(editing ? "Cancel":"Edit") {if editing {load()};editing.toggle()}.buttonStyle(QuietButton())
                    if editing {Button("Save") {save()}.buttonStyle(DeskButtonStyle(prominent:true))}
                }
            }.padding(12)
            if let error {Text(error).font(.system(size:11)).foregroundStyle(DeskColor.danger).padding(10)}
            if document != nil {
                if editing {TextEditor(text:$text).font(.system(size:12,design:.monospaced)).scrollContentBackground(.hidden).padding(12)}
                else {ScrollView([.horizontal,.vertical]) {Text(text).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(16)}}
            } else {FileQuickLook(url:url)}
        }.foregroundStyle(DeskColor.ink).onAppear{load()}.onChange(of:url){_,_ in editing=false;load()}
    }
    private func load(){document=try? PanelFileDocument(url:url);text=document?.text ?? "";error=nil}
    private func save(){do {guard var document else{return};document.text=text;try document.save();load();editing=false}catch{self.error=error.localizedDescription}}
}
private struct FileQuickLook:NSViewRepresentable {
    let url:URL
    func makeNSView(context:Context)->QLPreviewView {let view=QLPreviewView(frame:.zero,style:.normal)!;view.autostarts=false;view.previewItem=url as NSURL;return view}
    func updateNSView(_ view:QLPreviewView,context:Context){view.previewItem=url as NSURL}
}
