import AppKit
import SwiftUI

/// Semantic colors resolve against the window appearance, including sheets and menus.
enum DeskColor {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let window = adaptive(0xF6F8FC, 0x17191E)
    static let sidebar = adaptive(0xEAF0F8, 0x20232B)
    static let composer = adaptive(0xFFFFFF, 0x2A2E37)
    static let ink = adaptive(0x171D2C, 0xEDF1F8)
    static let muted = adaptive(0x606E86, 0xA4AEC1)
    static let brass = adaptive(0x222B3C, 0xDFE7F4)
    static let inkOnBrass = adaptive(0xFFFFFF, 0x202635)
    static let danger = adaptive(0xAE3838, 0xEF9692)
    static let select = adaptive(0x376BC2, 0x9ABCF4)
    static let hairline = adaptive(0xDCE3EE, 0x3A404D).opacity(0.7)
    static let row = adaptive(0xDFE7F3, 0x343B49).opacity(0.55)
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content.background { LiquidGlassBackdrop(radius: radius) }
    }
}

extension View {
    func deskGlass(radius: CGFloat = 16) -> some View { modifier(GlassSurface(radius: radius)) }
}

struct DeskButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? DeskColor.inkOnBrass : DeskColor.ink)
            .padding(.horizontal, prominent ? 16 : 11).frame(height: prominent ? 34 : 30)
            .background(prominent ? DeskColor.brass : DeskColor.row.opacity(configuration.isPressed ? 1 : 0.5), in: RoundedRectangle(cornerRadius: prominent ? 17 : 8))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 17 : 8).stroke(prominent ? Color.clear : DeskColor.hairline, lineWidth: 0.5))
            .opacity(enabled ? (configuration.isPressed ? 0.88 : 1) : 0.35)
            .modifier(DeskInteraction(pressed: configuration.isPressed, radius: prominent ? 17 : 8, hoverFill: !prominent))
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .foregroundStyle(DeskColor.muted)
            .padding(.horizontal, 7).frame(height: 28)
            .background(configuration.isPressed ? DeskColor.row : .clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.4)
            .modifier(DeskInteraction(pressed: configuration.isPressed, radius: 7))
    }
}
