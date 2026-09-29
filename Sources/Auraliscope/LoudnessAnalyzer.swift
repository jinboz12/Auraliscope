import Accelerate
import AudioRing
import Foundation

/// Role-mapped audio de-interleaved once per DSP delivery: role r's `count` samples start at `base + r * stride`.
/// Every analysis reads contiguous channels from it instead of each gathering its own copy out of the frames.
struct PlanarBlock {
    let base: UnsafePointer<Float>
    let stride: Int
    let count: Int

    func channel(_ role: Int) -> UnsafePointer<Float> { base + role * stride }

    /// The `length` samples from `offset` on, with the same layout.
    func slice(_ offset: Int, _ length: Int) -> PlanarBlock { PlanarBlock(base: base + offset, stride: stride, count: length) }

    /// De-interleaves `roles` of `frames` into `storage` (`Role.count × capacity` floats), `capacity` frames at a
    /// time, and hands each chunk to `body`. Roles left out keep whatever `storage` held.
    static func deinterleave(_ frames: UnsafeBufferPointer<ChannelFrame>, roles: [Int], into storage: UnsafeMutablePointer<Float>,
                             capacity: Int, _ body: (PlanarBlock) -> Void) {
        guard let source = frames.baseAddress, !frames.isEmpty else { return }
        source.withMemoryRebound(to: Float.self, capacity: frames.count * Role.count) { samples in
            var position = 0
            while position < frames.count {
                let count = min(capacity, frames.count - position)
                for role in roles {
                    audio_gather_strided(samples + position * Role.count + role, UInt32(Role.count),
                                         storage + role * capacity, UInt32(count))
                }
                body(PlanarBlock(base: storage, stride: capacity, count: count))
                position += count
            }
        }
    }
}

struct MultichannelLevels {
    var peak = [Float](repeating: 0, count: Role.count)
    var rms = [Float](repeating: 0, count: Role.count)
    /// Highest oversampled (true) peak per role this tick, linear.
    var truePeak = [Float](repeating: 0, count: Role.count)
    var momentary: Float = -100
    var shortTerm: Float = -100
    var integrated: Float = -100
    /// EBU Tech 3342 loudness range in LU; negative until a short-term value has passed the gates.
    var range: Float = -1
}

