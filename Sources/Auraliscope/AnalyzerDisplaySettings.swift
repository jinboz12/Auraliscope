import AnalysisCore
import CoreGraphics
import Foundation

// Display choices of the Spectrum and Waveform panels, chosen in their settings and read by the canvases and overlays.
/// How an analyzer spaces frequency, chosen in each panel's settings: Log gives every octave the same room from
/// 20 Hz, as the ear hears pitch; Linear gives every hertz the same room from 0 Hz, as an FFT's bins are spaced,
/// so harmonic series fall evenly apart and the treble opens out. The analysis is the same; only the axis changes.
enum FrequencyScale: String, CaseIterable {
    case log, linear

    /// The Spectrum panel's (spectrogram and spectrum together) and the Multi-FFT Spectrum's.
    static let key = "spectrum.frequencyScale"
    static let multiFFTKey = "spectrum.multiFFT.frequencyScale"
    static var stored: FrequencyScale { FrequencyScale(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .log }
    static var storedMultiFFT: FrequencyScale { FrequencyScale(rawValue: UserDefaults.standard.string(forKey: multiFFTKey) ?? "") ?? .log }

    var title: String {
        switch self {
        case .log: return L("Log")
        case .linear: return L("Linear")
        }
    }

    /// Frequency marks along an axis, before thinning to the room there is: the log axis names 20, 50, 100 Hz…;
    /// the linear one starts at 0 and steps through the kilohertz.
    var marks: [(Double, String)] {
        switch self {
        case .log: return SpectrogramLayout.frequencyMarks
        case .linear: return [(0, "0"), (1_000, "1k"), (2_000, "2k"), (3_000, "3k"), (4_000, "4k"), (5_000, "5k"),
                              (10_000, "10k"), (15_000, "15k")]
        }
    }
    /// The marks drawn a little stronger.
    func isMajor(_ frequency: Double) -> Bool {
        switch self {
        case .log: return [100.0, 1_000, 10_000].contains(frequency)
        case .linear: return [0.0, 5_000, 10_000, 15_000].contains(frequency)
        }
    }
}

/// The levels the spectrogram's colours span, chosen in the panel's settings. Standard suits most programme; Deep
/// lifts quiet detail (reverb tails, noise floors, low-level hum) into view; Hot keeps a loud master's upper
/// partials apart instead of letting them all reach the brightest colour.
enum SpectrogramRange: String, CaseIterable {
    case standard, deep, hot

    static let key = "spectrogram.range"
    static var stored: SpectrogramRange { SpectrogramRange(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard }

    /// The darkest and brightest colours' levels, in dBFS.
    var floor: Float {
        switch self {
        case .standard: return -90
        case .deep: return -114
        case .hot: return -72
        }
    }
    var ceiling: Float {
        switch self {
        case .standard: return -12
        case .deep: return -24
        case .hot: return 0
        }
    }
    var title: String {
        switch self {
        case .standard: return L("Standard")
        case .deep: return L("Deep")
        case .hot: return L("Hot")
        }
    }
}

/// The spectrogram's colour map, chosen in the panel's settings. Theme runs from the well through the accent to cream;
/// Heat is a perceptually ordered black–indigo–crimson–amber map, whose hue turns as the level rises, so neighbouring
/// levels are easier to tell apart; Gray is plain greyscale, the most neutral picture. On a light appearance each runs
/// from the paper-white well toward ink instead (`Theme.rampStops(_:)`).
enum SpectrogramColors: String, CaseIterable {
    case heat, theme, gray

    static let key = "spectrogram.colors"
    static var stored: SpectrogramColors { SpectrogramColors(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .heat }

    var title: String {
        switch self {
        case .theme: return L("Theme")
        case .heat: return L("Heat")
        case .gray: return L("Gray")
        }
    }
}

/// How quickly the live spectrum follows the newest column, chosen in the panel's settings. Fast shows every attack;
/// Slow steadies the curve so a mix's tonal balance reads at a glance. Peak holds and the average are unaffected.
enum SpectrumResponse: String, CaseIterable {
    case fast, medium, slow

