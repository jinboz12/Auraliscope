import Accelerate
import AudioRing
import Foundation

/// The five frequency bands of the multiband stereo readings: the correlation bar's lanes in Channel Levels, the
/// stereometer and the Immersive band map. Edges in Hz; the top band runs to the display ceiling. Each view shows
/// them at a `Resolution` of its own: the five bands, three (merged from the five) or one overall reading.
enum StereoBands {
    static let count = 5
    static let edges: [Double] = [20, 120, 500, 2_000, 8_000]

    /// How finely a view splits the spectrum: one full-band reading (the whole spectrum, as a conventional meter
    /// reads it), three bands (below 120 Hz, 120 Hz–2 kHz, above 2 kHz) or the five.
    enum Resolution: String, CaseIterable {
        case overall, three, five

        /// The five bands each group merges, low to high.
        var groups: [[Int]] {
            switch self {
            case .overall: return [[0, 1, 2, 3, 4]]
            case .three: return [[0], [1, 2], [3, 4]]
            case .five: return [[0], [1], [2], [3], [4]]
            }
        }
        var count: Int { groups.count }
        /// Index of this resolution's first group among `StereoBands.groups` (the published readings).
        var offset: Int {
            switch self {
            case .five: return 0
            case .three: return 5
            case .overall: return 8
            }
        }
        /// A group's label: its lower edge, or "Full band".
        func label(_ group: Int) -> String { self == .overall ? L("Full band") : StereoBands.label(groups[group][0]) }
        /// The switcher's segment: "Full band", "3 bands", "5 bands" (multiband meters name their split by the
        /// number of bands, and a meter that does not split reads full band).
        var title: String { self == .overall ? L("Full band") : L("%d bands", count) }
    }

    /// Every group any resolution shows, in `Resolution.offset` order: the five bands, the three, then overall.
    static let groups = Resolution.five.groups + Resolution.three.groups + Resolution.overall.groups
    /// Values published per group: correlation, width, balance and level (see `MeterSnapshot`).
    static let publishedFloats = 4 * groups.count

    /// Values published for the Immersive room's band image: each role's mean square in each band.
    static let roleFloats = Role.count * count

    /// Points per band in the stereometer's cloud, taken evenly across the newest 1/30 s.
    static let scopePoints = 128
    /// Floats of the stereometer's cloud: per band, `scopePoints` (L, R) pairs.
    static let scopeFloats = count * scopePoints * 2

    /// A band's label: its lower edge, "20 Hz", "120 Hz", "500 Hz", "2 kHz", "8 kHz"; each band reaches up to the
    /// next one's.
    static func label(_ band: Int) -> String {
        let edge = edges[band]
        return edge >= 1_000 ? "\(Int(edge / 1_000)) kHz" : "\(Int(edge)) Hz"
    }

    /// Band of each FFT bin from 1 to `fftSize / 2 − 1`, or −1 outside 20 Hz…the display ceiling.
    static func binBands(sampleRate: Double, fftSize: Int) -> [Int8] {
        let binWidth = sampleRate / Double(fftSize)
        let upper = min(20_000, sampleRate / 2)
        return (0..<(fftSize / 2)).map { bin in
            let frequency = Double(bin) * binWidth
            guard bin > 0, frequency >= edges[0], frequency <= upper else { return -1 }
            return Int8(edges.lastIndex { frequency >= $0 } ?? 0)
        }
    }
}

/// Splits L and R into the five `StereoBands` with fourth-order Linkwitz–Riley crossovers (two cascaded
/// Butterworth sections at each edge, from the RBJ cookbook) and keeps the newest samples of every band, for the
/// stereometer's multiband cloud. Owned by the DSP queue.
final class StereoBandSplitter {
    static let historyLength = 4096
    let sampleRate: Double
    /// One cascade per band: low-pass for the lowest, high-pass for the highest, both for the bands between.
    private var setups: [vDSP_biquad_Setup] = []
    private var sections: [Int] = []
    /// Filter state per band and side (L, R).
    private var delays: [[Float]] = []
    /// Newest `historyLength` filtered samples per band and side, all sharing `cursor`.
    private var history: [Float]
    private var cursor = 0
    private var left: [Float] = []
    private var right: [Float] = []
    private var scratch: [Float] = []

