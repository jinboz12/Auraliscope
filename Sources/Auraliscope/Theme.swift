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

    /// Takes up the stored theme and appearance again (a settings preset rewrote them).
    func reloadStored() {
        palette = Theme.Palette.stored
        mode = AppearanceMode.stored
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

/// Auraliscope's visual system, in a dark and a light appearance: glass, soft light and shade, few lines, and motion.
///
/// - **Atmosphere** belongs to the window backdrop alone, and it is a sky with almost no colour (`skyMute`): on dark a
///   deep night, near-black over most of the window with a soft light pooled behind the top row, a low glow from the
///   horizon and a vignette; on light a grey haze deepest across the upper third, thinning to white light on the
///   horizon. A fine static grain lies over it (`Grain`), so the backdrop reads as film rather than as a flat gradient.
///   Colour is left to the signal and the lit controls.
/// - **Glass**: panels are frosted graphite / white glass (`CardSurface`) that keeps the sky beneath their headers and
///   plots. A faint inset wash separates plotting regions without opaque plates. The spectrogram retains a stable
///   neutral ground for its energy ramp.
/// - **Light and shade** (neumorphism, kept soft): the light falls from the upper left. A panel's one rim is a bevel,
///   lit on its upper-left edge and shaded on its lower right; tracks are pressed into the surface (`DockTrack`); a
///   round button rises out of its track under the pointer and sinks into it while pressed (`DiscFace`, `neuLight`,
///   `neuShade`, `raisedFace`). Nothing carries a border it does not need.
/// - **Motion** (`Motion`): one family of springs for presses, hovers, changes of state and pages; SF Symbols morph
///   and bounce (`SymbolMotion`); a live light breathes (`PulseRing`). All of it rests when nothing changes, and
///   Reduce Motion turns it into short eases.
/// - **Radius scale**: panels 22, plots clipped at 14 where they need a shape, controls are capsules (`controlRadius`
///   is half a control's height), tags 5. Round buttons are discs.
/// - **Type levels**: readings in `ink`; panel titles in `title`; reading names, scales and units in `tertiary`;
///   unavailable things in `disabled`.
/// - **Colour roles**: the palette's **accent** is the live signal (levels, traces, LIVE, the resume button, AUTO
///   while it drives the mode). **Ink** marks what is held or pointed at: peak holds, the target, needles, cursors,
///   the chosen segment. **Ochre** is caution (near full scale, above target, wide stereo), **ember** is an alarm
///   only (overs, out of phase, clipping), always with a word or glyph as well, and **slate** is below target.
///   Selection and "on" states are shown by a **lit** plate (`lit`): the inverse of the surface, cream on dark and
///   ink on light, with a soft halo on dark; never by a warning hue.
///
/// Beyond those, hue carries meaning only for speaker groups (bed accent, height heather, LFE clay) and frequency
/// bands. On light surfaces every hue is deepened just enough to read as body text does (4.5 : 1). Metal draws with
/// the `RGB` values, SwiftUI with the matching `Color`s, so both layers read as one surface.
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
        /// The same lightness with `amount` of its hue drained toward grey.
        func muted(_ amount: Float) -> RGB {
            let grey = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return mixed(with: RGB(r: grey, g: grey, b: grey), amount: amount)
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

    /// Colour stays in the signal and small controls, with a nearly neutral backdrop. The additional pastel
    /// accents are deliberately muted; caution, alarm and frequency-band colours retain their existing meanings.
    /// Studio Console additionally gives the same panels an opaque, machined surface, without changing layout.
    enum Palette: String, CaseIterable, Identifiable {
        /// The user's Pearl reference: blue light, a rose companion and a pearl-white centre.
        case iconPearl
        case labsIndigo
        case cobalt, glacier, sage, starlight, graphite
        case sakuraPink, milkFrog, mistLilac
        case studioConsole
        var id: String { rawValue }
        /// The default for a fresh install. Previously chosen palettes remain selected.
        static let standard = Palette.iconPearl
        var title: String {
            switch self {
            case .iconPearl: return L("Pearl")
            case .labsIndigo: return L("Indigo")
            case .cobalt: return L("Cobalt")
            case .glacier: return L("Glacier")
            case .sage: return L("Sage")
            case .starlight: return L("Starlight")
            case .graphite: return L("Graphite")
            case .sakuraPink: return L("Sakura Pink")
            case .milkFrog: return L("Milk Frog")
            case .mistLilac: return L("Mist Lilac")
            case .studioConsole: return L("Studio Console")
            }
        }
        var hex: UInt32 {
            switch self {
            case .iconPearl: return 0x6EA5FB
            case .labsIndigo: return 0x6B7E97
            // A clear studio blue, brighter and bluer than Indigo's slate.
            case .cobalt: return 0x5C8DEB
            // Pale ice: the lightest blue, airy on the night.
            case .glacier: return 0x8CC4D9
            case .sage: return 0x8B9A6E
            case .starlight: return 0xE8DEC8
            // Cool silver: the signal in light alone, for a monochrome meter.
            case .graphite: return 0xAEB4BE
            // Rose leaning toward mauve, away from the red clipping indicator.
            case .sakuraPink: return 0xD6A4BC
            // A deliberately playful frog green; butter yellow is the right-channel companion, not caution.
            case .milkFrog: return 0xC7DF6A
            case .mistLilac: return 0xB4ADC8
            // A quiet green signal lamp on neutral console metal.
            case .studioConsole: return 0xA8B79A
            }
        }
        var hexLabel: String { String(format: "#%06X", hex) }
        /// The exact swatch; what the interface draws is `Theme.sageRGB`, adjusted for the appearance.
        var accent: RGB { RGB(hex: hex) }
        /// The right-channel companion, chosen to remain separate from each new accent. Warning and speaker
        /// group hues are not remapped by a decorative palette.
        var companion: RGB {
            switch self {
            case .iconPearl: return RGB(hex: 0xFCA8B9)
            case .sakuraPink: return RGB(hex: 0xA6BDC5)
            case .milkFrog: return RGB(hex: 0xEAC657)
            default: return RGB(r: 0.816, g: 0.757, b: 0.620)
            }
        }
        /// The palette's light companion: type on dark surfaces and on accent fills. The cool themes' are cool, so
        /// cream type never turns warm beside a blue or green signal.
        var cream: RGB {
            switch self {
            case .iconPearl: return RGB(hex: 0xFFF7FE)
            case .labsIndigo: return RGB(r: 237/255, g: 241/255, b: 248/255)
            case .cobalt: return RGB(r: 236/255, g: 241/255, b: 252/255)
            case .glacier: return RGB(r: 236/255, g: 245/255, b: 249/255)
            case .graphite: return RGB(r: 241/255, g: 243/255, b: 246/255)
            case .sage, .starlight: return RGB(r: 247/255, g: 242/255, b: 235/255)
            case .sakuraPink: return RGB(hex: 0xF8EFF3)
            case .milkFrog: return RGB(hex: 0xFFF6D9)
            case .mistLilac: return RGB(hex: 0xF2F0F7)
            case .studioConsole: return RGB(hex: 0xF1F2EC)
            }
        }

        static var stored: Palette {
            let defaults = UserDefaults.standard
            // Keep the existing migration marker, but never replace a saved choice with a new default.
            if !defaults.bool(forKey: adoptedKey) {
                defaults.set(true, forKey: adoptedKey)
                if defaults.string(forKey: ThemeSettings.paletteKey) == nil {
                    defaults.set(standard.rawValue, forKey: ThemeSettings.paletteKey)
                }
            }
            let saved = defaults.string(forKey: ThemeSettings.paletteKey) ?? ""
            // Retired choices give way to a retained palette and are saved under that name.
            if let replacement = retired[saved] {
                defaults.set(replacement.rawValue, forKey: ThemeSettings.paletteKey)
                return replacement
            }
            return Palette(rawValue: saved) ?? standard
        }
        private static let adoptedKey = "labsIndigoDefaultAdopted"
        /// The themes before build 103 that are gone, and the one nearest each: the cool ones by hue, the warm and
        /// pink ones (which wore the caution and alarm hues) to Starlight's warm white, the purples to Indigo.
        private static let retired: [String: Palette] = [
            "lagoon": .sage, "mint": .sage, "slateBlue": .labsIndigo,
            "iceBlue": .glacier, "ocean": .sage, "phosphorGreen": .sage, "electricViolet": .cobalt, "plum": .labsIndigo,
            "blossomPink": .starlight, "vintageAmber": .starlight, "safetyOrange": .starlight, "copper": .starlight,
        ]
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
            let hues = (sand: palette.companion, heather: RGB(r: 0.655, g: 0.604, b: 0.733),
                        clay: RGB(r: 0.800, g: 0.557, b: 0.400), ochre: RGB(r: 0.867, g: 0.698, b: 0.376),
                        ember: RGB(r: 0.894, g: 0.408, b: 0.357), slate: RGB(r: 0.576, g: 0.651, b: 0.675))
            if dark {
                ink = cream
                // Neutral graphite card tint; a slightly deeper stable ground is reserved for raster data.
                windowTop = palette == .studioConsole ? RGB(hex: 0x303638) : RGB(r: 0.052, g: 0.056, b: 0.068)
                windowBottom = palette == .studioConsole ? RGB(hex: 0x161A1B) : RGB(r: 0.018, g: 0.019, b: 0.024)
                card = palette == .studioConsole ? RGB(hex: 0x343B3D) : RGB(r: 0.160, g: 0.168, b: 0.190)
                display = palette == .studioConsole ? RGB(hex: 0x101516) : RGB(r: 0.050, g: 0.053, b: 0.062)
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
                tertiaryOpacity = 0.76
            } else {
                ink = RGB(r: 0.102, g: 0.110, b: 0.125)
                windowTop = palette == .studioConsole ? RGB(hex: 0xD6D8D5) : RGB(r: 0.945, g: 0.948, b: 0.953)
                windowBottom = palette == .studioConsole ? RGB(hex: 0xB8BDBB) : RGB(r: 0.902, g: 0.907, b: 0.916)
                // Frosted cards reveal the backdrop; preserve the existing raster energy ramp.
                card = palette == .studioConsole ? RGB(hex: 0xE3E5E1) : RGB(r: 0.996, g: 0.996, b: 0.996)
                display = palette == .studioConsole ? RGB(hex: 0xF0F2EC) : RGB(r: 0.992, g: 0.992, b: 0.993)
                let contrastGround: RGB
                switch palette {
                case .studioConsole: contrastGround = RGB(hex: 0xD6D8D5)
                // Allow headroom for the translucent light cards, rather than measuring against pure white alone.
                case .iconPearl, .sakuraPink, .milkFrog, .mistLilac: contrastGround = RGB(hex: 0xF0F0F0)
                default: contrastGround = RGB(r: 1, g: 1, b: 1)
                }
                func deepen(_ rgb: RGB) -> RGB {
                    rgb.legible(on: palette == .studioConsole ? contrastGround : RGB(r: 1, g: 1, b: 1), ratio: 4.5)
                }
                accent = swatch.legible(on: contrastGround, ratio: 4.5)
                sand = deepen(hues.sand)
                heather = deepen(hues.heather)
                clay = deepen(hues.clay)
                ochre = deepen(hues.ochre)
                ember = deepen(hues.ember)
                slate = deepen(hues.slate)
                // A wash of the swatch itself, so the summary keeps the accent's own hue under dark type.
                banner = RGB(r: 1, g: 1, b: 1).mixed(with: swatch, amount: 0.5)
                secondaryOpacity = 0.84
                tertiaryOpacity = 0.76
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
                // From the panel's own ground, so silence in the waterfall is the panel and never a darker box.
                rampStops = [display, swatch.scaled(0.14), swatch.scaled(0.33),
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
    static var isConsole: Bool { palette == .studioConsole }

    // MARK: RGB, for Metal and Core Animation

    /// The accent as drawn: the exact swatch on dark, deepened on light.
    static var sageRGB: RGB { style.accent }
    static var inkRGB: RGB { style.ink }
    static var creamRGB: RGB { style.cream }
    static var displayRGB: RGB { style.display }
    static var sandRGB: RGB { style.sand }
    static var heatherRGB: RGB { style.heather }
    static var clayRGB: RGB { style.clay }
    static var ochreRGB: RGB { style.ochre }
    static var emberRGB: RGB { style.ember }

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
    /// Panel titles: the strongest label, a step under the readings themselves.
    static var title: Color { ink.opacity(style.dark ? 0.94 : 0.90) }
    static var secondary: Color { ink.opacity(style.secondaryOpacity) }
    /// Unavailable controls and silent channels: clearly receded, never mistaken for a scale label.
    static var disabled: Color { ink.opacity(style.dark ? 0.36 : 0.34) }
    static var tertiary: Color { ink.opacity(style.tertiaryOpacity) }
    /// Micro-borders and tracks: ink at low opacity, so edges stay warm on dark and neutral on light.
    static var hairline: Color { ink }

    static var windowTop: Color { style.windowTop.color }
    static var windowBottom: Color { style.windowBottom.color }
    static var cardTint: Color { style.card.color }
    static var display: Color { style.display.color }
    /// Neutral tint over native frosted material; keep the backdrop visible without adding saturation.
    static var panelFill: Color { style.dark ? style.card.color.opacity(0.32) : Color.white.opacity(0.20) }
    /// Background-only inset tint. Never apply this opacity to the measurement content.
    static var plotWash: Color { isConsole ? display : (style.dark ? Color.black.opacity(0.36) : Color.white.opacity(0.48)) }
    /// Head of the summary, welcome and About banners; ink stays legible on it in both appearances.
    static var bannerAccent: Color { style.banner.color }
    /// Panels float on a soft shadow: deep on dark, where it separates them from the night, faint on light.
    static var cardShadow: Color { Color.black.opacity(style.dark ? 0.34 : 0.10) }
    /// A control's resting fill and its hover and pressed steps, on panels and on the toolbar alike.
    static var controlFill: Color {
        isConsole ? style.card.mixed(with: style.ink, amount: style.dark ? 0.12 : 0.08).color
                  : ink.opacity(style.dark ? 0.08 : 0.06)
    }
    static var controlHover: Color { ink.opacity(style.dark ? 0.14 : 0.10) }
    /// The recessed track a group of controls sits in (segments, the toolbar docks).
    static var trackFill: Color { ink.opacity(style.dark ? 0.07 : 0.06) }
    /// A lit control: the chosen segment, a toggled button. The inverse of its surface (cream on dark, ink on light),
    /// so the state reads at a glance; `onLit` is the type on it.
    /// A lit control (the mode in use, a chosen segment, a switched-on button) is a glowing key in both appearances:
    /// cream on dark, white on light, each with its halo, and the label in the dark ink on it.
    static var lit: Color { style.dark ? style.cream.color : .white }
    static var onLit: Color { style.dark ? style.windowBottom.color : style.ink.color }
    /// The halo around a lit control: the cream's glow on dark, a white bloom over the light sky and cards.
    static var litHalo: Color {
        isConsole ? style.cream.color.opacity(style.dark ? 0.14 : 0.18)
                  : (style.dark ? style.cream.color.opacity(0.42) : Color.white.opacity(0.95))
    }
    /// How much of the palette's hue the sky gives up: it keeps only a trace, so the backdrop reads as a near-neutral
    /// night or haze and colour is left to the signal, the lit controls and the panels' readings.
    static let skyMute: Float = 0.8
    /// The light the dark sky pools behind the top row and raises from the horizon: the banner's, nearly grey.
    static var skyLight: Color { style.banner.muted(skyMute).color }
    /// The window backdrop at its top edge (and the toolbar's in full screen): near-black on dark, the muted
    /// palette wash on light.
    static var backdropTop: Color { style.dark ? style.windowTop.color : style.banner.muted(skyMute).color }
    /// The backdrop's light band: the muted wash turning into the pale window.
    static var backdropMiddle: Color { style.banner.mixed(with: style.windowTop, amount: 0.62).muted(skyMute).color }
    /// The very top of the light sky: a little deeper than the wash, so the title row sits under the sky's deepest
    /// tone, which thins toward the horizon.
    static var skyTop: Color {
        style.palette.accent.mixed(with: style.ink, amount: 0.18).mixed(with: style.banner, amount: 0.2).muted(skyMute).color
    }
    /// The horizon at the foot of the light sky: white light.
    static var horizon: Color { Color(red: 0.985, green: 0.986, blue: 0.99) }
    /// Type on a solid status fill (accent, ochre, slate): near-black on dark, where the hues are light, and
    /// cream on light, where they are deepened.
    static var onStatus: Color { style.dark ? style.display.color : style.cream.color }
    /// Soft coloured light around lit elements; on light surfaces colour alone carries it.
    static func glow(_ color: Color, _ opacity: Double) -> Color { style.dark ? color.opacity(opacity) : .clear }
    /// The Settings sidebar and the bars over a scrolling page, laid on the sky: a deeper night on dark, a frosted
    /// veil on light.
    static var sidebarTint: Color { style.dark ? Color.black.opacity(0.32) : Color.white.opacity(0.40) }
    /// Neumorphic light and shade, with the light from the upper left as everywhere in the interface. A raised control
    /// catches `neuLight` on its upper-left edge and casts `neuShade` to its lower right; a recessed track is the
    /// reverse, its shade inside the upper edge and its light inside the lower.
    static var neuLight: Color { style.dark ? Color.white.opacity(0.07) : Color.white.opacity(0.9) }
    static var neuShade: Color { style.dark ? Color.black.opacity(0.6) : Color.black.opacity(0.16) }
    /// A raised control's face: brightest at its upper-left edge, turning away from the light toward the lower right.
    static var raisedFace: LinearGradient {
        LinearGradient(colors: style.dark ? [Color.white.opacity(0.17), Color.white.opacity(0.06)]
                                          : [Color.white, Color.white.opacity(0.72)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

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
        let raw = SpectralHue.bands[max(0, min(SpectralHue.bands.count - 1, band))]
        let hue = RGB(r: raw.x, g: raw.y, b: raw.z)
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
            // On dark it starts at the panel's ground (`displayRGB`, near-black) rather than pure black, so silence
            // is the panel itself and the waterfall never shows as a box.
            let stops = [displayRGB, RGB(r: 0.106, g: 0.047, b: 0.255),
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

    // One radius scale, each step nested inside the one before by its inset: panels, the plot plates inside them,
    // controls on either (capsules: half the 22 pt control height), and tags over the plots.
    static let cardRadius: CGFloat = 22
    static let wellRadius: CGFloat = 14
    static let controlRadius: CGFloat = 11
    static let tagRadius: CGFloat = 5
    /// The toolbar's round buttons and the docks that hold them.
    static let dockButton: CGFloat = 26
}

/// The film grain over the backdrop: one small tile of monochrome noise, made once and tiled, at device resolution
/// so it stays a fine texture on Retina displays. Static: it never animates, and it lies under every panel, so no
/// plot is ever drawn through it.
enum Grain {
    static let tile: NSImage = {
        let side = 192
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: side * side)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
        let data = Data(bytes)
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        // Half the pixel count in points: one noise pixel per device pixel on a 2× display.
        return NSImage(cgImage: image, size: NSSize(width: side / 2, height: side / 2))
    }()

    /// How strongly the grain shows: screened onto the night, multiplied into the light sky.
    static var opacity: Double { Theme.dark ? darkOpacity : lightOpacity }
    /// On the night (the dark window, the report's header band).
    static let darkOpacity = 0.10
    /// On the light sky (the light window, the report's pages).
    static let lightOpacity = 0.15
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
    /// The wordmark's voice (`BrandMark`): SF Pro Expanded, semibold, title case. Page and popover titles use it too.
    static func wordmark(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
}

enum Tracking {
    static let eyebrow: CGFloat = 1.3
    /// The title-case wordmark at 13 pt; `BrandMark` scales it with its size.
    static let wordmark: CGFloat = 0.3
    /// The wordmark's tracking for its font set at `size` points (the 13 pt wordmark's font is 15.34 pt).
    static func wordmark(size: CGFloat) -> CGFloat { wordmark * size / (13 * 1.18) }
}

/// A page's or popover's own title, set like the toolbar's wordmark: Settings' panes, Speaker Layout and every panel's
/// settings. CJK titles keep their glyphs' own spacing.
struct PageTitle: View {
    let text: String
    var size: CGFloat = 20
    var color: Color = Theme.ink
    init(_ text: String, size: CGFloat = 20, color: Color = Theme.ink) {
        self.text = text
        self.size = size
        self.color = color
    }
    var body: some View {
        Text(text).font(.wordmark(size)).tracking(Localizer.shared.tracking(Tracking.wordmark(size: size)))
            .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
    }
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

// MARK: - Motion

/// The interface's motion: one family of springs, so every control answers alike. A press is quick and firm, a hover
/// a soft rise, a change of state (lit, chosen, shown) a settled glide with a touch of overshoot, and a page or bar
/// arriving a longer, calm one. With Reduce Motion on, each is a short ease instead.
@MainActor
enum Motion {
    static var press: Animation { reduced ? .easeOut(duration: 0.08) : .spring(response: 0.22, dampingFraction: 0.6) }
    static var hover: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.78) }
    static var state: Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.72) }
    static var page: Animation { reduced ? .easeOut(duration: 0.18) : .spring(response: 0.46, dampingFraction: 0.86) }

    /// Every control asks for its springs each time it redraws, so the system setting is read once and again only
    /// after the accessibility display options change.
    static var reduced: Bool {
        if let cached = reducedCache { return cached }
        let value = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reducedCache = value
        if reducedObserver == nil {
            reducedObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { reducedCache = nil }
            }
        }
        return value
    }
    private static var reducedCache: Bool?
    private static var reducedObserver: NSObjectProtocol?
}

/// SF Symbols' own motion (macOS 14 and later): a symbol swapped for another (pin ↔ pin.fill, pause ↔ play) morphs
/// into it, and each change of `bounce` bounces it once, as a click lands. Before macOS 14, a plain swap.
struct SymbolMotion<Value: Equatable>: ViewModifier {
    let bounce: Value
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.down, options: .speed(1.3), value: bounce)
        } else {
            content
        }
    }
}

/// A plain button that gives under the pointer: it sinks a little while pressed and springs back, and fades when
/// unavailable as a plain button does.
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        Pressed(label: configuration.label, pressed: configuration.isPressed, scale: scale)
    }

    private struct Pressed<Label: View>: View {
        let label: Label
        let pressed: Bool
        let scale: CGFloat
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            label
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(pressed ? scale : 1)
                .animation(Motion.press, value: pressed)
        }
    }
}