// ITU-R BS.1770-5 Annex 1 and Annex 3 for every role up to 9.1.6, plus the Annex 2 true-peak meter and
// the EBU Tech 3342 loudness range. Input is mapped to roles before entering this class; roles that are
// not routed skip all work.
final class LoudnessAnalyzer {
    private static let capacity = 4096
    private let segmentLength: Int
    private let active: [Bool]
    private let activeRoles: [Int]
    /// K-weighting (shelf, then high-pass) for this rate, in double precision: single-precision coefficients and
    /// state move the high-pass poles enough to misread low frequencies at 192 kHz and above.
    private let coefficients: [Double]
    /// Routed roles with a loudness weight: the channels that are K-weighted.
    private let weightedRoles: [Int]
    private let truePeak: TruePeakDetector
    /// Filter state, four doubles per role (`k_weight_energy`).
    private let filterState = UnsafeMutablePointer<Double>.allocate(capacity: Role.count * 4)
    /// Per-call lanes for `k_weight_energy`: the filtered roles' state, input and energy.
    private let laneStates = UnsafeMutablePointer<UnsafeMutablePointer<Double>?>.allocate(capacity: Role.count)
    private let laneInputs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: Role.count)
    private let laneEnergy = UnsafeMutablePointer<Double>.allocate(capacity: Role.count)
    private var laneRoles = [Int](repeating: 0, count: Role.count)
    /// Sample peak of each role in the block being analysed.
    private var blockPeak = [Float](repeating: 0, count: Role.count)
    private var input = [Float](repeating: 0, count: Role.count * capacity)
    private var peak = [Float](repeating: 0, count: Role.count)
    private var sumSquares = [Double](repeating: 0, count: Role.count)
    private var filterSettled = [Bool](repeating: true, count: Role.count)
    private var levelFrames = 0
    private var segmentFrames = 0
    private var segmentSum = 0.0
    private var recent = [Double]()
    private var gated = GatedIntegration()
    private var momentary: Float = -100
    private var shortTerm: Float = -100
    private var integrated: Float = -100
    private var range = LoudnessRange()

    /// `activeRoles` marks routed roles; the default analyses all sixteen.
    init?(sampleRate: Double, activeRoles: [Bool] = [Bool](repeating: true, count: Role.count)) {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000, activeRoles.count == Role.count else { return nil }
        segmentLength = max(1, Int((sampleRate * 0.1).rounded()))
        active = activeRoles
        self.activeRoles = (0..<Role.count).filter { activeRoles[$0] }
        let shelf48 = [1.53512485958697, -2.69169618940638, 1.19839281085285,
                       -1.69065929318241, 0.73248077421585]
        let highPass48 = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        let shelf = Self.warp(shelf48, from: 48_000, to: sampleRate, center: 1681.974450955533)
        let highPass = Self.warp(highPass48, from: 48_000, to: sampleRate, center: 38.13547087602444)
        coefficients = shelf + highPass
        weightedRoles = self.activeRoles.filter { Role.loudnessWeights[$0] > 0 }
        filterState.initialize(repeating: 0, count: Role.count * 4)
        truePeak = TruePeakDetector(sampleRate: sampleRate, capacity: Self.capacity)
        recent.reserveCapacity(30)
    }

    deinit {
        filterState.deallocate()
        laneStates.deallocate()
        laneInputs.deallocate()
        laneEnergy.deallocate()
    }

    // Bilinear frequency scaling preserves the ITU table exactly at 48 kHz.
    // At other rates it preserves the reference filter's corresponding analog response.
    private static func warp(_ reference: [Double], from referenceRate: Double, to rate: Double,
                             center: Double) -> [Double] {
        if rate == referenceRate { return reference }
        let scale = tan(.pi * center / referenceRate) / tan(.pi * center / rate)
        func polynomial(_ c0: Double, _ c1: Double, _ c2: Double) -> (Double, Double, Double) {
            let constant = c0 + c1 + c2
            let linear = 2 * (c0 - c2) * scale
            let quadratic = (c0 - c1 + c2) * scale * scale
            return (constant + linear + quadratic, 2 * (constant - quadratic), constant - linear + quadratic)
        }
        let b = polynomial(reference[0], reference[1], reference[2])
        let a = polynomial(1, reference[3], reference[4])
        return [b.0 / a.0, b.1 / a.0, b.2 / a.0, a.1 / a.0, a.2 / a.0]
    }

    func consume(_ frames: UnsafeBufferPointer<ChannelFrame>) {
        // De-interleave only the routed roles.
        input.withUnsafeMutableBufferPointer { buffer in
            PlanarBlock.deinterleave(frames, roles: activeRoles, into: buffer.baseAddress!, capacity: Self.capacity) { analyze($0) }
        }
    }

    /// Already de-interleaved audio (see `MeterPipeline`); every routed role must be present.
    func consume(_ block: PlanarBlock) {
        var offset = 0
        while offset < block.count {
            let count = min(Self.capacity, block.count - offset)
            analyze(block.slice(offset, count))
            offset += count
        }
    }

    private func analyze(_ block: PlanarBlock) {
        let count = block.count
        for role in activeRoles {
            let signal = block.channel(role)
            var maximum: Float = 0
            var squared: Float = 0
            vDSP_maxmgv(signal, 1, &maximum, vDSP_Length(count))
            if maximum > 0 {
                vDSP_svesq(signal, 1, &squared, vDSP_Length(count))
            }
            truePeak.process(role: role, signal: signal, count: count, samplePeak: maximum)
            peak[role] = max(peak[role], maximum)
            sumSquares[role] += Double(squared)
            blockPeak[role] = maximum
            if maximum > 0 { filterSettled[role] = false }
        }
        levelFrames += count
        // A settled filter fed silence outputs silence: leave it out.
        var lanes = 0
        for role in weightedRoles where !filterSettled[role] {
            laneRoles[lanes] = role
            laneStates[lanes] = filterState + role * 4
            lanes += 1
        }
        var offset = 0
        while offset < count {
            let length = min(segmentLength - segmentFrames, count - offset)
            if lanes > 0 {
                for lane in 0..<lanes {
                    laneInputs[lane] = block.channel(laneRoles[lane]) + offset
                    laneEnergy[lane] = 0
                }
                coefficients.withUnsafeBufferPointer { c in
                    k_weight_energy(c.baseAddress!, laneStates, laneInputs, UInt32(lanes), UInt32(length), laneEnergy)
                }
                for lane in 0..<lanes { segmentSum += Role.loudnessWeights[laneRoles[lane]] * laneEnergy[lane] }
            }
            segmentFrames += length
            offset += length
            if segmentFrames == segmentLength { completeSegment() }
        }
        for lane in 0..<lanes {
            let role = laneRoles[lane]
            guard blockPeak[role] == 0 else { continue }
            // A number of buffers is not a duration: short buffers must preserve the decay too. Rest only after
            // the actual state falls below −300 dBFS, far below the loudness gate, and clear it so a later
            // signal has no stale tail.
            let state = filterState + role * 4
            if (0..<4).allSatisfy({ abs(state[$0]) < 1e-15 }) {
                state.update(repeating: 0, count: 4)
                filterSettled[role] = true
            }
        }
    }

    static func loudness(_ energy: Double) -> Float {
        guard energy > 0, energy.isFinite else { return -100 }
        return Float(-0.691 + 10 * log10(energy))
    }

    private func completeSegment() {
        recent.append(segmentSum / Double(segmentLength))
        if recent.count > 30 { recent.removeFirst() }
        segmentFrames = 0
        segmentSum = 0
        if recent.count >= 4 {
            let four = recent.suffix(4).reduce(0, +) / 4
            momentary = Self.loudness(four)
            if momentary > -70 {
                gated.add(four)
            }
            integrated = gated.integrated()
        }
        if recent.count == 30 {
            let energy = recent.reduce(0, +) / 30
            shortTerm = Self.loudness(energy)
            range.add(energy)
        }
    }

    /// A break in the audio (see `MeterPipeline`): the K-weighting filters start from rest, the unfinished 100 ms
    /// segment is dropped, and momentary and short-term start over (reading no value until 400 ms and 3 s of new
    /// audio are in), so no block spans the break. Integrated loudness and loudness range keep every block
    /// completed so far and go on adding new ones. The true-peak interpolator does not reach across the break.
    func interrupt() {
        filterState.update(repeating: 0, count: Role.count * 4)
        for role in filterSettled.indices { filterSettled[role] = true }
        segmentFrames = 0
        segmentSum = 0
        recent.removeAll(keepingCapacity: true)
        momentary = -100
        shortTerm = -100
        truePeak.interrupt()
    }

    /// Moves the per-role peak, energy and true peak gathered since the previous call into `slice` and restarts
    /// them. Roles that are not routed read zero.
    func take(into slice: inout LevelSlice) {
        slice.clear()
        slice.frames = levelFrames
        for role in activeRoles {
            slice.peak[role] = peak[role]
            slice.sumSquares[role] = sumSquares[role]
            slice.truePeak[role] = truePeak.take(role: role)
            peak[role] = 0
            sumSquares[role] = 0
        }
        levelFrames = 0
    }

    /// Momentary, short-term, integrated (LUFS) and loudness range (LU) as of the last completed 100 ms segment.
    func loudnessValues() -> (momentary: Float, shortTerm: Float, integrated: Float, range: Float) {
        (momentary, shortTerm, integrated, range.value)
    }

    func snapshot() -> MultichannelLevels {
        var slice = LevelSlice()
        take(into: &slice)
        var result = MultichannelLevels()
        if slice.frames > 0 {
            for role in activeRoles {
                result.peak[role] = slice.peak[role]
                result.rms[role] = Float(sqrt(slice.sumSquares[role] / Double(slice.frames)))
                result.truePeak[role] = slice.truePeak[role]
            }
        }
        (result.momentary, result.shortTerm, result.integrated, result.range) = loudnessValues()
        return result
    }
}

