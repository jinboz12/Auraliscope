import Foundation

/// Loudness delivery standards offered on the summary. A standard sets the target (gauge, delta, history band, the VU
/// alignment when 0 VU follows the target), its true-peak ceiling and how a measurement is judged against it.
/// Stereo (with Mono) and Spatial each keep their own standard.
struct LoudnessStandard: Hashable, Identifiable {
    /// How a measurement is judged.
    enum Kind: Hashable {
        /// Delivery specification: integrated loudness within ±`tolerance` LU of the target, true peak at or below the
        /// ceiling.
        case delivery(tolerance: Double)
        /// An upper limit: integrated loudness no louder than the target, true peak at or below the ceiling.
        case maximum
        /// A playback service normalizes to the target: louder programmes are turned down. The verdict is how it will
        /// play, not a pass or a fail.
        case normalization
        /// A mastering aim with no published tolerance: the reading is the difference alone.
        case reference
    }

    let id: String
    let target: Double
    let ceiling: Double
    let kind: Kind
    /// The specification measures dialogue loudness (dialogue-gated). The meter measures the full programme with the
    /// BS.1770 gates, so its reading can differ on programmes with music and effects louder than speech.
    var dialogue = false
    /// Technical standards retain their names; commercial presets use neutral descriptions.
    let names: [String]

    /// Menu label in the current language.
    var title: String { names.map { L($0) }.joined(separator: " · ") }
    /// The first name, for the compliance tile.
    var shortTitle: String { L(names[0]) }

    /// From loudest to quietest.
    static let all: [LoudnessStandard] = [
        LoudnessStandard(id: "club", target: -9, ceiling: -1, kind: .reference, names: [LKey("Loud master · club, EDM")]),
        LoudnessStandard(id: "spotify-loud", target: -11, ceiling: -2, kind: .normalization, names: [LKey("Streaming · loud")]),
        LoudnessStandard(id: "streaming", target: -14, ceiling: -1, kind: .normalization,
                         names: [LKey("Music streaming")]),
        LoudnessStandard(id: "deezer", target: -15, ceiling: -1, kind: .normalization, names: [LKey("Music streaming")]),
        LoudnessStandard(id: "apple", target: -16, ceiling: -1, kind: .normalization, names: [LKey("Music & podcasts")]),
        LoudnessStandard(id: "atmos-music", target: -18, ceiling: -1, kind: .maximum, names: [LKey("Immersive music")]),
        LoudnessStandard(id: "aswg-mobile", target: -18, ceiling: -1, kind: .delivery(tolerance: 2),
                         names: [LKey("Games · mobile (ASWG-R001)")]),
        LoudnessStandard(id: "r128", target: -23, ceiling: -1, kind: .delivery(tolerance: 0.5), names: ["EBU R128"]),
        LoudnessStandard(id: "arib", target: -24, ceiling: -1, kind: .delivery(tolerance: 1), names: ["ARIB TR-B32"]),
        LoudnessStandard(id: "aswg-console", target: -24, ceiling: -1, kind: .delivery(tolerance: 2),
                         names: [LKey("Games · console (ASWG-R001)")]),
        LoudnessStandard(id: "atsc", target: -24, ceiling: -2, kind: .delivery(tolerance: 2), names: ["ATSC A/85"]),
        LoudnessStandard(id: "op59", target: -24, ceiling: -2, kind: .delivery(tolerance: 1), names: ["OP-59"]),
        LoudnessStandard(id: "prime", target: -24, ceiling: -2, kind: .delivery(tolerance: 2), names: [LKey("Online video")]),
        LoudnessStandard(id: "netflix", target: -27, ceiling: -2, kind: .delivery(tolerance: 2), dialogue: true,
                         names: [LKey("Film & series · dialogue")])
    ]
    /// True-peak ceilings offered on the summary, in dBTP.
    static let ceilings: [Double] = [-0.1, -0.5, -1, -1.5, -2, -3]
    /// A target and ceiling set by hand are judged as a delivery within ±1 LU.
    static let customTolerance = 1.0

    static func with(id: String?) -> LoudnessStandard? { all.first { $0.id == id } }

    /// The first standard with this target and ceiling (for settings saved before standards had identities).
    static func matching(target: Double, ceiling: Double) -> LoudnessStandard? {
        all.first { $0.target == target && $0.ceiling == ceiling }
    }

    /// The tolerance line for the menu and the report.
    var rule: String {
        switch kind {
        case .delivery(let tolerance): return "±\(MeterScale.tenths(Float(tolerance))) LU"
        case .maximum: return L("maximum")
        case .normalization: return L("normalized")
        case .reference: return L("aim")
        }
    }
}

/// How a measurement stands against a standard: the integrated loudness and the highest true peak since the last
/// reset, judged once the measurement has run long enough to mean something.
struct ComplianceResult: Equatable {
    enum State: Equatable { case measuring, pass, check, info }

    let state: State
    /// The headline word: PASS, CHECK, a playback change or a difference.
    let headline: String
    /// What decided it, one short line each.
    let reasons: [String]

    /// Seconds of measurement before a verdict.
    static let minimumSeconds: TimeInterval = 10

