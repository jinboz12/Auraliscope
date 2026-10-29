import AnalysisCore
import Foundation

/// One analysis result as a display draws it: a decoded RESULT (analysis schema 1), whether it came from this device's
/// own analysis or from a Bridge plugin over the network. The values are exactly those sent, in the protocol's units:
/// levels linear (1 = full scale), loudness in LUFS with −100 for "no value yet" and −1 for a range not yet
/// measurable, spectra in dBFS with −120 for silence. Nothing here is smoothed or recomputed; cumulative values
/// (integrated loudness, range, held peaks) are the analysing side's own.
public struct AnalysisFrame: Sendable {
    public struct Channel: Sendable, Equatable {
        /// Speaker role index (`Role`, the same as ABR_ROLE_*).
        public var role: Int
        public var name: String
        public var peak: Float, rms: Float, truePeak: Float, heldPeak: Float, heldTruePeak: Float
        /// Linear, signed; nil when the analysis does not measure it (a plugin before build 90).
        public var dcOffset: Float?
        /// Mean square below 20 Hz, linear.
        public var infrasonic: Float?
    }

    public var generation: UInt32
    public var formatEpoch: UInt32
    public var sampleRate: Double
    public var layout: UInt32
    public var channels: [Channel]
    public var tick: UInt64
    public var tickRate: Double
    public var framesAnalysed: UInt64
    public var measurement: UInt32       // 1 measuring, 2 paused
    public var idle: Bool                // published without new audio
    public var breaks: UInt32
    public var missingSeconds: Double
    public var lastBreakReasons: UInt32

    public var momentary: Float, shortTerm: Float, integrated: Float, loudnessRange: Float

    /// 64 display bands, dBFS, 20 Hz to `upperFrequency`.
    public var spectrum: [Float]
    /// The same bands halved (128); empty when not sent.
    public var spectrumFine: [Float]
    /// Whether the spectrum sums every channel (Immersive) rather than L and R.
    public var spectrumAllChannels: Bool
    public var dominantFrequency: Float?, dominantLevel: Float?

    /// L/R correlation, −1…1; nil when there is nothing to correlate.
    public var correlation: Float?
    /// Per band group (five bands, three, overall): correlation (nil none), width, balance, level dBFS.
    public var bandCorrelation: [Float?]
    public var bandWidth: [Float], bandBalance: [Float], bandLevel: [Float]
    /// Stereometer points: per stereo band, 128 (L, R) pairs (1280 floats).
    public var stereoPoints: [Float]
    /// 0 stereo, 1 immersive, 2 mono.
    public var detectedFormat: UInt32
    /// 1 settled, 0.5 settling, nil not measured.
    public var healthStatus: Float?

    // Ordered columns this result carries (not yet shown).
    public var spectrogramFirst: UInt64
    public var spectrogramColumns: [[Float]]
    public var spectrogramDropped: UInt64
    public var spectrogramEnhanced: Bool
    public var waveformFirst: UInt64
    public var waveformColumns: Int

    public var fftSize: UInt32

    public static let spectrumBands = MeterSnapshot.bandCount
    public static let spectrogramRows = MeterSnapshot.spectrogramBandCount
    public static let stereoBands = StereoBands.count
    public static let stereoBandEdges = StereoBands.edges

    /// The top of the frequency axis (20 kHz, or Nyquist below 40 kHz).
    public var upperFrequency: Double { LogFrequencyAxis.upper(sampleRate: sampleRate) }
    public static func bandCentre(_ index: Int, of count: Int, upper: Double) -> Double {
        LogFrequencyAxis.centre(index, of: count, upper: upper)
    }
    public static func axisPosition(of frequency: Double, upper: Double) -> Double {
        LogFrequencyAxis.position(of: frequency, upper: upper)
    }

    /// The loudness, true peak and range values at "no value yet".
    public static let noLoudness: Float = -100
    public var hasIntegrated: Bool { integrated > -99.5 }
    public var hasRange: Bool { loudnessRange >= 0 }

    /// The loudest held true peak of all channels (linear), with the held sample peak as a floor, as the desktop
    /// reports a file's true peak.
    public var maxHeldTruePeak: Float { channels.map { max($0.heldTruePeak, $0.heldPeak) }.max() ?? 0 }
    public var maxHeldPeak: Float { channels.map(\.heldPeak).max() ?? 0 }

