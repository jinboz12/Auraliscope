import AnalysisCore
import CoreGraphics
import Foundation
// Pure scale and layout math shared by the Metal scenes and the SwiftUI label overlays,
// so both sides place ticks, bars and speaker nodes from one source of truth.
enum MeterScale {
    static let spectrumFloor: Float = -96
    static let loudnessFloor: Float = -36

    static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0.000001 ? 20 * log10(amplitude) : -120
    }

    /// IEC 60268-18 style deflection: expands the top 20 dB where engineers read peaks.
    static func position(decibels db: Float) -> Float {
        switch db {
        case ..<(-70): return 0
        case ..<(-60): return (db + 70) * 0.0025
        case ..<(-50): return (db + 60) * 0.005 + 0.025
        case ..<(-40): return (db + 50) * 0.0075 + 0.075
        case ..<(-30): return (db + 40) * 0.015 + 0.15
        case ..<(-20): return (db + 30) * 0.02 + 0.3
        case ..<0: return (db + 20) * 0.025 + 0.5
        default: return 1
        }
    }

    static func position(amplitude: Float) -> Float { position(decibels: decibels(amplitude)) }

    static func upperFrequency(sampleRate: Double) -> Double { LogFrequencyAxis.upper(sampleRate: sampleRate) }

    /// Fraction of a frequency along an analyzer's axis: the shared 20 Hz – upper log axis, or 0 Hz – upper linear.
    static func frequencyFraction(_ frequency: Double, sampleRate: Double, scale: FrequencyScale = .log) -> CGFloat {
        let upper = upperFrequency(sampleRate: sampleRate)
        switch scale {
        case .log: return CGFloat(LogFrequencyAxis.position(of: max(frequency, 20), upper: upper))
        case .linear: return CGFloat(max(0, frequency) / upper)
        }
    }

    /// Inverse of `frequencyFraction`.
    static func frequency(fraction: Double, sampleRate: Double, scale: FrequencyScale = .log) -> Double {
        let upper = upperFrequency(sampleRate: sampleRate)
        switch scale {
        case .log: return LogFrequencyAxis.frequency(atPosition: fraction, upper: upper)
        case .linear: return max(0, fraction) * upper
        }
    }

    static func spectrumFraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - spectrumFloor) / -spectrumFloor)))
    }

    /// Fixed one-decimal text with a true minus sign; silence reads as −∞.
    /// Whole number with a typographic minus, e.g. "−18".
    static func signedInteger(_ value: Float) -> String {
        let rounded = Int(value.rounded())
        return rounded < 0 ? "−\(-rounded)" : "\(rounded)"
    }

    static func tenths(_ value: Float, floor: Float = -99) -> String {
        guard value.isFinite, value > floor else { return "−∞" }
        let scaled = Int((value * 10).rounded())
        let magnitude = abs(scaled)
        return "\(scaled < 0 ? "−" : "")\(magnitude / 10).\(magnitude % 10)"
    }

    /// `tenths` with an explicit plus for positive values, for amounts over a limit: "+0.8".
    static func signedTenths(_ value: Float, floor: Float = -99) -> String {
        let text = tenths(value, floor: floor)
        return Int((value * 10).rounded()) > 0 ? "+" + text : text
    }

    /// Level change when L and R are summed to mono, in dB, against the average of the two sides: 0 for identical
    /// sides, about −3 for unrelated ones, and falling toward −∞ as the sides cancel. `left` and `right` are RMS
    /// amplitudes; nil in silence. Clamped at −40 dB.
    static func monoFoldDown(correlation: Float, left: Float, right: Float) -> Float? {
        let pl = Double(left) * Double(left), pr = Double(right) * Double(right)
        guard pl + pr > 1e-10, correlation != MeterSnapshot.noCorrelation else { return nil }
        let r = Double(max(-1, min(1, correlation)))
        let ratio = (pl + pr + 2 * r * (pl * pr).squareRoot()) / (2 * (pl + pr))
        return Float(max(-40, 10 * log10(max(ratio, 1e-4))))
    }
}

/// What an L/R correlation reading means: +1 is the same signal on both sides (mono), 0 two unrelated sides
/// (very wide), −1 one side inverted, which cancels when the mix is folded to mono. The meter names the zone
/// beside its number and colours its bar by it.
enum CorrelationZone: Int, CaseIterable {
    case outOfPhase, wide, stereo, mono

    /// Lower edges of `wide`, `stereo` and `mono`.
    static let edges: [Float] = [-0.1, 0.3, 0.9]
    /// A reading leaves its zone only once it is this far past the edge, so the name does not flicker.
    static let hysteresis: Float = 0.05

    /// The name printed beside the correlation reading, in the current language.
    var title: String {
        switch self {
        case .outOfPhase: return L("OUT OF PHASE")
        case .wide: return L("WIDE")
        case .stereo: return L("STEREO")
        case .mono: return L("MONO")
        }
    }

    /// The zone's name under the track.
    var caption: String {
        switch self {
        case .outOfPhase: return L("Out of phase")
        case .wide: return L("Wide")
        case .stereo: return L("Stereo")
        case .mono: return L("Mono")
        }
    }

    /// What the reading means for the listener, in one or two short lines.
    var hint: String {
        switch self {
        case .outOfPhase: return L("Sounds hollow and loses its centre; cancels on mono speakers, phones and club PAs.")
        case .wide: return L("Very wide: some parts thin out or drop away when played in mono.")
        case .stereo: return L("Healthy stereo width that holds up on mono speakers.")
        case .mono: return L("Almost mono: narrow and centred, fully mono-safe.")
        }
    }