    static let key = "spectrum.response"
    static var stored: SpectrumResponse { SpectrumResponse(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .medium }

    /// Rate of the critically damped filter, per second: settling times of about 0.2, 0.45 and 1.2 s.
    var rate: Float {
        switch self {
        case .fast: return 22
        case .medium: return 10
        case .slow: return 4
        }
    }
    var title: String {
        switch self {
        case .fast: return L("Fast")
        case .medium: return L("Medium")
        case .slow: return L("Slow")
        }
    }
}

/// How much the live spectrum's curve, peak holds and average are smoothed across frequency: a Gaussian of the given
/// width (full width at half maximum, in octaves), averaged in power so a narrow peak keeps its energy. Off draws
/// every fine band; 1/6 octave reads like a mixing engineer's analyser; 1/3 octave shows the broad tonal balance.
enum SpectrumSmoothing: String, CaseIterable {
    case off, twelfth, sixth, third, variable

    static let key = "spectrum.smoothing"
    static var stored: SpectrumSmoothing { SpectrumSmoothing(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sixth }

    var octaves: Double {
        switch self {
        case .off: return 0
        case .twelfth: return 1.0 / 12
        case .sixth: return 1.0 / 6
        case .third: return 1.0 / 3
        case .variable: return 1.0 / 6
        }
    }

    /// The smoothing width at `frequency`, in octaves. Variable follows the room-measurement convention: 1/48 octave
    /// up to 100 Hz, where modes and fundamentals need detail, widening steadily (on a log scale) to 1/3 octave from
    /// 10 kHz, where the ear hears broad balance and fine detail is mostly noise.
    func octaves(at frequency: Double) -> Double {
        guard self == .variable else { return octaves }
        let position = max(0, min(1, log10(max(frequency, 1) / 100) / 2))
        return exp(log(1.0 / 48) + (log(1.0 / 3) - log(1.0 / 48)) * position)
    }

    var title: String {
        switch self {
        case .off: return L("Off")
        case .twelfth: return "1/12"
        case .sixth: return "1/6"
        case .third: return "1/3"
        case .variable: return L("Var")
        }
    }

    /// One kernel per point of a spectrum of `count` points spaced evenly in log frequency from 20 Hz to `upper`:
    /// the same everywhere for a fixed width, each point's own for Variable.
    func kernels(count: Int, upper: Double) -> [[Float]] {
        let pointsPerOctave = Double(count) / LogFrequencyAxis.octaves(upper: upper)
        guard self == .variable else { return [[Float]](repeating: kernel(pointsPerOctave: pointsPerOctave), count: count) }
        return (0..<count).map { index in
            let frequency = LogFrequencyAxis.centre(index, of: count, upper: upper)
            return Self.kernel(octaves: octaves(at: frequency), pointsPerOctave: pointsPerOctave)
        }
    }

    /// Normalised kernel weights for offsets −n…n points, with `pointsPerOctave` points to an octave; empty when off
    /// or narrower than a point.
    func kernel(pointsPerOctave: Double) -> [Float] { Self.kernel(octaves: octaves, pointsPerOctave: pointsPerOctave) }

    static func kernel(octaves: Double, pointsPerOctave: Double) -> [Float] {
        let sigma = octaves * pointsPerOctave / 2.3548
        guard sigma > 0.35 else { return [] }
        let reach = Int((3 * sigma).rounded(.up))
        let weights = (-reach...reach).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }

    /// `levels` (dBFS) smoothed in power, each point with its own kernel; the ends reuse the nearest point.
    static func apply(_ kernels: [[Float]], to levels: [Float]) -> [Float] {
        guard kernels.count == levels.count, kernels.contains(where: { !$0.isEmpty }) else { return levels }
        let power = levels.map { pow(10, $0 / 10) }
        return levels.indices.map { index in
            let kernel = kernels[index]
            guard !kernel.isEmpty else { return levels[index] }
            let reach = kernel.count / 2
            var sum: Float = 0
            for (offset, weight) in kernel.enumerated() {
                sum += weight * power[max(0, min(levels.count - 1, index + offset - reach))]
            }
            return max(-120, 10 * log10(max(sum, 1e-12)))
        }
    }

    /// `levels` (dBFS) smoothed with `kernel` in power; the ends reuse the nearest point.
    static func apply(_ kernel: [Float], to levels: [Float]) -> [Float] {
        guard !kernel.isEmpty else { return levels }
        let reach = kernel.count / 2
        let power = levels.map { pow(10, $0 / 10) }
        return levels.indices.map { index in
            var sum: Float = 0
            for (offset, weight) in kernel.enumerated() {
                sum += weight * power[max(0, min(levels.count - 1, index + offset - reach))]
            }
            return max(-120, 10 * log10(max(sum, 1e-12)))
        }
    }
}

/// How the spectrogram is analysed. Classic is the multi-resolution short-time Fourier analysis, every row at its
/// calibrated level. Enhanced reassigns each bin's energy to where its phase says it belongs, in time and in frequency
/// (`ReassignedSpectrogram`): tones become thin lines and onsets sharp edges, while noise breaks into fine grain.
enum SpectrogramAnalysis: String, CaseIterable {
    case classic, enhanced

