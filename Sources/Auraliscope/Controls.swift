import AnalysisCore
import SwiftUI

/// Toolbar-only light styling; panel controls and every dark appearance keep their existing treatment.
private struct ToolbarControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var toolbarControls: Bool {
        get { self[ToolbarControlsKey.self] }
        set { self[ToolbarControlsKey.self] = newValue }
    }
}

/// A row of choices on a glass capsule: the Stereo | Immersive switch (`large`) and panel settings.
/// Each segment is a plain button
/// sized to its label, so nothing is cropped in any language, and carries its full name for VoiceOver.
struct GlassSegments<Value: Hashable>: View {
    let label: String
    /// Value, the title shown, and the full name for accessibility.
    let options: [(Value, String, String)]
    let selection: Value
    let select: (Value) -> Void
    var large = false
    @Environment(\.toolbarControls) private var toolbar
    @Namespace private var thumb
    @State private var hovered: Value?

    /// A recessed capsule track with a sliding selected plate. The light toolbar uses ink without a halo;
    /// dark mode and panel controls retain their glowing plate.
    var body: some View {
        let height: CGFloat = large ? 24 : 20
        let inner = height / 2
        let outer = inner + 2
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { value, title, name in
                let chosen = value == selection
                Button {
                    guard !chosen else { return }
                    withAnimation(.formatShift) { select(value) }
                } label: {
                    Text(verbatim: title)
                        .font(.system(size: large ? 13 : 11, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? (toolbar && !Theme.dark ? Color.white : Theme.onLit) : (hovered == value ? Theme.ink : Theme.secondary))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, large ? 13 : 10)
                        .frame(height: height)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: inner, style: .continuous)
                            if chosen {
                                shape.fill(toolbar && !Theme.dark ? Theme.ink : Theme.lit)
                                    .overlay {
                                        if Theme.isConsole {
                                            shape.gradientBorder(LinearGradient(colors: [.white.opacity(0.62), .black.opacity(0.32)],
                                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1)
                                        }
                                    }
                                    .shadow(color: toolbar && !Theme.dark ? .clear : Theme.litHalo, radius: 6)
                                    .shadow(color: .black.opacity(Theme.dark ? 0.0 : 0.16), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            } else if hovered == value {
                                shape.fill(Theme.controlHover)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
                }
                .buttonStyle(PressScale(scale: 0.95))
                .onHover { inside in
                    withAnimation(Motion.hover) { hovered = inside ? value : (hovered == value ? nil : hovered) }
                }
                .accessibilityLabel(name)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .fixedSize()
        .background { DockTrack(radius: outer) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The recessed capsule a group of controls sits in: the segments' track and the toolbar's docks. Pressed into the
/// surface: shade falls inside its upper-left edge and light inside its lower right (`InsetShading`), and a hairline of
/// light along its lower edge catches the rim.
struct DockTrack: View {
    var radius: CGFloat
    var tint: Color? = nil
    @Environment(\.toolbarControls) private var toolbar
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = Theme.dark
        shape.fill(tint ?? (toolbar && !dark ? Color.white.opacity(0.28) : Theme.trackFill))
            .overlay { shape.fill(InsetShading.gradient(strength: dark ? 0.9 : 0.8)) }
            .overlay {
                if Theme.isConsole {
                    shape.gradientBorder(LinearGradient(colors: [.black.opacity(dark ? 0.70 : 0.30),
                                                                 .white.opacity(dark ? 0.16 : 0.80)],
                                                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .overlay {
                shape.gradientBorder(LinearGradient(colors: [Theme.hairline.opacity(dark ? 0.0 : 0.08),
                                                             Color.white.opacity(dark ? 0.09 : (toolbar ? 0.45 : 0.9))],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            }
    }
}

/// The shading of a surface pressed in: shade along the upper-left edge, light along the lower right. A gradient fill,
/// which SwiftUI draws with the rest of the window; an inner shadow (`ShapeStyle.shadow(.inner)`) would be rasterized
/// on the CPU each time its control redraws.
enum InsetShading {
    static func gradient(strength: Double) -> LinearGradient {
        LinearGradient(stops: [.init(color: Theme.neuShade.opacity(0.55 * strength), location: 0),
                               .init(color: .clear, location: 0.42),
                               .init(color: .clear, location: 0.7),
                               .init(color: Theme.neuLight.opacity(0.6 * strength), location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Whether the button a disc face belongs to is held down (`DiscPress`).
private struct DiscPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var discPressed: Bool {
        get { self[DiscPressedKey.self] }
        set { self[DiscPressedKey.self] = newValue }
    }
}

/// A disc button's press: it hands the pressed state to its face, which sinks into its track.
struct DiscPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.discPressed, configuration.isPressed)
    }
}

/// A round button: an SF Symbol on a disc that rises under the pointer, sinks while pressed and lights
/// (`Theme.lit`) when its state is on, with a halo on dark; its symbol bounces as a click lands and morphs into the
/// next when the state swaps it (pin ↔ pin.fill, pause ↔ play). The toolbar's transport and window buttons and the
/// panels' settings buttons are all this one shape.
struct DiscButton: View {
    let symbol: String
    let help: String
    var diameter: CGFloat = Theme.dockButton
    /// The state the button shows: lit while on.
    var on = false
    /// A solid fill in a meaning colour instead of the lit plate (the resume button in the accent); nil otherwise.
    var fill: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            DiscFace(symbol: symbol, diameter: diameter, hovering: hovering, lit: on, fill: fill, bounce: taps)
        }
        .buttonStyle(DiscPress())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .animation(Motion.state, value: on)
        .animation(Motion.state, value: fill == nil)
        .animation(Motion.state, value: symbol)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A round control's face: `DiscButton`'s, and the menus' that look like one (the layout and panel window controls).
/// At rest a quiet disc in its track; under the pointer it rises out of it (a face lit from the upper left, shade
/// cast to the lower right); held down it sinks into it, its shade now inside the upper edge. Lit or filled, it glows.
struct DiscFace: View {
    @Environment(\.toolbarControls) private var toolbar
    @Environment(\.discPressed) private var pressed
    let symbol: String
    var diameter: CGFloat = 22
    var hovering = false
    var lit = false
    /// A solid fill in a meaning colour instead of the lit plate; nil otherwise.
    var fill: Color? = nil
    /// Bounces the symbol each time it changes (a click).
    var bounce = 0

    var body: some View {
        let lightToolbar = toolbar && !Theme.dark
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .modifier(SymbolMotion(bounce: bounce))
            .foregroundStyle(fill != nil ? Theme.onAction : (lit ? (lightToolbar ? Color.white : Theme.onLit) : (hovering || lightToolbar ? Theme.ink : Theme.secondary)))
            .frame(width: diameter, height: diameter)
            .background {
                if Theme.isConsole {
                    ConsoleDiscSurface(face: fill ?? (lit ? (lightToolbar ? Theme.ink : Theme.lit) : Theme.controlFill),
                                       pressed: pressed, hovering: hovering, illuminated: lit || fill != nil)
                } else if let fill {
                    Circle().fill(fill)
                        .shadow(color: Theme.glow(fill, 0.6), radius: 10)
                        .shadow(color: .black.opacity(Theme.dark ? 0 : 0.18), radius: 2, y: 1)
                } else if lit {
                    Circle().fill(lightToolbar ? Theme.ink : Theme.lit)
                        .shadow(color: lightToolbar ? .clear : Theme.litHalo, radius: pressed ? 6 : 11)
                        .shadow(color: .black.opacity(Theme.dark ? 0 : 0.18), radius: 2, y: 1)
                } else if pressed {
                    // Sunk into the track.
                    Circle().fill(Theme.controlFill)
                        .overlay { Circle().fill(InsetShading.gradient(strength: 1.2)) }
                } else if hovering {
                    // Risen out of it.
                    Circle().fill(Theme.raisedFace)
                        .overlay { Circle().gradientBorder(Theme.controlRim, lineWidth: 0.5) }
                        .shadow(color: Theme.neuShade.opacity(0.8), radius: 3, x: 1, y: 2)
                        .shadow(color: Theme.neuLight, radius: 2, x: -1, y: -1)
                } else {
                    Circle().fill(lightToolbar && !Theme.isConsole ? Color.clear : Theme.controlFill)
                        .overlay { if !lightToolbar || Theme.isConsole { Circle().gradientBorder(Theme.controlRim, lineWidth: 0.5) } }
                }
            }
            .scaleEffect(pressed ? 0.9 : (hovering && fill == nil && !lit ? 1.04 : 1))
            .animation(Motion.press, value: pressed)
            .contentShape(Circle())
    }
}

/// Diagnostics (`--render-controls <png>`): the disc button at rest, under the pointer, pressed, lit and filled, and
/// the segments on their track, on a panel and in the toolbar, in the dark appearance above the light one.
@MainActor
enum ControlStateSheet {
    static func write(to url: URL) -> Bool {
        var images: [CGImage] = []
        for dark in [true, false] {
            Theme.resolve(palette: Theme.palette, dark: dark)
            let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            guard let image = renderer.cgImage else { return false }
            images.append(image)
        }
        let width = images.map(\.width).max() ?? 0, height = images.map(\.height).reduce(0, +)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        var top = height
        for image in images {
            top -= image.height
            context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
        }
        guard let sheet = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print(url.path)
        return true
    }

    private static var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(toolbar: false)
            row(toolbar: true)
        }
        .padding(18)
        .background { WindowBackdrop() }
    }

    private static func row(toolbar: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            state("rest") { DiscFace(symbol: "pin", diameter: Theme.dockButton) }
            state("hover") { DiscFace(symbol: "pin", diameter: Theme.dockButton, hovering: true) }
            state("pressed") { DiscFace(symbol: "pin", diameter: Theme.dockButton).environment(\.discPressed, true) }
            state("lit") { DiscFace(symbol: "pin.fill", diameter: Theme.dockButton, lit: true) }
            state("filled") { DiscFace(symbol: "play.fill", diameter: Theme.dockButton, fill: Theme.action) }
            state("segments") {
                GlassSegments(label: "", options: [(0, "Stereo", "Stereo"), (1, "Immersive", "Immersive")],
                              selection: 0, select: { _ in }, large: toolbar)
            }
            state("track") { DockTrack(radius: 16).frame(width: 90, height: 32) }
        }
        .padding(14)
        .background { if !toolbar { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.cardTint) } }
        .environment(\.toolbarControls, toolbar)
    }

    private static func state<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
            Text(verbatim: name).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
        }
    }
}