    init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 100 else { return nil }
        self.sampleRate = sampleRate
        history = [Float](repeating: 0, count: StereoBands.count * 2 * Self.historyLength)
        let nyquist = sampleRate / 2
        func butterworth(_ frequency: Double, highPass: Bool) -> [Double] {
            let w = 2 * Double.pi * min(frequency, nyquist * 0.95) / sampleRate
            let alpha = sin(w) / (2 * 0.5.squareRoot())
            let c = cos(w), a0 = 1 + alpha
            let b0 = highPass ? (1 + c) / 2 : (1 - c) / 2
            let b1 = highPass ? -(1 + c) : 1 - c
            return [b0 / a0, b1 / a0, b0 / a0, -2 * c / a0, (1 - alpha) / a0]
        }
        for band in 0..<StereoBands.count {
            var coefficients: [Double] = []
            if band > 0 {
                let edge = butterworth(StereoBands.edges[band], highPass: true)
                coefficients += edge + edge
            }
            if band + 1 < StereoBands.count, StereoBands.edges[band + 1] < nyquist {
                let edge = butterworth(StereoBands.edges[band + 1], highPass: false)
                coefficients += edge + edge
            }
            let count = coefficients.count / 5
            guard count > 0, let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(count)) else { return nil }
            setups.append(setup)
            sections.append(count)
            delays.append([Float](repeating: 0, count: 2 * count + 2))
            delays.append([Float](repeating: 0, count: 2 * count + 2))
        }
    }

    deinit { setups.forEach { vDSP_biquad_DestroySetup($0) } }

    /// Filters `count` frames of L and R, read from `samples` with `stride` floats per frame.
    func consume(_ samples: UnsafePointer<Float>, stride: Int, count: Int, leftOffset: Int = 0, rightOffset: Int = 1) {
        guard count > 0 else { return }
        if left.count < count {
            left = [Float](repeating: 0, count: count)
            right = [Float](repeating: 0, count: count)
            scratch = [Float](repeating: 0, count: count)
        }
        let n = vDSP_Length(count)
        vDSP_mmov(samples + leftOffset, &left, 1, n, vDSP_Length(stride), 1)
        vDSP_mmov(samples + rightOffset, &right, 1, n, vDSP_Length(stride), 1)
        let length = Self.historyLength
        for band in 0..<StereoBands.count {
            for side in 0..<2 {
                let input = side == 0 ? left : right
                vDSP_biquad(setups[band], &delays[2 * band + side], input, 1, &scratch, 1, n)
                // Newest `historyLength` samples into the band's ring.
                let skip = max(0, count - length)
                var written = 0
                var position = cursor + skip
                while written < count - skip {
                    let run = min(count - skip - written, length - position % length)
                    let base = (2 * band + side) * length + position % length
                    history.withUnsafeMutableBufferPointer { ring in
                        scratch.withUnsafeBufferPointer { source in
                            (ring.baseAddress! + base).update(from: source.baseAddress! + skip + written, count: run)
                        }
                    }
                    written += run
                    position += run
                }
            }
        }
        cursor = (cursor + count) % length
    }

    /// Writes `StereoBands.scopeFloats`: per band, `scopePoints` (L, R) pairs spread evenly over the newest
    /// 1/30 s, oldest first. `silent` writes zeros.
    func writePoints(into v: UnsafeMutablePointer<Float>, silent: Bool) {
        let points = StereoBands.scopePoints
        guard !silent else {
            for i in 0..<StereoBands.scopeFloats { v[i] = 0 }
            return
        }
        let length = Self.historyLength
        let window = min(length, max(points, Int(sampleRate / 30)))
        for band in 0..<StereoBands.count {
            for point in 0..<points {
                let age = window - 1 - point * window / points
                let index = (cursor - 1 - age + 2 * length) % length
                v[(band * points + point) * 2] = history[(2 * band) * length + index]
                v[(band * points + point) * 2 + 1] = history[(2 * band + 1) * length + index]
            }
        }
    }
}

