import AnalysisCore
import Foundation

/// The Immersive nebula's display settings (the panel's settings): what is drawn and how, never what is measured,
/// except `coherence`, which the analysis uses (locally and in the Bridge plugin) to decide which speakers share an
/// image.
struct NebulaSettings: Equatable {
    /// How the field is drawn: as particles where each band is heard, or its level as a body's radius (`NebulaStyle`).
    var style = NebulaStyle.radiant
    /// The quietest level drawn, dBFS. Radiant: no band quieter glows. Level body: the level at the listener, the radius
    /// running from it (0) to 0 dBFS at the speakers' shell (1).
    var floor = -60.0
    /// Frequencies drawn, in Hz.
    var lowest = SpatialField.lowestFrequency
    var highest = SpatialField.highestFrequency
    /// Level body: every lobe's widening (degrees at half maximum), and the share of each image's predicted spread
    /// drawn. Radiant places particles from the analysis' own bins, where nothing is spread; only from a source without
    /// them (a Bridge plugin before build 87, the demo) does it scatter energy out of phase over this share.
    var smoothing = 30.0
    var spread = 1.0
    /// Radiant: how far below the loudest band (dB) particles still glow, how many particles each band sends per
    /// analysis frame, their size, how much they smear as they age and how brightly new ones glint (factors of
    /// `Radiant.size`, `Radiant.blur` and `Radiant.sparkGain`).
    var range = 30.0
    var particles = 20.0
    var particleSize = 1.0
    var blur = 1.0
    var sparkle = 1.0
    /// 0…1: how readily speakers that share coherent energy form one image (`threshold`).
    var coherence = 0.65
    var opacity = 1.0
    /// How the field is coloured: by the frequencies heard from each place, or in the theme's (and bands') colours.
    var colors = NebulaColors.frequency
    /// Level body: a fine static grain in the glow, like the backdrop's film grain.
    var grain = true
    /// Milliseconds: level body, the rise and fall of the level in each direction; both, how long light lingers (the
    /// level body's afterglow, Radiant's particles).
    var attack = 30.0
    var release = 250.0
    var persistence = 500.0
    var speakers = true
    var lfe = true
    var grid = true
    var axes = false

    static let ranges = (floor: -96.0...(-36.0), range: 9.0...48.0, frequency: 20.0...20_000.0, smoothing: 10.0...60.0,
                         spread: 0.0...2.0, particles: 2.0...32.0, particleSize: 0.4...3.0, blur: 0.0...3.0,
                         sparkle: 0.0...2.0, coherence: 0.0...1.0, opacity: 0.2...1.5, attack: 5.0...200.0,
                         release: 50.0...2_000.0, persistence: 0.0...3_000.0)

    /// The analysis' coherence threshold for `coherence` (0.75 at 0, 0.30 at the default 0.65, 0.05 at 1).
    var threshold: Float { Float(0.75 - 0.7 * min(1, max(0, coherence))) }

    /// The body's radius (0…1) of a level in dBFS.
    func radius(decibels: Float) -> Float {
        let low = Float(floor)
        return decibels.isFinite ? max(0, min(1, (decibels - low) / -low)) : (decibels > 0 ? 1 : 0)
    }

    /// Whether the field is coloured by frequency for `choice`: the full band with Frequency colours (a split always
    /// wears its bands' hues).
    func spectral(_ choice: BandChoice) -> Bool { colors == .frequency && choice.resolution == .overall }

    /// The level rings on the floor, dBFS: every 20 dB from −20 down, while they stay clear of the listener. Only the
    /// level body has them: in Radiant, the distance from the listener is not a level.
    var rings: [Int] {
        guard style == .level else { return [] }
        return stride(from: -20, through: -80, by: -20).filter { Double($0) > floor + 8 }
    }

