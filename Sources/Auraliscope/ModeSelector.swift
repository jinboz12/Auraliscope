import SwiftUI

extension FormatMode {
    /// Name in Settings and menus, in the current language (立体声, 스테레오…).
    var title: String {
        switch self {
        case .auto: return L("Auto")
        case .mono: return L("Mono")
        case .stereo: return L("Stereo")
        case .spatial: return L("Multi Channel")
        }
    }
}

extension ChannelFormat {
    /// Label on the meter window, which keeps its English vocabulary in every language.
    var title: String {
        switch self {
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        case .spatial: return "Multi Channel"
        }
    }

    /// Name in tooltips and accessibility text, in the current language.
    var localizedName: String { FormatMode(self).title }

    /// The selector's label: "Multi Channel" is shortened to fit its segment; the full name is its tooltip and
    /// accessibility label.
    var shortTitle: String {
        self == .spatial ? "Multi-Ch" : title
    }

    /// Segment order in the selector, narrowest programme first.
    static let selectorOrder: [ChannelFormat] = [.mono, .stereo, .spatial]
}

/// Pointer state for the selector. `@State` is unavailable with this toolchain, so it lives in a tiny object.
final class HoverState: ObservableObject {
    @Published var segment: ChannelFormat?
    @Published var auto = false
}

/// Top-bar monitoring mode: a three-segment Mono | Stereo | Spatial control with a lit thumb that follows the
/// effective mode, plus an AUTO toggle. Clicking a segment pins it; AUTO hands control back to the detector.
/// Every part has a fixed size, so switching never moves the toolbar.
struct ModeSelector: View {
    static let segmentWidth: CGFloat = 88
    static let height: CGFloat = 28

    @ObservedObject var model: MeterModel
    @StateObject private var hover = HoverState()
    @ObservedObject private var l10n = Localizer.shared
    /// The toolbar sits outside the meter view, so it follows palette and appearance changes itself.
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some View {
        let format = model.format
        let slot = CGFloat(ChannelFormat.selectorOrder.firstIndex(of: format) ?? 1)
        let count = CGFloat(ChannelFormat.selectorOrder.count)
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Thumb()
                    .frame(width: Self.segmentWidth - 4, height: Self.height - 4)
                    .offset(x: slot * Self.segmentWidth + 2)
                    .animation(.spring(response: 0.38, dampingFraction: 0.8), value: format)
                HStack(spacing: 0) {
                    ForEach(ChannelFormat.selectorOrder, id: \.self) { segment($0, active: $0 == format) }
                }
            }
            .frame(width: Self.segmentWidth * count, height: Self.height)
            .modifier(SelectorTrack())
            AutoToggle(auto: model.formatMode == .auto, hovered: hover.auto, detected: model.automaticFormat) {
                model.toggleAuto()
            }
            .onHover { hover.auto = $0 }
        }
        // The track and the AUTO key are sampled as one glass layer on macOS 26.
        .glassGroup(spacing: 6)
        .id(theme.signature)
    }

    private func segment(_ format: ChannelFormat, active: Bool) -> some View {
        let hovered = hover.segment == format
        return Button { model.pin(format) } label: {
            HStack(spacing: 7) {
                ModeIcon(format: format, color: active ? Theme.sage : (hovered ? Theme.ink : Theme.secondary), lit: active)
                Text(format.shortTitle)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Theme.ink : (hovered ? Theme.ink.opacity(0.85) : Theme.secondary))
                    .lineLimit(1)
            }
            .frame(width: Self.segmentWidth, height: Self.height)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.18), value: hovered)
            .animation(.easeOut(duration: 0.25), value: active)
        }
        .buttonStyle(PressStyle())
        .onHover { inside in
            if inside { hover.segment = format } else if hover.segment == format { hover.segment = nil }
        }
        .help(help(for: format))
        .accessibilityLabel(format.localizedName)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func help(for format: ChannelFormat) -> String {
        switch format {
        case .mono: return L("Monitor in Mono: one channel, read from the input routed to L")
        case .stereo: return L("Monitor in Stereo: L and R lead; other channels recede")
        case .spatial: return L("Monitor in Multi Channel: every channel of %@. Change the format in Settings ▸ Channels.", model.speakerLayout.name)
        }
    }
}

/// The capsule the segments sit in: Liquid Glass on macOS 26, a thin material with a rim before it. The glass
/// is the control's own surface, drawn behind its thumb and labels.
private struct SelectorTrack: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { Capsule().fill(Theme.hairline.opacity(Theme.dark ? 0.05 : 0.03)) }
            .glassSurface(Capsule())
    }
}

