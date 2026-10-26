import AnalysisCore
import SwiftUI

/// Where the live spectrum sits beside the spectrogram. On the left the whole pair mirrors: the waterfall's
/// newest column meets the spectrum at the waterfall's left edge, and the spectrum's levels rise toward the keys.
enum SpectrumSide: String, CaseIterable {
    case right, left

    static let key = "spectrum.side"
    static var stored: SpectrumSide { SpectrumSide(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .right }

    /// Offered as the panel's orientation: standard, or mirrored left to right.
    var title: String { self == .right ? L("Standard") : L("Mirrored") }
}

/// The loudness summary's main reading: the large number, its gauge and its delta to the target. The other two
/// LUFS readings take the tiles beside it.
enum LoudnessReading: String, CaseIterable {
    case momentary, shortTerm, integrated

    static let key = "loudness.headline"
    static var stored: LoudnessReading { LoudnessReading(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .shortTerm }

    var title: String {
        switch self {
        case .momentary: return L("Momentary")
        case .shortTerm: return L("Short-term")
        case .integrated: return L("Integrated")
        }
    }
    /// Over the main reading.
    var heading: String {
        switch self {
        case .momentary: return L("MOMENTARY LOUDNESS")
        case .shortTerm: return L("SHORT-TERM LOUDNESS")
        case .integrated: return L("INTEGRATED LOUDNESS")
        }
    }
    /// The standard abbreviation (EBU Tech 3341): M, S, I.
    var abbreviation: String {
        switch self {
        case .momentary: return "M"
        case .shortTerm: return "S"
        case .integrated: return "I"
        }
    }
    /// On a tile.
    var tileTitle: String {
        switch self {
        case .momentary: return L("MOMENTARY")
        case .shortTerm: return L("SHORT-TERM")
        case .integrated: return L("INTEGRATED")
        }
    }
    func value(_ values: Readouts.Values) -> Float {
        switch self {
        case .momentary: return values.momentary
        case .shortTerm: return values.shortTerm
        case .integrated: return values.integrated
        }
    }
}

/// Display choices that shape the panels, read by the canvases every frame.
struct DisplayOptions: Equatable {
    var spectrumSide = SpectrumSide.right
    /// The live spectrum's per-band peak dashes.
    var peakHolds = true
    /// Seconds across the Waveform lanes, and their vertical scale.
    var waveSeconds = 4
    var waveScale = WaveScale.linear
    /// The Immersive room's band markers (the BANDS menu's Off hides them).
    var bandMarkers = true
    /// The levels the spectrogram's colors span, and the display slope of the spectrum and spectrogram.
    var spectrogramRange = SpectrogramRange.standard
    var spectrogramColors = SpectrogramColors.heat
    var tilt = SpectrumTilt.flat
    /// How the Spectrum panel spaces frequency (`FrequencyScale`).
    var frequencyScale = FrequencyScale.log
    /// The live spectrum's long-term average since the last reset.
    var averageSpectrum = true
    /// How quickly the live spectrum follows the sound.
    var spectrumResponse = SpectrumResponse.medium
    /// Seconds across the spectrogram.
    var spectrogramSpan = SpectrogramSpan.auto
    /// Smoothing of the live spectrum across frequency.
    var spectrumSmoothing = SpectrumSmoothing.sixth
    /// Classic or reassigned spectrogram, drawn flat or in 3D.
    var spectrogramAnalysis = SpectrogramAnalysis.classic
    var spectrogramView = SpectrogramView.flat
    var domeView = DomeView.perspective
    /// The Immersive dome's bands, and the Stereo/Mono stereometer's single band (nil: every band of its split).
    var domeBands = BandChoice(.overall)
    var stageSolo: Int?
    /// The programme's energy centre in the dome, as the stereometer's focal dot; on unless turned off.
    var domeCentroid = true
    var domeYaw = 0.0
    var domePitch = DomeGeometry.defaultPitch
    var domeZoom = 1.0
    /// The pose the window's camera shows (`DomeCamera`), its turn continuous; nil derives it from the fields above.
    var domePose: DomePose?
    /// Counts the camera's glides, so the canvas glides with the labels (`DomePoseSpring`).
    var domeGlides = 0
    /// The pose to draw: the window's, or the one the fields stand for.
    var cameraPose: DomePose { domePose ?? DomePose(view: domeView, yaw: domeYaw, pitch: domePitch, zoom: domeZoom) }
    /// The Immersive nebula's display settings.
    var nebula = NebulaSettings()
    /// Channel Levels' peak-hold marks: seconds held (0: until reset) and the release after it.
    var levelsHold = PeakHoldTime.standard
    var levelsRelease = PeakRelease.normal

    static let domeBandsKey = "soundstage.domeBands"
    /// Build 76's dome band (−1 full, −2 all five, 0…4 one band), read once when the new key is unset.
    static let legacyDomeBandKey = "soundstage.domeBand"
    static let stageBandsKey = "soundstage.bands"
    static let levelsBandsKey = "levels.bands"

