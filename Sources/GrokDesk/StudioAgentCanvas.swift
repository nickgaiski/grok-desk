import AppKit
import SwiftUI
import GrokDeskCore

struct StudioAgentCanvas: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var studio: StudioModel
    @State private var previewPath: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.blocks.isEmpty {
                    VStack(spacing: 10) {
                        Text("Create a whole story.").font(.system(size: 30, weight: .light))
                        Text("Plan a sequence, generate matching scenes, and refine them together.")
                            .font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(model.blocks) { block in ConversationBlock(block: block) }
                if !studio.session.assetPaths.isEmpty {
                    Text("Canvas").font(.system(size: 13, weight: .medium))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                        ForEach(studio.session.assetPaths, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 6) {
                                MediaThumbnail(url: URL(fileURLWithPath: path), maxPixels: 360).frame(height: 110).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 10)).lineLimit(1)
                                HStack {
                                    Button("Use as reference") { if !studio.agentBoard.references.contains(path) { studio.agentBoard.references.append(path); studio.persistAgent() } }
                                    Menu {
                                        Button("Preview") { previewPath = path }
                                        Button("Export…") { export(path) }
                                        Button("Move earlier") { move(path, offset: -1) }
                                        Button("Move later") { move(path, offset: 1) }
                                        Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                                }.buttonStyle(QuietButton()).font(.system(size: 10))
                            }.padding(10).background(DeskColor.composer.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }.frame(maxWidth: 800).frame(maxWidth: .infinity).padding(4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 120)
            .sheet(isPresented: Binding(get: { previewPath != nil }, set: { if !$0 { previewPath=nil } })) {
                if let path=previewPath {
                    VStack { HStack { Spacer(); Button("Done") {previewPath=nil} }.padding(12); WorkspaceFilePreview(url:URL(fileURLWithPath:path)) }.frame(width:700,height:500)
                }
            }
    }
    private func export(_ path:String) {
        let panel=NSSavePanel();panel.nameFieldStringValue=URL(fileURLWithPath:path).lastPathComponent
        guard panel.runModal() == .OK,let target=panel.url,target.path != path else{return}
        do {try Data(contentsOf:URL(fileURLWithPath:path)).write(to:target,options:.atomic)} catch {studio.error=error.localizedDescription}
    }
    private func move(_ path: String, offset: Int) {
        guard let i = studio.session.assetPaths.firstIndex(of: path), studio.session.assetPaths.indices.contains(i + offset) else { return }
        studio.session.assetPaths.swapAt(i, i + offset); studio.persistAgent()
    }
}
