import AppKit
import GrokDeskCore
import SwiftUI

struct CinemaControls: View {
    @Binding var look: StudioLook
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Camera & lens").font(.system(size: 19, weight: .semibold))
                    Text("Shape the look of your shot.").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction).accessibilityLabel("Close camera controls")
            }
            HStack(alignment: .top, spacing: 12) {
                column("Camera", symbol: "video", values: ["Full-frame digital", "Super 35 digital", "Large-format film", "16 mm film"], selection: $look.camera)
                column("Lens", symbol: "camera.filters", values: ["Cinema prime", "Anamorphic", "Vintage prime", "Macro", "Tilt-shift", "Diffusion"], selection: $look.lens)
                column("Focal length", symbol: "viewfinder", values: ["14 mm", "24 mm", "35 mm", "50 mm", "85 mm"], selection: $look.focal)
                column("Aperture", symbol: "camera.aperture", values: ["f/1.4", "f/4", "f/11"], selection: $look.aperture)
            }
            HStack(spacing: 10) {
                Image(systemName: "camera.aperture").foregroundStyle(DeskColor.muted)
                Text("\(look.camera) · \(look.lens) · \(look.focal) · \(look.aperture)").font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(DeskButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
            Text("These choices guide Grok’s prompt; the generated result interprets the requested look.")
                .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
        }.padding(24).frame(width: 660).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
            
    }
    private func column(_ title: String, symbol: String, values: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(DeskColor.muted)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        let selected = selection.wrappedValue == value
                        Button { selection.wrappedValue = value } label: {
                            VStack(spacing: 9) {
                                if title == "Focal length" {
                                    Text(value.replacingOccurrences(of: " mm", with: "")).font(.system(size: 27, weight: .light, design: .rounded))
                                } else if title == "Aperture" {
                                    Image(systemName: symbol).font(.system(size: 26, weight: .ultraLight)).scaleEffect(value == "f/1.4" ? 1 : value == "f/4" ? 0.8 : 0.6)
                                } else {
                                    Image(systemName: symbol).font(.system(size: 25, weight: .ultraLight))
                                }
                                Text(value).font(.system(size: 10, weight: selected ? .medium : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                            }.foregroundStyle(selected ? DeskColor.ink : DeskColor.muted)
                                .frame(maxWidth: .infinity).frame(height: 82)
                                .background(selected ? DeskColor.composer : DeskColor.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? DeskColor.select : DeskColor.hairline, lineWidth: 1))
                                .overlay(alignment: .topTrailing) {
                                    if selected { Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)).padding(8) }
                                }
                        }.buttonStyle(.plain).accessibilityLabel("\(title): \(value)").accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(1)
            }.scrollIndicators(.hidden).frame(height: 284)
        }.frame(maxWidth: .infinity)
    }
}

struct StudioReferencePicker: View {
    @ObservedObject var studio: StudioModel
    let initial: [String]
    let multiple: Bool
    let use: ([String]) -> Void
    @State private var selected: [String] = []
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var candidates: [URL] {
        let saved = studio.boards.flatMap { [$0.startPath, $0.endPath].compactMap { $0 } + $0.references }
        let paths = studio.assets.filter { !$0.isVideo }.map { $0.url.path } + initial + saved
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            .filter { search.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(multiple ? "Reference images" : "Choose a frame").font(.system(size: 19, weight: .semibold))
                    Text("Reuse images from your local library.").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction).accessibilityLabel("Close references")
            }
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DeskColor.muted)
                    TextField("Search images", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(9).background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 7))
                Button { studio.importFiles(imagesOnly: true) } label: { Label("Import images", systemImage: "plus") }
                    .buttonStyle(DeskButtonStyle()).disabled(studio.importing)
            }
            if candidates.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30, weight: .ultraLight))
                    Text(search.isEmpty ? "Your references live here" : "No matching images").font(.system(size: 15, weight: .medium))
                    Text("Imported images stay available for future shots.").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                }.frame(maxWidth: .infinity).frame(height: 300)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(candidates, id: \.path) { url in
                            Button { toggle(url.path) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    MediaThumbnail(url: url, maxPixels: 420).frame(height: 110).frame(maxWidth: .infinity)
                                        .background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 8))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected.contains(url.path) ? DeskColor.ink : .clear, lineWidth: 1.5))
                                        .overlay(alignment: .topTrailing) {
                                            if let index = selected.firstIndex(of: url.path) {
                                                Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(DeskColor.window)
                                                    .frame(width: 20, height: 20).background(DeskColor.ink, in: Circle()).padding(6)
                                            }
                                        }
                                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 10)).foregroundStyle(DeskColor.muted).lineLimit(1)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("Reference \(url.lastPathComponent)")
                                .accessibilityAddTraits(selected.contains(url.path) ? .isSelected : [])
                        }
                    }.padding(2)
                }.frame(height: 300)
            }
            HStack {
                if studio.importing { ProgressView().controlSize(.small) }
                Text("\(selected.count) selected").font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                if !selected.isEmpty { Button("Clear") { selected = [] }.buttonStyle(QuietButton()) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DeskButtonStyle())
                Button("Use selected") { use(selected); dismiss() }.buttonStyle(DeskButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
            .onAppear { selected = initial }
    }
    private func toggle(_ path: String) {
        if selected.contains(path) { selected.removeAll { $0 == path } }
        else if !multiple { selected = [path] }
        else if selected.count < 14 { selected.append(path) }
    }
}