/// A live light's breath: a ring of its colour swells from it and fades every 1.8 s. Core Animation runs it in the
/// render server, so it costs the app nothing between frames; still under Reduce Motion.
struct PulseRing: NSViewRepresentable {
    let color: Theme.RGB
    func makeNSView(context: Context) -> PulseView { PulseView(color: color) }
    func updateNSView(_ view: PulseView, context: Context) { view.color = color }

    final class PulseView: NSView {
        private let ring = CALayer()
        // The status row redraws with the model; only a new colour touches the layer.
        var color: Theme.RGB { didSet { if color != oldValue { ring.backgroundColor = color.cgColor() } } }

        init(color: Theme.RGB) {
            self.color = color
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            ring.backgroundColor = color.cgColor()
            ring.opacity = 0
            layer?.addSublayer(ring)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.cornerRadius = min(bounds.width, bounds.height) / 2
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ring.removeAnimation(forKey: "pulse")
            guard window != nil, !Motion.reduced else { return }
            let swell = CABasicAnimation(keyPath: "transform.scale")
            swell.fromValue = 1
            swell.toValue = 2.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.5
            fade.toValue = 0
            let breath = CAAnimationGroup()
            breath.animations = [swell, fade]
            breath.duration = 1.8
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(breath, forKey: "pulse")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

}