    init(_ m: ResultMessage) {
        let roles = m.channelRoles ?? Array(0..<m.channels)
        channels = roles.indices.map { i in
            Channel(role: roles[i], name: SpeakerNames.name(roles[i], in: roles),
                    peak: m.peak[i], rms: m.rms[i], truePeak: m.truePeak[i], heldPeak: m.heldPeak[i],
                    heldTruePeak: m.heldTruePeak[i],
                    dcOffset: m.dcOffset.count == roles.count ? m.dcOffset[i] : nil,
                    infrasonic: m.infrasonic.count == roles.count ? m.infrasonic[i] : nil)
        }
        generation = m.generation
        formatEpoch = m.formatEpoch
        sampleRate = m.sampleRate
        layout = m.layout
        tick = m.tick
        tickRate = m.tickRate
        framesAnalysed = m.framesAnalysed
        measurement = m.measurement.rawValue
        idle = m.flags & ResultFlags.idle != 0
        breaks = m.breaks
        missingSeconds = m.missingSeconds
        lastBreakReasons = m.lastBreakReasons
        momentary = m.momentary
        shortTerm = m.shortTerm
        integrated = m.integrated
        loudnessRange = m.loudnessRange
        spectrum = m.spectrum.count == MeterSnapshot.bandCount ? m.spectrum : []
        spectrumFine = m.spectrumFine.count == MeterSnapshot.fineBandCount ? m.spectrumFine : []
        spectrumAllChannels = (m.spectrumChannels ?? 0) == 1
        if m.dominant.count == 2, m.dominant[0] > 0 {
            dominantFrequency = m.dominant[0]
            dominantLevel = m.dominant[1]
        }
        correlation = m.correlation <= MeterSnapshot.noCorrelation + 0.5 ? nil : m.correlation
        bandCorrelation = m.bandCorrelation.map { $0 <= MeterSnapshot.noCorrelation + 0.5 ? nil : $0 }
        bandWidth = m.bandWidth
        bandBalance = m.bandBalance
        bandLevel = m.bandLevel
        stereoPoints = m.bandPoints.count == StereoBands.scopeFloats ? m.bandPoints : []
        detectedFormat = m.detectedFormat
        healthStatus = m.dcOffset.isEmpty ? nil : m.healthStatus
        spectrogramFirst = m.spectrogramFirst
        let rows = m.spectrogramRows
        spectrogramColumns = (0..<m.spectrogramColumns).map { Array(m.spectrogram[($0 * rows)..<(($0 + 1) * rows)]) }
        spectrogramDropped = m.spectrogramDropped
        spectrogramEnhanced = (m.spectrogramMode ?? 0) == 1
        waveformFirst = m.waveformFirst
        waveformColumns = m.waveformColumns
        fftSize = m.fftSize
    }

    /// Decodes a RESULT payload; nil when it is not one this display can show (PROTOCOL.md: required fields, sizes,
    /// schema), whatever bytes it holds.
    public static func decode(_ payload: Data) -> AnalysisFrame? {
        let m = payload.withUnsafeBytes { ResultMessage.decode($0) }
        return m.valid ? AnalysisFrame(m) : nil
    }
}

/// Speaker names as Auraliscope shows them (the plugin window's `roleName`): side surrounds are Lss/Rss beside rear
/// surrounds.
public enum SpeakerNames {
    static let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Ltf", "Rtf", "Lrs", "Rrs", "Lw", "Rw", "Ltm", "Rtm", "Ltr", "Rtr"]

    public static func name(_ role: Int, in roles: [Int]) -> String {
        guard names.indices.contains(role) else { return "?" }
        if roles.contains(Role.leftRearSurround) {
            if role == Role.leftSurround { return "Lss" }
            if role == Role.rightSurround { return "Rss" }
        }
        if roles == [Role.left] { return "M" }
        return names[role]
    }
}

/// Decibels of a linear amplitude, as the desktop's `MeterScale.decibels` writes them: −120 at or below 10⁻⁶.
public func decibels(_ amplitude: Float) -> Float {
    amplitude > 0.000001 ? 20 * log10(amplitude) : -120
}
