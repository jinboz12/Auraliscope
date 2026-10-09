import AnalysisCore
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
/// `.id(signature)`, under a cross-fade (`ThemeFade`). Nothing in the audio path listens, so metering carries on.
@MainActor
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()
    nonisolated static let paletteKey = "colorTheme"
    nonisolated static let modeKey = "appearanceMode"

    @Published var palette: Theme.Palette {
        didSet {
            guard palette != oldValue else { return }
            UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteKey)
            DiagnosticLog.event("Color theme: \(palette.rawValue)")
            ThemeFade.begin()
            resolve()
        }
    }
    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            DiagnosticLog.event("Appearance: \(mode.rawValue)")
            // Auto may resolve to what is already on screen; only a visible change fades.
            if effectiveDark(mode, predicting: true) != dark { ThemeFade.begin() }
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
            // macOS changed appearance under Auto: start the fade now, before AppKit redraws its controls in the
            // new appearance, so the old picture it holds is the whole window as it was.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if let self, self.mode == .system, self.effectiveDark(.system) != self.dark { ThemeFade.begin() }
                }
            }
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

    /// Whether `mode` shows dark: fixed for Light and Dark; for Auto, the app's effective appearance. `predicting`
    /// answers for a switch to Auto that is not applied yet, while Light or Dark still overrides the app.
    private func effectiveDark(_ mode: AppearanceMode, predicting: Bool = false) -> Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system:
            guard let app = NSApp, !(predicting && app.appearance != nil) else { return Theme.systemIsDark }
            return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private func resolve() {
        let effective = effectiveDark(mode)
        guard effective != Theme.style.dark || palette != Theme.style.palette else { return }
        Theme.resolve(palette: palette, dark: effective)
        if dark != effective { dark = effective } else { objectWillChange.send() }
    }
}

/// Cross-fades every visible window from the old palette or appearance to the new one.
///
/// A Core Animation transition on each window's frame view: the render server keeps the picture as it was and
/// dissolves it into the live, restyled window, so SwiftUI surfaces, AppKit controls, the toolbar and the Metal
/// canvases all change together. The transition is committed with the views `.id(signature)` rebuilds, and
/// starts then (a zero `beginTime` is the commit time), so however long the rebuild takes, the old picture
/// stays whole until it is done and the fade always runs its full course. Nothing is captured by the app itself,
/// so no screen-recording permission is involved.
@MainActor
enum ThemeFade {
    static let duration: CFTimeInterval = 0.45
    private static let key = "auraliscope.themeFade"

    static func begin() {
        guard let app = NSApp else { return }
        for window in app.windows where window.isVisible && window.occlusionState.contains(.visible) {
            guard let layer = (window.contentView?.superview ?? window.contentView)?.layer else { continue }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: key)
        }
    }
}