/// The raised key under the active mode: faintly lit on dark, a white key with a soft shadow on light, as the
/// selection of a native segmented control.
private struct Thumb: View {
    var body: some View {
        let dark = Theme.dark
        Capsule()
            .fill(LinearGradient(colors: dark ? [Theme.hairline.opacity(0.16), Theme.hairline.opacity(0.08)]
                                              : [Color.white, Color.white.opacity(0.92)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { Capsule().fill(Theme.sage.opacity(dark ? 0.12 : 0.08)) }
            .overlay {
                Capsule().strokeBorder(LinearGradient(colors: dark ? [Theme.ink.opacity(0.32), Theme.hairline.opacity(0.08)]
                                                                   : [Theme.hairline.opacity(0.06), Theme.hairline.opacity(0.16)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(dark ? 0.22 : 0.12), radius: 3, y: 1)
            .shadow(color: Theme.glow(Theme.sage, 0.20), radius: 8)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Geometric marks drawn in the soundstage's own language.
/// Mono: one front-centre source and a listener on a single line.
/// Stereo: two sources and a listener, the classic equilateral stage.
/// Spatial: the bed ring with five sources, an inner height ring and the listener.
struct ModeIcon: View {
    let format: ChannelFormat
    let color: Color
    var lit = false

    /// The mode glyphs share the logo's language: flat-topped hexagons with a vertex pointing left and right,
    /// counted in comb cells. One ring is Mono; two neighbouring rings are Stereo; a honeycomb of seven cells is
    /// Multi Channel.
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func hexagon(_ center: CGPoint, _ radius: CGFloat) -> Path {
                Path { path in
                    for corner in 0..<6 {
                        let angle = CGFloat(corner) * .pi / 3
                        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                        if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                }
            }
            /// A ring as in the logo: the hole is `hole` of the outer radius.
            func ring(_ center: CGPoint, _ radius: CGFloat, hole: CGFloat, _ opacity: Double = 1) {
                var shape = hexagon(center, radius)
                shape.addPath(hexagon(center, radius * hole))
                context.fill(shape, with: .color(color.opacity(opacity)), style: FillStyle(eoFill: true))
            }
            // The ring height fills the glyph box: a flat-topped hexagon is √3·r tall.
            let height = size.height - 1
            switch format {
            case .mono:
                ring(c, height / sqrt(3), hole: 0.62)
            case .stereo:
                // Two neighbouring comb cells, left-low and right-high, joined along one edge: flat-topped
                // cells neighbour at 30°, √3·r apart. The pair spans 3.5 r across and 2.6 r down.
                let radius = min(size.width / 3.5, height / 2.6)
                let dx = radius * 0.75, dy = radius * sqrt(3) / 4
                ring(CGPoint(x: c.x - dx, y: c.y + dy), radius * 0.93, hole: 0.52)
                ring(CGPoint(x: c.x + dx, y: c.y - dy), radius * 0.93, hole: 0.52)
            case .spatial:
                // Centre cell plus six neighbours; flat-topped cells neighbour at 30° + k·60°, √3·r apart.
                let cell = height / (3 * sqrt(3)) * 1.02
                let step = cell * sqrt(3)
                // Tight joints so the seven cells read as one comb; the centre cell (the listener) is quieter.
                context.fill(hexagon(c, cell * 0.87), with: .color(color.opacity(0.5)))
                for k in 0..<6 {
                    let angle = CGFloat.pi / 6 + CGFloat(k) * .pi / 3
                    let center = CGPoint(x: c.x + step * cos(angle), y: c.y + step * sin(angle))
                    context.fill(hexagon(center, cell * 0.87), with: .color(color))
                }
            }
        }
        .frame(width: 17, height: 15)
        .shadow(color: lit ? Theme.glow(Theme.sage, 0.55) : .clear, radius: 3)
        .accessibilityHidden(true)
    }
}

/// AUTO key: the system switch and its label. The switch is the native control, so it is the Liquid Glass switch
/// on macOS 26 (the knob turns to glass while it is pressed or dragged) and the classic switch on macOS 15 and
/// earlier. On, while the detector drives the mode, the switch shows the accent and the key is tinted and
/// outlined in it; off, the key is plain. Fixed size, so toggling never moves the toolbar.
private struct AutoToggle: View {
    let auto: Bool
    let hovered: Bool
    let detected: ChannelFormat
    let action: () -> Void
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 7) {
            Toggle(L("Auto mode"), isOn: Binding(get: { auto }, set: { if $0 != auto { action() } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.sage)
            // Clicking the title flips the switch, as it does beside any macOS switch.
            Button(action: action) {
                Text(verbatim: "AUTO")
                    .font(.system(size: 9, weight: auto ? .bold : .semibold).width(.expanded))
                    .tracking(Tracking.eyebrow)
                    .foregroundStyle(auto ? Theme.ink : (hovered ? Theme.secondary : Theme.tertiary))
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.leading, 7)
        .padding(.trailing, 11)
        .frame(height: ModeSelector.height)
        .background {
            ZStack {
                Capsule().fill(Theme.sage.opacity(auto ? (Theme.dark ? 0.24 : 0.16) : 0))
                Capsule().strokeBorder(Theme.sage.opacity(auto ? 0.85 : 0), lineWidth: 1)
            }
        }
        .modifier(SelectorTrack())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: auto)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .help(L("Auto: Mono when a single input is routed. Otherwise Multi Channel after 150 ms above −60 dBFS on any channel but L, R and LFE, and back to Stereo after 2.5 s of front-only programme. Silence holds the mode; LFE alone never switches it. Detected now: %@.", detected.localizedName))
    }
}
