import Accelerate
import AnalysisKernels
import Foundation

/// The five frequency bands of the multiband stereo readings: the correlation bar's lanes in Channel Levels, the
/// stereometer and the Immersive band map. Edges in Hz; the top band runs to the display ceiling. Each view shows
/// them at a `Resolution` of its own: the five bands, three (merged from the five) or one overall reading.
package enum StereoBands {
    package static let count = 5
    package static let edges: [Double] = [20, 120, 500, 2_000, 8_000]

    /// How finely a view splits the spectrum: one full-band reading (the whole spectrum, as a conventional meter
    /// reads it), three bands (below 120 Hz, 120 Hz–2 kHz, above 2 kHz) or the five.
    package enum Resolution: String, CaseIterable {
        case overall, three, five

        /// The five bands each group merges, low to high.
        package var groups: [[Int]] {
            switch self {
            case .overall: return [[0, 1, 2, 3, 4]]
            case .three: return [[0], [1, 2], [3, 4]]
            case .five: return [[0], [1], [2], [3], [4]]
            }
        }
        package var count: Int { groups.count }
        /// Index of this resolution's first group among `StereoBands.groups` (the published readings).
        package var offset: Int {
            switch self {
            case .five: return 0
            case .three: return 5
            case .overall: return 8
            }
        }
    }

    /// Every group any resolution shows, in `Resolution.offset` order: the five bands, the three, then overall.
    package static let groups = Resolution.five.groups + Resolution.three.groups + Resolution.overall.groups
    /// Values published per group: correlation, width, balance and level (see `MeterSnapshot`).
    package static let publishedFloats = 4 * groups.count

    /// Values published for the Immersive room's band image: each role's mean square in each band.
    package static let roleFloats = Role.count * count

    /// Points per band in the stereometer's cloud, taken evenly across the newest 1/30 s.
    package static let scopePoints = 128
    /// Floats of the stereometer's cloud: per band, `scopePoints` (L, R) pairs.
    package static let scopeFloats = count * scopePoints * 2

    /// A band's label: its lower edge, "20 Hz", "120 Hz", "500 Hz", "2 kHz", "8 kHz"; each band reaches up to the
    /// next one's.
    package static func label(_ band: Int) -> String {
        let edge = edges[band]
        return edge >= 1_000 ? "\(Int(edge / 1_000)) kHz" : "\(Int(edge)) Hz"
    }

    /// Band of each FFT bin from 1 to `fftSize / 2 − 1`, or −1 outside 20 Hz…the display ceiling.
    package static func binBands(sampleRate: Double, fftSize: Int) -> [Int8] {
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
/// stereometer's multiband cloud. All ten cascades (band × side) run together in `band_filter`, padded to four
/// sections with pass-through ones. Owned by the DSP queue.
package final class StereoBandSplitter {
    package static let historyLength = 4096
    package let sampleRate: Double
    /// `band_filter` coefficients: lane 2 × band + side, four sections each; a band above Nyquist outputs zero.
    private static let sections = Int(BAND_SECTIONS)
    private static let groups = Int(BAND_LANES) / 4
    private var coefficients = [Float](repeating: 0, count: groups * sections * 5 * 4)
    private var state = [Float](repeating: 0, count: groups * sections * 2 * 4)
    /// Newest `historyLength` filtered samples per band and side, all sharing `cursor`.
    private var history: [Float]
    private var cursor = 0
    private var left: [Float] = []
    private var right: [Float] = []

    package init?(sampleRate: Double) {
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
        let passThrough: [Double] = [1, 0, 0, 0, 0]
        for band in 0..<StereoBands.count {
            var sections: [[Double]] = []
            if StereoBands.edges[band] < nyquist {
                if band > 0 {
                    let edge = butterworth(StereoBands.edges[band], highPass: true)
                    sections += [edge, edge]
                }
                if band + 1 < StereoBands.count, StereoBands.edges[band + 1] < nyquist {
                    let edge = butterworth(StereoBands.edges[band + 1], highPass: false)
                    sections += [edge, edge]
                }
                sections += Array(repeating: passThrough, count: Self.sections - sections.count)
            } else {
                sections = Array(repeating: [0, 0, 0, 0, 0], count: Self.sections)
            }
            for side in 0..<2 {
                let lane = 2 * band + side
                for (k, section) in sections.enumerated() {
                    for (j, value) in section.enumerated() {
                        coefficients[((lane / 4 * Self.sections + k) * 5 + j) * 4 + lane % 4] = Float(value)
                    }
                }
            }
        }
    }

    /// Filters `count` frames of L and R, read from `samples` with `stride` floats per frame.
    package func consume(_ samples: UnsafePointer<Float>, stride: Int, count: Int, leftOffset: Int = 0, rightOffset: Int = 1) {
        guard count > 0 else { return }
        if left.count < count {
            left = [Float](repeating: 0, count: count)
            right = [Float](repeating: 0, count: count)
        }
        audio_gather_strided(samples + leftOffset, UInt32(stride), &left, UInt32(count))
        audio_gather_strided(samples + rightOffset, UInt32(stride), &right, UInt32(count))
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in consume(left: l.baseAddress!, right: r.baseAddress!, count: count) }
        }
    }

    /// A break in the audio: the band filters and their history start from silence.
    package func interrupt() {
        state.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        history.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        cursor = 0
    }

    /// Filters `count` contiguous samples of L and R straight into the band rings.
    package func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        let length = Self.historyLength
        let lanes = 2 * StereoBands.count
        history.withUnsafeMutableBufferPointer { ring in
            coefficients.withUnsafeBufferPointer { c in
                state.withUnsafeMutableBufferPointer { s in
                    withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: lanes) { outputs in
                        var offset = 0
                        while offset < count {
                            let run = min(count - offset, length - cursor)
                            for lane in 0..<lanes { outputs[lane] = ring.baseAddress! + lane * length + cursor }
                            band_filter(c.baseAddress!, s.baseAddress!, left + offset, right + offset, outputs.baseAddress!,
                                        UInt32(lanes), UInt32(run))
                            offset += run
                            cursor = (cursor + run) % length
                        }
                    }
                }
            }
        }
    }

    /// Writes `StereoBands.scopeFloats`: per band, `scopePoints` (L, R) pairs spread evenly over the newest
    /// 1/30 s, oldest first. `silent` writes zeros.
    package func writePoints(into v: UnsafeMutablePointer<Float>, silent: Bool) {
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

package struct MeterSnapshot: Equatable {
    package static let bandCount = 64
    /// The live spectrum's finer bands: each of the 64 split in two (about 1/13 octave), from the same transform, so
    /// a curve drawn from them keeps the 64 bands' single-resolution calibration with twice the detail and lines up
    /// with every fourth waterfall row.
    package static let fineBandCount = 128
    /// Log-spaced rows for the waterfall: at least one row per device pixel on a typical Retina panel, so the
    /// shader never stretches a row across several pixels and harmonics stay crisp.
    package static let spectrogramBandCount = 512
    /// Published when L and R carry no signal, so the correlation meter can rest instead of reading 0.
    package static let noCorrelation: Float = -2
    package init() {}
    package var spectrum: [Float] = Array(repeating: -120, count: bandCount)
    package var spectrumFine: [Float] = Array(repeating: -120, count: fineBandCount)
    package var spectrogram: [Float] = Array(repeating: -120, count: spectrogramBandCount)
    package var sequence: Float = 0
    /// Advances once per waterfall column (30 per second), independent of the snapshot rate.
    package var spectrogramSerial: Float = 0
    /// `SpectrogramMode` of the newest column (a plugin before build 72 sends only Classic).
    package var spectrogramMode: Float = 0
    package var streamID: Float = 0
    package var leftPeak: Float = 0
    package var rightPeak: Float = 0
    package var leftRMS: Float = 0
    package var rightRMS: Float = 0
    /// Per role (see `Role`), linear.
    package var channelPeaks = [Float](repeating: 0, count: Role.count)
    package var channelRMS = [Float](repeating: 0, count: Role.count)
    package var channelTruePeaks = [Float](repeating: 0, count: Role.count)
    /// Highest sample and true peak per role since the stream started, linear. Kept on the DSP side so a
    /// readout that samples snapshots at 10 Hz still sees every overshoot.
    package var heldPeaks = [Float](repeating: 0, count: Role.count)
    package var heldTruePeaks = [Float](repeating: 0, count: Role.count)
    package var momentaryLUFS: Float = -100
    package var shortLUFS: Float = -100
    package var integratedLUFS: Float = -100
    /// EBU Tech 3342 loudness range in LU; negative until measurable.
    package var loudnessRange: Float = -1
    /// Loudest spectral peak between 20 Hz and the display ceiling (display power: L+R, or every routed role in
    /// Spatial), in Hz and dBFS.
    package var peakFrequency: Float = 0
    package var peakLevel: Float = -120
    /// The notes sounding together (`SpectrumAnalyzer.tonalPeaks`): up to `maxNotes` (Hz, dBFS) pairs, loudest
    /// first; an unused pair has frequency 0.
    package var notes = [Float](repeating: 0, count: 2 * SpectrumAnalyzer.maxNotes)
    /// `ChannelFormat` raw value from the DSP-side detector.
    package var detectedFormat: Float = 0
    /// L/R phase correlation over the last tick, −1…+1, or `noCorrelation` in silence.
    package var correlation: Float = MeterSnapshot.noCorrelation
    /// Per `StereoBands.groups` entry (five bands, three, overall), integrated like `correlation`: the L/R
    /// correlation (`noCorrelation` while the group is silent), the width (side share of the energy: 0 mono,
    /// ½ unrelated sides, 1 out of phase), the balance (−1 all left … +1 all right) and the level (RMS of L and R,
    /// dBFS).
    package var bandCorrelation = [Float](repeating: MeterSnapshot.noCorrelation, count: StereoBands.groups.count)
    package var bandWidth = [Float](repeating: 0, count: StereoBands.groups.count)
    package var bandBalance = [Float](repeating: 0, count: StereoBands.groups.count)
    package var bandLevel = [Float](repeating: -120, count: StereoBands.groups.count)
    /// The stereometer's cloud: per band, `StereoBands.scopePoints` (L, R) sample pairs from the newest 1/30 s.
    package var bandPoints = [Float](repeating: 0, count: StereoBands.scopeFloats)
    /// Mean square of every role in every band (role-major), integrated like the band correlation: where each
    /// band's energy sits in the Immersive room. Only L and R carry values outside Spatial analysis.
    package var roleBandPower = [Float](repeating: 0, count: StereoBands.roleFloats)
    package var waveSerial: Float = 0
    package var waveform: [Float] = Array(repeating: 0, count: WaveformEnvelope.publishedFloats)
    /// Breaks in the analysed audio since the analysis started (`MeterPipeline.interrupt`), and the seconds of
    /// audio known to be missing at them: integrated loudness, loudness range and the held peaks span them.
    package var breaks: Float = 0
    package var missingSeconds: Float = 0
    /// Per role: DC offset (linear, signed) and infrasonic mean square (linear), from `SignalHealthMeter`; status 1
    /// settled, 0.5 settling, 0 not measured.
    package var dcOffset = [Float](repeating: 0, count: Role.count)
    package var infrasonic = [Float](repeating: 0, count: Role.count)
    package var healthStatus: Float = 0
    /// The Immersive soundstage's spatial field (`SpatialField` layout); status 0 while there is none.
    package var spatialField = [Float](repeating: 0, count: SpatialField.floats)
    /// The same transform's bins at their centres of gravity (`SpatialPoints` layout); status 0 while there are none
    /// (also from a Bridge plugin before build 87).
    package var spatialPoints = [Float](repeating: 0, count: SpatialPoints.floats)
}

// Owned exclusively by the serial DSP queue. No audio callback enters this class.
package final class SpectrumAnalyzer {
    // 8192 points at 44.1 and 48 kHz: 5.9 Hz bins, so the bottom octaves get real detail. At higher rates the
    // transform grows with the rate (`historyLength`: 16384 at 96 kHz, 32768 at 192 kHz), so the spectrum, its peaks
    // and notes resolve the same Hz over the same ~170 ms at every rate. The waterfall reads the same history rings at
    // several resolutions of its own (`SpectrogramAnalyzer`). Channels share complex transforms in
    // pairs (one real, one imaginary) and are separated by conjugate symmetry, which halves the FFT cost without
    // giving up any resolution; that is cheaper than dropping to 4096 points and keeps the 5.9 Hz bins.
    package static let fftSize = 8192
    package let sampleRate: Double
    /// Samples each role's ring keeps, and the spectrum's transform length: `fftSize` at 44.1 and 48 kHz, doubled
    /// with each doubling of the rate, so the spectrum and the waterfall analyse the same ~170 ms (and resolve the
    /// same Hz) at every rate.
    package let historyLength: Int
    private let setup: OpaquePointer
    private var window: [Float]
    /// `window` halved: the conjugate-symmetric split's ¼ rides on the window (a power of two, so exact).
    private var fftWindow: [Float]
    /// Newest `historyLength` samples of each recorded role: one ring per role, all sharing `cursor`.
    private var history: [Float]
    /// L, R and every other routed role: what a Spatial spectrum sums.
    private let recordedRoles: [Int]
    /// The other roles are recorded only while Spatial analysis is wanted (it costs a strided copy per role).
    /// Turning it on starts their history afresh; they join the spectrum once a full window has been captured.
    package var recordsSpatial = false {
        didSet { if recordsSpatial != oldValue { spatialHistoryCount = 0 } }
    }
    private var spatialHistoryCount = 0
    private var inputReal: [Float]
    private var inputImaginary: [Float]
    /// Newest frames of each role's ring that are all digital silence (`historyLength`: the whole ring).
    private var silentFrames: [Int]
    private var outputReal: [Float]
    private var outputImaginary: [Float]
    private var leftPower: [Float]
    private var rightPower: [Float]
    /// Display power per bin: the sum over the analysed roles, halved so it is referenced to a stereo pair.
    /// For L and R alone that is their mean, exactly as before; stereo content reads the same in both modes.
    private var power: [Float]
    private var bands: [BandMap] = []
    private var fineBands: [BandMap] = []
    /// The newest transform's `MeterSnapshot.fineBandCount` bands (dBFS), filled with the 64 by `refreshSpectrum`.
    package private(set) var fineSpectrum = [Float](repeating: -120, count: MeterSnapshot.fineBandCount)
    /// The waterfall's own multi-resolution analysis of the same history rings; tests and comparisons may substitute
    /// one of another window or resolving power.
    package var spectrogramAnalyzer: SpectrogramAnalyzer
    /// Which analysis the waterfall's columns use; Enhanced builds its analyser the first time it is asked for.
    package var spectrogramMode = SpectrogramMode.classic
    private var reassigned: ReassignedSpectrogram?
    /// Roles the newest transform was asked for, which the waterfall column follows (L and R, or every Spatial role).
    private var requestedRoles = [Role.left, Role.right]
    /// Roles the newest transform analysed: L and R, and the requested roles that were sounding.
    private var analysedRoles = [Role.left, Role.right]
    /// dB of the low bins that interpolated bands read (one vectorised log per tick instead of three per band).
    private var lowDecibels: [Float] = []
    /// Scratch for one pass of band powers, converted to dB together.
    private var rowPower = [Float](repeating: 0, count: MeterSnapshot.fineBandCount)
    /// The loudest bin of each wide band in the newest pass, refined in dB afterwards.
    private var rowPeakBin = [Int](repeating: 0, count: MeterSnapshot.fineBandCount)
    private var amplitudeScale: Float = 0
    /// Band of each bin (`StereoBands.binBands`) and the per-band |L|², |R|² and Re(L·R̄) of the newest transform.
    private var binBands: [Int8] = []
    package private(set) var bandSums = [(left: Double, right: Double, cross: Double)](repeating: (0, 0, 0), count: StereoBands.count)
    /// Mean square of the windowed signal per unit of one-sided |X|² (Parseval): 2 / (N · Σw²).
    package private(set) var bandPowerScale: Double = 0
    /// First and last bin of each band, and every transformed role's mean square per band (role-major).
    private var bandBins: [Range<Int>] = []
    package private(set) var roleBandPower = [Float](repeating: 0, count: StereoBands.roleFloats)
    /// The routed roles' spatial field (the Immersive soundstage), built from each Spatial transform while
    /// `buildsSpatialField` is on; `spatialFieldBuilt` says whether the newest transform built it.
    package let spatialField: SpatialFieldAnalyzer
    package var buildsSpatialField = false
    package private(set) var spatialFieldBuilt = false
    private var cursor = 0
    private var historyCount = 0
    private var peakLeft: Float = 0
    private var peakRight: Float = 0
    private var sumLeft: Double = 0
    private var sumRight: Double = 0
    private var sumProduct: Double = 0
    private var levelFrames = 0

    /// `recording` marks the routed roles whose history is kept for Spatial analysis (L and R always are).
    package init?(sampleRate: Double, recording roles: [Bool] = []) {
        guard sampleRate.isFinite, sampleRate > 100,
              let spectrogramAnalyzer = SpectrogramAnalyzer(sampleRate: sampleRate, span: Self.historyLength(sampleRate: sampleRate)),
              let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.historyLength(sampleRate: sampleRate)), .FORWARD)
        else { return nil }
        self.setup = setup
        self.spectrogramAnalyzer = spectrogramAnalyzer
        self.sampleRate = sampleRate
        let n = Self.historyLength(sampleRate: sampleRate)
        historyLength = n
        history = [Float](repeating: 0, count: Role.count * n)
        silentFrames = [Int](repeating: n, count: Role.count)
        window = [Float](repeating: 0, count: n)
        fftWindow = [Float](repeating: 0, count: n)
        inputReal = [Float](repeating: 0, count: n)
        inputImaginary = [Float](repeating: 0, count: n)
        outputReal = [Float](repeating: 0, count: n)
        outputImaginary = [Float](repeating: 0, count: n)
        leftPower = [Float](repeating: 0, count: n / 2)
        rightPower = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
        recordedRoles = [Role.left, Role.right] + (0..<min(roles.count, Role.count)).filter { $0 > Role.right && roles[$0] }
        spatialField = SpatialFieldAnalyzer(sampleRate: sampleRate, transformLength: n, roles: recordedRoles)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var half: Float = 0.5
        vDSP_vsmul(window, 1, &half, &fftWindow, 1, vDSP_Length(n))
        var windowSum: Float = 0
        vDSP_sve(window, 1, &windowSum, vDSP_Length(n))
        amplitudeScale = 2 / windowSum
        var windowSquares: Float = 0
        vDSP_svesq(window, 1, &windowSquares, vDSP_Length(n))
        bandPowerScale = 2 / (Double(n) * Double(windowSquares))
        binBands = StereoBands.binBands(sampleRate: sampleRate, fftSize: n)
        bandBins = (0..<StereoBands.count).map { band in
            let bins = binBands.indices.filter { binBands[$0] == band }
            guard let first = bins.first, let last = bins.last else { return 0..<0 }
            return first..<(last + 1)
        }
        bands = Self.bandMaps(count: MeterSnapshot.bandCount, sampleRate: sampleRate, fftSize: n)
        fineBands = Self.bandMaps(count: MeterSnapshot.fineBandCount, sampleRate: sampleRate, fftSize: n)
        let lowBins = (bands + fineBands).filter(\.interpolated).map { $0.last + 2 }.max() ?? 0
        lowDecibels = [Float](repeating: -120, count: min(n / 2, lowBins))
    }

    /// `historyLength` at `sampleRate`: `fftSize` up to 48 kHz, then doubled per doubling of the rate (up to 8×).
    package static func historyLength(sampleRate: Double) -> Int {
        var length = fftSize
        while Double(length) * 48_000 / Double(fftSize) < sampleRate * 0.99 && length < 8 * fftSize { length *= 2 }
        return length
    }

    /// Roles a Spatial spectrum sums: L, R and every other routed role.
    package var spatialRoles: [Int] { recordedRoles }
    /// Every routed role has a full FFT window (always true when only L and R are routed).
    package var spatialReady: Bool { recordedRoles.count <= 2 || (recordsSpatial && spatialHistoryCount == historyLength) }

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
    package func consume(_ frames: UnsafeBufferPointer<StereoFrame>) {
        guard let base = frames.baseAddress, !frames.isEmpty else { return }
        base.withMemoryRebound(to: Float.self, capacity: frames.count * 2) { samples in
            accumulate(count: frames.count, stride: 2, roles: [Role.left, Role.right]) { samples + ($0 == Role.left ? 0 : 1) }
        }
    }

    /// Role-mapped frames from the capture ring: L/R sums for the correlation, history for every recorded role.
    package func consume(_ frames: UnsafeBufferPointer<ChannelFrame>) {
        guard let base = frames.baseAddress, !frames.isEmpty else { return }
        base.withMemoryRebound(to: Float.self, capacity: frames.count * Role.count) { samples in
            accumulate(count: frames.count, stride: Role.count, roles: historyRoles) { samples + $0 }
        }
        if recordsSpatial { spatialHistoryCount = min(historyLength, spatialHistoryCount + frames.count) }
    }

    /// Already de-interleaved audio (see `MeterPipeline`); L, R and, while Spatial is recorded, every routed role
    /// must be present.
    package func consume(_ block: PlanarBlock) {
        guard block.count > 0 else { return }
        accumulate(count: block.count, stride: 1, roles: historyRoles) { block.channel($0) }
        if recordsSpatial { spatialHistoryCount = min(historyLength, spatialHistoryCount + block.count) }
    }

    /// The roles whose history is kept right now: L and R, plus every routed role while Spatial is recorded.
    package var historyRoles: [Int] { recordsSpatial ? recordedRoles : [Role.left, Role.right] }

    /// `channel(role)` is the role's first sample; its samples lie `stride` floats apart. L and R come first.
    private func accumulate(count frameCount: Int, stride: Int, roles: [Int], channel: (Int) -> UnsafePointer<Float>) {
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var leftSquared: Float = 0
        var rightSquared: Float = 0
        var product: Float = 0
        let count = vDSP_Length(frameCount)
        let left = channel(roles[0]), right = channel(roles[1])
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
        // Keep the newest `historyLength` samples: at most two contiguous copies per role into its ring.
        let length = historyLength
        var remaining = frameCount
        var skip = 0
        if remaining > length {
            skip = remaining - length
            remaining = length
        }
        history.withUnsafeMutableBufferPointer { rings in
            while remaining > 0 {
                let run = min(remaining, length - cursor)
                for role in roles {
                    audio_gather_strided(channel(role) + skip * stride, UInt32(stride), rings.baseAddress! + role * length + cursor, UInt32(run))
                }
                cursor = (cursor + run) % length
                skip += run
                remaining -= run
            }
        }
        // How long each ring has held nothing but zeros: a ring that is all zeros transforms to zeros.
        for role in roles {
            var peak: Float = 0
            switch role {
            case roles[0]: peak = leftPeak
            case roles[1]: peak = rightPeak
            default: vDSP_maxmgv(channel(role), stride, &peak, count)
            }
            silentFrames[role] = peak > 0 ? 0 : min(length, silentFrames[role] + frameCount)
        }
        levelFrames += frameCount
        historyCount = min(length, historyCount + frameCount)
    }

    /// A full FFT window has been captured, so spectra are meaningful.
    package var ready: Bool { historyCount == historyLength }

    /// A break in the audio: the FFT window starts empty, so no transform mixes audio from both sides of it.
    /// Until it has refilled (`ready`), the spectrum reads as it does when a stream starts.
    package func interrupt() {
        spatialField.reset()
        spatialFieldBuilt = false
        history.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        for role in silentFrames.indices { silentFrames[role] = historyLength }
        cursor = 0
        historyCount = 0
        spatialHistoryCount = 0
    }

    /// L², R² and L·R sums since the previous call, for the phase correlation, and the frames they cover.
    package func takeStereoSums() -> (left: Double, right: Double, product: Double, frames: Int) {
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
    package static func correlation(left: Double, right: Double, product: Double) -> Float {
        let energy = left * right
        return energy > 1e-12 ? Float(max(-1, min(1, product / sqrt(energy)))) : MeterSnapshot.noCorrelation
    }

    /// Transforms the newest FFT window of `roles` (L and R by default; `spatialRoles` for every routed role)
    /// and fills the 64 display bands (and `fineSpectrum`); returns the dominant peak (Hz, dBFS). The power spectrum
    /// stays available to `spectrogram(into:)` until the next transform.
    package func refreshSpectrum(into spectrum: inout [Float], roles: [Int] = [Role.left, Role.right]) -> (frequency: Float, level: Float) {
        transform(roles)
        refreshLowDecibels()
        levels(bands, into: &spectrum)
        levels(fineBands, into: &fineSpectrum)
        notes = tonalPeaks()
        return dominantPeak()
    }

    /// Note slots in each published snapshot (`MeterSnapshot.notes`).
    package static let maxNotes = 6
    /// Most notes the keyboard lights at once: the few that clearly lead, not every partial of a dense mix.
    package static let litNotes = 4
    /// The newest transform's notes (`tonalPeaks`), loudest first.
    package private(set) var notes: [(frequency: Float, level: Float)] = []

    /// The notes most likely sounding together, from the newest transform: tonal peaks between A0 and C8 (a
    /// local maximum at least 12 dB above the spectrum 3 to 8 bins either side, so noise and the window's own
    /// skirt do not count), within 18 dB of the loudest and above −70 dBFS, one per semitone, at most `litNotes`
    /// of them. A peak lying on
    /// the 2nd to 8th harmonic of a lower note already kept (within 40 cents) and not clearly louder than it is
    /// that note's overtone, not a note of its own. Each frequency is refined like `dominantPeak`.
    private func tonalPeaks() -> [(frequency: Float, level: Float)] {
        let binWidth = sampleRate / Double(historyLength)
        let first = max(2, Int(27 / binWidth))
        let last = min(historyLength / 2 - 10, Int(min(4_200, sampleRate / 2) / binWidth))
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
            guard level - decibels(around / neighbors) >= 12 else { continue }
            candidates.append((bin, level))
        }
        guard let loudest = candidates.map(\.level).max() else { return [] }
        var peaks: [(frequency: Float, level: Float)] = candidates
            .filter { $0.level >= loudest - 18 }
            .sorted { $0.level > $1.level }
            .prefix(16)
            .map { candidate in
                let peak = Self.hannPeak(decibels(power[candidate.bin - 1]), candidate.level, decibels(power[candidate.bin + 1]))
                return (Float((Double(candidate.bin) + Double(peak.offset)) * binWidth), peak.level)
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
        return Array(kept.sorted { $0.level > $1.level }.prefix(Self.litNotes))
    }

    /// `notes` packed as `MeterSnapshot.notes`.
    package func packedNotes(into output: UnsafeMutablePointer<Float>) {
        for index in 0..<Self.maxNotes {
            let note: (frequency: Float, level: Float) = index < notes.count ? notes[index] : (0, -120)
            output[2 * index] = note.frequency
            output[2 * index + 1] = note.level
        }
    }

    /// A waterfall column (`SpectrogramAnalyzer`) of the roles the newest transform was asked for, over the whole
    /// history. Rings silent throughout add nothing and are skipped, as in `transform`.
    package func spectrogram(into rows: inout [Float]) {
        let length = historyLength
        let roles = requestedRoles.count > 2
            ? Array(requestedRoles.prefix(2)) + requestedRoles.dropFirst(2).filter { silentFrames[$0] < length }
            : requestedRoles
        let sounding = roles.allSatisfy { silentFrames[$0] >= length } ? [] : roles
        // The newest transform is the bass zone's own: the same Hann window over the same ring, for the same roles
        // unless one fell silent within the window.
        let reuse = sounding == analysedRoles
        if spectrogramMode == .enhanced {
            if reassigned == nil { reassigned = ReassignedSpectrogram(sampleRate: sampleRate, span: length) }
            if let reassigned {
                history.withUnsafeBufferPointer { rings in
                    rows.withUnsafeMutableBufferPointer { out in
                        reassigned.column(rings: rings.baseAddress!, cursor: cursor, roles: sounding, into: out.baseAddress!)
                    }
                }
                return
            }
        }
        history.withUnsafeBufferPointer { rings in
            power.withUnsafeBufferPointer { longest in
                rows.withUnsafeMutableBufferPointer { out in
                    spectrogramAnalyzer.column(rings: rings.baseAddress!, cursor: cursor, roles: sounding,
                                               longest: reuse ? longest.baseAddress! : nil, into: out.baseAddress!)
                }
            }
        }
    }

    /// The waterfall's analysis (resolutions in use, for diagnostics).
    package var spectrogramResolutions: [(length: Int, frames: Int, window: SpectralWindow)] { spectrogramAnalyzer.resolutions }

    package func snapshot() -> MeterSnapshot {
        var result = MeterSnapshot()
        if levelFrames > 0 {
            result.leftPeak = peakLeft
            result.rightPeak = peakRight
            result.leftRMS = Float(sqrt(sumLeft / Double(levelFrames)))
            result.rightRMS = Float(sqrt(sumRight / Double(levelFrames)))
            result.correlation = Self.correlation(left: sumLeft, right: sumRight, product: sumProduct)
            if ready {
                (result.peakFrequency, result.peakLevel) = refreshSpectrum(into: &result.spectrum)
                result.spectrumFine = fineSpectrum
                result.notes.withUnsafeMutableBufferPointer { packedNotes(into: $0.baseAddress!) }
                spectrogram(into: &result.spectrogram)
            }
        }
        _ = takeStereoSums()
        return result
    }

    /// A log-spaced display band (the spectrum's 64, or a waterfall row at one of its resolutions). Bands wider than
    /// ~1.5 bins take the loudest bin they cover; narrower ones (the low octaves) interpolate at their centre
    /// frequency instead of repeating one bin, which removes the staircase at the bottom of the axis.
    package struct BandMap {
        package let first: Int
        package let last: Int
        package let fraction: Float
        /// Half the band's width in bins, for an interpolated band (which reads the loudest point within it).
        package var halfWidth: Float = 0
        package var interpolated: Bool { fraction >= 0 }
        /// The band's centre, in fractional bins (interpolated bands).
        package var position: Float { Float(first) + fraction }
    }

    package static func bandMaps(count: Int, sampleRate: Double, fftSize: Int = SpectrumAnalyzer.fftSize) -> [BandMap] {
        let upper = min(20_000, sampleRate / 2)
        let binWidth = sampleRate / Double(fftSize)
        let lastBin = fftSize / 2 - 1
        return (0..<count).map { index in
            let low = 20 * pow(upper / 20, Double(index) / Double(count))
            let high = 20 * pow(upper / 20, Double(index + 1) / Double(count))
            if (high - low) / binWidth < 1.5 {
                let position = min(Double(lastBin - 1), max(1, sqrt(low * high) / binWidth))
                let first = Int(position)
                return BandMap(first: first, last: first + 1, fraction: Float(position - Double(first)),
                               halfWidth: Float((high - low) / binWidth / 2))
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
        power.withUnsafeBufferPointer { bins in
            rowPower.withUnsafeMutableBufferPointer { rows in
                rowPeakBin.withUnsafeMutableBufferPointer { peaks in
                    for index in 0..<count where !maps[index].interpolated {
                        let map = maps[index]
                        let width = map.last - map.first + 1
                        var power: Float = 0
                        var peak = map.first
                        if width < 8 {
                            for bin in map.first...map.last where bins[bin] > power { power = bins[bin]; peak = bin }
                        } else {
                            var offset: vDSP_Length = 0
                            vDSP_maxvi(bins.baseAddress! + map.first, 1, &power, &offset, vDSP_Length(width))
                            peak = map.first + Int(offset)
                        }
                        rows[index] = max(0, power)
                        peaks[index] = peak
                    }
                }
            }
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
        let scale2 = amplitudeScale * amplitudeScale
        // Read through buffer pointers, with the estimator fetched once: indexing the stored arrays and reaching the
        // static estimator per band cost an access check, a lazy-initialisation check and a retain each time, which
        // was most of the time the bands took.
        let estimator = PeakEstimator.hann
        power.withUnsafeBufferPointer { bins in
            rowPower.withUnsafeBufferPointer { rows in
                rowPeakBin.withUnsafeBufferPointer { peaks in
                    lowDecibels.withUnsafeBufferPointer { low in
                        output.withUnsafeMutableBufferPointer { out in
                            func decibels(_ bin: Int) -> Float { 10 * log10(max(bins[bin] * scale2, 1e-12)) }
                            for index in 0..<count {
                                let map = maps[index]
                                guard map.interpolated else {
                                    // A tone between two bins reads up to 1.4 dB low in either (Hann scalloping); where
                                    // the band's loudest bin is a local maximum, the Hann peak estimate restores the
                                    // level, if the tone lies in the band.
                                    var level = rows[index]
                                    let k = peaks[index]
                                    if k > 0, k + 1 < bins.count, bins[k] > 0, bins[k] >= bins[k - 1], bins[k] >= bins[k + 1] {
                                        let peak = estimator.peak(decibels(k - 1), level, decibels(k + 1))
                                        let tone = Float(k) + peak.offset
                                        if tone >= Float(map.first) - 0.5, tone <= Float(map.last) + 0.5 { level = peak.level }
                                    }
                                    out[index] = level
                                    continue
                                }
                                out[index] = Self.interpolatedLevel(low, at: map.position, halfWidth: map.halfWidth,
                                                                    estimator: estimator)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A tone's offset from bin k (−½…½ bin) and its level, from the dB levels `a`, `b`, `c` of bins k−1, k, k+1 of a
    /// Hann-windowed spectrum, k the loudest. The Hann window's lobe makes the magnitude ratio of the two loudest bins
    /// α = (1 + δ)/(2 − δ), so δ = (2α − 1)/(α + 1) exactly (Grandke's estimator), and the lobe's shape at δ,
    /// sinc(δ)/(1 − δ²), gives the level lost to scalloping. For one tone it is exact (to the window's leakage from
    /// elsewhere): a fitted log parabola was off by up to 2.9 cents and 0.3 dB at 55 Hz. Neighbours louder than
    /// `b` (not a peak) give no offset. (`PeakEstimator` derives the same from any cosine-sum window's kernel.)
    package static func hannPeak(_ a: Float, _ b: Float, _ c: Float) -> (offset: Float, level: Float) {
        PeakEstimator.hann.peak(a, b, c)
    }

    /// The loudest level within `position ± halfWidth` (fractional bins) of a spectrum in dB, read from the parabola
    /// through three bins: a band narrower than a bin stands for an interval of frequency, and a tone anywhere in it
    /// reads its full level there, as it does in a wide band (its loudest bin). The parabola is centred on the local
    /// maximum beside `position` when there is one, so it is the peak's own model (the one `dominantPeak` uses);
    /// sampled at the band's centre around the nearest bin, a tone between rows read up to ~1.4 dB low. Elsewhere
    /// (a flank or the floor) it is centred on the nearest bin. Never above the vertex or below −120 dB.
    package static func interpolatedLevel(_ d: UnsafeBufferPointer<Float>, at position: Float, halfWidth: Float = 0,
                                          estimator: PeakEstimator = .hann) -> Float {
        guard d.count >= 3 else { return d.first ?? -120 }
        var centre = min(d.count - 2, max(1, Int(position.rounded())))
        if centre - 1 >= 1, d[centre - 1] > d[centre], d[centre - 1] >= d[centre - 2] {
            centre -= 1
        } else if centre + 2 < d.count, d[centre + 1] > d[centre], d[centre + 1] >= d[centre + 2] {
            centre += 1
        }
        let a = d[centre - 1], b = d[centre], c = d[centre + 1]
        let curvature = a - 2 * b + c
        var x = position - Float(centre)
        var ceiling = max(a, max(b, c))
        if b >= a, b >= c, b > -120 {
            // A peak: where the tone itself lies within the band, the band reads the tone's level (`hannPeak`);
            // otherwise the band's edge nearer to it, on the flank.
            let peak = estimator.peak(a, b, c)
            if abs(peak.offset - x) <= halfWidth { return max(-120, peak.level) }
            ceiling = peak.level
            x = peak.offset < x ? x - halfWidth : x + halfWidth
        }
        x = max(-1.5, min(1.5, x))
        let value = b + 0.5 * (c - a) * x + 0.5 * curvature * x * x
        return max(-120, min(ceiling, value))
    }

    /// Loudest bin k in 20 Hz…upper, refined from k−1, k, k+1 (`hannPeak`). Plain `k · sampleRate / fftSize` is
    /// quantised to 5.9 Hz, which is more than a semitone below ~100 Hz; the offset (|δ| ≤ ½ bin) makes note names
    /// and cents meaningful there.
    private func dominantPeak() -> (Float, Float) {
        let binWidth = sampleRate / Double(historyLength)
        let first = max(2, Int(20 / binWidth))
        let last = min(historyLength / 2 - 2, Int(min(20_000, sampleRate / 2) / binWidth))
        guard first < last else { return (0, -120) }
        var peakPower: Float = 0
        var index: vDSP_Length = 0
        power.withUnsafeBufferPointer { vDSP_maxvi($0.baseAddress! + first, 1, &peakPower, &index, vDSP_Length(last - first + 1)) }
        // The first loudest bin; a silent spectrum keeps the lowest.
        let peakBin = peakPower > 0 ? first + Int(index) : first
        func decibels(_ bin: Int) -> Float {
            return 20 * log10(max(sqrt(power[bin]) * amplitudeScale, 0.000001))
        }
        let peak = Self.hannPeak(decibels(peakBin - 1), decibels(peakBin), decibels(peakBin + 1))
        return (Float((Double(peakBin) + Double(peak.offset)) * binWidth), max(-120, peak.level))
    }

    /// One complex DFT per pair of roles, z = A + iB (both windowed); Z[k] and conj(Z[N−k]) give each spectrum:
    /// |A[k]|² = ((Zr[k] + Zr[N−k])² + (Zi[k] − Zi[N−k])²) / 4 and
    /// |B[k]|² = ((Zi[k] + Zi[N−k])² + (Zr[k] − Zr[N−k])²) / 4.
    /// The display power is the sum over `roles`, halved (see `power`). L and R alone need one transform.
    private func transform(_ requested: [Int]) {
        // A silent ring adds nothing to the power, and its band powers are zero: after L and R, only roles with
        // sound are transformed, paired among themselves. A 7.1.4 stream carrying stereo costs one transform.
        let roles = requested.count > 2
            ? Array(requested.prefix(2)) + requested.dropFirst(2).filter { silentFrames[$0] < historyLength }
            : requested
        requestedRoles = requested
        analysedRoles = roles
        // The spatial field reads the Spatial transform of every routed role (in Immersive only), every
        // `SpatialFieldAnalyzer.interval`-th one; between them the newest field stands.
        let spatialTransform = buildsSpatialField && requested == recordedRoles
        let field = spatialTransform && spatialField.due(continuing: spatialFieldBuilt)
        spatialFieldBuilt = spatialTransform && (field || spatialFieldBuilt)
        let fieldSeconds = Double(SpatialFieldAnalyzer.interval) / MeterPipeline.tickRate
        let bins = vDSP_Length(historyLength / 2)
        if roles.allSatisfy({ silentFrames[$0] >= historyLength }) {
            // Digital silence everywhere (a paused player still delivers zeros): the transforms would be zeros.
            for i in power.indices { power[i] = 0 }
            for i in roleBandPower.indices { roleBandPower[i] = 0 }
            if roles.count > 1 && roles[0] == Role.left && roles[1] == Role.right {
                bandSums = Array(repeating: (0, 0, 0), count: StereoBands.count)
            }
            if field { spatialField.silenceAll(seconds: fieldSeconds) }
            return
        }
        if field {
            for role in requested where !roles.contains(role) { spatialField.silence(role) }
        }
        var index = 0
        while index < roles.count {
            let pair = index + 1 < roles.count
            transformPair(roles[index], pair ? roles[index + 1] : nil)
            if field {
                outputReal.withUnsafeBufferPointer { real in
                    outputImaginary.withUnsafeBufferPointer { imaginary in
                        spatialField.capture(roles[index], pair ? roles[index + 1] : nil,
                                             real: real.baseAddress!, imaginary: imaginary.baseAddress!)
                    }
                }
            }
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
        if field { spatialField.analyse(seconds: fieldSeconds, scale: bandPowerScale) }
    }

    /// Mean square per band of the pair just transformed (`leftPower` for `a`, `rightPower` for `b`).
    private func accumulateRoleBands(_ a: Int, _ b: Int?) {
        let scale = Float(bandPowerScale)
        for (band, bins) in bandBins.enumerated() {
            guard !bins.isEmpty else { continue }
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
        let n = historyLength
        var sums = [(left: Double, right: Double, cross: Double)](repeating: (0, 0, 0), count: StereoBands.count)
        outputReal.withUnsafeBufferPointer { zr in
            outputImaginary.withUnsafeBufferPointer { zi in
                for (band, bins) in bandBins.enumerated() where !bins.isEmpty {
                    let start = bins.lowerBound, count = vDSP_Length(bins.count)
                    var left: Float = 0, right: Float = 0, crossA: Float = 0, crossB: Float = 0
                    leftPower.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + start, 1, &left, count) }
                    rightPower.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + start, 1, &right, count) }
                    vDSP_dotpr(zr.baseAddress! + start, 1, zi.baseAddress! + n - start, -1, &crossA, count)
                    vDSP_dotpr(zi.baseAddress! + start, 1, zr.baseAddress! + n - start, -1, &crossB, count)
                    // Z comes from the half-amplitude window: ½·(…) of full-amplitude Z is 2·(…) here.
                    sums[band] = (Double(left), Double(right), 2 * (Double(crossA) + Double(crossB)))
                }
            }
        }
        bandSums = sums
    }

    /// Fills `leftPower` with |A|² and `rightPower` with |B|² (zero without a second role).
    private func transformPair(_ a: Int, _ b: Int?) {
        let n = historyLength
        let tail = n - cursor
        // Oldest sample first: the ring from the cursor to the end, then from the start, windowed on the way.
        inputReal.withUnsafeMutableBufferPointer { real in
            inputImaginary.withUnsafeMutableBufferPointer { imaginary in
                history.withUnsafeBufferPointer { rings in
                    fftWindow.withUnsafeBufferPointer { w in
                        func windowed(_ ring: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
                            vDSP_vmul(ring + cursor, 1, w.baseAddress!, 1, out, 1, vDSP_Length(tail))
                            if cursor > 0 { vDSP_vmul(ring, 1, w.baseAddress! + tail, 1, out + tail, 1, vDSP_Length(cursor)) }
                        }
                        windowed(rings.baseAddress! + a * n, into: real.baseAddress!)
                        if let b {
                            windowed(rings.baseAddress! + b * n, into: imaginary.baseAddress!)
                        } else {
                            vDSP_vclr(imaginary.baseAddress!, 1, vDSP_Length(n))
                        }
                    }
                }
            }
        }
        vDSP_DFT_Execute(setup, inputReal, inputImaginary, &outputReal, &outputImaginary)
        outputReal.withUnsafeBufferPointer { zr in
            outputImaginary.withUnsafeBufferPointer { zi in
                leftPower.withUnsafeMutableBufferPointer { lp in
                    rightPower.withUnsafeMutableBufferPointer { rp in
                        let r = zr.baseAddress!, i = zi.baseAddress!
                        // Bins 1..<half, in one pass; the half-amplitude window (`fftWindow`) already supplies the ¼.
                        packed_pair_powers(r, i, UInt32(n), lp.baseAddress!, rp.baseAddress!)
                        // DC pairs with itself: A = Re Z[0], B = Im Z[0] (each halved by the window).
                        lp[0] = 4 * r[0] * r[0]
                        rp[0] = 4 * i[0] * i[0]
                    }
                }
            }
        }
    }
}