struct MeterSnapshot: Equatable {
    static let bandCount = 64
    /// Log-spaced rows for the waterfall: at least one row per device pixel on a typical Retina panel, so the
    /// shader never stretches a row across several pixels and harmonics stay crisp.
    static let spectrogramBandCount = 512
    /// Published when L and R carry no signal, so the correlation meter can rest instead of reading 0.
    static let noCorrelation: Float = -2
    var spectrum: [Float] = Array(repeating: -120, count: bandCount)
    var spectrogram: [Float] = Array(repeating: -120, count: spectrogramBandCount)
    var sequence: Float = 0
    /// Advances once per waterfall column (30 per second), independent of the snapshot rate.
    var spectrogramSerial: Float = 0
    var streamID: Float = 0
    var leftPeak: Float = 0
    var rightPeak: Float = 0
    var leftRMS: Float = 0
    var rightRMS: Float = 0
    /// Per role (see `Role`), linear.
    var channelPeaks = [Float](repeating: 0, count: Role.count)
    var channelRMS = [Float](repeating: 0, count: Role.count)
    var channelTruePeaks = [Float](repeating: 0, count: Role.count)
    /// Highest sample and true peak per role since the stream started, linear. Kept on the DSP side so a
    /// readout that samples snapshots at 10 Hz still sees every overshoot.
    var heldPeaks = [Float](repeating: 0, count: Role.count)
    var heldTruePeaks = [Float](repeating: 0, count: Role.count)
    var momentaryLUFS: Float = -100
    var shortLUFS: Float = -100
    var integratedLUFS: Float = -100
    /// EBU Tech 3342 loudness range in LU; negative until measurable.
    var loudnessRange: Float = -1
    /// Loudest spectral peak between 20 Hz and the display ceiling (display power: L+R, or every routed role in
    /// Spatial), in Hz and dBFS.
    var peakFrequency: Float = 0
    var peakLevel: Float = -120
    /// The notes sounding together (`SpectrumAnalyzer.tonalPeaks`): up to `maxNotes` (Hz, dBFS) pairs, loudest
    /// first; an unused pair has frequency 0.
    var notes = [Float](repeating: 0, count: 2 * SpectrumAnalyzer.maxNotes)
    /// `ChannelFormat` raw value from the DSP-side detector.
    var detectedFormat: Float = 0
    /// L/R phase correlation over the last tick, −1…+1, or `noCorrelation` in silence.
    var correlation: Float = MeterSnapshot.noCorrelation
    /// Per `StereoBands.groups` entry (five bands, three, overall), integrated like `correlation`: the L/R
    /// correlation (`noCorrelation` while the group is silent), the width (side share of the energy: 0 mono,
    /// ½ unrelated sides, 1 out of phase), the balance (−1 all left … +1 all right) and the level (RMS of L and R,
    /// dBFS).
    var bandCorrelation = [Float](repeating: MeterSnapshot.noCorrelation, count: StereoBands.groups.count)
    var bandWidth = [Float](repeating: 0, count: StereoBands.groups.count)
    var bandBalance = [Float](repeating: 0, count: StereoBands.groups.count)
    var bandLevel = [Float](repeating: -120, count: StereoBands.groups.count)
    /// The stereometer's cloud: per band, `StereoBands.scopePoints` (L, R) sample pairs from the newest 1/30 s.
    var bandPoints = [Float](repeating: 0, count: StereoBands.scopeFloats)
    /// Mean square of every role in every band (role-major), integrated like the band correlation: where each
    /// band's energy sits in the Immersive room. Only L and R carry values outside Spatial analysis.
    var roleBandPower = [Float](repeating: 0, count: StereoBands.roleFloats)
    var waveSerial: Float = 0
    var waveform: [Float] = Array(repeating: 0, count: WaveformEnvelope.publishedFloats)
}

// Owned exclusively by the serial DSP queue. No audio callback enters this class.
final class SpectrumAnalyzer {
    // 8192 points: 5.9 Hz bins at 48 kHz, so the bottom octaves get real detail. At 30 columns/s the
    // windows overlap by ~80 %, which keeps the waterfall continuous. Channels share complex transforms in
    // pairs (one real, one imaginary) and are separated by conjugate symmetry, which halves the FFT cost without
    // giving up any resolution; that is cheaper than dropping to 4096 points and keeps the 5.9 Hz bins.
    static let fftSize = 8192
    let sampleRate: Double
    private let setup: OpaquePointer
    private var window = [Float](repeating: 0, count: fftSize)
    /// Newest `fftSize` samples of each recorded role: one ring per role, all sharing `cursor`.
    private var history = [Float](repeating: 0, count: Role.count * fftSize)
    /// L, R and every other routed role: what a Spatial spectrum sums.
    private let recordedRoles: [Int]
    /// The other roles are recorded only while Spatial analysis is wanted (it costs a strided copy per role).
    /// Turning it on starts their history afresh; they join the spectrum once a full window has been captured.
    var recordsSpatial = false {
        didSet { if recordsSpatial != oldValue { spatialHistoryCount = 0 } }
    }
    private var spatialHistoryCount = 0
    private var inputReal = [Float](repeating: 0, count: fftSize)
    private var inputImaginary = [Float](repeating: 0, count: fftSize)
    private var mirrored = [Float](repeating: 0, count: fftSize / 2)
    private var scratch = [Float](repeating: 0, count: fftSize / 2)
    private var outputReal = [Float](repeating: 0, count: fftSize)
    private var outputImaginary = [Float](repeating: 0, count: fftSize)
    private var leftPower = [Float](repeating: 0, count: fftSize / 2)
    private var rightPower = [Float](repeating: 0, count: fftSize / 2)
    /// Display power per bin: the sum over the analysed roles, halved so it is referenced to a stereo pair.
    /// For L and R alone that is their mean, exactly as before; stereo content reads the same in both modes.
    private var power = [Float](repeating: 0, count: fftSize / 2)
    private var bands: [BandMap] = []
    private var spectrogramBands: [BandMap] = []
    /// dB of the low bins that interpolated rows read (one vectorised log per tick instead of three per row).
    private var lowDecibels: [Float] = []
    /// Scratch for one pass of row powers, converted to dB together.
    private var rowPower = [Float](repeating: 0, count: max(MeterSnapshot.bandCount, MeterSnapshot.spectrogramBandCount))
    private var amplitudeScale: Float = 0
    /// Band of each bin (`StereoBands.binBands`) and the per-band |L|², |R|² and Re(L·R̄) of the newest transform.
    private var binBands: [Int8] = []
    private(set) var bandSums = [(left: Double, right: Double, cross: Double)](repeating: (0, 0, 0), count: StereoBands.count)
    /// Mean square of the windowed signal per unit of one-sided |X|² (Parseval): 2 / (N · Σw²).
    private(set) var bandPowerScale: Double = 0
    /// First and last bin of each band, and every transformed role's mean square per band (role-major).
    private var bandBins: [ClosedRange<Int>] = []
    private(set) var roleBandPower = [Float](repeating: 0, count: StereoBands.roleFloats)
    private var cursor = 0
    private var historyCount = 0
    private var peakLeft: Float = 0
    private var peakRight: Float = 0
    private var sumLeft: Double = 0
    private var sumRight: Double = 0
    private var sumProduct: Double = 0
    private var levelFrames = 0