    /// The zone of `value`; next to an edge the `previous` zone holds until the reading clears it.
    init(_ value: Float, previous: CorrelationZone? = nil) {
        let raw = CorrelationZone(rawValue: Self.edges.filter { value >= $0 }.count) ?? .mono
        if let previous, abs(previous.rawValue - raw.rawValue) == 1,
           abs(value - Self.edges[min(previous.rawValue, raw.rawValue)]) < Self.hysteresis {
            self = previous
        } else {
            self = raw
        }
    }
}

/// Equal-tempered pitch (A4 = 440 Hz) of a frequency: MIDI = 69 + 12·log2(f / 440).
struct Pitch: Equatable {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let midi: Int
    let cents: Int

    init?(frequency: Double) {
        guard frequency.isFinite, frequency >= 8 else { return nil }
        let exact = 69 + 12 * log2(frequency / 440)
        var nearest = Int(exact.rounded())
        var cents = Int(((exact - Double(nearest)) * 100).rounded())
        // −50.4 rounds to −50 but +49.6 to +50; keep the range to −50…+49 on the nearer note.
        if cents == 50 { nearest += 1; cents = -50 }
        midi = nearest
        self.cents = cents
    }

    var name: String { Self.names[((midi % 12) + 12) % 12] }
    /// Scientific pitch notation: MIDI 60 is C4.
    var octave: Int { Int((Double(midi) / 12).rounded(.down)) - 1 }
    var label: String { "\(name)\(octave)" }
    var centsLabel: String { cents == 0 ? "±0¢" : (cents > 0 ? "+\(cents)¢" : "−\(-cents)¢") }
}

/// Readability filter for the peak readout: fast attack, short hold, gentle decay, noise gate.
struct PeakTracker: Equatable {
    static let gate: Float = -60
    static let holdTime = 0.4
    static let decayPerSecond: Float = 24

    private(set) var frequency: Float = 0
    private(set) var level: Float = -120
    private(set) var visible = false
    private var hold = 0.0

    mutating func update(frequency newFrequency: Float, level newLevel: Float, deltaTime: Double) {
        let gated = newLevel < Self.gate || newFrequency <= 0
        let decayed = level - Self.decayPerSecond * Float(deltaTime)
        guard visible else {
            if !gated { accept(newFrequency, newLevel) }
            return
        }
        let sameNote = !gated && abs(12 * log2(newFrequency / frequency)) < 0.5
        if sameNote {
            // Same note: average the frequency so cents settle, attack instantly on level.
            frequency += (newFrequency - frequency) * 0.5
            level = max(newLevel, decayed)
            hold = Self.holdTime
        } else if !gated && newLevel >= level - 3 {
            accept(newFrequency, newLevel)
        } else {
            hold -= deltaTime
            level = max(newLevel, decayed)
            if hold <= 0 {
                if gated { visible = false } else { accept(newFrequency, newLevel) }
            }
        }
    }

    mutating func reset() { self = PeakTracker() }

    private mutating func accept(_ newFrequency: Float, _ newLevel: Float) {
        frequency = newFrequency
        level = newLevel
        visible = true
        hold = Self.holdTime
    }
}

/// The notes lit on the Spectrum panel's keyboard, from the analyzer's `notes` sampled at 10 Hz: each key stays
/// lit 0.35 s after its note was last found (so a note does not flicker between readouts), with its newest level;
/// notes under the peak readout's gate are ignored.
struct NoteHolds: Equatable {
    static let holdTime = 0.35

    struct Note: Equatable {
        let midi: Int
        /// The newest refined frequency the analyzer found for this key, in Hz.
        var frequency: Float
        var level: Float
        var hold: Double
    }

    private(set) var notes: [Note] = []

    /// `packed` is `MeterSnapshot.notes`: (Hz, dBFS) pairs, frequency 0 for none.
    mutating func update(_ packed: [Float], deltaTime: Double) {
        for index in notes.indices { notes[index].hold -= deltaTime }
        for pair in stride(from: 0, to: packed.count - 1, by: 2) {
            let frequency = packed[pair], level = packed[pair + 1]
            guard frequency > 0, level >= PeakTracker.gate else { continue }
            let midi = Int((69 + 12 * log2(Double(frequency) / 440)).rounded())
            if let index = notes.firstIndex(where: { $0.midi == midi }) {
                notes[index].frequency = frequency
                notes[index].level = level
                notes[index].hold = Self.holdTime
            } else {
                notes.append(Note(midi: midi, frequency: frequency, level: level, hold: Self.holdTime))
            }
        }
        notes.removeAll { $0.hold <= 0 }
    }

    mutating func reset() { notes = [] }
}

/// Uniform-grid monotone cubic Hermite interpolation for spectrum drawing. Harmonic-mean slopes
/// vanish at extrema and preserve the interval between adjacent measured levels (including mirrored axes).
/// This only draws the curve; measurement values and analysis bandwidth are unchanged.
enum SpectrumInterpolation {
    static func value(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, fraction: CGFloat) -> CGFloat {
        func slope(_ left: CGFloat, _ right: CGFloat) -> CGFloat {
            guard left * right > 0 else { return 0 }
            return 2 * left * right / (left + right)
        }
        let t = max(0, min(1, fraction)), t2 = t * t, t3 = t2 * t
        let delta = c - b
        let m0 = slope(b - a, delta), m1 = slope(delta, d - c)
        return (2 * t3 - 3 * t2 + 1) * b + (t3 - 2 * t2 + t) * m0
             + (-2 * t3 + 3 * t2) * c + (t3 - t2) * m1
    }
}