/// A SwiftUI button preserves the two-line control label that AppKit menus flatten.
struct StudioDirectionControl: View {
    let title: String
    let symbol: String
    @Binding var selection: String
    let choices: [String]
    @State private var presented = false
    @State private var focusedChoice: String?
    @FocusState private var menuFocused: Bool
    var body: some View {
        Button { presented.toggle() } label: {
            VStack(alignment: .leading, spacing: 11) {
                Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                HStack(spacing: 4) {
                    Text(selection).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.foregroundStyle(DeskColor.ink)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(DeskColor.composer.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).deskHover(radius: 12).accessibilityLabel(title + ": " + selection)
            .popover(isPresented: $presented, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DeskColor.muted).padding(.horizontal, 10).padding(.vertical, 6)
                    Divider().padding(.horizontal, 6)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(choices, id: \.self) { choice in
                                Button { selection = choice; presented = false } label: {
                                    HStack(spacing: 10) {
                                        Text(choice).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(selection == choice ? 1 : 0)
                                    }
                                }.buttonStyle(DeskMenuRowStyle(selected: focusedChoice == choice))
                                    .onHover { if $0 { focusedChoice = choice } }
                                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                            }
                        }
                    }.frame(height: min(CGFloat(choices.count) * 34, 340))
                }.padding(8).frame(width: 232).deskPopup().foregroundStyle(DeskColor.ink)
                    .focusable().focused($menuFocused).focusEffectDisabled()
                    .onAppear {
                        focusedChoice = choices.contains(selection) ? selection : choices.first
                        DispatchQueue.main.async { menuFocused = true }
                    }
                    .onKeyPress(.return) {
                        guard let focusedChoice else { return .ignored }
                        selection = focusedChoice; presented = false; return .handled
                    }
                    .onKeyPress(.downArrow) { moveFocus(1); return .handled }
                    .onKeyPress(.upArrow) { moveFocus(-1); return .handled }
                    .onExitCommand { presented = false }
            }
    }
    private func moveFocus(_ offset: Int) {
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex(of: focusedChoice ?? selection) ?? 0
        focusedChoice = choices[min(max(0, current + offset), choices.count - 1)]
    }

}


enum ComposerMode: String, CaseIterable {
    case image = "Image", video = "Video", agent = "Agent"
    var symbol: String {
        switch self { case .image: "photo"; case .video: "video"; case .agent: "terminal" }
    }
}

/// Stable capsule footprint; only the selected mode expands to show its label.
struct ComposerModeSelector: View {
    let selection: ComposerMode
    var showsAgent = true
    let select: (ComposerMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight
    @AppStorage("interfaceMotion") private var interfaceMotion = true
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ComposerMode.allCases.filter { showsAgent || $0 != .agent }, id: \.self) { mode in
                Button { select(mode) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbol).font(.system(size: 13, weight: .medium))
                        if selection == mode { Text(mode.rawValue).font(.system(size: 12, weight: .medium)).fixedSize() }
                    }
                    .foregroundStyle(selection == mode ? DeskColor.ink : DeskColor.muted)
                    .frame(width: selection == mode ? 82 : 36, height: 32)
                    .background {
                        if selection == mode {
                            Capsule().fill(DeskColor.composer.opacity(0.55))
                                .overlay(Capsule().strokeBorder(DeskColor.ink.opacity(0.07), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "selected", in: highlight, properties: reduceMotion || !interfaceMotion ? [] : .frame)
                        }
                    }
                    .contentShape(Capsule())
                }.buttonStyle(.plain).help(mode.rawValue)
                    .accessibilityLabel(mode.rawValue + " mode")
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }.padding(3).deskGlass(radius: 24).fixedSize()
            .animation(reduceMotion ? nil : DeskMotion.selection(reduced: false, enabled: interfaceMotion), value: selection)
            .accessibilityElement(children: .contain).accessibilityLabel("Creation mode")
    }
}
