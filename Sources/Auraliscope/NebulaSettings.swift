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
    /// Radiant: how far below the loudest band (dB) particles still glow, how many particles a band keeps per analysis
    /// frame on average (the analysis' detail, `SpatialGeometry.detail`: it gathers a band's frequencies that sit
    /// together into one particle and shares the frame's budget out by need; the total light never depends on it),
    /// their size, how much they smear as they age and how brightly new ones glint (factors of `Radiant.size`,
    /// `Radiant.blur` and `Radiant.sparkGain`).
    var range = 30.0
    var particles = 20.0
    var particleSize = 1.0
    var blur = 1.0
    var sparkle = 1.0
    /// Radiant body: how bright the point lights of the frequencies are over the body (build 100's Radiant particles,
    /// `RadiantBody.points`), 0 the body alone.
    var points = 1.0
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
    /// A head at the listening position, facing the front: which way the dome faces at a glance.
    var listener = true
    var lfe = true
    var grid = true
    var axes = false
    /// The spatial analysis' window (`SpatialGeometry.Window`): the spectrum's own (about 170 ms), or shorter ones in
    /// the treble for a faster response. The analysis uses it (in the plugin, too).
    var window = SpatialGeometry.Window.standard
    /// Radiant drawn as the bare observations, for checking positions: the newest frame only, every particle the same
    /// small size, no smear, glint, glow, depth shading or exposure control.
    var rawPoints = false

    static let ranges = (floor: -96.0...(-36.0), range: 9.0...48.0, frequency: 20.0...20_000.0, smoothing: 10.0...60.0,
                         spread: 0.0...2.0, particles: 2.0...32.0, particleSize: 0.4...3.0, blur: 0.0...3.0,
                         sparkle: 0.0...2.0, points: 0.0...2.0, coherence: 0.0...1.0, opacity: 0.2...1.5, attack: 5.0...200.0,
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
        static let listener = "soundstage.nebula.listener"
        static let grid = "soundstage.nebula.grid", axes = "soundstage.nebula.axes"
        static let colors = "soundstage.nebula.colorMap", grain = "soundstage.nebula.grain"
        static let style = "soundstage.nebula.style", range = "soundstage.nebula.range"
        static let particles = "soundstage.nebula.particles", particleSize = "soundstage.nebula.particleSize"
        static let blur = "soundstage.nebula.blur", sparkle = "soundstage.nebula.sparkle"
        static let window = "soundstage.nebula.spatialWindow", rawPoints = "soundstage.nebula.rawPoints"
        static let points = "soundstage.nebula.points"
        static let all = [style, range, particles, particleSize, blur, sparkle, points, floor, lowest, highest, smoothing, spread,
                          coherence, opacity, attack, release, persistence, speakers, listener, lfe, grid, axes, colors, grain, window,
                          rawPoints]
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
        s.points = number(Key.points, ranges.points, s.points)
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
        s.listener = flag(Key.listener, s.listener)
        s.lfe = flag(Key.lfe, s.lfe)
        s.grid = flag(Key.grid, s.grid)
        s.axes = flag(Key.axes, s.axes)
        s.colors = d.string(forKey: Key.colors).flatMap(NebulaColors.init(rawValue:)) ?? s.colors
        s.grain = flag(Key.grain, s.grain)
        s.style = d.string(forKey: Key.style).flatMap(NebulaStyle.init(rawValue:)) ?? s.style
        s.window = d.string(forKey: Key.window).flatMap(SpatialWindowChoice.init(rawValue:))?.window ?? s.window
        s.rawPoints = flag(Key.rawPoints, s.rawPoints)
        return s
    }

    /// Back to the defaults (the camera is reset on its own).
    static func restoreDefaults() {
        for key in Key.all + Key.retired { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// The spatial analysis window as stored and shown (`SpatialGeometry.Window`).
enum SpatialWindowChoice: String, CaseIterable {
    case standard, fast
    var window: SpatialGeometry.Window { self == .fast ? .multiResolution : .standard }
    init(_ window: SpatialGeometry.Window) { self = window == .multiResolution ? .fast : .standard }
    var title: String {
        switch self {
        case .standard: return L("Standard")
        case .fast: return L("Fast")
        }
    }
}

/// How the Immersive nebula draws the spatial field; the panel's settings switch between them.
/// - Radiant body (the default, build 101; stored as "radiant", so whoever chose Radiant before gets it): each band's
///   frequencies where they are heard, at the centre of gravity of the speakers weighted by each frequency's amplitude
///   in each (`SpatialObservations`, `RadiantParticles`), gathered into a volume and drawn as the level body's glowing
///   gas (`RadiantBody`): in the frequencies' hues, burning toward white where it is dense and loud, its older light
///   swelling into haze. A centred phantom gathers between L and R, a panned source where its gains put it, a wide
///   stereo programme along the line between them, a hard-panned source at its speaker, sound all round toward the
///   listener. Over it, the particles themselves as build 100's Radiant drew them, as point lights (`NebulaSettings.points`),
///   so where each band sits reads exactly; Raw observations draws the particles alone, as they are.
/// - Level body: one body whose radius in each direction is the level heard from there, read on the floor's dBFS
///   rings (build 83).
enum NebulaStyle: String, CaseIterable {
    case radiant, level

    var title: String {
        switch self {
        case .radiant: return L("Radiant body")
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
    /// wide, at an eighth), and the exposure over which the densest light burns toward white.
    /// The gain is build 86's 3.4 times √20: until build 97 a band's particles each carried 1/√N of its light, √N in
    /// all, so at the default 20 particles a band emitted √20 of it; now it emits its light once however many particles
    /// share it, and this keeps the default picture as bright as it was.
    static let exposure: Float = 3.4 * Float(20).squareRoot()
    static let bloom: Float = 1
    static let glowNear: Float = 1
    static let glowFar: Float = 2.2
    static let hotFrom: Float = 3
    static let hotTo: Float = 16
    /// The level body's palette (build 100): how far a point's hue moves toward the hues heard around it (the wide
    /// glow's), as the body mixes the hues of every band reaching a place, its chroma, and the depth of its static grain.
    /// Radiant is exposed `burn` times as hard per channel, so its densest light burns to cream-white as the body's does.
    static let blend: Float = 0.8
    static let paletteChroma: Float = 1.3
    static let grain: Float = 0.28
    static let burn: Float = 0.8
    /// The broad density (the wide glow's brightest point, exposed) past which the exposure eases, how much (0 not at
    /// all, 1 down to it), and how quickly the held density falls back (seconds per e-fold; it rises at once). A
    /// dense, broadband programme keeps its colours; a bright bead still burns white.
    static let denseLimit: Float = 2
    static let denseEase: Float = 0.7
    static let meterRelease: Float = 0.8
    /// Seconds: how quickly the loudest level, which the range hangs from, falls back (it rises at once).
    static let peakRelease: Float = 2.5

    /// A band's light at `x`, before the loudest level's own (`presence`): the display's dynamic-range compression,
    /// e^(contrast·x), which for a band at L dB is (E / E_loudest)^γ with γ = contrast·10 / (range·ln 10) (0.58 at the
    /// default 30 dB range). It is applied once, to the band's whole energy; the band's particles then share that
    /// light in proportion to their energy, so their total is the band's however many there are.
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

/// The Radiant body's volumes and look (build 101): Radiant's particles, where each band's frequencies are heard, drawn
/// as the level body's glowing gas rather than as points of light (`radiantSplatKernel`, `radiantBodyFragment`).
enum RadiantBody {
    /// How far the volumes reach from the listener on every axis (radii of the speakers' sphere: a particle sits inside
    /// it, its blur a little past it), and their voxels per side: fine for new light, coarse for the haze it becomes.
    static let reach: Float = 1.15
    /// Where the body fades out toward the speakers' shell (radii): from `shellFrom` to `shell`, where rays stop.
    static let shellFrom: Float = 0.95
    static let shell: Float = 1.06
    static let fineSize = 56
    static let coarseSize = 28
    /// A particle's σ when born at Particle size 1 (radii), and the variance its smear adds per second at Blur 1
    /// (radii²; Radiant's grows by 0.045² a second, the body's haze swells more, to σ ≈ 0.12 at the end of the default
    /// half-second life).
    static let size: Float = 0.05
    static let blur: Float = 0.02
    /// Fixed-point steps per unit of light in the splat's 32-bit sums (2²¹: a voxel holds up to 2048 units of light,
    /// a particle's at most 1), the faintest light still added, and the stored density's unit (light per cubic radius,
    /// times this).
    static let fixedScale: Float = 2_097_152
    static let least: Float = 1e-6
    static let unit: Float = 0.01
    /// The look (`RadiantBodyLook`): stored density to the gas' (at the loudest band's full presence), where the body
    /// fills in (from, to), its glow inside before its density's, how much the near side dims what lies behind it, and
    /// the extra chroma of its hues (the level body's).
    static let density: Float = 1.0
    static let edgeFrom: Float = 0.08
    static let edgeTo: Float = 0.25
    static let base: Float = 0.4
    static let absorb: Float = 1.2
    static let chroma: Float = 1.3
    static let wash: Float = 1.4
    /// The point lights over the body (Points 1): Radiant's particles as build 100 drew them, their exposure as a share
    /// of Radiant's, and how much near and wide glow they keep (less than Radiant's: the body is their glow).
    static let pointExposure: Float = 0.3
    static let pointGlowNear: Float = 0.15
    static let pointGlowFar: Float = 0
    /// The body's light under point lights at Points 1 and above, as a share of its own (less as they brighten), so
    /// the body stays a coloured bed and the points carry the brightest light.
    static let underPoints: Float = 0.55
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