    enum Key {
        static let floor = "soundstage.nebula.floor"
        static let lowest = "soundstage.nebula.lowest", highest = "soundstage.nebula.highest"
        static let smoothing = "soundstage.nebula.smoothing", spread = "soundstage.nebula.spread"
        static let coherence = "soundstage.nebula.coherence"
        static let opacity = "soundstage.nebula.opacity"
        static let attack = "soundstage.nebula.attack", release = "soundstage.nebula.release"
        static let persistence = "soundstage.nebula.persistence"
        static let speakers = "soundstage.nebula.speakers", lfe = "soundstage.nebula.lfe"
        static let grid = "soundstage.nebula.grid", axes = "soundstage.nebula.axes"
        static let colors = "soundstage.nebula.colorMap", grain = "soundstage.nebula.grain"
        static let style = "soundstage.nebula.style", range = "soundstage.nebula.range"
        static let particles = "soundstage.nebula.particles", particleSize = "soundstage.nebula.particleSize"
        static let blur = "soundstage.nebula.blur", sparkle = "soundstage.nebula.sparkle"
        static let all = [style, range, particles, particleSize, blur, sparkle, floor, lowest, highest, smoothing, spread,
                          coherence, opacity, attack, release, persistence, speakers, lfe, grid, axes, colors, grain]
        /// Settings nothing reads any more (build 80's splats, build 84's shell smoothing): cleared with the defaults.
        static let retired = ["soundstage.nebula.colors", "soundstage.nebula.density", "soundstage.nebula.sensitivity",
                              "soundstage.nebula.size", "soundstage.nebula.brightness", "soundstage.nebula.bloom",
                              "soundstage.nebula.radiantSmoothing"]
    }

