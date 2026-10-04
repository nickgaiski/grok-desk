import SwiftUI

struct SessionRowButton: View {
    var title: String
    var time: String
    var selected: Bool
    var repositoryContext: String? = nil
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("interfaceMotion") private var interfaceMotion = true

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(selected ? DeskColor.ink.opacity(0.7) : DeskColor.muted.opacity(0.4)).frame(width: 3, height: 3)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? DeskColor.ink : DeskColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let repositoryContext { Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(DeskColor.select).help(repositoryContext).accessibilityLabel(repositoryContext) }
                Text(time)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DeskColor.muted)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 29)
            .background(
                selected ? DeskColor.row : hovered ? DeskColor.row : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
            .animation(DeskMotion.feedback(reduced: reduceMotion, enabled: interfaceMotion), value: hovered)
            .animation(DeskMotion.feedback(reduced: reduceMotion, enabled: interfaceMotion), value: selected)
        .help(title)
    }
}

struct ProjectHeaderButton: View {
    var name: String
    var path: String
    var count: Int
    var isOpen: Bool
    var selected: Bool
    var enabled: Bool
    var action: () -> Void
    var toggle: () -> Void
    var newChat: () -> Void
    var edit: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("interfaceMotion") private var interfaceMotion = true
    @State private var details = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: hovered ? (isOpen ? "chevron.down" : "chevron.right") : "folder")
                    .font(.system(size: 11, weight: .light)).frame(width: 20, height: 28)
            }.buttonStyle(.plain).accessibilityLabel("\(isOpen ? "Collapse" : "Expand") \(name)")
            Button(action: action) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(DeskColor.ink)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled)
            Button { details.toggle() } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 18, height: 26) }
                .buttonStyle(.plain).opacity(hovered || details ? 1 : 0.3).help("Project details").accessibilityLabel("Project details for \(name)")
                .popover(isPresented: $details, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(name, systemImage: "folder").font(.system(size: 13, weight: .medium))
                        Text("\(count) chat\(count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                        Divider()
                        Label(path, systemImage: "folder").font(.system(size: 11)).foregroundStyle(DeskColor.muted).textSelection(.enabled).lineLimit(4)
                        Divider()
                        Button { details = false; newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }.buttonStyle(DeskMenuRowStyle()).disabled(!enabled)
                        Button { details = false; edit() } label: { Label("Edit project", systemImage: "slider.horizontal.3") }.buttonStyle(DeskMenuRowStyle())
                    }.padding(16).frame(width: 260, alignment: .leading).deskPopup().foregroundStyle(DeskColor.ink)
                }
            Button(action: newChat) { Image(systemName: "square.and.pencil").font(.system(size: 11)).frame(width: 18, height: 26) }
                .buttonStyle(.plain).disabled(!enabled).opacity(hovered ? 1 : 0.3).help("New chat in \(name)").accessibilityLabel("New chat in \(name)")
        }.foregroundStyle(DeskColor.muted).padding(.horizontal, 8)
            .background(selected || hovered ? DeskColor.row : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(DeskMotion.feedback(reduced: reduceMotion, enabled: interfaceMotion), value: hovered)
            .animation(DeskMotion.feedback(reduced: reduceMotion, enabled: interfaceMotion), value: selected)
    }
}
