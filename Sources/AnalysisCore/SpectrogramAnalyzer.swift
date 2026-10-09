import Accelerate
import AnalysisKernels
import Foundation

/// The waterfall's columns: a multi-resolution, time-aligned short-time Fourier analysis on the log-frequency rows of
/// `MeterSnapshot.spectrogram`.
///
/// One FFT length cannot serve a 20 Hz…20 kHz log axis. 8192 points resolve the bass (5.9 Hz bins at 48 kHz) but
/// average 170 ms, which smears every onset in the treble; short windows are sharp in time but useless below 1 kHz.
/// So each row is analysed with the shortest window that still resolves pitch there, and every window is one whose
/// whole main lobe fits the display.
///
/// - Window: the minimum 4-term Blackman–Harris (`SpectralWindow`). Its main lobe is ±4 bins and no sidelobe rises
///   above −92 dB, so a tone's leakage ends inside the colour range (Hann's sidelobes, from −31 dB, spread a loud
///   tone ±2 semitones at the floor of a 78 dB range). Below the frequency where even the span's Blackman–Harris
///   window meets the resolving rule (750 Hz at 48 kHz), the narrowest main lobe matters more than leakage: those
///   rows read the span's Hann transform, which is the spectrum's own and costs nothing, as in build 68.
/// - Resolution: an N-point window has bins `sampleRate / N` wide; a row keeps its window's main-lobe half-width
///   within 1/`resolvingPower` (1/32) of its frequency, about ±½ semitone, so neighbouring notes stay apart. That is
///   N ≥ 128 · sampleRate / f for Blackman–Harris. At 48 kHz: Hann 8192 below 750 Hz, Blackman–Harris 8192 to
///   1.5 kHz, then 4096, 2048, 1024 and 512 from 12 kHz. A 1024-point window (21 ms) is already shorter than a column (33 ms), so shorter ones
///   would add no time detail the display can show, only frequency smear.
/// - Zones: rows from the frequency where the shorter window first meets the rule up to half an octave above it
///   blend the two zones' levels in dB, so the change of resolution never shows as a seam. Below a boundary the
///   longer window is always used: no row is ever analysed more coarsely than the rule allows.
/// - Time: every window is centred on the same instant, the middle of the span, so a broadband onset (a kick's
///   click and its body) lands in one column instead of reaching the treble rows first.
/// - Coverage: a column stands for 1/30 s of audio. A window shorter than that would sample the interval with
///   gaps, and a hi-hat could fall between columns, so short windows are repeated across the interval, as many
///   times as it takes for every instant to weigh within 1 dB of every other (`Zone.frames`), and their powers
///   averaged (a Welch estimate, which also steadies the noise floor).
/// - Calibration: levels are in dBFS for a sine (amplitude-normalised windows), the same scale as the spectrum, and
///   the display power is the sum over the analysed roles, halved, so it is referenced to a stereo pair. Broadband
///   sound reads per analysis bandwidth, which widens with the zone: white noise reads about 3 dB higher per
///   halving of the window, as on any multi-resolution display.
/// - Rows: a row stands for its slice of frequency and shows the loudest level in it. A row wider than 1.5 bins reads
///   its loudest bin, corrected for the window's scalloping when a tone peaks inside the row; a narrower one reads
///   the tone's level where the tone lies inside it, and the main lobe's flank where it does not
///   (`SpectrumAnalyzer.interpolatedLevel`, `PeakEstimator`). A sine reads its level within 0.05 dB in every zone.
package final class SpectrogramAnalyzer {
    /// The analysis window (see the type's notes).
    package static let window = SpectralWindow.blackmanHarris
    /// Frequency over main-lobe half-width that every row keeps (see the type's notes).
    package static let resolvingPower = 32.0
    /// Largest spread, in dB, of the weight a column's frames give the instants of its interval.
    static let coverageRipple = 1.0
    /// Shortest window analysed.
    package static let minimumLength = 512
    /// Rows above a zone boundary that blend the two zones, in octaves.
    package static let blendOctaves = 0.5
    /// Columns per second (`MeterPipeline`: one per two 60 Hz ticks).
    package static let columnRate = 30.0

    /// One window length and what it needs: its FFT, window, frames per column and the rows it serves. Its scratch
    /// lives in one block allocated here, so analysing a column allocates nothing.
    private final class Zone {
        let length: Int
        let shape: SpectralWindow
        let estimator: PeakEstimator
        /// Lowest row frequency (Hz) this zone may serve under the resolving rule; 0 for the span's bass zone.
        var floor = 0.0
        let setup: OpaquePointer
        /// dB per unit of |X|² for a sine: (2 / Σw)².
        let scale: Float
        /// Start of each frame in the analysis span (oldest sample first).
        let starts: [Int]
        private let block: UnsafeMutablePointer<Float>
        /// The window halved: the conjugate-symmetric split's ¼ rides on it (see `packed_pair_powers`).
        let window: UnsafeMutablePointer<Float>
        let real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>
        let outReal: UnsafeMutablePointer<Float>, outImaginary: UnsafeMutablePointer<Float>
        let powerA: UnsafeMutablePointer<Float>, powerB: UnsafeMutablePointer<Float>
        /// Display power per bin, then its dB (`length / 2` each).
        let power: UnsafeMutablePointer<Float>
        let decibels: UnsafeMutablePointer<Float>
        var bins: Int { length / 2 }
        /// The window as a circular convolution of the spectrum: a₀, then (−1)ᵐ aₘ / 2 for the bins ±m away.
        let taps: [Float]
        /// The row → bin mapping of this zone's resolution.
        var maps: [SpectrumAnalyzer.BandMap] = []
        var used = false

        init?(length: Int, span: Int, hop: Int, window shape: SpectralWindow) {
            guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else { return nil }
            self.length = length
            self.shape = shape
            taps = shape.coefficients.enumerated().map { m, a in Float(m == 0 ? a : (m.isMultiple(of: 2) ? a : -a) / 2) }
            estimator = shape == .hann ? .hann : shape == .blackmanHarris ? .blackmanHarris : PeakEstimator(window: shape)
            self.setup = setup
            let half = length / 2
            block = .allocate(capacity: 5 * length + 4 * half)
            block.initialize(repeating: 0, count: 5 * length + 4 * half)
            window = block
            real = block + length
            imaginary = block + 2 * length
            outReal = block + 3 * length
            outImaginary = block + 4 * length
            powerA = block + 5 * length
            powerB = powerA + half
            power = powerB + half
            decibels = power + half
            let samples = shape.samples(length)
            window.update(from: samples, count: length)
            let sum = samples.reduce(0, +)
            scale = (2 / sum) * (2 / sum)
            var halfScale: Float = 0.5
            vDSP_vsmul(window, 1, &halfScale, window, 1, vDSP_Length(length))
            let frames = Self.frames(samples, hop: hop, span: span)
            starts = (0..<frames).map { frame in
                let offset = ((Double(frame) + 0.5) / Double(frames) - 0.5) * Double(hop)
                return max(0, min(span - length, span / 2 + Int(offset.rounded()) - half))
            }
        }

        /// Frames per column: the fewest whose windows, repeated every `hop / frames` samples from column to column,
        /// weigh every instant within `coverageRipple` of every other (power adds as the window squared), so a click
        /// reads the same wherever it falls, between columns too. A window as long as the span has room for one only.
        static func frames(_ window: [Float], hop: Int, span: Int) -> Int {
            let length = window.count
            guard length < span else { return 1 }
            for frames in 1...64 {
                let spacing = Double(hop) / Double(frames)
                guard Double(length) + Double(hop) - spacing <= Double(span) else { return max(1, frames - 1) }
                var low = Double.greatestFiniteMagnitude, high = 0.0
                for step in 0..<32 {
                    let t = Double(step) / 32 * spacing
                    var weight = 0.0
                    var k = -Int((Double(length) / spacing).rounded(.up)) - 1
                    while Double(k) * spacing <= t + Double(length) {
                        let n = Int((t - Double(k) * spacing).rounded())
                        if n >= 0 && n < length { weight += Double(window[n] * window[n]) }
                        k += 1
                    }
                    low = min(low, weight)
                    high = max(high, weight)
                }
                if low > 0 && 10 * log10(high / low) <= coverageRipple { return frames }
            }
            return 64
        }

        /// The unwindowed spectrum (`real`, `imaginary`, `length` bins) windowed by this zone's window (`taps`).
        func applyWindow(real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>,
                         intoReal outReal: UnsafeMutablePointer<Float>, imaginary outImaginary: UnsafeMutablePointer<Float>) {
            let n = length
            for (input, output) in [(real, outReal), (imaginary, outImaginary)] {
                var centre = taps[0]
                vDSP_vsmul(input, 1, &centre, output, 1, vDSP_Length(n))
                for m in 1..<taps.count {
                    var tap = taps[m]
                    // X[k − m] for k ≥ m and X[k + m] for k < n − m, then the wrapped ends.
                    vDSP_vsma(input, 1, &tap, output + m, 1, output + m, 1, vDSP_Length(n - m))
                    vDSP_vsma(input + m, 1, &tap, output, 1, output, 1, vDSP_Length(n - m))
                    for k in 0..<m {
                        output[k] += tap * input[k - m + n]
                        output[n - m + k] += tap * input[k]
                    }
                }
            }
        }

        deinit {
            vDSP_DFT_DestroySetup(setup)
            block.deallocate()
        }
    }

    /// Which zone (and, in a blend, which second zone with what weight) each row reads.
    private struct RowPlan {
        let zone: Int
        let next: Int
        let blend: Float
    }

    package let sampleRate: Double
    package let rows: Int
    package let window: SpectralWindow
    /// Samples the analysis looks back over: the longest window.
    private let span: Int
    /// The span's bass zone first (Hann), then `window` from the span down to `minimumLength`.
    private var zones: [Zone] = []
    private var plan: [RowPlan] = []

    /// `span` is the length of the history rings it reads (`SpectrumAnalyzer.fftSize`). `window` and
    /// `resolvingPower` default to the display's; others serve comparisons and tests (a Hann analysis has no
    /// separate bass zone).
    package init?(sampleRate: Double, rows: Int = MeterSnapshot.spectrogramBandCount, span: Int = SpectrumAnalyzer.fftSize,
                  window: SpectralWindow = SpectrogramAnalyzer.window, resolvingPower: Double = SpectrogramAnalyzer.resolvingPower) {
        guard sampleRate.isFinite, sampleRate > 100, rows > 0, span >= Self.minimumLength else { return nil }
        self.sampleRate = sampleRate
        self.rows = rows
        self.span = span
        self.window = window
        let hop = Int((sampleRate / Self.columnRate).rounded())
        func floor(_ shape: SpectralWindow, _ length: Int) -> Double {
            resolvingPower * shape.mainLobe * sampleRate / Double(length)
        }
        if window != .hann {
            guard let bass = Zone(length: span, span: span, hop: hop, window: .hann) else { return nil }
            zones.append(bass)
        }
        var length = span
        while length >= Self.minimumLength {
            guard let zone = Zone(length: length, span: span, hop: hop, window: window) else { return nil }
            zone.floor = zones.isEmpty ? 0 : floor(window, length)
            zones.append(zone)
            length /= 2
        }
        let upper = min(20_000, sampleRate / 2)
        let edges = (0...rows).map { 20 * pow(upper / 20, Double($0) / Double(rows)) }
        plan = (0..<rows).map { row in
            let centre = (edges[row] * edges[row + 1]).squareRoot()
            let zone = zones.indices.last { zones[$0].floor <= centre } ?? 0
            // Just above a boundary the previous (longer) zone fades out over `blendOctaves`.
            guard zone > 0 else { return RowPlan(zone: 0, next: -1, blend: 0) }
            let position = log2(centre / zones[zone].floor) / Self.blendOctaves
            guard position < 1 else { return RowPlan(zone: zone, next: -1, blend: 0) }
            return RowPlan(zone: zone - 1, next: zone, blend: Float(max(0, position)))
        }
        for row in plan {
            zones[row.zone].used = true
            if row.next >= 0 { zones[row.next].used = true }
        }
        for zone in zones where zone.used {
            zone.maps = SpectrumAnalyzer.bandMaps(count: rows, sampleRate: sampleRate, fftSize: zone.length)
        }
    }

    /// Windows in use, bass zone first, longest first, and the frames each analyses per column (diagnostics and
    /// tests).
    package var resolutions: [(length: Int, frames: Int, window: SpectralWindow)] {
        zones.filter(\.used).map { ($0.length, $0.starts.count, $0.shape) }
    }

    /// The window length a row is analysed with (the shorter one in a blend).
    package func length(ofRow row: Int) -> Int { zone(ofRow: row).length }

    /// The window a row is analysed with (the shorter one's in a blend).
    package func window(ofRow row: Int) -> SpectralWindow { zone(ofRow: row).shape }

    private func zone(ofRow row: Int) -> Zone { zones[plan[row].next >= 0 ? plan[row].next : plan[row].zone] }

    /// Fills `output` (`rows` dBFS values) from the history rings: ring `role` starts at `rings + role · span` and its
    /// oldest sample is at `cursor`. `roles` are summed (and halved); an empty list writes silence. `longest`, when
    /// given, is that display power already transformed over the whole span with a Hann window (the spectrum's,
    /// `span / 2` bins), and stands in for the span's Hann zone's own transform.
    package func column(rings: UnsafePointer<Float>, cursor: Int, roles: [Int], longest: UnsafePointer<Float>? = nil,
                        into output: UnsafeMutablePointer<Float>) {
        guard !roles.isEmpty else {
            output.update(repeating: -120, count: rows)
            return
        }
        // The span's Hann zone and the span's zone of `window` see the same samples: unless the spectrum's transform
        // stands in for the first, one unwindowed transform serves both (`analyseSpan`).
        let shared = longest == nil && zones.count > 1 && zones[0].used && zones[1].used && zones[1].length == span
        for (index, zone) in zones.enumerated() where zone.used {
            if let longest, zone.length == span, zone.shape == .hann {
                zone.power.update(from: longest, count: zone.bins)
                decibels(zone, frames: 1, halved: true)
            } else if shared && index < 2 {
                if index == 0 { analyseSpan(zones[0], zones[1], rings: rings, cursor: cursor, roles: roles) }
            } else {
                analyse(zone, rings: rings, cursor: cursor, roles: roles)
            }
        }
        for (row, entry) in plan.enumerated() {
            let a = level(zones[entry.zone], row: row)
            guard entry.next >= 0 else {
                output[row] = a
                continue
            }
            let b = level(zones[entry.next], row: row)
            output[row] = a + (b - a) * entry.blend
        }
    }

    /// Display power of every frame of `zone`, averaged, then its dB.
    private func analyse(_ zone: Zone, rings: UnsafePointer<Float>, cursor: Int, roles: [Int]) {
        let n = zone.length
        let bins = vDSP_Length(zone.bins)
        vDSP_vclr(zone.power, 1, bins)
        for start in zone.starts {
            var index = 0
            while index < roles.count {
                let pair = index + 1 < roles.count
                windowed(rings + roles[index] * span, cursor: cursor, start: start, zone: zone, into: zone.real)
                if pair {
                    windowed(rings + roles[index + 1] * span, cursor: cursor, start: start, zone: zone, into: zone.imaginary)
                } else {
                    vDSP_vclr(zone.imaginary, 1, vDSP_Length(n))
                }
                vDSP_DFT_Execute(zone.setup, zone.real, zone.imaginary, zone.outReal, zone.outImaginary)
                packed_pair_powers(zone.outReal, zone.outImaginary, UInt32(n), zone.powerA, zone.powerB)
                zone.powerA[0] = 4 * zone.outReal[0] * zone.outReal[0]
                zone.powerB[0] = 4 * zone.outImaginary[0] * zone.outImaginary[0]
                vDSP_vadd(zone.power, 1, zone.powerA, 1, zone.power, 1, bins)
                if pair { vDSP_vadd(zone.power, 1, zone.powerB, 1, zone.power, 1, bins) }
                index += 2
            }
        }
        decibels(zone, frames: zone.starts.count, halved: false)
    }

    /// `analyse` for two zones of the span's length (one frame each, the whole span) with different windows: one
    /// unwindowed transform per pair of roles, each window then applied in the frequency domain. A cosine-sum
    /// window multiplies the signal by a few cosines, which shifts copies of its spectrum by ±m bins, so
    /// X_w[k] = a₀X[k] + Σₘ (−1)ᵐ aₘ/2 · (X[k−m] + X[k+m]), circularly: exactly the time-domain windowing, for a 3- and
    /// a 7-tap convolution instead of a second FFT of up to 32768 points.
    private func analyseSpan(_ first: Zone, _ second: Zone, rings: UnsafePointer<Float>, cursor: Int, roles: [Int]) {
        let n = span
        let bins = vDSP_Length(first.bins)
        vDSP_vclr(first.power, 1, bins)
        vDSP_vclr(second.power, 1, bins)
        var index = 0
        while index < roles.count {
            let pair = index + 1 < roles.count
            // Halved, as the zones' windows are: the conjugate-symmetric split's ¼ rides on it.
            plain(rings + roles[index] * span, cursor: cursor, into: second.real)
            if pair {
                plain(rings + roles[index + 1] * span, cursor: cursor, into: second.imaginary)
            } else {
                vDSP_vclr(second.imaginary, 1, vDSP_Length(n))
            }
            vDSP_DFT_Execute(second.setup, second.real, second.imaginary, second.outReal, second.outImaginary)
            // The second zone's windowed spectrum goes to its input buffers, free once the transform has run.
            for (zone, real, imaginary) in [(first, first.outReal, first.outImaginary), (second, second.real, second.imaginary)] {
                zone.applyWindow(real: second.outReal, imaginary: second.outImaginary, intoReal: real, imaginary: imaginary)
                packed_pair_powers(real, imaginary, UInt32(n), zone.powerA, zone.powerB)
                zone.powerA[0] = 4 * real[0] * real[0]
                zone.powerB[0] = 4 * imaginary[0] * imaginary[0]
                vDSP_vadd(zone.power, 1, zone.powerA, 1, zone.power, 1, bins)
                if pair { vDSP_vadd(zone.power, 1, zone.powerB, 1, zone.power, 1, bins) }
            }
            index += 2
        }
        decibels(first, frames: 1, halved: false)
        decibels(second, frames: 1, halved: false)
    }

    /// The whole span of a ring, oldest sample first, halved.
    private func plain(_ ring: UnsafePointer<Float>, cursor: Int, into out: UnsafeMutablePointer<Float>) {
        var half: Float = 0.5
        let run = span - cursor
        vDSP_vsmul(ring + cursor, 1, &half, out, 1, vDSP_Length(run))
        if cursor > 0 { vDSP_vsmul(ring, 1, &half, out + run, 1, vDSP_Length(cursor)) }
    }

    /// `zone.power` (summed over the roles, or already `halved`) averaged over `frames`, then to dB for a sine,
    /// floored at −120.
    private func decibels(_ zone: Zone, frames: Int, halved: Bool) {
        let bins = vDSP_Length(zone.bins)
        var factor = (halved ? 1 : 0.5) / Float(frames) * zone.scale
        var floor: Float = 1e-12
        var ceiling = Float.greatestFiniteMagnitude
        var ten: Float = 10
        var count = Int32(zone.bins)
        vDSP_vsmul(zone.power, 1, &factor, zone.decibels, 1, bins)
        vDSP_vclip(zone.decibels, 1, &floor, &ceiling, zone.decibels, 1, bins)
        vvlog10f(zone.decibels, zone.decibels, &count)
        vDSP_vsmul(zone.decibels, 1, &ten, zone.decibels, 1, bins)
    }

    /// `zone.length` samples of a ring from `start` (oldest-first position in the span), times the window.
    private func windowed(_ ring: UnsafePointer<Float>, cursor: Int, start: Int, zone: Zone, into out: UnsafeMutablePointer<Float>) {
        let n = zone.length
        let first = (cursor + start) % span
        let run = min(n, span - first)
        vDSP_vmul(ring + first, 1, zone.window, 1, out, 1, vDSP_Length(run))
        if run < n { vDSP_vmul(ring, 1, zone.window + run, 1, out + run, 1, vDSP_Length(n - run)) }
    }

    /// A row's level at `zone`'s resolution (see the type's notes).
    private func level(_ zone: Zone, row: Int) -> Float {
        let map = zone.maps[row]
        let d = UnsafeBufferPointer(start: zone.decibels, count: zone.bins)
        guard map.interpolated else {
            var peak = map.first
            for bin in map.first...map.last where d[bin] > d[peak] { peak = bin }
            // A tone between two bins reads low in either (the window's scalloping: Hann 1.4 dB, Blackman–Harris
            // 0.8 dB). Where the loudest bin is a local maximum, the zone's `PeakEstimator` restores the level, provided the
            // tone lies inside this row; otherwise the row is only the tone's flank.
            guard peak > 0, peak + 1 < d.count, d[peak] >= d[peak - 1], d[peak] >= d[peak + 1] else { return d[peak] }
            let estimate = zone.estimator.peak(d[peak - 1], d[peak], d[peak + 1])
            let tone = Float(peak) + estimate.offset
            guard d[peak] > -120, tone >= Float(map.first) - 0.5, tone <= Float(map.last) + 0.5 else { return d[peak] }
            return estimate.level
        }
        return SpectrumAnalyzer.interpolatedLevel(d, at: map.position, halfWidth: map.halfWidth, estimator: zone.estimator)
    }
}
