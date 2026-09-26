import Accelerate
import AudioRing
import Foundation

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
    private let filterSetups: [OpaquePointer?]
    private let truePeak: TruePeakDetector
    private var delay = [Float](repeating: 0, count: Role.count * 6)
    private var input = [Float](repeating: 0, count: Role.count * capacity)
    private var filtered = [Float](repeating: 0, count: Role.count * capacity)
    private var peak = [Float](repeating: 0, count: Role.count)
    private var sumSquares = [Double](repeating: 0, count: Role.count)
    private var silentBatches = [Int](repeating: 2, count: Role.count)
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
        let coefficients = shelf + highPass
        var setups = [OpaquePointer?](repeating: nil, count: Role.count)
        for role in 0..<Role.count where Role.loudnessWeights[role] > 0 && activeRoles[role] {
            guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else {
                for created in setups { if let created { vDSP_biquad_DestroySetup(created) } }
                return nil
            }
            setups[role] = setup
        }
        filterSetups = setups
        truePeak = TruePeakDetector(sampleRate: sampleRate, capacity: Self.capacity)
        recent.reserveCapacity(30)
    }

    deinit {
        for setup in filterSetups { if let setup { vDSP_biquad_DestroySetup(setup) } }
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
        guard let source = frames.baseAddress, !frames.isEmpty else { return }
        var position = 0
        source.withMemoryRebound(to: Float.self, capacity: frames.count * Role.count) { samples in
            while position < frames.count {
                let count = min(Self.capacity, frames.count - position)
                input.withUnsafeMutableBufferPointer { buffer in
                    let start = buffer.baseAddress!
                    // De-interleave only the routed roles: one strided column copy each.
                    for role in activeRoles {
                        vDSP_mmov(samples + position * Role.count + role, start + role * Self.capacity,
                                  1, vDSP_Length(count), vDSP_Length(Role.count), 1)
                    }
                }
                analyze(count)
                position += count
            }
        }
    }

    private func analyze(_ count: Int) {
        input.withUnsafeBufferPointer { inputs in
            filtered.withUnsafeMutableBufferPointer { outputs in
                delay.withUnsafeMutableBufferPointer { delays in
                    let inputBase = inputs.baseAddress!
                    let outputBase = outputs.baseAddress!
                    let delayBase = delays.baseAddress!
                    for role in activeRoles {
                        let signal = inputBase + role * Self.capacity
                        var maximum: Float = 0
                        var squared: Float = 0
                        vDSP_maxmgv(signal, 1, &maximum, vDSP_Length(count))
                        if maximum > 0 {
                            vDSP_svesq(signal, 1, &squared, vDSP_Length(count))
                            truePeak.process(role: role, signal: signal, count: count, samplePeak: maximum)
                        } else {
                            truePeak.silence(role: role)
                        }
                        peak[role] = max(peak[role], maximum)
                        sumSquares[role] += Double(squared)
                        if let setup = filterSetups[role] {
                            if maximum == 0 && silentBatches[role] >= 2 {
                                vDSP_vclr(outputBase + role * Self.capacity, 1, vDSP_Length(count))
                            } else {
                                vDSP_biquad(setup, delayBase + role * 6, signal, 1,
                                            outputBase + role * Self.capacity, 1, vDSP_Length(count))
                            }
                            silentBatches[role] = maximum == 0 ? min(2, silentBatches[role] + 1) : 0
                        }
                    }
                    levelFrames += count
                    var offset = 0
                    while offset < count {
                        let length = min(segmentLength - segmentFrames, count - offset)
                        for role in activeRoles where filterSetups[role] != nil {
                            var squared: Float = 0
                            vDSP_svesq(outputBase + role * Self.capacity + offset, 1, &squared, vDSP_Length(length))
                            segmentSum += Role.loudnessWeights[role] * Double(squared)
                        }
                        segmentFrames += length
                        offset += length
                        if segmentFrames == segmentLength { completeSegment() }
                    }
                }
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

/// BS.1770 gated integration over every 400 ms block since the start, at a cost that does not grow with the
/// programme: after hours of metering the old per-block rescan (ten times a second) cost more than the rest of
/// the loudness meter. Blocks that passed the −70 LUFS gate are filed in 0.1 LU bins holding their count, their
/// energy sum and the energies themselves. The −10 LU relative gate is still applied block by block: bins
/// wholly above it add their totals, bins wholly below are skipped, and only the bins at the gate are scanned.
struct GatedIntegration {
    static let floor = -70.0
    static let resolution = 0.1
    static let bins = 1300  // −70 … +60 LUFS; louder blocks share the top bin, which is scanned if it holds the gate
    private var energies = [[Double]](repeating: [], count: bins)
    private var sums = [Double](repeating: 0, count: bins)
    private var total = 0.0
    private(set) var count = 0

    static func bin(_ energy: Double) -> Int {
        let lufs = -0.691 + 10 * log10(energy)
        guard lufs.isFinite else { return 0 }
        return max(0, min(bins - 1, Int(((lufs - floor) / resolution).rounded(.down))))
    }

    /// `energy` is a block's mean-square energy that passed the absolute gate.
    mutating func add(_ energy: Double) {
        let b = Self.bin(energy)
        energies[b].append(energy)
        sums[b] += energy
        total += energy
        count += 1
    }

    /// Mean energy of the blocks above the relative gate, in LUFS; −100 before any block.
    func integrated() -> Float {
        guard count > 0 else { return -100 }
        let absoluteMean = total / Double(count)
        let threshold = pow(10, (Double(LoudnessAnalyzer.loudness(absoluteMean)) - 10 + 0.691) / 10)
        // One bin either side of the gate absorbs any rounding in the bin arithmetic.
        let gate = Self.bin(threshold)
        let first = max(0, gate - 1), last = min(Self.bins - 1, gate + 1)
        var sum = 0.0
        var above = 0
        for b in first...last {
            for energy in energies[b] where energy > threshold {
                sum += energy
                above += 1
            }
        }
        if last + 1 < Self.bins {
            for b in (last + 1)..<Self.bins where !energies[b].isEmpty {
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
/// gate −20 LU under the gated mean, then the spread between the 10th and 95th percentiles. Values are
/// kept in a 0.1 LU histogram, so an hour of programme costs the same as a minute.
struct LoudnessRange {
    static let floor: Float = -70
    static let resolution: Float = 0.1
    static let bins = 900  // −70 … +20 LUFS
    private var histogram = [Int](repeating: 0, count: bins)
    private var count = 0
    private var energySum = 0.0
    private var dirty = false
    private var cached: Float = -1

    mutating func add(_ energy: Double) {
        let lufs = LoudnessAnalyzer.loudness(energy)
        guard lufs > Self.floor else { return }
        histogram[Self.bin(lufs)] += 1
        count += 1
        energySum += energy
        dirty = true
    }

    static func bin(_ lufs: Float) -> Int { max(0, min(bins - 1, Int((lufs - floor) / resolution))) }

    var value: Float {
        mutating get {
            guard dirty else { return cached }
            dirty = false
            let gate = LoudnessAnalyzer.loudness(energySum / Double(max(1, count))) - 20
            let first = Self.bin(gate)
            let gated = histogram[first...].reduce(0, +)
            guard gated > 0 else { cached = -1; return cached }
            // Nearest-rank percentiles over the gated values.
            func percentile(_ p: Double) -> Int {
                let rank = max(1, Int((p * Double(gated)).rounded(.up)))
                var seen = 0
                for bin in first..<Self.bins {
                    seen += histogram[bin]
                    if seen >= rank { return bin }
                }
                return Self.bins - 1
            }
            cached = Float(percentile(0.95) - percentile(0.10)) * Self.resolution
            return cached
        }
    }
}

/// ITU-R BS.1770-5 Annex 2 true-peak meter: 4× polyphase oversampling below 96 kHz, 2× below 192 kHz,
/// none above. Each phase is a 12-tap Kaiser-windowed sinc run with `vDSP_conv`; the result never reads
/// below the sample peak.
final class TruePeakDetector {
    static let tapsPerPhase = 12
    let factor: Int
    private let history = TruePeakDetector.tapsPerPhase - 1
    private let capacity: Int
    /// Per phase, reversed so `vDSP_conv` (a correlation) computes the convolution.
    private let phases: [[Float]]
    private var scratch: [Float]
    private var output: [Float]
    private var held = [Float](repeating: 0, count: Role.count)

    init(sampleRate: Double, capacity: Int) {
        factor = sampleRate < 96_000 ? 4 : (sampleRate < 192_000 ? 2 : 1)
        self.capacity = capacity
        phases = Self.design(factor: factor)
        scratch = [Float](repeating: 0, count: Role.count * (capacity + Self.tapsPerPhase))
        output = [Float](repeating: 0, count: capacity)
    }

    /// Low-pass at the original Nyquist frequency, centred on a tap so phase 0 reproduces the input samples.
    static func design(factor: Int) -> [[Float]] {
        guard factor > 1 else { return [] }
        let length = Self.tapsPerPhase * factor
        let centre = Double(length) / 2
        let beta = 7.0
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<32 {
                term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
                sum += term
            }
            return sum
        }
        let taps = (0..<length).map { n -> Double in
            let t = (Double(n) - centre) / Double(factor)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let r = (Double(n) - centre) / centre
            return sinc * bessel(beta * sqrt(max(0, 1 - r * r))) / bessel(beta)
        }
        return (0..<factor).map { phase in
            let coefficients = (0..<Self.tapsPerPhase).map { taps[$0 * factor + phase] }
            let gain = coefficients.reduce(0, +)
            return coefficients.reversed().map { Float($0 / gain) }
        }
    }

    func process(role: Int, signal: UnsafePointer<Float>, count: Int, samplePeak: Float) {
        var peak = samplePeak
        if factor > 1 {
            scratch.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress! + role * (capacity + Self.tapsPerPhase)
                (base + history).update(from: signal, count: count)
                output.withUnsafeMutableBufferPointer { out in
                    for phase in phases {
                        phase.withUnsafeBufferPointer { filter in
                            vDSP_conv(base, 1, filter.baseAddress!, 1, out.baseAddress!, 1,
                                      vDSP_Length(count), vDSP_Length(Self.tapsPerPhase))
                        }
                        var maximum: Float = 0
                        vDSP_maxmgv(out.baseAddress!, 1, &maximum, vDSP_Length(count))
                        peak = max(peak, maximum)
                    }
                }
                // Keep the newest samples as the next block's filter history.
                memmove(base, base + count, history * MemoryLayout<Float>.stride)
            }
        }
        held[role] = max(held[role], peak)
    }

    /// A silent block still has to flush the filter history, or the next block would ring on stale samples.
    func silence(role: Int) {
        guard factor > 1 else { return }
        scratch.withUnsafeMutableBufferPointer { buffer in
            vDSP_vclr(buffer.baseAddress! + role * (capacity + Self.tapsPerPhase), 1, vDSP_Length(history))
        }
    }

    func take(role: Int) -> Float {
        defer { held[role] = 0 }
        return held[role]
    }
}