    /// `recording` marks the routed roles whose history is kept for Spatial analysis (L and R always are).
    init?(sampleRate: Double, recording roles: [Bool] = []) {
        guard sampleRate.isFinite, sampleRate > 100,
              let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else { return nil }
        self.setup = setup
        self.sampleRate = sampleRate
        recordedRoles = [Role.left, Role.right] + (0..<min(roles.count, Role.count)).filter { $0 > Role.right && roles[$0] }
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_DENORM))
        var windowSum: Float = 0
        vDSP_sve(window, 1, &windowSum, vDSP_Length(Self.fftSize))
        amplitudeScale = 2 / windowSum
        var windowSquares: Float = 0
        vDSP_svesq(window, 1, &windowSquares, vDSP_Length(Self.fftSize))
        bandPowerScale = 2 / (Double(Self.fftSize) * Double(windowSquares))
        binBands = StereoBands.binBands(sampleRate: sampleRate, fftSize: Self.fftSize)
        bandBins = (0..<StereoBands.count).map { band in
            let bins = binBands.indices.filter { binBands[$0] == band }
            return (bins.first ?? 1)...(bins.last ?? 1)
        }
        bands = Self.bandMaps(count: MeterSnapshot.bandCount, sampleRate: sampleRate)
        spectrogramBands = Self.bandMaps(count: MeterSnapshot.spectrogramBandCount, sampleRate: sampleRate)
        let lowBins = (bands + spectrogramBands).filter(\.interpolated).map { $0.last + 2 }.max() ?? 0
        lowDecibels = [Float](repeating: -120, count: min(Self.fftSize / 2, lowBins))
    }

    /// Roles a Spatial spectrum sums: L, R and every other routed role.
    var spatialRoles: [Int] { recordedRoles }
    /// Every routed role has a full FFT window (always true when only L and R are routed).
    var spatialReady: Bool { recordedRoles.count <= 2 || (recordsSpatial && spatialHistoryCount == Self.fftSize) }

    /// Fills `lowDecibels`: 10·log10 of the display power times the amplitude scale², floored at −120 dB.
    private func refreshLowDecibels() {
        let count = lowDecibels.count
        guard count > 0 else { return }
        var scale: Float = amplitudeScale * amplitudeScale
        var floor: Float = 1e-12
        var ceiling = Float.greatestFiniteMagnitude
        var ten: Float = 10
        var n = Int32(count)
        lowDecibels.withUnsafeMutableBufferPointer { out in
            vDSP_vsmul(power, 1, &scale, out.baseAddress!, 1, vDSP_Length(count))
            vDSP_vclip(out.baseAddress!, 1, &floor, &ceiling, out.baseAddress!, 1, vDSP_Length(count))
            vvlog10f(out.baseAddress!, out.baseAddress!, &n)
            vDSP_vsmul(out.baseAddress!, 1, &ten, out.baseAddress!, 1, vDSP_Length(count))
        }
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// Interleaved L/R frames (tests and tools): only L and R are recorded.
    func consume(_ frames: UnsafeBufferPointer<StereoFrame>) {
        guard let base = frames.baseAddress, !frames.isEmpty else { return }
        base.withMemoryRebound(to: Float.self, capacity: frames.count * 2) { samples in
            accumulate(samples, stride: 2, count: frames.count, roles: [(Role.left, 0), (Role.right, 1)])
        }
    }

    /// Role-mapped frames from the capture ring: L/R sums for the correlation, history for every recorded role.
    func consume(_ frames: UnsafeBufferPointer<ChannelFrame>) {
        guard let base = frames.baseAddress, !frames.isEmpty else { return }
        let roles = recordsSpatial ? recordedRoles : [Role.left, Role.right]
        base.withMemoryRebound(to: Float.self, capacity: frames.count * Role.count) { samples in
            accumulate(samples, stride: Role.count, count: frames.count, roles: roles.map { ($0, $0) })
        }
        if recordsSpatial { spatialHistoryCount = min(Self.fftSize, spatialHistoryCount + frames.count) }
    }

    /// `roles` pairs a role with its offset inside each frame of `stride` floats; L and R come first.
    private func accumulate(_ samples: UnsafePointer<Float>, stride: Int, count frameCount: Int, roles: [(role: Int, offset: Int)]) {
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var leftSquared: Float = 0
        var rightSquared: Float = 0
        var product: Float = 0
        let count = vDSP_Length(frameCount)
        let left = samples + roles[0].offset, right = samples + roles[1].offset
        vDSP_maxmgv(left, stride, &leftPeak, count)
        vDSP_maxmgv(right, stride, &rightPeak, count)
        vDSP_svesq(left, stride, &leftSquared, count)
        vDSP_svesq(right, stride, &rightSquared, count)
        vDSP_dotpr(left, stride, right, stride, &product, count)
        peakLeft = max(peakLeft, leftPeak)
        peakRight = max(peakRight, rightPeak)
        sumLeft += Double(leftSquared)
        sumRight += Double(rightSquared)
        sumProduct += Double(product)
        // Keep the newest FFT window: at most two contiguous copies per role into its ring.
        var remaining = frameCount
        var source = samples
        if remaining > Self.fftSize {
            source += (remaining - Self.fftSize) * stride
            remaining = Self.fftSize
        }
        history.withUnsafeMutableBufferPointer { rings in
            while remaining > 0 {
                let run = min(remaining, Self.fftSize - cursor)
                // vDSP_mmov with one column copies a strided run into a contiguous one.
                for (role, offset) in roles {
                    vDSP_mmov(source + offset, rings.baseAddress! + role * Self.fftSize + cursor, 1, vDSP_Length(run), vDSP_Length(stride), 1)
                }
                cursor = (cursor + run) % Self.fftSize
                source += run * stride
                remaining -= run
            }
        }
        levelFrames += frameCount
        historyCount = min(Self.fftSize, historyCount + frameCount)
    }

    /// A full FFT window has been captured, so spectra are meaningful.
    var ready: Bool { historyCount == Self.fftSize }

    /// L², R² and L·R sums since the previous call, for the phase correlation, and the frames they cover.
    func takeStereoSums() -> (left: Double, right: Double, product: Double, frames: Int) {
        defer {
            peakLeft = 0
            peakRight = 0
            sumLeft = 0
            sumRight = 0
            sumProduct = 0
            levelFrames = 0
        }
        return (sumLeft, sumRight, sumProduct, levelFrames)
    }

    /// Pearson correlation of L and R from `takeStereoSums` totals; silence (or one silent side) has none.
    static func correlation(left: Double, right: Double, product: Double) -> Float {
        let energy = left * right
        return energy > 1e-12 ? Float(max(-1, min(1, product / sqrt(energy)))) : MeterSnapshot.noCorrelation
    }

    /// Transforms the newest FFT window of `roles` (L and R by default; `spatialRoles` for every routed role)
    /// and fills the 64 display bands; returns the dominant peak (Hz, dBFS). The power spectrum stays available
    /// to `spectrogram(into:)` until the next transform.
    func refreshSpectrum(into spectrum: inout [Float], roles: [Int] = [Role.left, Role.right]) -> (frequency: Float, level: Float) {
        transform(roles)
        refreshLowDecibels()
        levels(bands, into: &spectrum)
        notes = tonalPeaks()
        return dominantPeak()
    }

    /// Most notes the keyboard lights at once.
    static let maxNotes = 6
    /// The newest transform's notes (`tonalPeaks`), loudest first.
    private(set) var notes: [(frequency: Float, level: Float)] = []

    /// The notes most likely sounding together, from the newest transform: tonal peaks between A0 and C8 (a
    /// local maximum at least 10 dB above the spectrum 3 to 8 bins either side, so noise and the window's own
    /// skirt do not count), within 30 dB of the loudest and above −70 dBFS, one per semitone. A peak lying on
    /// the 2nd to 8th harmonic of a lower note already kept (within 40 cents) and not clearly louder than it is
    /// that note's overtone, not a note of its own. Each frequency is refined like `dominantPeak`.
    private func tonalPeaks() -> [(frequency: Float, level: Float)] {
        let binWidth = sampleRate / Double(Self.fftSize)
        let first = max(2, Int(27 / binWidth))
        let last = min(Self.fftSize / 2 - 10, Int(min(4_200, sampleRate / 2) / binWidth))
        guard first < last else { return [] }
        let scale = amplitudeScale * amplitudeScale
        func decibels(_ power: Float) -> Float { 10 * log10(max(power * scale, 1e-12)) }
        var candidates: [(bin: Int, level: Float)] = []
        for bin in first...last {
            let p = power[bin]
            guard p > power[bin - 1], p >= power[bin + 1], p > power[bin - 2], p >= power[bin + 2] else { continue }
            let level = decibels(p)
            guard level > -70 else { continue }
            var around: Float = 0
            var neighbors: Float = 0
            // Near DC there are fewer bins below the tone. Use only available neighbours rather than
            // dropping the first eight bins (which hid bass notes below 105 Hz at 96 kHz).
            for offset in 3...8 {
                if bin - offset >= 1 { around += power[bin - offset]; neighbors += 1 }
                around += power[bin + offset]; neighbors += 1
            }
            guard level - decibels(around / neighbors) >= 10 else { continue }
            candidates.append((bin, level))
        }
        guard let loudest = candidates.map(\.level).max() else { return [] }
        var peaks: [(frequency: Float, level: Float)] = candidates
            .filter { $0.level >= loudest - 30 }
            .sorted { $0.level > $1.level }
            .prefix(16)
            .map { candidate in
                let a = decibels(power[candidate.bin - 1]), b = candidate.level, c = decibels(power[candidate.bin + 1])
                let curvature = a - 2 * b + c
                let offset = curvature < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / curvature)) : 0
                return (Float((Double(candidate.bin) + Double(offset)) * binWidth), b - 0.25 * (a - c) * offset)
            }
        peaks = peaks.filter { (27...4_200).contains($0.frequency) }
        // One per semitone: the louder of two peaks on the same key.
        var byKey: [Int: (frequency: Float, level: Float)] = [:]
        for peak in peaks {
            let key = Int((69 + 12 * log2(Double(peak.frequency) / 440)).rounded())
            if byKey[key].map({ $0.level < peak.level }) ?? true { byKey[key] = peak }
        }
        peaks = byKey.values.sorted { $0.frequency < $1.frequency }
        var kept: [(frequency: Float, level: Float)] = []
        for peak in peaks {
            let overtone = kept.contains { root in
                let ratio = Double(peak.frequency / root.frequency)
                let harmonic = ratio.rounded()
                return (2...8).contains(harmonic) && abs(1200 * log2(ratio / harmonic)) < 40 && peak.level < root.level + 6
            }
            if !overtone { kept.append(peak) }
        }
        return Array(kept.sorted { $0.level > $1.level }.prefix(Self.maxNotes))
    }

    /// `notes` packed as `MeterSnapshot.notes`.
    func packedNotes(into output: UnsafeMutablePointer<Float>) {
        for index in 0..<Self.maxNotes {
            let note: (frequency: Float, level: Float) = index < notes.count ? notes[index] : (0, -120)
            output[2 * index] = note.frequency
            output[2 * index + 1] = note.level
        }
    }

    /// Waterfall rows of the most recent transform.
    func spectrogram(into rows: inout [Float]) {
        levels(spectrogramBands, into: &rows)
    }

    func snapshot() -> MeterSnapshot {
        var result = MeterSnapshot()
        if levelFrames > 0 {
            result.leftPeak = peakLeft
            result.rightPeak = peakRight
            result.leftRMS = Float(sqrt(sumLeft / Double(levelFrames)))
            result.rightRMS = Float(sqrt(sumRight / Double(levelFrames)))
            result.correlation = Self.correlation(left: sumLeft, right: sumRight, product: sumProduct)
            if ready {
                (result.peakFrequency, result.peakLevel) = refreshSpectrum(into: &result.spectrum)
                result.notes.withUnsafeMutableBufferPointer { packedNotes(into: $0.baseAddress!) }
                spectrogram(into: &result.spectrogram)
            }
        }
        _ = takeStereoSums()
        return result
    }

    /// A log-spaced display row. Rows wider than ~1.5 bins take the loudest bin they cover;
    /// narrower rows (the low octaves) interpolate power at their centre frequency instead of
    /// repeating one bin, which removes the staircase at the bottom of the waterfall.
    struct BandMap {
        let first: Int
        let last: Int
        let fraction: Float
        var interpolated: Bool { fraction >= 0 }
    }

    static func bandMaps(count: Int, sampleRate: Double) -> [BandMap] {
        let upper = min(20_000, sampleRate / 2)
        let binWidth = sampleRate / Double(fftSize)
        let lastBin = fftSize / 2 - 1
        return (0..<count).map { index in
            let low = 20 * pow(upper / 20, Double(index) / Double(count))
            let high = 20 * pow(upper / 20, Double(index + 1) / Double(count))
            if (high - low) / binWidth < 1.5 {
                let position = min(Double(lastBin - 1), max(1, sqrt(low * high) / binWidth))
                let first = Int(position)
                return BandMap(first: first, last: first + 1, fraction: Float(position - Double(first)))
            }
            let first = max(1, min(lastBin, Int(low / binWidth)))
            return BandMap(first: first, last: max(first, min(lastBin, Int(high / binWidth))), fraction: -1)
        }
    }

    /// dB level of every row. Wide rows take their loudest bin; their powers are gathered and converted with one
    /// vectorised log. Narrow rows fit a parabola through the dB values of the nearest bin and its neighbours,
    /// evaluated at the row centre: the same peak model as `dominantPeak`. Linear power interpolation sagged by
    /// up to ~2 dB between bins (a tone half-way between two rows read low); the parabola recovers the peak.
    private func levels(_ maps: [BandMap], into output: inout [Float]) {
        let count = maps.count
        for (index, map) in maps.enumerated() where !map.interpolated {
            var power: Float = 0
            for bin in map.first...map.last { power = max(power, self.power[bin]) }
            rowPower[index] = power
        }
        var scale = amplitudeScale * amplitudeScale
        var floor: Float = 1e-12
        var ceiling = Float.greatestFiniteMagnitude
        var ten: Float = 10
        var n = Int32(count)
        rowPower.withUnsafeMutableBufferPointer { rows in
            let base = rows.baseAddress!
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(count))
            vDSP_vclip(base, 1, &floor, &ceiling, base, 1, vDSP_Length(count))
            vvlog10f(base, base, &n)
            vDSP_vsmul(base, 1, &ten, base, 1, vDSP_Length(count))
        }
        for (index, map) in maps.enumerated() {
            guard map.interpolated else {
                output[index] = rowPower[index]
                continue
            }
            let position = Float(map.first) + map.fraction
            let nearest = min(lowDecibels.count - 2, max(1, Int(position.rounded())))
            let a = lowDecibels[nearest - 1], b = lowDecibels[nearest], c = lowDecibels[nearest + 1]
            let x = position - Float(nearest)
            let value = b + 0.5 * (c - a) * x + 0.5 * (a - 2 * b + c) * x * x
            output[index] = max(-120, min(max(a, max(b, c)), value))
        }
    }

    /// Loudest bin k in 20 Hz…upper, refined by parabolic interpolation of the dB values at k−1, k, k+1.
    /// Plain `k · sampleRate / fftSize` is quantised to 5.9 Hz, which is more than a semitone below ~100 Hz;
    /// the vertex offset (|δ| ≤ ½ bin) makes note names and cents meaningful there.
    private func dominantPeak() -> (Float, Float) {
        let binWidth = sampleRate / Double(Self.fftSize)
        let first = max(2, Int(20 / binWidth))
        let last = min(Self.fftSize / 2 - 2, Int(min(20_000, sampleRate / 2) / binWidth))
        guard first < last else { return (0, -120) }
        var peakBin = first
        var peakPower: Float = 0
        for bin in first...last {
            let power = self.power[bin]
            if power > peakPower {
                peakPower = power
                peakBin = bin
            }
        }
        func decibels(_ bin: Int) -> Float {
            return 20 * log10(max(sqrt(power[bin]) * amplitudeScale, 0.000001))
        }
        let a = decibels(peakBin - 1), b = decibels(peakBin), c = decibels(peakBin + 1)
        let curvature = a - 2 * b + c
        let offset = curvature < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / curvature)) : 0
        let level = b - 0.25 * (a - c) * offset
        return (Float((Double(peakBin) + Double(offset)) * binWidth), max(-120, level))
    }

    /// One complex DFT per pair of roles, z = A + iB (both windowed); Z[k] and conj(Z[N−k]) give each spectrum:
    /// |A[k]|² = ((Zr[k] + Zr[N−k])² + (Zi[k] − Zi[N−k])²) / 4 and
    /// |B[k]|² = ((Zi[k] + Zi[N−k])² + (Zr[k] − Zr[N−k])²) / 4.
    /// The display power is the sum over `roles`, halved (see `power`). L and R alone need one transform.
    private func transform(_ roles: [Int]) {
        let bins = vDSP_Length(Self.fftSize / 2)
        var index = 0
        while index < roles.count {
            let pair = index + 1 < roles.count
            transformPair(roles[index], pair ? roles[index + 1] : nil)
            if index == 0 && pair && roles[0] == Role.left && roles[1] == Role.right { accumulateStereoBands() }
            if index == 0 { for i in roleBandPower.indices { roleBandPower[i] = 0 } }
            accumulateRoleBands(roles[index], pair ? roles[index + 1] : nil)
            power.withUnsafeMutableBufferPointer { sum in
                let out = sum.baseAddress!
                if index == 0 {
                    leftPower.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: Int(bins)) }
                } else {
                    vDSP_vadd(out, 1, leftPower, 1, out, 1, bins)
                }
                if pair { vDSP_vadd(out, 1, rightPower, 1, out, 1, bins) }
            }
            index += 2
        }
        var half: Float = 0.5
        power.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &half, $0.baseAddress!, 1, bins) }
    }

    /// Mean square per band of the pair just transformed (`leftPower` for `a`, `rightPower` for `b`).
    private func accumulateRoleBands(_ a: Int, _ b: Int?) {
        let scale = Float(bandPowerScale)
        for (band, bins) in bandBins.enumerated() {
            var sum: Float = 0
            leftPower.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + bins.lowerBound, 1, &sum, vDSP_Length(bins.count)) }
            roleBandPower[a * StereoBands.count + band] = sum * scale
            if let b {
                rightPower.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + bins.lowerBound, 1, &sum, vDSP_Length(bins.count)) }
                roleBandPower[b * StereoBands.count + band] = sum * scale
            }
        }
    }

    /// Per-band |L|², |R|² and the cross spectrum Re(L·R̄) of the L/R transform just made. With z = L + iR, the
    /// conjugate-symmetric split gives Re(L[k]·conj(R[k])) = (Zr[k]·Zi[N−k] + Zr[N−k]·Zi[k]) / 2.
    private func accumulateStereoBands() {
        let n = Self.fftSize
        var sums = [(left: Double, right: Double, cross: Double)](repeating: (0, 0, 0), count: StereoBands.count)
        outputReal.withUnsafeBufferPointer { zr in
            outputImaginary.withUnsafeBufferPointer { zi in
                for bin in 1..<(n / 2) {
                    let band = Int(binBands[bin])
                    guard band >= 0 else { continue }
                    let cross = 0.5 * (zr[bin] * zi[n - bin] + zr[n - bin] * zi[bin])
                    sums[band].left += Double(leftPower[bin])
                    sums[band].right += Double(rightPower[bin])
                    sums[band].cross += Double(cross)
                }
            }
        }
        bandSums = sums
    }

    /// Fills `leftPower` with |A|² and `rightPower` with |B|² (zero without a second role).
    private func transformPair(_ a: Int, _ b: Int?) {
        let n = Self.fftSize, half = n / 2
        let tail = n - cursor
        // Oldest sample first: the ring from the cursor to the end, then from the start.
        inputReal.withUnsafeMutableBufferPointer { real in
            inputImaginary.withUnsafeMutableBufferPointer { imaginary in
                history.withUnsafeBufferPointer { rings in
                    let ringA = rings.baseAddress! + a * n
                    real.baseAddress!.update(from: ringA + cursor, count: tail)
                    (real.baseAddress! + tail).update(from: ringA, count: cursor)
                    if let b {
                        let ringB = rings.baseAddress! + b * n
                        imaginary.baseAddress!.update(from: ringB + cursor, count: tail)
                        (imaginary.baseAddress! + tail).update(from: ringB, count: cursor)
                    } else {
                        vDSP_vclr(imaginary.baseAddress!, 1, vDSP_Length(n))
                    }
                }
                vDSP_vmul(real.baseAddress!, 1, window, 1, real.baseAddress!, 1, vDSP_Length(n))
                vDSP_vmul(imaginary.baseAddress!, 1, window, 1, imaginary.baseAddress!, 1, vDSP_Length(n))
            }
        }
        vDSP_DFT_Execute(setup, inputReal, inputImaginary, &outputReal, &outputImaginary)
        outputReal.withUnsafeBufferPointer { zr in
            outputImaginary.withUnsafeBufferPointer { zi in
                mirrored.withUnsafeMutableBufferPointer { m in
                    scratch.withUnsafeMutableBufferPointer { t in
                        leftPower.withUnsafeMutableBufferPointer { lp in
                            rightPower.withUnsafeMutableBufferPointer { rp in
                                let r = zr.baseAddress!, i = zi.baseAddress!
                                let count = vDSP_Length(half - 1)
                                // Bins 1..<half; bin k pairs with N−k, read with a negative stride.
                                let rMirror = r + n - 1, iMirror = i + n - 1
                                var quarter: Float = 0.25
                                // |A|²: (Zr[k] + Zr[N−k])² + (Zi[k] − Zi[N−k])²
                                vDSP_vadd(r + 1, 1, rMirror, -1, m.baseAddress! + 1, 1, count)
                                vDSP_vsub(iMirror, -1, i + 1, 1, t.baseAddress! + 1, 1, count)
                                vDSP_vdist(m.baseAddress! + 1, 1, t.baseAddress! + 1, 1, lp.baseAddress! + 1, 1, count)
                                vDSP_vsq(lp.baseAddress! + 1, 1, lp.baseAddress! + 1, 1, count)
                                vDSP_vsmul(lp.baseAddress! + 1, 1, &quarter, lp.baseAddress! + 1, 1, count)
                                // |B|²: (Zi[k] + Zi[N−k])² + (Zr[k] − Zr[N−k])²
                                vDSP_vadd(i + 1, 1, iMirror, -1, m.baseAddress! + 1, 1, count)
                                vDSP_vsub(rMirror, -1, r + 1, 1, t.baseAddress! + 1, 1, count)
                                vDSP_vdist(m.baseAddress! + 1, 1, t.baseAddress! + 1, 1, rp.baseAddress! + 1, 1, count)
                                vDSP_vsq(rp.baseAddress! + 1, 1, rp.baseAddress! + 1, 1, count)
                                vDSP_vsmul(rp.baseAddress! + 1, 1, &quarter, rp.baseAddress! + 1, 1, count)
                                // DC pairs with itself: A = Re Z[0], B = Im Z[0].
                                lp[0] = r[0] * r[0]
                                rp[0] = i[0] * i[0]
                            }
                        }
                    }
                }
            }
        }
    }
}
