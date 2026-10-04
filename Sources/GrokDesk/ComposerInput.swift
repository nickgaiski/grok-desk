import AppKit
import GrokDeskCore
import SwiftUI

struct ComposerInput: View {
    @Binding var text: String
    let placeholder: String
    var accessibilityName = "Message Grok"
    var canSubmit = true
    let submit: () -> Void
    let attach: ([URL]) -> Void
    let reportError: (String) -> Void
    @State private var height: CGFloat = 46
    var body: some View {
        NativeComposer(text: $text, height: $height, placeholder: placeholder,
            accessibilityName: accessibilityName, canSubmit: canSubmit, submit: submit, attach: attach, reportError: reportError)
            .frame(height: height).frame(maxWidth: .infinity)
    }
}

private struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let accessibilityName: String
    let canSubmit: Bool
    let submit: () -> Void
    let attach: ([URL]) -> Void
    let reportError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 46))
        editor.isRichText = false; editor.drawsBackground = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: 14); editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PromptTextView else { return }
        context.coordinator.parent = self
        editor.placeholder = placeholder; editor.canSubmit = canSubmit
        editor.submit = submit; editor.attach = attach; editor.reportError = reportError
        editor.setAccessibilityLabel(accessibilityName)
        if editor.string != text {
            let location = min(editor.selectedRange().location, (text as NSString).length)
            editor.string = text; editor.setSelectedRange(NSRange(location: location, length: 0))
        }
        editor.needsDisplay = true
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        init(_ parent: NativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PromptTextView else { return }
            parent.text = editor.string; editor.needsDisplay = true; measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let next = min(150, max(46, layout.usedRect(for: container).height + 10))
            if abs(parent.height - next) > 1 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = next }
            }
        }
    }
}

private final class PromptTextView: NSTextView {
    var placeholder = ""
    var canSubmit = true
    var submit: (() -> Void)?
    var attach: (([URL]) -> Void)?
    var reportError: ((String) -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else if canSubmit { submit?() }
            return
        }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        do {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Grok Desk/attachments")
            if let urls = try clipboardAttachments(from: .general, directory: folder) { attach?(urls); return }
            pasteAsPlainText(sender)
        } catch { reportError?(error.localizedDescription) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(in: NSRect(x: 5, y: 4, width: max(0, bounds.width - 10), height: 32), withAttributes: attributes)
        }
    }
}
