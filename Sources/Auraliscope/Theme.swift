import AppKit
import SwiftUI

/// Light or dark, chosen in Settings ▸ Appearance, View ▸ Appearance or the toolbar. Auto follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    /// macOS's own names for the three choices.
    var title: String {
        switch self {
        case .system: return L("Auto")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// Owns the two appearance choices, the accent palette and light or dark, and resolves them into `Theme`.
/// A change resolves the palette once and republishes; the views that drew with the old one are rebuilt by
/// `.id(signature)`. Nothing in the audio path listens, so metering carries on.
@MainActor
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()
    nonisolated static let paletteKey = "colorTheme"
    nonisolated static let modeKey = "appearanceMode"

    @Published var palette: Theme.Palette {
        didSet {
            guard palette != oldValue else { return }
            UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteKey)
            resolve()
        }
    }
    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            applyToAppKit()
            resolve()
        }
    }
    /// The appearance on screen: `mode`, or macOS's own while it is Auto.
    @Published private(set) var dark: Bool
    private var observation: NSKeyValueObservation?

    private init() {
        palette = Theme.Palette.stored
        mode = AppearanceMode.stored
        dark = Theme.style.dark
        resolve()
    }

    /// Identity of the resolved palette: a change rebuilds whatever drew with the previous one.
    var signature: String { "\(palette.rawValue)-\(dark ? "dark" : "light")" }

    /// The toolbar button flips what is on screen, whether it came from Auto or was chosen.
    func toggle() { mode = dark ? .light : .dark }

    /// Called once AppKit is up: applies the choice to every window, menu and sheet, and follows macOS on Auto.
    func attach() {
        applyToAppKit()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resolve() } }
        }
        resolve()
    }

    private func applyToAppKit() {
        guard let app = NSApp else { return }
        switch mode {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func resolve() {
        let effective: Bool
        switch mode {
        case .dark: effective = true
        case .light: effective = false
        case .system:
            if let app = NSApp {
                effective = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            } else {
                effective = Theme.systemIsDark
            }
        }
        guard effective != Theme.style.dark || palette != Theme.style.palette else { return }
        Theme.resolve(palette: palette, dark: effective)
        if dark != effective { dark = effective } else { objectWillChange.send() }
    }
}

/// Auraliscope dashboard palette, in a dark and a light appearance.
///
/// - **Surfaces**: dark slate window, charcoal cards and obsidian display wells; or a pale grey window, white
///   cards and paper wells.
/// - **Ink** is the high-contrast voice for type, peak readouts and lit edges: the palette's cream on dark,
///   slate ink on light.
/// - The selected **accent** marks actions, selections, signal levels and the live summary.
///
/// Beyond those, hue carries meaning in only two places: level zones (accent → ochre → ember) and speaker
/// groups (bed accent, height heather, LFE clay). On light surfaces every hue is deepened just enough to read as
/// body text does (4.5 : 1), so a pale accent such as Starlight stays legible. Metal draws with the `RGB`
/// values, SwiftUI with the matching `Color`s, so both layers read as one surface.
enum Theme {
    struct RGB: Equatable {
        let r: Float, g: Float, b: Float
        init(r: Float, g: Float, b: Float) {
            self.r = r
            self.g = g
            self.b = b
        }
        init(hex: UInt32) {
            self.init(r: Float((hex >> 16) & 0xFF) / 255, g: Float((hex >> 8) & 0xFF) / 255, b: Float(hex & 0xFF) / 255)
        }
        var color: Color { Color(red: Double(r), green: Double(g), blue: Double(b)) }
        func simd(_ alpha: Float = 1) -> SIMD4<Float> { SIMD4(r, g, b, alpha) }
        func cgColor(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: alpha) }
        func scaled(_ amount: Float) -> RGB { RGB(r: r * amount, g: g * amount, b: b * amount) }
        func mixed(with other: RGB, amount: Float) -> RGB {
            RGB(r: r * (1 - amount) + other.r * amount,
                g: g * (1 - amount) + other.g * amount,
                b: b * (1 - amount) + other.b * amount)
        }
        /// `float3(r, g, b)` literal for the Metal source, so shaders never restate a palette value.
        var metal: String { "float3(\(r), \(g), \(b))" }

        /// WCAG 2 relative luminance.
        var luminance: Float {
            func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(with other: RGB) -> Float {
            let a = luminance, b = other.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        /// The same hue, darkened only as far as it must be to reach `ratio` against a lighter `background`.
        func legible(on background: RGB, ratio: Float) -> RGB {
            guard contrast(with: background) < ratio else { return self }
            var low: Float = 0, high: Float = 1
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if scaled(mid).contrast(with: background) >= ratio { low = mid } else { high = mid }
            }
            return scaled(low)
        }
    }

    enum Palette: String, CaseIterable, Identifiable {
        case starlight, blossomPink, sage, vintageAmber, phosphorGreen, iceBlue, electricViolet, safetyOrange
        case ocean, plum, copper
        var id: String { rawValue }
        var title: String {
            switch self {
            case .starlight: return "Starlight"
            case .blossomPink: return "Blossom Pink"
            case .sage: return "Sage"
            case .vintageAmber: return "Vintage Amber"
            case .phosphorGreen: return "Phosphor Green"
            case .iceBlue: return "Ice Blue"
            case .electricViolet: return "Electric Violet"
            case .safetyOrange: return "Safety Orange"
            case .ocean: return "Ocean & Mist"
            case .plum: return "Plum & Pearl"
            case .copper: return "Copper & Linen"
            }
        }
        var hex: UInt32 {
            switch self {
            case .starlight: return 0xE8DEC8
            case .blossomPink: return 0xFF6584
            case .sage: return 0x8B9A6E
            case .vintageAmber: return 0xE5A93C
            case .phosphorGreen: return 0x4EBA6F
            case .iceBlue: return 0x38BDF8
            case .electricViolet: return 0xA78BFA
            case .safetyOrange: return 0xFF6B35
            case .ocean: return 0x65A6B4
            case .plum: return 0xA883B1
            case .copper: return 0xBE8D62
            }
        }
        var hexLabel: String { String(format: "#%06X", hex) }
        /// The exact swatch; what the interface draws is `Theme.sageRGB`, adjusted for the appearance.
        var accent: RGB { RGB(hex: hex) }
        /// The palette's light companion: type on dark surfaces and on accent fills.
        var cream: RGB {
            switch self {
            case .ocean: return RGB(r: 236/255, g: 246/255, b: 247/255)
            case .plum: return RGB(r: 248/255, g: 239/255, b: 247/255)
            case .copper: return RGB(r: 250/255, g: 241/255, b: 226/255)
            default: return RGB(r: 247/255, g: 242/255, b: 235/255)
            }
        }

        static var stored: Palette { Palette(rawValue: UserDefaults.standard.string(forKey: ThemeSettings.paletteKey) ?? "") ?? .sage }
    }

    /// Everything a palette and an appearance resolve to. `ThemeSettings` replaces it when either changes;
    /// until then it comes from the saved choices, so offscreen renders and early reads agree with the window.
    struct Style {
        let palette: Palette
        let dark: Bool
        let ink: RGB
        let cream: RGB
        let windowTop: RGB, windowBottom: RGB, card: RGB, display: RGB
        let accent: RGB
        let action: RGB
        let banner: RGB
        let sand: RGB, heather: RGB, clay: RGB, ochre: RGB, ember: RGB, slate: RGB
        let secondaryOpacity: Double, tertiaryOpacity: Double
        let levelStops: [(db: Float, rgb: RGB)]
        let rampStops: [RGB]

        init(palette: Palette, dark: Bool) {
            self.palette = palette
            self.dark = dark
            let swatch = palette.accent
            cream = palette.cream
            // Supporting hues, desaturated to sit beside the accent and cream. Sand is the right channel: it
            // separates from the accent by hue, not brightness; slate is below-target loudness, calm and clearly
            // not a warning.
            let hues = (sand: RGB(r: 0.816, g: 0.757, b: 0.620), heather: RGB(r: 0.655, g: 0.604, b: 0.733),
                        clay: RGB(r: 0.800, g: 0.557, b: 0.400), ochre: RGB(r: 0.867, g: 0.698, b: 0.376),
                        ember: RGB(r: 0.894, g: 0.408, b: 0.357), slate: RGB(r: 0.576, g: 0.651, b: 0.675))
            if dark {
                ink = cream
                windowTop = RGB(r: 0.132, g: 0.141, b: 0.156)
                windowBottom = RGB(r: 0.092, g: 0.098, b: 0.110)
                card = RGB(r: 0.170, g: 0.179, b: 0.196)
                display = RGB(r: 0.066, g: 0.070, b: 0.079)
                accent = swatch
                sand = hues.sand
                heather = hues.heather
                clay = hues.clay
                ochre = hues.ochre
                ember = hues.ember
                slate = hues.slate
                // Dark enough under cream type even when the accent itself is very bright.
                banner = swatch.scaled(min(1, 0.5 / max(swatch.r, max(swatch.g, swatch.b))))
                secondaryOpacity = 0.88
                tertiaryOpacity = 0.68
            } else {
                ink = RGB(r: 0.102, g: 0.110, b: 0.125)
                windowTop = RGB(r: 0.953, g: 0.954, b: 0.950)
                windowBottom = RGB(r: 0.918, g: 0.920, b: 0.914)
                card = RGB(r: 0.996, g: 0.996, b: 0.993)
                display = RGB(r: 0.972, g: 0.971, b: 0.964)
                func deepen(_ rgb: RGB) -> RGB { rgb.legible(on: RGB(r: 1, g: 1, b: 1), ratio: 4.5) }
                accent = deepen(swatch)
                sand = deepen(hues.sand)
                heather = deepen(hues.heather)
                clay = deepen(hues.clay)
                ochre = deepen(hues.ochre)
                ember = deepen(hues.ember)
                slate = deepen(hues.slate)
                // A wash of the swatch itself, so the summary keeps the accent's own hue under dark type.
                banner = RGB(r: 1, g: 1, b: 1).mixed(with: swatch, amount: 0.5)
                secondaryOpacity = 0.80
                tertiaryOpacity = 0.64
            }
            // Fills under cream type (prominent buttons, switches, the selected segment) meet body-text contrast.
            action = accent.legible(on: cream, ratio: 4.5)
            // Level colour anchored to the scale, not to the bar length: faint to full accent, then ochre and ember.
            levelStops = [
                (-60, display.mixed(with: accent, amount: dark ? 0.42 : 0.46)),
                (-24, display.mixed(with: accent, amount: dark ? 0.82 : 0.86)),
                (-12, accent),
                (-4, ochre),
                (0, ember)
            ]
            // Waterfall ramp, compiled into the Metal `rampMap`. Energy always moves away from the well's own
            // lightness (obsidian → accent → cream on dark, paper → accent → ink on light), so loudness reads
            // the same in every hue and both appearances.
            if dark {
                rampStops = [RGB(r: 0.030, g: 0.029, b: 0.026), swatch.scaled(0.14), swatch.scaled(0.33),
                             swatch.scaled(0.72), swatch.mixed(with: cream, amount: 0.35), cream]
            } else {
                let paper = RGB(r: 0.992, g: 0.991, b: 0.986)
                rampStops = [paper, paper.mixed(with: accent, amount: 0.16), paper.mixed(with: accent, amount: 0.40),
                             paper.mixed(with: accent, amount: 0.80), accent.mixed(with: ink, amount: 0.40),
                             ink.mixed(with: accent, amount: 0.12)]
            }
        }

        static var stored: Style {
            let mode = AppearanceMode.stored
            return Style(palette: .stored, dark: mode == .dark || (mode == .system && systemIsDark))
        }
    }

    private(set) static var style = Style.stored
    static func resolve(palette: Palette, dark: Bool) { style = Style(palette: palette, dark: dark) }
    /// macOS's appearance before AppKit is up (offscreen renders from the command line).
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    static var dark: Bool { style.dark }
    static var palette: Palette { style.palette }

    // MARK: RGB, for Metal and Core Animation

    /// The accent as drawn: the exact swatch on dark, deepened on light.
    static var sageRGB: RGB { style.accent }
    static var inkRGB: RGB { style.ink }
    static var creamRGB: RGB { style.cream }
    static var displayRGB: RGB { style.display }
    static var cardRGB: RGB { style.card }
    static var actionRGB: RGB { style.action }
    static var sandRGB: RGB { style.sand }
    static var heatherRGB: RGB { style.heather }
    static var clayRGB: RGB { style.clay }
    static var ochreRGB: RGB { style.ochre }
    static var emberRGB: RGB { style.ember }
    static var slateRGB: RGB { style.slate }

    // MARK: Colours, for SwiftUI

    static var sage: Color { style.accent.color }
    /// Light type on accent fills, whatever the appearance.
    static var cream: Color { style.cream.color }
    static var sand: Color { style.sand.color }
    static var heather: Color { style.heather.color }
    static var clay: Color { style.clay.color }
    static var ochre: Color { style.ochre.color }
    static var ember: Color { style.ember.color }
    static var slate: Color { style.slate.color }
    /// Prominent fills and the tint of native controls.
    static var action: Color { style.action.color }

    static var ink: Color { style.ink.color }
    static var secondary: Color { ink.opacity(style.secondaryOpacity) }
    static var tertiary: Color { ink.opacity(style.tertiaryOpacity) }
    /// Micro-borders and tracks: ink at low opacity, so edges stay warm on dark and neutral on light.
    static var hairline: Color { ink }

    static var windowTop: Color { style.windowTop.color }
    static var windowBottom: Color { style.windowBottom.color }
    static var cardTint: Color { style.card.color }
    static var display: Color { style.display.color }
    static var wellFill: Color { style.display.color.opacity(style.dark ? 0.97 : 1) }
    /// Head of the summary, welcome and About banners; ink stays legible on it in both appearances.
    static var bannerAccent: Color { style.banner.color }
    /// Small labels set on a banner (LIVE, version) sit on this.
    static var chipFill: Color { style.dark ? Color.black.opacity(0.22) : ink.opacity(0.07) }
    /// Stat tiles on the summary: a faint lift on dark, frosted white on light.
    static var tileFill: Color { style.dark ? ink.opacity(0.05) : Color.white.opacity(0.62) }
    static var cardShadow: Color { Color.black.opacity(style.dark ? 0.13 : 0.07) }
    /// Type on a solid status fill (accent, ochre, slate): near-black on dark, where the hues are light, and
    /// cream on light, where they are deepened.
    static var onStatus: Color { style.dark ? style.display.color : style.cream.color }
    /// Soft coloured light around lit elements; on light surfaces colour alone carries it.
    static func glow(_ color: Color, _ opacity: Double) -> Color { style.dark ? color.opacity(opacity) : .clear }

    static var levelStops: [(db: Float, rgb: RGB)] { style.levelStops }

    static func level(_ db: Float) -> SIMD4<Float> {
        let stops = style.levelStops
        guard db > stops[0].db else { return stops[0].rgb.simd() }
        for (lower, upper) in zip(stops, stops.dropFirst()) where db <= upper.db {
            let t = (db - lower.db) / (upper.db - lower.db)
            return lower.rgb.simd() + (upper.rgb.simd() - lower.rgb.simd()) * t
        }
        return style.ember.simd()
    }

    /// Blend toward the colour's own luma; 0 is grey, 1 leaves it untouched. Alpha is kept.
    static func desaturate(_ color: SIMD4<Float>, _ saturation: Float) -> SIMD4<Float> {
        guard saturation < 1 else { return color }
        let luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
        let grey = SIMD4<Float>(luma, luma, luma, color.w)
        return grey + (color - grey) * max(0, saturation)
    }

    static func groupRGB(_ group: SpeakerGroup) -> RGB {
        switch group {
        case .front, .surround: return sageRGB
        case .height: return heatherRGB
        case .lfe: return clayRGB
        }
    }

    static func groupColor(_ group: SpeakerGroup) -> Color { groupRGB(group).color }

    /// Waveform lane ink: left-side channels in the accent, right-side in sand, centre between them,
    /// LFE in clay and the upper layer in heather (warmer on the right), so lanes read apart by hue.
    static func laneRGB(_ speaker: Speaker) -> RGB {
        switch speaker.group {
        case .lfe: return clayRGB
        case .height:
            return (speaker.azimuth ?? 0) < 0 ? heatherRGB : heatherRGB.mixed(with: sandRGB, amount: 0.45)
        default:
            let azimuth = speaker.azimuth ?? 0
            if azimuth == 0 { return sageRGB.mixed(with: inkRGB, amount: 0.45) }
            return azimuth < 0 ? sageRGB : sandRGB
        }
    }

    static var rampStops: [RGB] { style.rampStops }

    // Soft dashboard card and recessed plot radii.
    static let cardRadius: CGFloat = 18
    static let wellRadius: CGFloat = 12
}

extension AppearanceMode {
    static var stored: AppearanceMode {
        // A fresh install follows the current macOS appearance, including later system changes.
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: ThemeSettings.modeKey) ?? "") ?? .system
    }
}

