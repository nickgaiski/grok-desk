import SwiftUI

private enum GlassAssets {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("GrokDesk_GrokDesk.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return .module
    }()
}

private struct GlassSceneSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 1280, height: 800)
}
extension EnvironmentValues {
    var glassSceneSize: CGSize {
        get { self[GlassSceneSizeKey.self] }
        set { self[GlassSceneSizeKey.self] = newValue }
    }
}

/// One clock and coordinate system keep each refracted surface registered to the background.
struct LiquidField: View {
    var radius: CGFloat = 0
    var lens = false
    @AppStorage("ambientBackground") private var enabled = true
    @AppStorage("ambientPreset") private var preset = 0
    @AppStorage("ambientMotion") private var motion = true
    @AppStorage("performanceMode") private var performanceMode = false
    @AppStorage("glassLight") private var light = 0.7
    @AppStorage("glassRefraction") private var refraction = 28.0
    @AppStorage("glassDepth") private var depth = 18.0
    @AppStorage("glassDispersion") private var dispersion = 0.65
    @AppStorage("glassFrost") private var frost = 0.12
    @AppStorage("glassSplay") private var splay = 1.4
    @Environment(\.glassSceneSize) private var scene
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var phase
    private static let epoch = Date()
    var body: some View {
        GeometryReader { geometry in
            if performanceMode {
                Rectangle().fill(LinearGradient(colors: [DeskColor.window, DeskColor.sidebar, DeskColor.composer], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motion || reduceMotion || phase != .active || !enabled || reduceTransparency)) { context in
                let rect = geometry.frame(in: .named("glassScene"))
                let time = motion && !reduceMotion ? context.date.timeIntervalSince(Self.epoch) : 0
                Rectangle().fill(.white)
                    .colorEffect(ShaderLibrary.bundle(GlassAssets.bundle).liquidField(
                        .float2(geometry.size), .float2(rect.origin), .float2(scene),
                        .float(time), .float(Double(preset)), .float(scheme == .dark ? 1.0 : 0.0),
                        .float(enabled && !reduceTransparency ? 1.0 : 0.0), .float(radius), .float(lens ? 1.0 : 0.0),
                        .float(light), .float(refraction), .float(depth), .float(dispersion), .float(frost), .float(splay)
                    ))
            }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct LiquidGlassBackdrop: View {
    var radius: CGFloat
    @AppStorage("glassDispersion") private var dispersion = 0.65
    @AppStorage("ambientMotion") private var motion = true
    @AppStorage("performanceMode") private var performanceMode = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var phase
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    var body: some View {
        Group {
            if reduceTransparency || performanceMode { shape.fill(DeskColor.composer) }
            else if #available(macOS 26.0, *) {
                // Native glass also refracts content that crosses behind the panel.
                LiquidField(radius: radius, lens: true).opacity(0.70)
                    .clipShape(shape)
                    .glassEffect(.clear, in: shape)
            } else {
                LiquidField(radius: radius, lens: true).clipShape(shape)
            }
        }
        .overlay {
            if performanceMode {
                shape.strokeBorder(DeskColor.hairline, lineWidth: 1)
            } else if !reduceTransparency {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motion || reduceMotion || phase != .active)) { context in
                    let time = motion && !reduceMotion ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18) : 1.75
                    GeometryReader { geometry in
                        shape.strokeBorder(.white, lineWidth: 1.2)
                            .colorEffect(ShaderLibrary.bundle(GlassAssets.bundle).glassRim(
                                .float2(geometry.size), .float(time), .float(dispersion)))
                    }
                }
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: performanceMode ? 3 : 18, y: performanceMode ? 1 : 7)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct GlassSettings: View {
    @AppStorage("interfaceMotion") private var interfaceMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("ambientBackground") private var enabled = true
    @AppStorage("ambientPreset") private var preset = 0
    @AppStorage("ambientMotion") private var motion = true
    @AppStorage("performanceMode") private var performanceMode = false
    @AppStorage("glassLight") private var light = 0.7
    @AppStorage("glassRefraction") private var refraction = 28.0
    @AppStorage("glassDepth") private var depth = 18.0
    @AppStorage("glassDispersion") private var dispersion = 0.65
    @AppStorage("glassFrost") private var frost = 0.12
    @AppStorage("glassSplay") private var splay = 1.4
    private let names = ["Iris", "Tide", "Dusk", "Silver"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Appearance")
                Spacer()
                Picker("Appearance", selection: $appearance) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            Toggle("Interface motion", isOn: $interfaceMotion).toggleStyle(.switch)
            Text(reduceMotion ? "Reduce Motion is on. Interface transitions use a short fade without scaling or travel." : "Gentle selection, press and panel transitions. Streaming text and the composer stay still.")
                .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            Toggle("Performance Mode", isOn: $performanceMode).toggleStyle(.switch)
            Text("Static lighting and simpler surfaces reduce rendering work. Your glass settings are preserved.")
                .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            Toggle("Gradient background", isOn: $enabled).toggleStyle(.switch)
            HStack(spacing: 10) {
                ForEach(0..<4) { index in
                    Button { preset = index } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: swatch(index), startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(height: 46)
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(preset == index ? DeskColor.select : .clear, lineWidth: 2))
                            Text(names[index]).font(.system(size: 11))
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Background: " + names[index])
                        .accessibilityAddTraits(preset == index ? .isSelected : [])
                }
            }.disabled(!enabled)
            Toggle("Animate background and reflections", isOn: $motion).toggleStyle(.switch)
            Text("Motion pauses while the window is inactive and follows Reduce Motion.")
                .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Live glass preview").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: "sparkles").foregroundStyle(DeskColor.muted) }
            Text(performanceMode ? "Performance Mode is on. Turn it off to preview refraction and lighting." : "Adjust the surface around these controls.")
                .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            Text("Glass").font(.system(size: 14, weight: .medium))
            control("Light", value: $light, range: 0...1.5)
            control("Refraction", value: $refraction, range: 0...70)
            control("Depth", value: $depth, range: 4...40)
            control("Dispersion", value: $dispersion, range: 0...2)
            control("Frost", value: $frost, range: 0...1)
            control("Splay", value: $splay, range: 0.4...3)
            Button("Reset glass") {
                light = 0.7; refraction = 28; depth = 18; dispersion = 0.65; frost = 0.12; splay = 1.4
            }.buttonStyle(QuietButton())
            }.padding(22).deskGlass(radius: 22)
                .coordinateSpace(name: "glassScene")
        }.font(.system(size: 12)).padding(16).foregroundStyle(DeskColor.ink)
    }
    private func control(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(name).frame(width: 76, alignment: .leading)
            GlassSlider(value: value, range: range, title: name).frame(height: 28)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                .monospacedDigit().foregroundStyle(DeskColor.muted).frame(width: 36, alignment: .trailing)
        }
    }
    private func swatch(_ index: Int) -> [Color] {
        switch index {
        case 0: [.init(red: 0.6, green: 0.7, blue: 1), .init(red: 0.85, green: 0.7, blue: 0.92), .init(red: 1, green: 0.8, blue: 0.65)]
        case 1: [.teal.opacity(0.6), .blue.opacity(0.4), .mint.opacity(0.4)]
        case 2: [.orange.opacity(0.5), .pink.opacity(0.4), .purple.opacity(0.4)]
        default: [.gray.opacity(0.3), .blue.opacity(0.25), .white]
        }
    }
}
