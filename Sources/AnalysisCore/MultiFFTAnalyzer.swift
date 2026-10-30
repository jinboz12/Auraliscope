import Accelerate
import Foundation

package struct MultiFFTSnapshot: Sendable {
    package let serial: UInt64
    /// Absolute sample indices since this analyser was created; all three windows have this exact centre.
    package let centreSample: UInt64
    package let windowEndSample: UInt64
    package let sampleRate: Double
    package let hop: Int
    package let lengths: [Int]
    package let frequencies: [Double]
    /// L, R, then optionally M=(L+R)/2, S=(L-R)/2. Amplitude dBFS or PSD dBFS/Hz, per `scale`.
    package let curves: [[Float]]
    package let scale: MultiFFTConfiguration.Scale
}

/// Owned by the non-realtime DSP consumer. Consumes mapped PCM independently of UI ticks and old FFTs.
/// Bounded history and FFT scratch are allocated at configuration time; no audio callback enters this class.
///
/// Build 117: each zone separates, scales and converts to dB only the bins the fusion can read (its weighted
/// display points plus the neighbours the peak estimator inspects), windows with two contiguous vector multiplies
/// instead of a modulo per sample, and reuses its fusion/smoothing scratch. Calibration, fusion weights, smoothing
/// and timing are unchanged; `exhaustiveBins` recomputes every bin so tests can prove the two paths agree.
package final class MultiFFTAnalyzer {
    package static let points = 512
    /// Diagnostics only: convert every bin as Builds 114–116 did. Read once per transform.
    package static var exhaustiveBins = false
    package let configuration: MultiFFTConfiguration
    package let sampleRate: Double
    package let span: Int
    package let hop: Int
    package private(set) var latest: MultiFFTSnapshot?
    package private(set) var transforms: UInt64 = 0
    private let zones: [Zone]
    private let frequencies: [Double]
    private let maps: [[SpectrumAnalyzer.BandMap]]
    private let weights: [[Double]]
    package let lengths: [Int]
    private var left: [Float], right: [Float]
    private var cursor = 0
    private var filled = 0
    private var untilFrame: Int
    private var frames: UInt64 = 0
    private var serial: UInt64 = 0
    private var smoothed: [[Double]] = []
    private var fused: [[Double]]
    private var prefix: [Double]

    private final class Zone {
        let size: Int
        let bins: Int
        let setup: OpaquePointer
        let window: [Float]
        let toneScale: Double, densityScale: Double
        let estimator: PeakEstimator
        /// The bins the fusion can read from this zone, including the estimator's neighbours. Set once by the owner.
        var first = 0, last = 0
        var real: [Float], imaginary: [Float], outReal: [Float], outImaginary: [Float]
        /// One `bins`-long row per channel. Only `first...last` (or every bin when exhaustive) is written per frame;
        /// the rest stays at the display floor so a stray read can never look like signal.
        var powers: [Float]
        var decibels: [Float]
        let channels: Int
        init?(size: Int, sampleRate: Double, window shape: SpectralWindow, channels: Int) {
            guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else { return nil }
            self.size = size; self.setup = setup; self.channels = channels
            bins = size / 2 + 1
            last = bins - 1
            window = shape.samples(size)
            let sum = window.reduce(0) { $0 + Double($1) }
            let squares = window.reduce(0) { $0 + Double($1) * Double($1) }
            toneScale = 4 / (sum * sum)
            densityScale = 2 / (sampleRate * squares)
            estimator = shape == .hann ? .hann : .blackmanHarris
            real = .init(repeating: 0, count: size); imaginary = real; outReal = real; outImaginary = real
            powers = .init(repeating: 0, count: bins * channels)
            decibels = .init(repeating: -200, count: bins * channels)
        }
        deinit { vDSP_DFT_DestroySetup(setup) }
        func analyse(left: [Float], right: [Float], cursor: Int, span: Int, exhaustive: Bool) {
            let bins = self.bins, size = self.size, channels = self.channels
            let start = (cursor + (span - size) / 2) % span
            // The ring wraps at most once inside a window: two contiguous multiplies replace a modulo per sample.
            let head = min(size, span - start)
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in window.withUnsafeBufferPointer { w in
                real.withUnsafeMutableBufferPointer { re in imaginary.withUnsafeMutableBufferPointer { im in
                    vDSP_vmul(l.baseAddress! + start, 1, w.baseAddress!, 1, re.baseAddress!, 1, vDSP_Length(head))
                    vDSP_vmul(r.baseAddress! + start, 1, w.baseAddress!, 1, im.baseAddress!, 1, vDSP_Length(head))
                    if head < size {
                        vDSP_vmul(l.baseAddress!, 1, w.baseAddress! + head, 1, re.baseAddress! + head, 1, vDSP_Length(size - head))
                        vDSP_vmul(r.baseAddress!, 1, w.baseAddress! + head, 1, im.baseAddress! + head, 1, vDSP_Length(size - head))
                    }
                } }
            } } }
            vDSP_DFT_Execute(setup, real, imaginary, &outReal, &outImaginary)
            let lo = exhaustive ? 0 : first, hi = exhaustive ? bins - 1 : last
            guard lo <= hi else { return }
            let count = hi - lo + 1
            // A single complex FFT packs the two real channels. Retain phase until M/S is formed.
            outReal.withUnsafeBufferPointer { xr in outImaginary.withUnsafeBufferPointer { xi in
                powers.withUnsafeMutableBufferPointer { p in
                    for k in lo...hi {
                        let j = (size - k) % size
                        let lr = 0.5 * (xr[k] + xr[j]), li = 0.5 * (xi[k] - xi[j])
                        let rr = 0.5 * (xi[k] + xi[j]), ri = 0.5 * (xr[j] - xr[k])
                        p[k] = lr * lr + li * li
                        p[bins + k] = rr * rr + ri * ri
                        if channels == 4 {
                            p[2 * bins + k] = 0.25 * ((lr + rr) * (lr + rr) + (li + ri) * (li + ri))
                            p[3 * bins + k] = 0.25 * ((lr - rr) * (lr - rr) + (li - ri) * (li - ri))
                        }
                    }
                }
            } }
            // Tone dB = 10·log10(max(1e-20, power·toneScale)), vectorised per channel over the read range only.
            // DC and Nyquist carry a quarter of the one-sided scale, as before.
            var scale = Float(toneScale)
            var floorValue = Float(1e-20), ten = Float(10)
            powers.withUnsafeBufferPointer { p in decibels.withUnsafeMutableBufferPointer { d in
                for c in 0..<channels {
                    let src = p.baseAddress! + c * bins + lo, dst = d.baseAddress! + c * bins + lo
                    vDSP_vsmul(src, 1, &scale, dst, 1, vDSP_Length(count))
                    if lo == 0 { dst[0] *= 0.25 }
                    if hi == bins - 1 { dst[count - 1] *= 0.25 }
                    vDSP_vthr(dst, 1, &floorValue, dst, 1, vDSP_Length(count))
                    var n = Int32(count)
                    vvlog10f(dst, dst, &n)
                    vDSP_vsmul(dst, 1, &ten, dst, 1, vDSP_Length(count))
                }
            } }
        }
        func tone(channel: Int, map: SpectrumAnalyzer.BandMap) -> Double {
            let db: Float = decibels.withUnsafeBufferPointer { all in
                let d = UnsafeBufferPointer(rebasing: all[(channel * bins)..<((channel + 1) * bins)])
                if map.interpolated {
                    return SpectrumAnalyzer.interpolatedLevel(d, at: map.position, halfWidth: map.halfWidth, estimator: estimator)
                }
                var k = map.first
                for b in map.first...map.last where d[b] > d[k] { k = b }
                if k > 0, k + 1 < d.count, d[k] >= d[k-1], d[k] >= d[k+1] {
                    let peak = estimator.peak(d[k-1], d[k], d[k+1])
                    let position = Float(k) + peak.offset
                    if position >= Float(map.first) - 0.5, position <= Float(map.last) + 0.5 { return peak.level }
                }
                return d[k]
            }
            return pow(10, Double(db) / 10)
        }
        /// Linear interpolation on a Hz axis, after window-energy normalization. Unlike coherent-gain
        /// normalization this has a resolution-independent expected noise floor. DC/Nyquist are not doubled.
        func density(channel: Int, frequency: Double, sampleRate: Double) -> Double {
            let p = min(Double(size / 2), max(0, frequency * Double(size) / sampleRate))
            let k = Int(p), j = min(size / 2, k + 1), t = p - Double(k)
            let row = channel * bins
            func value(_ bin: Int) -> Double {
                Double(powers[row + bin]) * densityScale * (bin == 0 || bin == size / 2 ? 0.5 : 1)
            }
            return value(k) * (1-t) + value(j) * t
        }
        /// The bins `density` reads for `frequency`.
        func densityBins(frequency: Double, sampleRate: Double) -> ClosedRange<Int> {
            let p = min(Double(size / 2), max(0, frequency * Double(size) / sampleRate))
            let k = Int(p)
            return k...min(size / 2, k + 1)
        }
    }

    package init?(sampleRate: Double, configuration requested: MultiFFTConfiguration = .init()) {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate) else { return nil }
        let c = requested.validated(sampleRate: sampleRate)
        self.configuration = c; self.sampleRate = sampleRate
        let channels = c.midSide ? 4 : 2
        let zones = c.bands.compactMap { Zone(size: $0.size, sampleRate: sampleRate, window: c.window.shape, channels: channels) }
        guard zones.count == 3 else { return nil }
        self.zones = zones
        lengths = zones.map(\.size)
        span = c.bands.map(\.size).max()!
        hop = c.hop(sampleRate: sampleRate); untilFrame = span
        left = .init(repeating: 0, count: span); right = left
        let upper = LogFrequencyAxis.upper(sampleRate: sampleRate)
        frequencies = (0..<Self.points).map { LogFrequencyAxis.centre($0, of: Self.points, upper: upper) }
        maps = c.bands.map { SpectrumAnalyzer.bandMaps(count: Self.points, sampleRate: sampleRate, fftSize: $0.size) }
        weights = frequencies.map { MultiFFTConfiguration.weights(frequency: $0, low: c.lowCrossover, high: c.highCrossover, octaves: c.blendOctaves) }
        fused = Array(repeating: Array(repeating: 0, count: Self.points), count: channels)
        prefix = Array(repeating: 0, count: Self.points + 1)
        // Each zone is read only where its fusion weight is nonzero: the mapped bins (tone) or the two
        // interpolation bins (PSD), widened by the neighbours `interpolatedLevel` and `peak` inspect (≤ 2).
        for z in zones.indices {
            var lo = Int.max, hi = Int.min
            for p in 0..<Self.points where weights[p][z] > 0 {
                let map = maps[z][p]
                lo = min(lo, map.first); hi = max(hi, map.last)
                let density = zones[z].densityBins(frequency: frequencies[p], sampleRate: sampleRate)
                lo = min(lo, density.lowerBound); hi = max(hi, density.upperBound)
            }
            if lo <= hi {
                zones[z].first = max(0, lo - 4); zones[z].last = min(zones[z].bins - 1, hi + 4)
            } else {
                zones[z].first = 1; zones[z].last = 0
            }
        }
    }

    /// Bins converted per frame by each zone, for diagnostics and tests (`first...last`, or all when exhaustive).
    package var convertedBins: [Int] { zones.map { Self.exhaustiveBins ? $0.bins : max(0, $0.last - $0.first + 1) } }

    package func consume(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var offset = 0
        while offset < count {
            let run = min(count - offset, min(span - cursor, untilFrame))
            left.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: cursor).update(from: l + offset, count: run) }
            right.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: cursor).update(from: r + offset, count: run) }
            cursor = (cursor + run) % span; filled = min(span, filled + run)
            frames += UInt64(run); offset += run; untilFrame -= run
            if untilFrame == 0 {
                if filled == span { analyse() }
                untilFrame = hop
            }
        }
    }

    package func interrupt() {
        cursor = 0; filled = 0; untilFrame = span
        latest = nil; smoothed = []
        // `frames` remains monotonic; no frame straddles a break.
    }

    private func analyse() {
        let exhaustive = Self.exhaustiveBins
        for zone in zones { zone.analyse(left: left, right: right, cursor: cursor, span: span, exhaustive: exhaustive) }
        transforms += 3; serial += 1
        let count = configuration.midSide ? 4 : 2
        let amplitude = configuration.scale == .amplitude
        for channel in 0..<count {
            fused[channel].withUnsafeMutableBufferPointer { out in
                for p in 0..<Self.points {
                    var sum = 0.0
                    for z in 0..<3 where weights[p][z] > 0 {
                        let power = amplitude
                            ? zones[z].tone(channel: channel, map: maps[z][p])
                            : zones[z].density(channel: channel, frequency: frequencies[p], sampleRate: sampleRate)
                        sum += power * weights[p][z]
                    }
                    out[p] = sum
                }
            }
        }
        let radius = Int(configuration.smoothingOctaves * Double(Self.points) / LogFrequencyAxis.octaves(upper: LogFrequencyAxis.upper(sampleRate: sampleRate)) / 2)
        if radius > 0 {
            for channel in 0..<count {
                prefix[0] = 0
                for p in 0..<Self.points { prefix[p+1] = prefix[p] + fused[channel][p] }
                for p in 0..<Self.points {
                    let a = max(0, p-radius), b = min(Self.points, p+radius+1)
                    fused[channel][p] = (prefix[b]-prefix[a]) / Double(b-a)
                }
            }
        }
        let alpha = configuration.smoothingSeconds > 0 ? 1-exp(-Double(hop) / sampleRate / configuration.smoothingSeconds) : 1
        if smoothed.isEmpty { smoothed = fused }
        else { for c in 0..<count { for p in 0..<Self.points { smoothed[c][p] += alpha * (fused[c][p]-smoothed[c][p]) } } }
        latest = MultiFFTSnapshot(serial: serial, centreSample: frames - UInt64(span/2), windowEndSample: frames,
            sampleRate: sampleRate, hop: hop, lengths: lengths, frequencies: frequencies,
            curves: smoothed.map { $0.map { Float(10 * log10(max(1e-16, $0))) } }, scale: configuration.scale)
    }
}