/// BS.1770 gated integration over every 400 ms block since the start. Energy bins and their actual extrema
/// skip whole ranges of history. Only a bin whose actual values straddle the relative gate needs a block scan;
/// worst-case work in that boundary bin can still grow with programme duration.
struct GatedIntegration {
    static let floor = -70.0
    static let resolution = 0.1
    static let bins = 1300  // −70 … +60 LUFS; louder blocks share the top bin, which is scanned if it holds the gate
    private var energies = [[Double]](repeating: [], count: bins)
    private var sums = [Double](repeating: 0, count: bins)
    private var minima = [Double](repeating: .infinity, count: bins)
    private var maxima = [Double](repeating: 0, count: bins)
    private var highestBin = 0
    private var total = 0.0
    private(set) var count = 0

    static func bin(_ energy: Double) -> Int {
        let lufs = -0.691 + 10 * log10(energy)
        guard lufs.isFinite else { return 0 }
        return max(0, min(bins - 1, Int(((lufs - floor) / resolution).rounded(.down))))
    }

    /// `energy` is a block's mean-square energy that passed the absolute gate.
    mutating func add(_ energy: Double) {
        guard energy > 0, energy.isFinite else { return }
        let b = Self.bin(energy)
        energies[b].append(energy)
        sums[b] += energy
        minima[b] = min(minima[b], energy)
        maxima[b] = max(maxima[b], energy)
        highestBin = max(highestBin, b)
        total += energy
        count += 1
    }