    static let key = "spectrogram.analysis"
    static var stored: SpectrogramAnalysis { SpectrogramAnalysis(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .classic }

    var title: String { self == .classic ? L("Classic") : L("Enhanced") }
}

/// The spectrogram as a flat image scrolling in time, or as a 3D landscape: time across, frequency in depth, level
/// as height, seen from above the front.
enum SpectrogramView: String, CaseIterable {
    case flat, surface

    static let key = "spectrogram.view"
    static var stored: SpectrogramView { SpectrogramView(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .flat }

    var title: String { self == .flat ? "2D" : "3D" }
}

/// How many seconds the spectrogram shows: Auto fits 3 to 8 s to the panel's width (about 100 pt a second); a fixed
/// span shows that much at any width, up to 15 s to see a whole phrase (the history keeps 17 s).
enum SpectrogramSpan: String, CaseIterable {
    case auto, four, eight, fifteen

    static let key = "spectrogram.span"
    static var stored: SpectrogramSpan { SpectrogramSpan(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }

    /// 0 for Auto.
    var seconds: Double {
        switch self {
        case .auto: return 0
        case .four: return 4
        case .eight: return 8
        case .fifteen: return 15
        }
    }
    var title: String { self == .auto ? L("Auto") : L("%d s", Int(seconds)) }
}

/// A display slope for the spectrum and the spectrogram, pivoting at 1 kHz. Music falls by roughly 3 to 4.5 dB per
/// octave, so a tilt of that much shows a balanced mix as level across the axis and makes the treble's detail as
/// readable as the bass's. Readouts (the peak badge, the inspector) always give the true level.
/// A display slope around 1 kHz, in dB per octave, set with a slider in the panel's settings: the Spectrum panel's
/// (spectrum and spectrogram) under `key`, the Multi-FFT Spectrum's under `multiFFTKey`. Readings stay true.
struct SpectrumTilt: Equatable {
    var decibelsPerOctave: Float

    static let key = "spectrum.tiltSlope"
    static let multiFFTKey = "spectrum.multiFFT.tiltSlope"
    /// Builds before 119 offered three fixed slopes, stored by name; read once into `key` (`migrateLegacy`).
    static let legacyKey = "spectrum.tilt"
    static let range: ClosedRange<Double> = 0...6
    static let step = 0.5
    static let pivot = 1_000.0
    static let flat = SpectrumTilt(decibelsPerOctave: 0)

    init(decibelsPerOctave: Float) { self.decibelsPerOctave = decibelsPerOctave }
    init(stored value: Double) {
        let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, value.isFinite ? value : 0))
        decibelsPerOctave = Float((clamped / Self.step).rounded() * Self.step)
    }

    static var stored: SpectrumTilt { SpectrumTilt(stored: UserDefaults.standard.double(forKey: key)) }
    static var storedMultiFFT: SpectrumTilt { SpectrumTilt(stored: UserDefaults.standard.double(forKey: multiFFTKey)) }

