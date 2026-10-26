import Foundation

/// Independent of the app's published meter/Bridge ABI. All sizes are actual samples at the input rate.
package struct MultiFFTConfiguration: Codable, Equatable, Sendable {
    package enum Preset: String, Codable, CaseIterable, Sendable { case economy, light, standard, high, ultra, custom }
    package enum Priority: String, Codable, CaseIterable, Sendable { case precision, balanced, responsive }
    package enum Window: String, Codable, CaseIterable, Sendable {
        case hann, blackmanHarris
        package var shape: SpectralWindow { self == .hann ? .hann : .blackmanHarris }
    }
    package enum Scale: String, Codable, CaseIterable, Sendable { case amplitude, psd }
    package struct Band: Codable, Equatable, Sendable {
        package var size: Int
        package var rate: Double
        package var overlap: Double
        package init(size: Int, rate: Double, overlap: Double) {
            self.size = size; self.rate = rate; self.overlap = overlap
        }
    }
    package static let sizes = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    package var preset = Preset.standard
    package var priority = Priority.balanced
    package var bands = [Band(size: 16384, rate: 30, overlap: 0.9375),
                         Band(size: 4096, rate: 30, overlap: 0.875),
                         Band(size: 1024, rate: 30, overlap: 0.75)]
    package var lowCrossover = 250.0
    package var highCrossover = 2500.0
    package var blendOctaves = 1.0
    package var window = Window.hann
    package var scale = Scale.amplitude
    package var smoothingSeconds = 0.15
    package var smoothingOctaves = 0.0
    package var midSide = false
    package init() {}

    package static func make(_ preset: Preset, priority: Priority = .balanced) -> Self {
        var c = Self(); c.preset = preset; c.priority = priority
        let index = [Preset.economy, .light, .standard, .high, .ultra].firstIndex(of: preset) ?? 2
        let base = [8192, 8192, 16384, 32768, 65536][index]
        let factor = priority == .precision ? 2.0 : priority == .responsive ? 0.5 : 1
        let size = min(65536, max(2048, Int(Double(base) * factor)))
        let rate = min(60.0, [10.0, 20, 30, 40, 60][index] * (priority == .responsive ? 1.5 : priority == .precision ? 0.75 : 1))
        c.bands = [Band(size: size, rate: rate, overlap: 0.9375),
                   Band(size: max(512, size / 4), rate: rate, overlap: 0.875),
                   Band(size: max(512, size / 16), rate: rate, overlap: 0.75)]
        c.smoothingSeconds = priority == .responsive ? 0.04 : priority == .precision ? 0.25 : 0.15
        return c
    }

    /// Bounds untrusted saved settings before any allocation, indexing, or conversion to an integer.
    package func validated(sampleRate: Double) -> Self {
        var c = self
        func finite(_ x: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, x.isFinite ? x : fallback))
        }
        // Presets retain their low-frequency resolving power as rates rise. Sizes shown in the settings are
        // the resolved sample counts. An advanced edit becomes Custom and thereafter uses exactly those counts.
        if c.preset != .custom {
            c.bands = Self.make(c.preset, priority: c.priority).bands
            var multiplier = 1
            while Double(multiplier) * 48000 < sampleRate * 0.99 && multiplier < 8 { multiplier *= 2 }
            for i in c.bands.indices { c.bands[i].size = min(65536, c.bands[i].size * multiplier) }
        }
        if c.bands.count != 3 { c.bands = Self().bands }
        for i in c.bands.indices {
            if !Self.sizes.contains(c.bands[i].size) { c.bands[i].size = Self().bands[i].size }
            c.bands[i].rate = finite(c.bands[i].rate, 30, 1...60)
            c.bands[i].overlap = finite(c.bands[i].overlap, 0.75, 0...0.96875)
        }
        let upper = LogFrequencyAxis.upper(sampleRate: sampleRate)
        c.lowCrossover = finite(c.lowCrossover, 250, 40...max(40, upper / 4))
        c.highCrossover = finite(c.highCrossover, 2500, (c.lowCrossover * 2)...max(c.lowCrossover * 2, upper * 0.9))
        c.blendOctaves = finite(c.blendOctaves, 1, 0.125...2)
        c.smoothingSeconds = finite(c.smoothingSeconds, 0.15, 0...2)
        c.smoothingOctaves = finite(c.smoothingOctaves, 0, 0...1)
        return c
    }

    /// A synchronized cadence obeys every band's rate ceiling and minimum hop (overlap ceiling).
    /// No frame fuses a fresh high window with a stale low window.
    package func hop(sampleRate: Double) -> Int {
        bands.map { max(1, Int(max(sampleRate / $0.rate, Double($0.size) * (1 - $0.overlap)).rounded(.up))) }.max() ?? 1
    }
    package static func weights(frequency: Double, low: Double, high: Double, octaves: Double) -> [Double] {
        func lower(_ edge: Double) -> Double {
            let t = max(0, min(1, log2(frequency / edge) / octaves + 0.5))
            return 0.5 + 0.5 * cos(.pi * t)
        }
        let a = lower(low), b = lower(high)
        return [a, (1 - a) * b, (1 - a) * (1 - b)]
    }
}

/// The existing display can opt into one fixed-size shared Hann STFT, or keep the original analysis intact.
package enum LegacySTFT: Int, CaseIterable, Codable, Sendable {
    case legacy = 0, shared2048 = 2048, shared4096 = 4096, shared8192 = 8192
}