    /// Mean energy of the blocks above the relative gate, in LUFS; −100 before any block.
    func integrated() -> Float {
        guard count > 0 else { return -100 }
        let absoluteMean = total / Double(count)
        // Applying −10 LU in linear energy avoids a Float dB round trip shifting a boundary block's gate.
        let threshold = absoluteMean * 0.1
        // One bin either side of the gate absorbs any rounding in the bin arithmetic.
        let gate = Self.bin(threshold)
        let first = max(0, gate - 1), last = min(Self.bins - 1, gate + 1)
        var sum = 0.0
        var above = 0
        for b in first...last {
            if minima[b] > threshold {
                sum += sums[b]
                above += energies[b].count
            } else if maxima[b] > threshold {
                for energy in energies[b] where energy > threshold {
                    sum += energy
                    above += 1
                }
            }
        }
        if last < highestBin {
            for b in (last + 1)...highestBin where !energies[b].isEmpty {
                sum += sums[b]
                above += energies[b].count
            }
        }
        return above > 0 ? LoudnessAnalyzer.loudness(sum / Double(above)) : -100
    }
}

/// Levels of every role over one DSP tick: sample peak, energy and true peak, plus the L/R sums the phase
/// correlation needs. The pipeline keeps the last few so a published window always spans the newest 1/30 s.
struct LevelSlice {
    var frames = 0
    var peak = [Float](repeating: 0, count: Role.count)
    var sumSquares = [Double](repeating: 0, count: Role.count)
    var truePeak = [Float](repeating: 0, count: Role.count)
    var left = 0.0
    var right = 0.0
    var product = 0.0

    mutating func clear() {
        frames = 0
        for role in 0..<Role.count {
            peak[role] = 0
            sumSquares[role] = 0
            truePeak[role] = 0
        }
        left = 0
        right = 0
        product = 0
    }
}

