import AnalysisCore
import Foundation

/// The five band hues on a dark ground, warm at the bottom of the spectrum to cool at the top (red, amber, green, blue,
/// violet): `Theme.bandRGB` draws them, deepened on light, and the Immersive nebula runs them along log frequency as one
/// spectral scale, so a direction is coloured by what is heard from it in the same hues the bands wear.
enum SpectralHue {
    static let bands: [SIMD3<Float>] = [SIMD3(0.93, 0.37, 0.33), SIMD3(0.95, 0.69, 0.26), SIMD3(0.42, 0.79, 0.46),
                                        SIMD3(0.37, 0.63, 0.96), SIMD3(0.73, 0.51, 0.96)]
    /// log₂ of each band's geometric centre in Hz (about 49 Hz, 245 Hz, 1 kHz, 4 kHz and 12.6 kHz).
    static let centres: [Double] = (0..<StereoBands.count).map { band in
        let low = StereoBands.edges[band], high = band + 1 < StereoBands.count ? StereoBands.edges[band + 1] : 20_000
        return log2((low * high).squareRoot())
    }

    /// The hue at `hz`: each band's hue at its centre, run straight between neighbours in log frequency and held beyond
    /// the outer centres.
    static func at(hz: Double) -> SIMD3<Float> {
        let x = log2(max(1, hz))
        guard x > centres[0] else { return bands[0] }
        for band in 1..<StereoBands.count where x <= centres[band] {
            let t = Float((x - centres[band - 1]) / (centres[band] - centres[band - 1]))
            return bands[band - 1] + (bands[band] - bands[band - 1]) * t
        }
        return bands[StereoBands.count - 1]
    }
}

// The analysis core has no localized text; the band switchers' words live with the app.
extension StereoBands.Resolution {
    /// A group's label: its lower edge, or "Full band".
    func label(_ group: Int) -> String { self == .overall ? L("Full band") : StereoBands.label(groups[group][0]) }
    /// The switcher's segment: "Full band", "3 bands", "5 bands" (multiband meters name their split by the
    /// number of bands, and a meter that does not split reads full band).
    var title: String { self == .overall ? L("Full band") : L("%d bands", count) }
}

/// The Soundstage's band choice, offered alike in Mono, Stereo and Immersive: a split (full band, 3 or 5 bands),
/// either every band of it in its colour or one band of it alone. Stored as the split's raw value, with ".n" for a
/// single band ("five", "three.1"), so a plain resolution written by earlier builds still reads.
struct BandChoice: Hashable {
    var resolution: StereoBands.Resolution
    /// The one group shown alone, or nil for every group of the split.
    var solo: Int?

    init(_ resolution: StereoBands.Resolution, solo: Int? = nil) {
        self.resolution = resolution
        self.solo = resolution == .overall ? nil : solo.map { max(0, min(resolution.count - 1, $0)) }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", maxSplits: 1)
        guard let first = parts.first, let resolution = StereoBands.Resolution(rawValue: String(first)) else { return nil }
        self.init(resolution, solo: parts.count > 1 ? Int(parts[1]) : nil)
    }

    var rawValue: String { solo.map { "\(resolution.rawValue).\($0)" } ?? resolution.rawValue }

    /// The groups drawn, low to high.
    var groups: [Int] { solo.map { [$0] } ?? Array(0..<resolution.count) }

    /// On the BANDS capsule: the split, or the single band's range.
    var title: String { solo.map { Self.range(resolution, $0) } ?? resolution.title }

    /// A group's frequency range, "120 Hz–2 kHz"; numeric labels are language-independent units.
    static func range(_ resolution: StereoBands.Resolution, _ group: Int) -> String {
        guard resolution != .overall else { return L("Full band") }
        let members = resolution.groups[max(0, min(resolution.count - 1, group))]
        let low = StereoBands.edges[members[0]]
        let high = members[members.count - 1] + 1 < StereoBands.count ? StereoBands.edges[members[members.count - 1] + 1] : 20_000
        func text(_ hz: Double) -> String { hz >= 1_000 ? "\(Int(hz / 1_000)) kHz" : "\(Int(hz)) Hz" }
        // Both ends in one unit read as one: "20–120 Hz", "2–8 kHz".
        guard (low >= 1_000) != (high >= 1_000) else { return "\(Int(low >= 1_000 ? low / 1_000 : low))–\(text(high))" }
        return "\(text(low))–\(text(high))"
    }

    /// The single bands the menu offers: the current split's, or the five while the full band is shown.
    var singles: [BandChoice] {
        let split = resolution == .overall ? StereoBands.Resolution.five : resolution
        return (0..<split.count).map { BandChoice(split, solo: $0) }
    }

    /// The five analysis bands a group merges.
    func members(_ group: Int) -> [Int] { resolution.groups[group] }
}