    static var stored: NebulaSettings {
        let d = UserDefaults.standard
        var s = NebulaSettings()
        func number(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard d.object(forKey: key) != nil else { return fallback }
            let v = d.double(forKey: key)
            return v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        s.floor = number(Key.floor, ranges.floor, s.floor)
        s.range = number(Key.range, ranges.range, s.range)
        s.particles = number(Key.particles, ranges.particles, s.particles).rounded()
        s.particleSize = number(Key.particleSize, ranges.particleSize, s.particleSize)
        s.blur = number(Key.blur, ranges.blur, s.blur)
        s.sparkle = number(Key.sparkle, ranges.sparkle, s.sparkle)
        s.lowest = number(Key.lowest, ranges.frequency, s.lowest)
        s.highest = number(Key.highest, ranges.frequency, s.highest)
        if s.highest < s.lowest * 1.5 { s.highest = min(ranges.frequency.upperBound, s.lowest * 1.5) }
        s.smoothing = number(Key.smoothing, ranges.smoothing, s.smoothing)
        s.spread = number(Key.spread, ranges.spread, s.spread)
        s.coherence = number(Key.coherence, ranges.coherence, s.coherence)
        s.opacity = number(Key.opacity, ranges.opacity, s.opacity)
        s.attack = number(Key.attack, ranges.attack, s.attack)
        s.release = number(Key.release, ranges.release, s.release)
        s.persistence = number(Key.persistence, ranges.persistence, s.persistence)
        s.speakers = flag(Key.speakers, s.speakers)
        s.lfe = flag(Key.lfe, s.lfe)
        s.grid = flag(Key.grid, s.grid)
        s.axes = flag(Key.axes, s.axes)
        s.colors = d.string(forKey: Key.colors).flatMap(NebulaColors.init(rawValue:)) ?? s.colors
        s.grain = flag(Key.grain, s.grain)
        s.style = d.string(forKey: Key.style).flatMap(NebulaStyle.init(rawValue:)) ?? s.style
        return s
    }

    /// Back to the defaults (the camera is reset on its own).
    static func restoreDefaults() {
        for key in Key.all + Key.retired { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// How the Immersive nebula draws the spatial field; the panel's settings switch between them.
/// - Radiant (the default): each band's frequencies as particles at the centre of gravity of the speakers, weighted by
///   each frequency's amplitude in each (`SpatialPoints`, `RadiantParticles`), glowing in the band's hue as bright as
///   it is loud, then fading and smearing as they age. A centred phantom is a bright point between L and R, a panned
///   source a point where its gains put it, a wide stereo programme a streak along the line between them, a
///   hard-panned source sits at its speaker, sound all round gathers inward.
/// - Level body: one body whose radius in each direction is the level heard from there, read on the floor's dBFS
///   rings (build 83).
enum NebulaStyle: String, CaseIterable {
    case radiant, level

    var title: String {
        switch self {
        case .radiant: return L("Radiant")
        case .level: return L("Level body")
        }
    }
}

/// Radiant's look, shared by the particles (`RadiantParticles`), their shader (`radiantParticleVertex`) and the key.
/// Like a spatial analyser's display, a particle's light is its band's level within `NebulaSettings.range` dB of the
/// loudest band: `x` is its place in that range (0 at the loudest, −1 at the range's foot). How loud the loudest band
/// is sets how bright the whole glow is (`presence`).
enum Radiant {
    /// Brightness e^(contrast·x): four e-folds over the range, so its foot fades out.
    static let contrast: Float = 4
    /// A new particle's haze (σ, radii of the speakers' sphere) at Particle size 1, the σ its smear adds over a second
    /// at Blur 1 (its variance grows with age, as repeated blurring grows it), the smallest it is drawn (pixels of its
    /// target) and how much dimmer the far side is.
    static let size: Float = 0.008
    static let blur: Float = 0.045
    static let minimumPixels: Float = 0.7
    static let depthFade: Float = 0.25
    /// A new particle's spark: σ (radii) at Particle size 1, seconds per e-fold of its fading, its peak as a share of
    /// the particle's light at Sparkle 1, and the smallest it is drawn (pixels of the canvas).
    static let sparkSize: Float = 0.0035
    static let sparkFade: Float = 0.05
    static let sparkGain: Float = 2.5
    static let sparkMinimumPixels: Float = 0.6
    /// The light's gain at opacity 1, how much glow is added (near, blurred at a quarter of the haze's target, and
    /// wide, at an eighth), the chroma added, and the exposure over which the densest light burns toward white.
    static let exposure: Float = 3.4
    static let bloom: Float = 0.7
    static let glowNear: Float = 1
    static let glowFar: Float = 1
    static let chroma: Float = 1.35
    static let hotFrom: Float = 3
    static let hotTo: Float = 16
    /// The broad density (the wide glow's brightest point, exposed) past which the exposure eases, how much (0 not at
    /// all, 1 down to it), and how quickly the held density falls back (seconds per e-fold; it rises at once). A
    /// dense, broadband programme keeps its colours; a bright bead still burns white.
    static let denseLimit: Float = 2
    static let denseEase: Float = 0.7
    static let meterRelease: Float = 0.8
    /// Seconds: how quickly the loudest level, which the range hangs from, falls back (it rises at once).
    static let peakRelease: Float = 2.5

    /// A particle's brightness at `x`, before the loudest level's own (`presence`).
    static func intensity(_ x: Float) -> Float { x > -1.5 ? Foundation.exp(contrast * x) : 0 }
    /// The whole glow's brightness when the loudest band is at `peak` dBFS over a level floor of `floor` dBFS.
    static func presence(peak: Float, floor: Float) -> Float {
        guard peak > floor else { return 0 }
        let t = max(0, min(1, (peak - floor) / 36))
        return 0.3 + 0.7 * t * t * (3 - 2 * t)
    }
    /// How bright the glow looks at `x` on the dark well (0…1), for the key.
    static func seen(_ x: Float) -> Float { 1 - Foundation.exp(-2.5 * intensity(x)) }
}

/// The Immersive nebula's colours: by frequency (each place in the spectral hues of what is heard there, warm bass to
/// cool treble, white where all of it is) or the theme's (the accent for the full band, the band hues for a split).
enum NebulaColors: String, CaseIterable {
    case frequency, theme

    var title: String {
        switch self {
        case .frequency: return L("Frequency")
        case .theme: return L("Theme")
        }
    }
}