/// EBU Tech 3342 loudness range from short-term (3 s) energies at 10 Hz: absolute gate −70 LUFS, relative
/// gate −20 LU under the gated mean, then the spread between the 10th and 95th percentiles, picked as Tech 3342
/// does from the n sorted values: index round((n − 1) · p), counting from 0. Every value is kept, sorted within
/// 0.1 LU bins: the bin counts locate the relative gate and each percentile, and a binary search finishes each
/// inside its bin, so the result is exact while a long programme costs little more than a short one.
struct LoudnessRange {
    static let floor = -70.0
    static let resolution = 0.1
    static let bins = 900  // −70 … +20 LUFS; louder values share the top bin
    private static let absoluteGate = pow(10, (floor + 0.691) / 10)
    private var energies = [[Double]](repeating: [], count: bins)
    private var count = 0
    private var energySum = 0.0
    private var dirty = false
    private var cached: Float = -1

    mutating func add(_ energy: Double) {
        guard energy > Self.absoluteGate, energy.isFinite else { return }
        let b = Self.bin(energy)
        energies[b].insert(energy, at: Self.lowerBound(energy, in: energies[b]))
        count += 1
        energySum += energy
        dirty = true
    }

    /// Index of the first value in ascending `values` that is not below `energy`.
    private static func lowerBound(_ energy: Double, in values: [Double]) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < energy { low = middle + 1 } else { high = middle }
        }
        return low
    }

    static func bin(_ energy: Double) -> Int {
        let lufs = -0.691 + 10 * log10(energy)
        guard lufs.isFinite else { return 0 }
        return max(0, min(bins - 1, Int(((lufs - floor) / resolution).rounded(.down))))
    }

    var value: Float {
        mutating get {
            guard dirty else { return cached }
            dirty = false
            // −20 LU in linear energy, as the integrated gate does, so no dB round trip moves a boundary value.
            let gate = energySum / Double(count) * 0.01
            let first = Self.bin(gate)
            let skipped = Self.lowerBound(gate, in: energies[first])
            var gated = energies[first].count - skipped
            for b in (first + 1)..<Self.bins { gated += energies[b].count }
            guard gated > 0 else { cached = -1; return cached }
            // The value at `index` (from 0) of the gated values in ascending order.
            func value(at index: Int) -> Double {
                var seen = -skipped
                for b in first..<Self.bins {
                    if index < seen + energies[b].count { return energies[b][index - seen] }
                    seen += energies[b].count
                }
                return 0
            }
            func rank(_ p: Double) -> Int { Int((Double(gated - 1) * p).rounded(.toNearestOrAwayFromZero)) }
            cached = Float(10 * log10(value(at: rank(0.95)) / value(at: rank(0.10))))
            return cached
        }
    }
}

