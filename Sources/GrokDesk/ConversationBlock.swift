import AppKit
import GrokDeskCore
import SwiftUI

struct ConversationBlock: View {
    let block: ChatBlock
    @State private var expanded = false
    @State private var hovered = false
    var body: some View {
        Group {
            if block.kind == "user" {
                HStack {
                    Spacer(minLength: 48)
                    Text(block.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(DeskColor.composer.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
                }
            } else if block.kind == "thought" || block.kind == "tool" {
                VStack(alignment: .leading, spacing: 8) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: block.kind == "tool" ? "terminal" : "sparkle").font(.system(size: 10))
                            Text(block.kind == "thought" ? "Thinking" : String(block.text.split(separator: "\n").first ?? "Tool activity"))
                                .font(.system(size: 11)).lineLimit(1)
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                            Spacer()
                        }.foregroundStyle(DeskColor.muted)
                    }.buttonStyle(.plain)
                    if expanded {
                        Text(block.text).font(.system(size: 12, design: block.kind == "tool" ? .monospaced : .default))
                            .foregroundStyle(DeskColor.muted).textSelection(.enabled)
                            .padding(.leading, 17)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    MarkdownMessage(text: block.text)
                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Copy response")
                        if block.kind == "plan" { Text("Plan").font(.system(size: 10)) }
                    }.foregroundStyle(DeskColor.muted.opacity(hovered ? 1 : 0.55))
                }
            }
        }
        .foregroundStyle(DeskColor.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
    }
}

/// Lightweight native Markdown layout. Keeps the transcript SwiftUI and text selectable.
struct MarkdownMessage: View {
    let text: String
    private struct Part: Identifiable {
        var id: Int
        var kind: String
        var text: String
        var depth = 0
    }
    private var parts: [Part] {
        var result: [Part] = [], buffer: [String] = []
        var code = false, language = ""
        func flush(_ kind: String = "paragraph") {
            if !buffer.isEmpty { result.append(Part(id: result.count, kind: kind == "paragraph" && buffer.first?.hasPrefix("|") == true ? "table" : kind, text: buffer.joined(separator: "\n"))); buffer = [] }
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if code { flush("code:" + language); code = false }
                else { flush(); code = true; language = String(line.dropFirst(3)) }
            } else if code { buffer.append(line) }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else if line.hasPrefix("#") {
                flush()
                let depth = line.prefix(while: { $0 == "#" }).count
                result.append(Part(id: result.count, kind: "heading", text: String(line.dropFirst(depth)).trimmingCharacters(in: .whitespaces), depth: depth))
            } else if line.trimmingCharacters(in: .whitespaces) == "---" { flush(); result.append(Part(id: result.count, kind: "divider", text: "")) }
            else if line.hasPrefix("|") {
                if !buffer.isEmpty && !buffer[0].hasPrefix("|") { flush() }
                buffer.append(line)
            } else {
                if !buffer.isEmpty && buffer[0].hasPrefix("|") { flush("table") }
                buffer.append(line)
            }
        }
        flush(code ? "code:" + language : buffer.first?.hasPrefix("|") == true ? "table" : "paragraph")
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(parts) { part in
                if part.kind == "heading" {
                    inline(part.text).font(.system(size: part.depth == 1 ? 22 : part.depth == 2 ? 18 : 15, weight: .semibold))
                        .padding(.top, 6)
                } else if part.kind == "divider" { Divider().overlay(DeskColor.hairline) }
                else if part.kind.hasPrefix("code:") { codeBlock(part.text, language: String(part.kind.dropFirst(5))) }
                else if part.kind == "table" { table(part.text) }
                else { inline(part.text).font(.system(size: 14)).lineSpacing(6) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).tint(DeskColor.select)
    }
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
    private func codeBlock(_ text: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.system(size: 10))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10)) }.buttonStyle(.plain)
            }.foregroundStyle(DeskColor.muted).padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(DeskColor.hairline)
            ScrollView(.horizontal) { Text(text).font(.system(size: 12, design: .monospaced)).lineSpacing(4).padding(12) }
        }.background(DeskColor.row, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeskColor.hairline, lineWidth: 1))
    }
    private func table(_ text: String) -> some View {
        let rows = text.components(separatedBy: "\n").filter { line in
            !line.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces).isEmpty
        }.map { $0.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) } }
        return Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inline(cell).font(.system(size: 12, weight: index == 0 ? .medium : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    }
                }
                Divider().overlay(DeskColor.hairline)
            }
        }
    }
}
