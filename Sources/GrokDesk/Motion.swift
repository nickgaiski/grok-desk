import SwiftUI

/// Motion describes changes of state; it never drives streaming text or moves the input dock.
enum DeskMotion {
    static func feedback(reduced: Bool, enabled: Bool) -> Animation? {
        enabled ? .easeOut(duration: reduced ? 0.04 : 0.08) : nil
    }
    static func selection(reduced: Bool, enabled: Bool) -> Animation? {
        guard enabled else { return nil }
        return reduced ? .easeOut(duration: 0.1) : .spring(response: 0.20, dampingFraction: 0.92)
    }
    static func presentation(reduced: Bool, enabled: Bool) -> Animation? {
        guard enabled else { return nil }
        return reduced ? .easeOut(duration: 0.1) : .spring(response: 0.24, dampingFraction: 1)
    }
    static func reveal(reduced: Bool, enabled: Bool, anchor: UnitPoint = .center) -> AnyTransition {
        guard enabled, !reduced else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.975, anchor: anchor)), removal: .opacity)
    }
}

struct DeskInteraction: ViewModifier {
    var pressed = false
    var radius: CGFloat = 8
    var hoverFill = true
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @AppStorage("interfaceMotion") private var motion = true
    func body(content: Content) -> some View {
        content
            // Match the full hover surface, including padding and spacers.
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DeskColor.ink.opacity(enabled && hovered && hoverFill ? 0.045 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(pressed && enabled && motion && !reduced ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(pressed ? nil : DeskMotion.feedback(reduced: reduced, enabled: motion), value: pressed)
            .animation(DeskMotion.feedback(reduced: reduced, enabled: motion), value: hovered)
    }
}

/// Material, inset highlight and radii shared by app-owned sheets and popovers.
struct DeskPopupSurface: ViewModifier {
    var radius: CGFloat
    var elevated: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var scheme
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    func body(content: Content) -> some View {
        content
            .background {
                if opaque { shape.fill(DeskColor.window) }
                else {
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(DeskColor.window.opacity(scheme == .dark ? 0.5 : 0.62)))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(DeskColor.ink.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 0.5).allowsHitTesting(false))
            .overlay(alignment: .top) {
                shape.strokeBorder(.white.opacity(scheme == .dark ? 0.09 : 0.65), lineWidth: 0.5)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(elevated ? (scheme == .dark ? 0.3 : 0.12) : 0), radius: 24, y: 10)
    }
}

struct DeskMenuRowStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(DeskColor.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(selected || configuration.isPressed ? DeskColor.row : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .modifier(DeskInteraction(pressed: configuration.isPressed, radius: 8))
    }
}

extension View {
    func deskPopup(radius: CGFloat = 16, elevated: Bool = false) -> some View {
        modifier(DeskPopupSurface(radius: radius, elevated: elevated))
    }
    func deskHover(radius: CGFloat = 8) -> some View { modifier(DeskInteraction(radius: radius)) }
}