extension Font {
    /// The single heading voice: SF Pro Expanded, semibold, uppercase, tracked. The wordmark uses it too.
    static let eyebrow = Font.system(size: 10, weight: .semibold).width(.expanded)
    static let axis = Font.system(size: 9, weight: .medium).monospacedDigit()
}

enum Tracking {
    static let eyebrow: CGFloat = 1.3
    /// The title-case wordmark at 13 pt; `BrandMark` scales it with its size.
    static let wordmark: CGFloat = 0.3
}

struct Eyebrow: View {
    let text: String
    var color: Color = Theme.secondary
    init(_ text: String, color: Color = Theme.secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).font(.eyebrow).tracking(Tracking.eyebrow).foregroundStyle(color).lineLimit(1)
    }
}

// MARK: - Liquid Glass, with the materials that stand in for it before macOS 26

extension View {
    /// Liquid Glass in `shape` on macOS 26; before it (macOS 13–15), a thin material with a hairline rim, which
    /// is how the same controls looked there. `tint` colours the glass; `interactive` lets it respond to the
    /// pointer as native glass controls do.
    /// `fallback` replaces the material where the surface sits on a colour it should keep (the summary).
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                          fallback: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background {
                ZStack {
                    if let fallback { shape.fill(fallback) } else { shape.fill(.ultraThinMaterial) }
                    if let tint { shape.fill(tint) }
                    shape.strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.14 : 0.10), lineWidth: 0.5)
                }
            }
        }
    }

    /// The system's glass button style on macOS 26 (`prominent`: tinted with the accent), the bordered styles
    /// before it.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// Groups neighbouring glass so it is sampled and blended as one layer on macOS 26 (glass cannot sample
    /// other glass); a plain container before it.
    @ViewBuilder
    func glassGroup(spacing: CGFloat) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
