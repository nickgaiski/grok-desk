import AppKit
import GrokDeskCore
import SwiftUI

struct StudioMediaPicker: View {
    enum Purpose { case references, firstFrame, lastFrame, agentAttachments }
    @ObservedObject var studio: StudioModel
    @ObservedObject var model: DeskModel
    @Binding var board: StudioBoard
    let purpose: Purpose
    var openCustomize: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Generations"
    @State private var query = ""
    @State private var selected: [String] = []
    @State private var voices: [String] = []
    private var title: String { purpose == .firstFrame ? "First frame" : purpose == .lastFrame ? "Last frame" : "Add to your scene" }
    private var candidates: [URL] {
        let imported = studio.library.importedNames()
        var urls = studio.assets.filter { (purpose == .agentAttachments || !$0.isVideo) && (tab == "Uploads" ? imported.contains($0.url.lastPathComponent) : tab == "Generations" ? !imported.contains($0.url.lastPathComponent) : true) }.map(\.url)
        if tab == "References" {
            urls = (board.references + studio.boards.flatMap(\.references)).map { URL(fileURLWithPath: $0) }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted && (query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 18, weight: .semibold)).tracking(-0.4).padding(.bottom, 20)
                category("Generations", icon: "sparkles")
                category("Uploads", icon: "square.and.arrow.up")
                if purpose == .references || purpose == .agentAttachments {
                    category("Audio", icon: "waveform")
                    category("References", icon: "person.crop.square")
                    category("Connectors", icon: "link")
                }
                Spacer()
                Button { studio.importFiles(imagesOnly: purpose != .agentAttachments); tab = "Uploads" } label: { Label(purpose == .agentAttachments ? "Upload media" : "Upload images", systemImage: "plus") }
                    .buttonStyle(DeskButtonStyle()).disabled(studio.importing)
            }.padding(20).frame(width: 190).background(DeskColor.sidebar.opacity(0.5))
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab).font(.system(size: 17, weight: .medium))
                        Text(purpose == .agentAttachments ? "Attach images or videos for the Studio agent to use in this canvas." : purpose == .references ? "Guide appearance and identity without pinning a frame." : "Pin this image as the exact \(purpose == .firstFrame ? "opening" : "closing") frame.")
                            .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton()).accessibilityLabel("Close media picker")
                }
                if tab == "Audio" { audioPanel }
                else if tab == "Connectors" { connectorPanel }
                else {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(DeskColor.muted)
                        TextField(purpose == .agentAttachments ? "Search media" : "Search images", text: $query).textFieldStyle(.plain)
                    }.font(.system(size: 12)).padding(10).background(DeskColor.row, in: Capsule())
                    if candidates.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.stack").font(.system(size: 30, weight: .ultraLight))
                            Text("Bring a reference into the picture").font(.system(size: 16, weight: .medium))
                            Text(purpose == .agentAttachments ? "Upload media, or choose another collection." : "Upload an image, or choose another collection.").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                            Button(purpose == .agentAttachments ? "Upload media" : "Upload images") { studio.importFiles(imagesOnly: purpose != .agentAttachments); tab = "Uploads" }.buttonStyle(DeskButtonStyle())
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 10)], spacing: 14) {
                                ForEach(candidates, id: \.path) { url in
                                    Button { toggle(url.path) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            MediaThumbnail(url: url, maxPixels: 380).frame(height: 98).frame(maxWidth: .infinity)
                                                .background(DeskColor.row, in: RoundedRectangle(cornerRadius: 12))
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected.contains(url.path) ? DeskColor.select : .clear, lineWidth: 2))
                                                .overlay(alignment: .topTrailing) {
                                                    if let index = selected.firstIndex(of: url.path) {
                                                        Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).padding(6)
                                                            .background(DeskColor.composer, in: Circle()).padding(6)
                                                    }
                                                }
                                            Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 10)).lineLimit(1).foregroundStyle(DeskColor.muted)
                                        }
                                    }.buttonStyle(.plain).accessibilityLabel("Select " + url.lastPathComponent)
                                        .accessibilityAddTraits(selected.contains(url.path) ? .isSelected : [])
                                }
                            }.padding(3)
                        }.scrollIndicators(.hidden)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text((purpose == .agentAttachments ? "\(selected.count) selected" : "\(selected.count) image\(selected.count == 1 ? "" : "s")") + (voices.isEmpty ? "" : " · \(voices.count) voices"))
                        .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
                    Button(purpose == .agentAttachments ? "Attach media" : purpose == .references ? "Add references" : "Use frame") {
                        if purpose == .firstFrame { board.startPath = selected.first }
                        else if purpose == .lastFrame { board.endPath = selected.first }
                        else { board.references = selected; board.voices = voices }
                        dismiss()
                    }.buttonStyle(DeskButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(maxWidth: .infinity)
        }.frame(width: 760, height: 500).deskPopup(radius: 22)
            .foregroundStyle(DeskColor.ink)
            .onAppear {
                selected = (purpose == .references || purpose == .agentAttachments) ? board.references : [purpose == .firstFrame ? board.startPath : board.endPath].compactMap { $0 }
                voices = board.voices
            }
    }
    private func category(_ name: String, icon: String) -> some View {
        Button { tab = name; query = "" } label: {
            Label(name, systemImage: icon).font(.system(size: 12, weight: tab == name ? .medium : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(tab == name ? DeskColor.composer.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preset voices").font(.system(size: 15, weight: .medium))
            Text(board.medium == "video" ? "Choose up to three voices and write their dialogue in your prompt using <AUDIO_0>, <AUDIO_1>, or <AUDIO_2>." : "Voices apply to video. Switch to Video to add dialogue.")
                .font(.system(size: 12)).foregroundStyle(DeskColor.muted)
            ForEach(["ara", "eve", "leo", "rex"], id: \.self) { voice in
                Button {
                    if voices.contains(voice) { voices.removeAll { $0 == voice } }
                    else if voices.count < 3 { voices.append(voice) }
                } label: {
                    HStack { Image(systemName: "waveform"); Text(voice.capitalized); Spacer(); if voices.contains(voice) { Image(systemName: "checkmark") } }
                        .padding(12).background(DeskColor.row, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(board.medium != "video")
            }
            Text("Custom audio uploads are not exposed by the installed Grok Build tool. Preset voices are supported.")
                .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
        }
    }
    private var connectorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected tools").font(.system(size: 15, weight: .medium))
            Text("Connectors belong to the agent workspace. They are not image or frame inputs.").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
            ForEach(model.mcpItems) { item in Label(item.name, systemImage: "link").font(.system(size: 12)) }
            if model.mcpItems.isEmpty { Text("No connectors configured.").font(.system(size: 12)).foregroundStyle(DeskColor.muted) }
            if let openCustomize { Button("Open Customize") { dismiss(); openCustomize() }.buttonStyle(DeskButtonStyle()) }
        }
    }
    private func toggle(_ path: String) {
        if selected.contains(path) { selected.removeAll { $0 == path } }
        else if purpose != .references && purpose != .agentAttachments { selected = [path] }
        else if selected.count < 14 { selected.append(path) }
    }
}