    static var storedDomeBands: BandChoice {
        let defaults = UserDefaults.standard
        if let choice = defaults.string(forKey: domeBandsKey).flatMap(BandChoice.init(rawValue:)) { return choice }
        guard defaults.object(forKey: legacyDomeBandKey) != nil else { return BandChoice(.overall) }
        let band = defaults.integer(forKey: legacyDomeBandKey)
        return band == -1 ? BandChoice(.overall) : (band == -2 ? BandChoice(.five) : BandChoice(.five, solo: band))
    }
    static let domeCentroidKey = "soundstage.domeCentroid"
    static let domeYawKey = "soundstage.domeYaw"
    static let domePitchKey = "soundstage.domePitch"
    static let domeZoomKey = "soundstage.domeZoom"

    static let peakHoldsKey = "spectrum.peakHolds"
    static let waveSecondsKey = "waveform.seconds"
    static let bandMarkersKey = "soundstage.bandMarkers"
    static let averageSpectrumKey = "spectrum.average"
    static let waveChoices = [2, 4, 8]

    static var stored: DisplayOptions {
        let defaults = UserDefaults.standard
        let seconds = defaults.integer(forKey: waveSecondsKey)
        return DisplayOptions(spectrumSide: .stored,
                              peakHolds: defaults.object(forKey: peakHoldsKey) == nil ? true : defaults.bool(forKey: peakHoldsKey),
                              waveSeconds: waveChoices.contains(seconds) ? seconds : 4,
                              waveScale: .stored,
                              bandMarkers: defaults.object(forKey: bandMarkersKey) == nil ? true : defaults.bool(forKey: bandMarkersKey),
                              spectrogramRange: .stored, spectrogramColors: .stored, tilt: .stored, frequencyScale: .stored,
                              averageSpectrum: defaults.object(forKey: averageSpectrumKey) == nil ? true : defaults.bool(forKey: averageSpectrumKey),
                              spectrumResponse: .stored, spectrogramSpan: .stored, spectrumSmoothing: .stored,
                              spectrogramAnalysis: .stored, spectrogramView: .stored,
                              domeView: DomeView(rawValue: defaults.string(forKey: DomeView.key) ?? "") ?? .perspective,
                              domeBands: storedDomeBands,
                              stageSolo: defaults.string(forKey: stageBandsKey).flatMap(BandChoice.init(rawValue:))?.solo,
                              domeCentroid: defaults.object(forKey: domeCentroidKey) == nil ? true : defaults.bool(forKey: domeCentroidKey),
                              domeYaw: defaults.double(forKey: domeYawKey),
                              domePitch: defaults.object(forKey: domePitchKey) == nil ? DomeGeometry.defaultPitch : defaults.double(forKey: domePitchKey),
                              domeZoom: defaults.object(forKey: domeZoomKey) == nil ? 1
                                  : min(DomeGeometry.zoomRange.upperBound, max(DomeGeometry.zoomRange.lowerBound, defaults.double(forKey: domeZoomKey))),
                              nebula: .stored, levelsHold: .stored, levelsRelease: .stored)
    }
}

/// How long Channel Levels holds each channel's peak mark before it falls.
enum PeakHoldTime: String, CaseIterable {
    case short, standard, long, infinite

    static let key = "levels.hold"
    static var stored: PeakHoldTime { PeakHoldTime(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard }

    /// Seconds; nil holds until a reset.
    var seconds: Float? {
        switch self {
        case .short: return 0.5
        case .standard: return 1.5
        case .long: return 3
        case .infinite: return nil
        }
    }

    var title: String {
        switch self {
        case .short: return L("%@ s", "0.5")
        case .standard: return L("%@ s", "1.5")
        case .long: return L("%@ s", "3")
        case .infinite: return "∞"
        }
    }
}

/// How fast a held peak mark falls once its hold has passed: fast, the meter's own 20 dB/s, or a PPM's slow return
/// (24 dB in 2.8 s, IEC 60268-10 Type II).
enum PeakRelease: String, CaseIterable {
    case fast, normal, ppm

    static let key = "levels.release"
    static var stored: PeakRelease { PeakRelease(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .normal }

    var decibelsPerSecond: Float {
        switch self {
        case .fast: return 40
        case .normal: return 20
        case .ppm: return 24 / 2.8
        }
    }

    var title: String {
        switch self {
        case .fast: return L("Fast")
        case .normal: return L("Normal")
        case .ppm: return "PPM"
        }
    }
}

/// How the Stereo stereometer draws each band: the sample cloud, the outline of where the band's samples reach,
/// or that outline over a tinted fill. Chosen in the panel's settings.
enum StageStyle: String, CaseIterable {
    case dots, outline, filled

    static let key = "soundstage.style"
    static var stored: StageStyle { StageStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dots }

    var title: String {
        switch self {
        case .dots: return L("Dots")
        case .outline: return L("Outlines")
        case .filled: return L("Filled")
        }
    }
}