    static func evaluate(standard: LoudnessStandard?, target: Double, ceiling: Double, integrated: Float, truePeak: Float,
                         elapsed: TimeInterval) -> ComplianceResult {
        guard integrated > -70, elapsed >= minimumSeconds else {
            return ComplianceResult(state: .measuring, headline: L("MEASURING"), reasons: [L("A verdict after %d s of programme", Int(minimumSeconds))])
        }
        // Readings compare as they are shown, to a tenth, so the verdict never disagrees with the numbers beside it.
        let integratedShown = (Double(integrated) * 10).rounded() / 10
        let peakShown = (Double(truePeak) * 10).rounded() / 10
        let delta = integratedShown - target
        let peakOK = peakShown <= ceiling
        let peakLine = peakOK ? L("TP %@ dBTP, within %@", MeterScale.tenths(Float(peakShown)), MeterScale.tenths(Float(ceiling)))
                              : L("TP %@ dBTP, above %@", MeterScale.signedTenths(Float(peakShown)), MeterScale.tenths(Float(ceiling)))
        let deltaText = MeterScale.signedTenths(Float(delta))
        switch standard?.kind ?? .delivery(tolerance: LoudnessStandard.customTolerance) {
        case .delivery(let tolerance):
            let inside = abs(delta) <= tolerance + 1e-9
            let line = inside ? L("I %@ LU from target, within ±%@", deltaText, MeterScale.tenths(Float(tolerance)))
                              : L("I %@ LU from target, outside ±%@", deltaText, MeterScale.tenths(Float(tolerance)))
            return ComplianceResult(state: inside && peakOK ? .pass : .check, headline: inside && peakOK ? L("PASS") : L("CHECK"),
                                    reasons: [line, peakLine])
        case .maximum:
            let inside = delta <= 1e-9
            let line = inside ? L("I %@ LU, at or below the limit", deltaText) : L("I %@ LU above the limit", deltaText)
            return ComplianceResult(state: inside && peakOK ? .pass : .check, headline: inside && peakOK ? L("PASS") : L("CHECK"),
                                    reasons: [line, peakLine])
        case .normalization:
            // Louder programmes are turned down to the target; quieter ones play as they are on most services.
            let line: String
            let headline: String
            if delta > 0.05 {
                headline = "−\(MeterScale.tenths(Float(delta))) dB"
                line = L("Plays %@ dB quieter after normalization", MeterScale.tenths(Float(delta)))
            } else if delta < -0.05 {
                headline = "\(deltaText) LU"
                line = L("%@ LU below the service's level; most play it as it is", MeterScale.tenths(Float(-delta)))
            } else {
                headline = L("ON TARGET")
                line = L("Plays at its own level")
            }
            return ComplianceResult(state: peakOK ? .info : .check, headline: headline, reasons: [line, peakLine])
        case .reference:
            return ComplianceResult(state: peakOK ? .info : .check, headline: "\(deltaText) LU",
                                    reasons: [L("I %@ LU from the aim", deltaText), peakLine])
        }
    }
}

/// How loudness readings are written: absolute (LUFS) or relative to the target (LU, 0 at the target), as an
/// EBU-mode meter's relative scale reads.
enum LoudnessUnit: String, CaseIterable {
    case lufs, lu

    static let key = "loudness.unit"
    static var stored: LoudnessUnit { LoudnessUnit(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .lufs }

    var title: String {
        switch self {
        case .lufs: return "LUFS"
        case .lu: return "LU"
        }
    }

    /// A loudness reading in this unit; silence reads as −∞ in both.
    func text(_ lufs: Float, target: Float) -> String {
        switch self {
        case .lufs: return MeterScale.tenths(lufs)
        case .lu: return lufs > -99 ? MeterScale.signedTenths(lufs - target) : "−∞"
        }
    }

    /// A scale label at `lufs`.
    func label(_ lufs: Float, target: Float) -> String {
        switch self {
        case .lufs: return MeterScale.signedInteger(lufs)
        case .lu:
            let relative = Int((lufs - target).rounded())
            return relative > 0 ? "+\(relative)" : MeterScale.signedInteger(Float(relative))
        }
    }
}

/// The loudness gauge's range: the meter's own −36…0 LUFS, or the EBU Tech 3341 scales, −18…+9 LU or −36…+18 LU around
/// the target.
enum LoudnessScale: String, CaseIterable {
    case full, ebu9, ebu18

    static let key = "loudness.scale"

    var title: String {
        switch self {
        case .full: return L("Full")
        case .ebu9: return "EBU +9"
        case .ebu18: return "EBU +18"
        }
    }

    func range(target: Float) -> ClosedRange<Float> {
        switch self {
        case .full: return MeterScale.loudnessFloor...0
        case .ebu9: return (target - 18)...(target + 9)
        case .ebu18: return (target - 36)...(target + 18)
        }
    }

    /// Minor ticks every `step` LU; labels every `labelStep`.
    var step: Float { self == .ebu18 ? 6 : 3 }
    var labelStep: Float { self == .ebu18 ? 18 : (self == .ebu9 ? 9 : 12) }
}