/// ITU-R BS.1770-5 Annex 2 true-peak meter: 4× polyphase oversampling below 96 kHz and 2× above finds where the
/// crests are, and a much longer interpolator measures them. The result never reads below the sample peak.
///
/// A plain 4× meter under-reads bright content twice over:
/// - The Annex's example filter has 12 taps per phase; its interpolating phases droop by 1.2 dB at 19 kHz and
///   2.3 dB at 20 kHz (48 kHz), 3.4 dB and 6.2 dB at 44.1 kHz.
/// - A crest can fall between the 4× points: at 18 kHz (48 kHz) the pattern repeats every 8 samples, and the
///   meter reads up to 0.4 dB low whatever its filter.
/// So the 4× stage (16 Kaiser-windowed taps per phase, β = 6) only locates crests: the local maxima of its
/// magnitudes (the samples themselves included), the loudest of each 64-sample segment and the runner-up too
/// when it is within 1 dB, because a coarse grid and a short filter can rank two near-equal crests the wrong way
/// round. Around each, a 64-tap Kaiser (β = 10)
/// interpolator, flat within 0.004 dB to 20 kHz even at 44.1 kHz, evaluates the signal every 1/16 sample (1/8
/// at 2×) as far as needed to bracket the loudest value, and a parabola through it and its neighbours places the
/// crest between them. Tones from 15 to 20 kHz read within 0.0002 dB of their crest at any phase and any rate
/// from 44.1 kHz, and dense 20-tone mixtures within 0.001 dB of their analytic crest.
/// Segments are counted in absolute samples, and a point is judged once both neighbours are known, so the
/// reading does not depend on how the audio is split into buffers.
final class TruePeakDetector {
    /// Taps per phase of the 4× (or 2×) stage that chooses candidates.
    static let tapsPerPhase = 16
    static let coarseBeta = 6.0
    /// Taps per fine step of the interpolator that measures them.
    static let fineTaps = 64
    static let fineBeta = 10.0
    /// Fine steps per coarse step.
    static let refinement = 4
    /// Samples per refinement segment.
    static let segmentLength = 64
    /// A segment's second-loudest coarse crest is refined too when it is within this many dB of the loudest.
    static let runnerUp = 1.0
    let factor: Int
    /// Input kept from one block to the next: the fine window and one sample either side, less one.
    private let history = TruePeakDetector.fineTaps + 1
    private let capacity: Int
    /// The interpolating phases, each reversed so `vDSP_conv` (a correlation) computes the convolution. Phase 0
    /// passes the input through (see `design`), and its peak is the sample peak the caller passes in, so it is
    /// not run: a quarter of the work at 4×, half at 2×.
    private let phases: [[Float]]
    private var scratch: [Float]
    private var output: [Float]
    private var held = [Float](repeating: 0, count: Role.count)
    /// Samples of FIR history still to drain when a role becomes digitally silent.
    private var pending = [Int](repeating: 0, count: Role.count)
    /// Samples received per role, silent ones included: the clock the segments are counted on.
    private var received = [Int](repeating: 0, count: Role.count)
    /// Samples still to go into the filter window, unmeasured, after a break (see `interrupt`).
    private var priming = [Int](repeating: 0, count: Role.count)
    /// Each role's refinement state (see `true_peak_scan`).
    private var segments = [TruePeakSegment](repeating: TruePeakSegment(), count: Role.count)
    private var kernel: TruePeakKernel

    init(sampleRate: Double, capacity: Int) {
        factor = sampleRate < 96_000 ? 4 : 2
        self.capacity = capacity
        phases = Array(Self.design(factor: factor).dropFirst())
        let steps = factor * Self.refinement
        let fine = UnsafeMutablePointer<Float>.allocate(capacity: steps * Self.fineTaps)
        fine.initialize(from: Self.design(factor: steps, taps: Self.fineTaps, beta: Self.fineBeta).flatMap { $0 },
                        count: steps * Self.fineTaps)
        kernel = TruePeakKernel(fine: fine, taps: UInt32(Self.fineTaps), factor: UInt32(factor),
                                refinement: UInt32(Self.refinement), segment_length: UInt32(Self.segmentLength),
                                runner_up: Float(pow(10, -Self.runnerUp / 20)))
        scratch = [Float](repeating: 0, count: Role.count * (capacity + Self.fineTaps + 2))
        output = [Float](repeating: 0, count: factor * capacity)
        for role in 0..<Role.count { segments[role].segment = -1 }
    }

    deinit { UnsafeMutablePointer(mutating: kernel.fine)?.deallocate() }

