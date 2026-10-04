import AppKit
import SwiftUI

struct ProjectEditor: View {
    @State var name: String
    @State var path: String
    let save: (String, URL) throws -> Void
    @State private var error: String?
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(editing ? "Edit project" : "Create project").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction).accessibilityLabel("Close project dialog")
            }
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(DeskColor.muted)
                TextField("Project name", text: $name).textFieldStyle(.plain).focused($nameFocused).font(.system(size: 13))
            }.padding(12).background(DeskColor.composer, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(nameFocused ? DeskColor.select.opacity(0.6) : DeskColor.hairline, lineWidth: 1))
            Text("Source folder").font(.system(size: 12, weight: .medium))
            VStack(spacing: 12) {
                if path.isEmpty {
                    Text("Add a folder on this computer").font(.system(size: 12)).foregroundStyle(DeskColor.muted)
                    Button { chooseFolder() } label: { Label("Add folder", systemImage: "folder.badge.plus") }.buttonStyle(DeskButtonStyle())
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").font(.system(size: 18, weight: .light)).foregroundStyle(DeskColor.muted)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13, weight: .medium))
                            Text(path).font(.system(size: 11)).foregroundStyle(DeskColor.muted).lineLimit(3).textSelection(.enabled)
                        }
                        Spacer()
                        if !editing { Button("Change") { chooseFolder() }.buttonStyle(QuietButton()) }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity).frame(minHeight: 94)
                .background(DeskColor.sidebar, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskColor.hairline, lineWidth: 1))
            Text("Chats in this project run in this folder. Use New Folder in the picker to create a directory.")
                .font(.system(size: 11)).foregroundStyle(DeskColor.muted).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(DeskColor.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
                Button(editing ? "Save changes" : "Create project") {
                    do { try save(name.trimmingCharacters(in: .whitespacesAndNewlines), URL(fileURLWithPath: path)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(DeskButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }.padding(.top, 10)
        }.padding(24).frame(width: 470).deskPopup(radius: 22).foregroundStyle(DeskColor.ink)
            .onAppear { editing = !path.isEmpty; nameFocused = true }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.message = "Choose a source folder, or create a new one."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        path = folder.path
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = folder.lastPathComponent }
    }
}