/// Auraliscope dashboard palette, in a dark and a light appearance.
///
/// - **Surfaces**: a near-black window with flat charcoal cards; or the palette's own gradient with frosted white
///   cards. Each live display is drawn straight onto its card.
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
        /// The Auraliscope LABS icon's slate indigo body: LABS' default, listed first.
        case labsIndigo
        case starlight, blossomPink, sage, vintageAmber, phosphorGreen, iceBlue, electricViolet, safetyOrange
        case ocean, plum, copper
        var id: String { rawValue }
        /// LABS' default theme (Auraliscope's is Sage).
        static let standard = Palette.labsIndigo
        var title: String {
            switch self {
            case .starlight: return L("Starlight")
            case .blossomPink: return L("Blossom Pink")
            case .sage: return L("Sage")
            case .vintageAmber: return L("Vintage Amber")
            case .phosphorGreen: return L("Phosphor Green")
            case .iceBlue: return L("Ice Blue")
            case .electricViolet: return L("Electric Violet")
            case .safetyOrange: return L("Safety Orange")
            case .ocean: return L("Ocean & Mist")
            case .plum: return L("Plum & Pearl")
            case .copper: return L("Copper & Linen")
            case .labsIndigo: return L("LABS Indigo")
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
            case .labsIndigo: return 0x6B7E97
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
            case .labsIndigo: return RGB(r: 237/255, g: 241/255, b: 248/255)
            default: return RGB(r: 247/255, g: 242/255, b: 235/255)
            }
        }

        static var stored: Palette {
            let defaults = UserDefaults.standard
            // Build 64 made LABS Indigo the default: a theme saved by an earlier LABS build gives way to it once;
            // a theme chosen after that is kept.
            if !defaults.bool(forKey: adoptedKey) {
                defaults.set(true, forKey: adoptedKey)
                defaults.set(standard.rawValue, forKey: ThemeSettings.paletteKey)
            }
            return Palette(rawValue: defaults.string(forKey: ThemeSettings.paletteKey) ?? "") ?? standard
        }
        private static let adoptedKey = "labsIndigoDefaultAdopted"
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
        let correlationStops: [(value: Float, rgb: RGB)]
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
                // Near-black studio dark: flat charcoal cards a step above the window, and the displays drawn
                // straight onto them, so `display` is the card itself.
                windowTop = RGB(r: 0.058, g: 0.062, b: 0.070)
                windowBottom = RGB(r: 0.040, g: 0.043, b: 0.049)
                card = RGB(r: 0.106, g: 0.112, b: 0.124)
                display = card
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
                // Frosted white cards over the palette's gradient; the displays sit on them, so `display` is the
                // card as it reads there.
                card = RGB(r: 0.996, g: 0.996, b: 0.996)
                display = RGB(r: 0.984, g: 0.985, b: 0.987)
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
            // Correlation colour along its scale, matching `CorrelationZone`: ember out of phase, ochre around 0
            // (very wide), the accent from moderate correlation to mono. Each zone edge is a short blend, so the
            // bar's colour moves with the reading instead of switching.
            correlationStops = [(-1, ember), (-0.15, ember), (-0.05, ochre), (0.2, ochre), (0.4, accent), (1, accent)]
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

    private(set) static var style = Style.stored { didSet { rampTables = [:] } }
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
    /// Text and symbols on a solid accent fill: white, or the well's ink when the accent is light.
    static var onAction: Color {
        let c = style.action
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.62 ? Color(red: 0.08, green: 0.09, blue: 0.08) : .white
    }

    static var ink: Color { style.ink.color }
    /// Type on a solid ink fill (the chosen segment's pill): near-black on dark, where ink is the palette's cream, and
    /// white on light.
    static var onInk: Color { style.dark ? style.windowBottom.color : .white }
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
    /// Flat cards on dark cast nothing; frosted cards on light float on a wide, faint shadow.
    static var cardShadow: Color { style.dark ? .clear : Color.black.opacity(0.07) }
    /// The window backdrop at its top edge (and the toolbar's in full screen): near-black on dark, the palette's
    /// wash on light.
    static var backdropTop: Color { style.dark ? style.windowTop.color : style.banner.color }
    /// The backdrop's light band: the palette's wash turning into the pale window.
    static var backdropMiddle: Color { style.banner.mixed(with: style.windowTop, amount: 0.62).color }
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

    static var correlationStops: [(value: Float, rgb: RGB)] { style.correlationStops }

    /// Colour of an L/R correlation reading (−1…+1) on the correlation meter's scale.
    static func correlation(_ value: Float) -> SIMD4<Float> {
        let stops = style.correlationStops
        guard value > stops[0].value else { return stops[0].rgb.simd() }
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.value {
            let t = (value - lower.value) / (upper.value - lower.value)
            return lower.rgb.simd() + (upper.rgb.simd() - lower.rgb.simd()) * t
        }
        return stops[stops.count - 1].rgb.simd()
    }

    /// Type for a correlation zone: its name in the zone's colour, the number in ink unless it warns.
    static func correlationColor(_ zone: CorrelationZone) -> Color {
        switch zone {
        case .outOfPhase: return ember
        case .wide: return ochre
        case .stereo, .mono: return sage
        }
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

    /// Hue of each `StereoBands` band, warm at the bottom of the spectrum to cool at the top, shared by the
    /// stereometer's cloud, its legend and the correlation lanes.
    /// Red, amber, green, blue and violet: five fixed hues, independent of the palette's accent, so they stay apart
    /// as small dots in every palette. On the light well they are deepened to hold contrast.
    static func bandRGB(_ band: Int) -> RGB {
        let hues = [RGB(r: 0.93, g: 0.37, b: 0.33), RGB(r: 0.95, g: 0.69, b: 0.26), RGB(r: 0.42, g: 0.79, b: 0.46),
                    RGB(r: 0.37, g: 0.63, b: 0.96), RGB(r: 0.73, g: 0.51, b: 0.96)]
        let hue = hues[max(0, min(hues.count - 1, band))]
        return dark ? hue : hue.legible(on: displayRGB, ratio: 4)
    }

    static func bandColor(_ band: Int) -> Color { bandRGB(band).color }

    /// A band group's hue at a resolution: the five band hues; red, green and blue for three bands; the accent
    /// for the single overall reading.
    static func bandRGB(_ resolution: StereoBands.Resolution, _ group: Int) -> RGB {
        switch resolution {
        case .five: return bandRGB(group)
        case .three: return bandRGB([0, 2, 3][max(0, min(2, group))])
        case .overall: return dark ? sageRGB : sageRGB.legible(on: displayRGB, ratio: 4)
        }
    }

    static func bandColor(_ resolution: StereoBands.Resolution, _ group: Int) -> Color { bandRGB(resolution, group).color }

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

    /// The theme's own waterfall ramp (`SpectrogramColors.theme`).
    static var rampStops: [RGB] { style.rampStops }

    /// The stops of a spectrogram colour map in the current appearance, 0 the empty well, 1 the loudest. Every map
    /// moves away from the well's own lightness (dark to bright on dark, paper to ink on light), so the grid, cursor
    /// and labels drawn over the waterfall stay legible.
    static func rampStops(_ colors: SpectrogramColors) -> [RGB] {
        switch colors {
        case .theme:
            return rampStops
        case .heat:
            // A perceptually ordered black–indigo–crimson–amber map in the manner of inferno: lightness rises
            // steadily, and the hue turns as it does, so neighbouring levels differ in two ways at once.
            let stops = [RGB(r: 0.000, g: 0.000, b: 0.016), RGB(r: 0.106, g: 0.047, b: 0.255),
                         RGB(r: 0.290, g: 0.047, b: 0.420), RGB(r: 0.494, g: 0.118, b: 0.427),
                         RGB(r: 0.710, g: 0.208, b: 0.353), RGB(r: 0.886, g: 0.353, b: 0.212),
                         RGB(r: 0.976, g: 0.565, b: 0.075), RGB(r: 0.984, g: 0.765, b: 0.200),
                         RGB(r: 0.988, g: 0.988, b: 0.700)]
            guard !dark else { return stops }
            // On paper: the same hues in reverse, lightness falling from white as steadily as it rises from black on
            // dark, so quiet detail stays a pale wash and only loud partials turn deep.
            return [RGB(r: 0.992, g: 0.991, b: 0.986), RGB(r: 0.990, g: 0.950, b: 0.850),
                    RGB(r: 0.990, g: 0.880, b: 0.620), RGB(r: 0.980, g: 0.740, b: 0.380),
                    RGB(r: 0.930, g: 0.550, b: 0.260), RGB(r: 0.820, g: 0.330, b: 0.270),
                    RGB(r: 0.600, g: 0.150, b: 0.380), RGB(r: 0.330, g: 0.060, b: 0.400),
                    RGB(r: 0.060, g: 0.020, b: 0.120)]
        case .gray:
            let black = RGB(r: 0.030, g: 0.030, b: 0.032), white = RGB(r: 0.965, g: 0.965, b: 0.955)
            return dark ? [black, white] : [RGB(r: 0.992, g: 0.991, b: 0.986), RGB(r: 0.060, g: 0.062, b: 0.070)]
        }
    }

    /// The theme's ramp is eased between its few stops; the other maps are dense enough to run straight between them.
    static func rampEased(_ colors: SpectrogramColors) -> Bool { colors == .theme }

    /// The waterfall's colour for a level, through the same tone curve and range (`SpectrogramTone`), so the live
    /// spectrum and the legend wear the colours the waterfall shows.
    static func ramp(decibels db: Float, range: SpectrogramRange, colors: SpectrogramColors) -> RGB {
        ramp(position: SpectrogramTone.position(db, range: range), colors: colors)
    }

    /// The colour at `x` (0…1) along `colors`' stops (`rampStops(_:)`), from a fine table: the live spectrum asks for
    /// about a thousand colours a frame.
    static func ramp(position x: Float, colors: SpectrogramColors) -> RGB {
        let table = rampTables[colors] ?? {
            let table = (0..<rampTableSize).map { exactRamp(position: Float($0) / Float(rampTableSize - 1), colors: colors) }
            rampTables[colors] = table
            return table
        }()
        return table[Int((max(0, min(1, x)) * Float(rampTableSize - 1)).rounded())]
    }

    private static let rampTableSize = 1024
    /// `exactRamp` per map in the current style; cleared when the style changes.
    private static var rampTables: [SpectrogramColors: [RGB]] = [:]

    private static func exactRamp(position x: Float, colors: SpectrogramColors) -> RGB {
        let x = max(0, min(1, x))
        let stops = rampStops(colors)
        let scaled = x * Float(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let t = scaled - Float(index)
        return stops[index].mixed(with: stops[index + 1], amount: rampEased(colors) ? t * t * (3 - 2 * t) : t)
    }

    /// Colours the waterfall shader reads per map: every 1/32, which holds each stop of the eight-segment maps exactly
    /// and follows the theme's eased ramp within a fraction of a percent.
    static let waterfallRampCount = 33

    /// The map sampled at `waterfallRampCount` evenly spaced positions for the waterfall shader, which runs straight
    /// between them.
    static func waterfallRamp(_ colors: SpectrogramColors) -> [SIMD4<Float>] {
        (0..<waterfallRampCount).map { exactRamp(position: Float($0) / Float(waterfallRampCount - 1), colors: colors).simd() }
    }

    // Card and inner radii: generous and continuous, so the panels read as calm objects rather than boxes.
    static let cardRadius: CGFloat = 24
    static let wellRadius: CGFloat = 16
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
        Text(text).font(.eyebrow).tracking(Localizer.shared.tracking(Tracking.eyebrow)).foregroundStyle(color).lineLimit(1)
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

    /// A round icon button in the system's glass style (bordered before macOS 26; round from macOS 14).
    @ViewBuilder
    func glassIconButton() -> some View {
        if #available(macOS 14, *) { glassButton().buttonBorderShape(.circle) } else { glassButton() }
    }

    /// The system's glass button style on macOS 26 (`prominent`: tinted with the accent), the bordered styles
    /// before it.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            // A plain glass button is the system's untinted glass: the window's accent tint would otherwise colour
            // its glass and make it read as the prominent one.
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass).tint(nil) }
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