    /// Low-pass at the original Nyquist frequency, centred on a tap so phase 0 reproduces the input samples:
    /// `factor` phases of `taps` coefficients each, reversed, every phase scaled to unity DC gain.
    static func design(factor: Int, taps: Int = tapsPerPhase, beta: Double = coarseBeta) -> [[Float]] {
        guard factor > 1 else { return [] }
        let length = taps * factor
        let centre = Double(length) / 2
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<48 {
                term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
                sum += term
            }
            return sum
        }
        let prototype = (0..<length).map { n -> Double in
            let t = (Double(n) - centre) / Double(factor)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let r = (Double(n) - centre) / centre
            return sinc * bessel(beta * sqrt(max(0, 1 - r * r))) / bessel(beta)
        }
        return (0..<factor).map { phase in
            let coefficients = (0..<taps).map { prototype[$0 * factor + phase] }
            let gain = coefficients.reduce(0, +)
            return coefficients.reversed().map { Float($0 / gain) }
        }
    }

    /// A break in the audio. Interpolating across it would join two unrelated signals, and padding either side
    /// with silence would invent an overshoot at a cut that never reached a converter, so neither is measured:
    /// what was found before the break is refined now; the last half window before it, whose interpolation needs
    /// samples that never come, is left out; and the first window after it only refills the filter. About 2 ms
    /// around each break is measured by sample peak alone.
    func interrupt() {
        for role in 0..<Role.count {
            true_peak_finish(&segments[role], &kernel, -1, &held[role])
            pending[role] = 0
            priming[role] = history
        }
    }

    func process(role: Int, signal: UnsafePointer<Float>, count: Int, samplePeak: Float) {
        var signal = signal, count = count
        if priming[role] > 0 {
            // After a break: these samples fill the filter window and are not measured themselves.
            let fill = min(count, priming[role])
            scratch.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress! + role * (capacity + Self.fineTaps + 2)
                memmove(base, base + fill, (history - fill) * MemoryLayout<Float>.stride)
                (base + history - fill).update(from: signal, count: fill)
            }
            priming[role] -= fill
            received[role] += fill
            signal += fill
            count -= fill
            held[role] = max(held[role], samplePeak)
            guard count > 0 else { return }
        }
        var peak = samplePeak
        // A burst can reach its interpolated maximum after its last nonzero input sample. Process the tail,
        // including across several short silent buffers, before taking the settled-silence fast path.
        let work = samplePeak > 0 ? count : min(count, pending[role])
        let start = received[role]
        received[role] += count
        if work > 0 {
            scratch.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress! + role * (capacity + Self.fineTaps + 2)
                (base + history).update(from: signal, count: work)
                output.withUnsafeMutableBufferPointer { out in
                    // Centred in the fine window: output i interpolates the same point as fine window base + 1 + i.
                    let coarse = base + 1 + (Self.fineTaps - Self.tapsPerPhase) / 2
                    for (index, phase) in phases.enumerated() {
                        phase.withUnsafeBufferPointer { filter in
                            vDSP_conv(coarse, 1, filter.baseAddress!, 1, out.baseAddress! + index * capacity, 1,
                                      vDSP_Length(work), vDSP_Length(Self.tapsPerPhase))
                        }
                    }
                    // The loudest phase at each point, the sample itself (phase 0) included: without it the
                    // coarse grid has a gap around every sample (a whole sample at 2×), and a crest there looks
                    // too quiet to rank. Its magnitude only; which phase it was is found per candidate.
                    let loudest = out.baseAddress! + phases.count * capacity
                    vDSP_vabs(base + Self.fineTaps / 2, 1, loudest, 1, vDSP_Length(work))
                    for index in phases.indices {
                        vDSP_vmaxmg(out.baseAddress! + index * capacity, 1, loudest, 1, loudest, 1, vDSP_Length(work))
                    }
                    // Output i belongs to the segment of sample start + i (a fixed delay behind the point it
                    // interpolates, the same for every split).
                    true_peak_scan(&segments[role], &kernel, base, out.baseAddress!, UInt32(capacity), loudest, UInt32(work), Int64(start), &peak)
                }
                // Keep the newest samples as the next block's filter history.
                memmove(base, base + work, history * MemoryLayout<Float>.stride)
            }
            pending[role] = samplePeak > 0 ? history : max(0, pending[role] - work)
            // Drained into silence: nothing louder can join this segment.
            if pending[role] == 0 { true_peak_finish(&segments[role], &kernel, -1, &peak) }
        }
        held[role] = max(held[role], peak)
    }

    func take(role: Int) -> Float {
        defer { held[role] = 0 }
        return held[role]
    }
}