    /// The old named slope, carried into the slider's key once.
    static func migrateLegacy(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil, let name = defaults.string(forKey: legacyKey) else { return }
        defaults.set(name == "three" ? 3.0 : name == "fourAndHalf" ? 4.5 : 0, forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    /// "3 dB/oct", "4.5 dB/oct".
    var title: String {
        decibelsPerOctave == 0 ? L("Flat")
            : L("%@ dB/oct", decibelsPerOctave.rounded() == decibelsPerOctave ? "\(Int(decibelsPerOctave))" : String(format: "%.1f", decibelsPerOctave))
    }
    /// What the slope adds at `frequency`.
    func offset(frequency: Double) -> Float { decibelsPerOctave * Float(log2(max(frequency, 1) / Self.pivot)) }
}

/// How a spectrogram level becomes a colour: the position on `Theme.rampStops` (0 the empty well, 1 the brightest).
/// The Metal waterfall evaluates the same curve (`waterfallTone`), the live spectrum's fill and the header legend
/// call it here, so the three always agree. A level is mapped linearly over the range, then shaped: a power curve
/// keeps the noise floor dark, and a partial S-curve separates quiet detail from loud partials.
enum SpectrogramTone {
    static let gamma: Float = 1.6
    static let contrast: Float = 0.6
    /// How far, in cells, an enlarged waterfall cell eases into its neighbour (`waterfallAxis`): a whole cell, so
    /// enlarged cells blend from centre to centre like a smooth image while each cell's centre keeps its exact level.
    static let columnSoftness: Float = 1.0
    static let rowSoftness: Float = 1.0

    static func position(_ db: Float, range: SpectrogramRange) -> Float {
        let linear = max(0, min(1, (db - range.floor) / (range.ceiling - range.floor)))
        let x = pow(linear, gamma)
        return x + (x * x * (3 - 2 * x) - x) * contrast
    }
}

/// The Waveform lanes' vertical scale. Linear amplitude reads as a DAW draws it; Decibels opens up quiet passages:
/// each lane edge is full scale and the centre line −`range` dBFS, so −12 dBFS fills three quarters of the half lane.
/// Either way the envelope is the exact sample peak of each column; only where it is drawn changes.
enum WaveScale: String, CaseIterable {
    case linear, decibels

    static let key = "waveform.scale"
    static let range: Float = 48
    static var stored: WaveScale { WaveScale(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .linear }

    var title: String { self == .linear ? L("Linear") : "dB" }

    /// The shader's dB range for this scale (0 = linear).
    var shaderRange: Float { self == .linear ? 0 : Self.range }

    /// Deflection in a lane (full scale at ±1) of a signed sample value. Mirrors `scaled` in `waveformFragment`.
    func deflection(_ amplitude: Float) -> Float {
        guard self == .decibels else { return amplitude }
        let a = abs(amplitude)
        guard a > 0 else { return 0 }
        let y = max(0, min(1, 1 + 20 * log10(a) / Self.range))
        return amplitude < 0 ? -y : y
    }

    /// Deflection of a level in dBFS (positive half).
    func deflection(decibels: Float) -> Float { deflection(pow(10, decibels / 20)) }

    /// Levels the scale names, most useful first: on the linear scale −6 dBFS (half the lane) and full scale; on
    /// the dB scale, where −6 crowds the edge, full scale and the even steps down.
    var marks: [Float] { self == .linear ? [-6, 0, -12, -24] : [0, -12, -24, -6] }

    /// The marks labelled in a lane of `height`, at least `spacing` points apart and clear of the centre line.
    func labelled(laneHeight height: CGFloat, spacing: CGFloat = 11) -> [Float] {
        let half = height / 2
        var kept: [CGFloat] = []
        var result: [Float] = []
        for db in marks {
            let y = CGFloat(deflection(decibels: db)) * half
            guard y >= spacing * 0.7, kept.allSatisfy({ abs($0 - y) >= spacing }) else { continue }
            kept.append(y)
            result.append(db)
        }
        return result
    }
}
