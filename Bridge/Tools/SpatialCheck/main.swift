// SpatialCheck: Radiant's observations (the production analysis, `MeterPipeline` in Float) against an independent
// reference in double precision that keeps every bin: its own radix-2 FFT, its own periodic Hann window and Parseval
// scale, its own band bookkeeping from the definition (log-spaced edges, edge bins by their overlap), each bin at
// Σ|Xᵢ|sᵢ / Σ|Xᵢ| with the geometry's positions. Nothing of the production placement code is used by the reference.
//
// For controlled fixtures (one speaker at a time, pairs at equal and unequal gains, front/back, lateral, ear to height,
// polarity and delay, several frequencies, a moving image, diffuse noise, custom layouts below the ear plane and in
// meters, silence, other rates) it compares, frame by frame and band by band (bands within 60 dB of the frame's
// loudest): energy, centre of gravity, its direction, and the second moment (each observation's own spread included);
// and the analytic centre where the fixture has one. It measures the response to a step (standard and
// multi-resolution windows), and compares three reductions at a small budget against the full set of bins.
//
//   SpatialCheck [--export <dir>] [--only <fixture substring>]
//
// Exit status 0 when every target is met. Targets (SOUNDSTAGE_V2 plan): analytic centre ≤ 1e-4 (normalized), direction
// ≤ 0.1°, energy ≤ 1 %; the second moment within 1 % where it must be conserved.

import Foundation

// MARK: - Reference (double precision)

/// In-place iterative radix-2 complex FFT, forward (e^(−2πik n/N)).
func fft(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j |= bit
        if i < j { re.swapAt(i, j); im.swapAt(i, j) }
    }
    var length = 2
    while length <= n {
        let angle = -2 * Double.pi / Double(length)
        let wr = cos(angle), wi = sin(angle)
        var start = 0
        while start < n {
            var cr = 1.0, ci = 0.0
            for k in 0..<(length / 2) {
                let a = start + k, b = a + length / 2
                let tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr
                re[b] = re[a] - tr; im[b] = im[a] - ti
                re[a] += tr; im[a] += ti
                let nr = cr * wr - ci * wi
                ci = cr * wi + ci * wr
                cr = nr
            }
            start += length
        }
        length <<= 1
    }
}

typealias V3 = SIMD3<Double>
func length(_ v: V3) -> Double { (v * v).sum().squareRoot() }

/// The reference analysis of one window: every bin's per-channel amplitude, position and energy, and per band the
/// energy, centre of gravity and second moment.
struct Reference {
    let rate: Double
    let n: Int
    let window: [Double]
    let scale: Double
    /// Per band, its bins and their weights.
    let bands: [[(k: Int, w: Double)]]

    struct Bin { var band: Int; var frequency: Double; var amplitudes: [Double]; var position: V3; var energy: Double }
    struct Band { var energy = 0.0; var centre = V3.zero; var moment = 0.0 }

    init(rate: Double, length n: Int) {
        self.rate = rate
        self.n = n
        // Periodic Hann, w[i] = ½(1 − cos 2πi/N).
        window = (0..<n).map { 0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n))) }
        // Mean square per unit of one-sided |X|²: 2 / (N Σw²) (Parseval for a windowed transform).
        scale = 2 / (Double(n) * window.reduce(0) { $0 + $1 * $1 })
        let width = rate / Double(n)
        let top = min(20_000, rate / 2 * 0.999)
        let first = max(1, Int((20 / width + 0.5).rounded(.down)))
        let last = max(first, min(n / 2 - 1, Int((top / width + 0.5).rounded(.down))))
        var list: [[(Int, Double)]] = []
        for band in 0..<96 {
            let low = 20 * pow(1_000, Double(band) / 96), high = min(20 * pow(1_000, Double(band + 1) / 96), top)
            guard high > low else { list.append([]); continue }
            let x0 = low / width, x1 = high / width
            let k0 = max(first, Int((x0 + 0.5).rounded(.down))), k1 = min(last, Int((x1 + 0.5).rounded(.down)))
            guard k1 >= k0 else { list.append([]); continue }
            list.append((k0...k1).map { k in
                let overlap = max(0, min(x1, Double(k) + 0.5) - max(x0, Double(k) - 0.5))
                return (k, (k == k0 || k == k1) ? overlap : 1)
            })
        }
        bands = list
    }

    /// The window ending at sample `end` of `channels` (each channel's whole signal), with each channel's position
    /// (nil: no direction, as the LFE).
    func analyse(_ channels: [[Double]], end: Int, positions: [V3?]) -> (bins: [Bin], bands: [Band]) {
        var spectra: [(re: [Double], im: [Double])] = []
        for signal in channels {
            var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let t = end - n + i
                re[i] = t >= 0 && t < signal.count ? signal[t] * window[i] : 0
            }
            fft(&re, &im)
            spectra.append((re, im))
        }
        var bins: [Bin] = []
        var result = [Band](repeating: Band(), count: 96)
        for (band, members) in bands.enumerated() {
            var energy = 0.0, sum = V3.zero
            var placed: [(V3, Double)] = []
            for (k, w) in members {
                var amplitudes: [Double] = [], centre = V3.zero, total = 0.0, power = 0.0
                for (c, s) in spectra.enumerated() {
                    let a = (s.re[k] * s.re[k] + s.im[k] * s.im[k]).squareRoot()
                    amplitudes.append(a)
                    guard let p = positions[c] else { continue }
                    centre += p * a
                    total += a
                    power += a * a
                }
                guard total > 0 else { continue }
                let e = w * scale * power, p = centre / total
                bins.append(Bin(band: band, frequency: Double(k) * rate / Double(n), amplitudes: amplitudes, position: p, energy: e))
                placed.append((p, e))
                energy += e
                sum += p * e
            }
            guard energy > 0 else { continue }
            let c = sum / energy
            let moment = placed.reduce(0) { $0 + $1.1 * (($1.0 - c) * ($1.0 - c)).sum() } / energy
            result[band] = Band(energy: energy, centre: c, moment: moment)
        }
        return (bins, result)
    }
}

// MARK: - Production

/// One frame of the production observations: the window's end and, per band, its observations.
struct Frame {
    var end: UInt64
    var bands: [[(position: V3, energy: Double, spread: Double, frequency: Double, zone: Int)]]
    var header: [Float]
}

func produce(rate: Double, roles: [Int], geometry: SpatialGeometry, channels: [[Double]]) -> [Frame] {
    let active = (0..<Role.count).map { roles.contains($0) }
    let pipeline = MeterPipeline(sampleRate: rate, activeRoles: active, detector: FormatDetector(initial: .spatial, canDetectSpatial: true),
                                 streamID: 1)!
    pipeline.spatialSpectrum = true
    pipeline.spatialGeometry = geometry
    let frames = channels.map(\.count).min() ?? 0
    var values = [Float](repeating: 0, count: SnapshotSlots.total)
    var buffer: [Float] = []
    var position = 0, tick = 0
    var out: [Frame] = []
    var lastEnd: UInt64 = 0
    while true {
        let end = Int((Double(tick + 1) * rate / MeterPipeline.tickRate).rounded())
        guard end <= frames else { break }
        let count = end - position
        buffer = [Float](repeating: 0, count: count * roles.count)
        for i in 0..<count { for c in 0..<roles.count { buffer[i * roles.count + c] = Float(channels[c][position + i]) } }
        buffer.withUnsafeBufferPointer { pipeline.consume(interleaved: $0.baseAddress!, channels: roles.count, frames: count, roles: roles) }
        position = end
        tick += 1
        values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
        let o = SnapshotSlots.spatialObservations
        guard values[o + SpatialObservations.Header.status] == 1 else { continue }
        let windowEnd = values.withUnsafeBufferPointer { SpatialObservations.windowEnd($0.baseAddress! + o) }
        guard windowEnd != lastEnd else { continue }
        lastEnd = windowEnd
        var bands: [[(V3, Double, Double, Double, Int)]] = []
        var at = 0
        for band in 0..<96 {
            let count = Int(values[o + SpatialObservations.counts + band])
            bands.append((0..<count).map { i in
                let b = o + SpatialObservations.observation(at + i)
                return (V3(Double(values[b]), Double(values[b + 1]), Double(values[b + 2])), Double(values[b + 3]),
                        Double(values[b + 7]), Double(values[b + 4]), Int(values[b + 8]))
            })
            at += count
        }
        out.append(Frame(end: windowEnd, bands: bands, header: Array(values[o..<(o + SpatialObservations.headerFloats)])))
    }
    return out
}

func summary(_ observations: [(position: V3, energy: Double, spread: Double, frequency: Double, zone: Int)]) -> Reference.Band {
    let e = observations.reduce(0) { $0 + $1.energy }
    guard e > 0 else { return Reference.Band() }
    let c = observations.reduce(V3.zero) { $0 + $1.position * $1.energy } / e
    let m = observations.reduce(0) { $0 + $1.energy * ((($1.position - c) * ($1.position - c)).sum() + $1.spread * $1.spread) } / e
    return Reference.Band(energy: e, centre: c, moment: m)
}

// MARK: - Fixtures

let roles714 = [Role.left, Role.right, Role.center, Role.lfe, Role.leftSurround, Role.rightSurround, Role.leftRearSurround,
                Role.rightRearSurround, Role.leftTopFront, Role.rightTopFront, Role.leftTopRear, Role.rightTopRear]
let names = SpatialGeometry.roleNames

struct Noise {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) / Double(1 << 53) - 0.5) * 0.5
    }
    static func signal(_ seed: UInt64, _ count: Int) -> [Double] {
        var g = Noise(state: seed)
        return (0..<count).map { _ in g.next() }
    }
}

struct Fixture {
    var name: String
    var rate = 48_000.0
    var seconds = 1.0
    var roles = roles714
    var geometry: SpatialGeometry? = nil
    /// Each channel's signal (channel order = `roles`).
    var signal: (Int, Double) -> [[Double]]
    /// The analytic centre of every bin, where the fixture has one (a coherent pan with non-negative gains).
    var analytic: ((SpatialGeometry) -> V3)? = nil
    /// The gains' centre, reported against each band's centre of gravity where bins have no common place (delays).
    var gainCentre: ((SpatialGeometry) -> V3)? = nil
}

func position(_ g: SpatialGeometry, _ role: Int) -> V3 { g.position(role: role) ?? .zero }

/// A coherent pan: one noise on the given roles with these gains, silence elsewhere; analytic centre Σgᵢsᵢ / Σgᵢ.
func pan(_ name: String, _ gains: [Int: Double], rate: Double = 48_000, polarity: [Int: Double] = [:], delays: [Int: Int] = [:],
         geometry: SpatialGeometry? = nil, roles: [Int] = roles714) -> Fixture {
    var fixture = Fixture(name: name, rate: rate, roles: roles, geometry: geometry, signal: { count, _ in
        let source = Noise.signal(11, count)
        return roles.map { role in
            guard let g = gains[role] else { return [Double](repeating: 0, count: count) }
            let d = delays[role] ?? 0, sign = polarity[role] ?? 1
            return (0..<count).map { i in i >= d ? g * sign * source[i - d] : 0 }
        }
    }, analytic: { geometry in
        let total = gains.values.reduce(0, +)
        return gains.reduce(V3.zero) { $0 + position(geometry, $1.key) * $1.value } / total
    })
    // A delay between coherent feeds changes each bin's magnitudes within a finite window (and makes a comb of the
    // pair), so its bins have no common analytic place: the reference decides, and the gains' centre is only where
    // the band's centre of gravity lies on average (reported, not a target).
    if !delays.isEmpty {
        fixture.gainCentre = fixture.analytic
        fixture.analytic = nil
    }
    return fixture
}

func customBelow() -> SpatialGeometry {
    var p = SpatialGeometry.standardPlacements(sidesAtNinety: true)
    p[Role.leftTopRear] = SpeakerPlacement(azimuth: -135, elevation: -25)
    p[Role.rightTopRear] = SpeakerPlacement(azimuth: 135, elevation: -25)
    p[Role.left] = SpeakerPlacement(azimuth: -40, elevation: 5)
    return SpatialGeometry(placements: p, roles: roles714)
}

func customMeters() -> SpatialGeometry {
    var p = SpatialGeometry.standardPlacements(sidesAtNinety: true)
    for role in 0..<Role.count { p[role].distance = 2.5 }
    p[Role.left].distance = 1.8
    p[Role.right].distance = 3.2
    p[Role.leftTopRear] = SpeakerPlacement(azimuth: -135, elevation: -20, distance: 2.9)
    return SpatialGeometry(placements: p, mapping: .positions, roles: roles714)
}

var fixtures: [Fixture] = []
let directional = roles714.filter { $0 != Role.lfe }
for role in directional { fixtures.append(pan("one speaker \(names[role])", [role: 1])) }
fixtures += [
    pan("L R equal", [Role.left: 1, Role.right: 1]),
    pan("L R 2:1", [Role.left: 1, Role.right: 0.5]),
    pan("L R 4:1", [Role.left: 1, Role.right: 0.25]),
    pan("front back C Lrs equal", [Role.center: 1, Role.leftRearSurround: 1]),
    pan("lateral Ls Rs equal", [Role.leftSurround: 1, Role.rightSurround: 1]),
    pan("ear to height L Ltf equal", [Role.left: 1, Role.leftTopFront: 1]),
    pan("ear to height L Ltf 1:3", [Role.left: 0.25, Role.leftTopFront: 0.75]),
    pan("L R polarity inverted", [Role.left: 1, Role.right: 1], polarity: [Role.right: -1]),
    pan("L R delay 0.1 ms", [Role.left: 1, Role.right: 1], delays: [Role.right: 5]),
    pan("L R delay 1 ms", [Role.left: 1, Role.right: 1], delays: [Role.right: 48]),
    pan("L R delay 5 ms", [Role.left: 1, Role.right: 1], delays: [Role.right: 240]),
    pan("L R 2:1 at 44.1 kHz", [Role.left: 1, Role.right: 0.5], rate: 44_100),
    pan("L R 2:1 at 96 kHz", [Role.left: 1, Role.right: 0.5], rate: 96_000),
    pan("below the ear plane: Ltr Rtr at -25 deg", [Role.leftTopRear: 1, Role.rightTopRear: 0.5], geometry: customBelow()),
    pan("meters: L 1.8 m R 3.2 m", [Role.left: 1, Role.right: 1], geometry: customMeters()),
    pan("meters: L and Ltr (-20 deg, 2.9 m)", [Role.left: 1, Role.leftTopRear: 0.5], geometry: customMeters()),
]
// Several frequencies at their own places (no analytic centre per bin; the reference decides).
fixtures.append(Fixture(name: "four tones at four places", signal: { count, rate in
    func tone(_ hz: Double, _ a: Double) -> [Double] { (0..<count).map { a * sin(2 * .pi * hz * Double($0) / rate) } }
    let t300 = tone(300, 0.3), t1k = tone(1_000, 0.3), t3k = tone(3_000, 0.3), t8k = tone(8_000, 0.3)
    return roles714.map { role in
        switch role {
        case Role.left: return zip(t300, t3k).map { $0 + 0.75 * $1 }
        case Role.right: return zip(t1k, t3k).map { $0 + 0.25 * $1 }
        case Role.leftTopRear: return t8k
        default: return [Double](repeating: 0, count: count)
        }
    }
}))
fixtures.append(Fixture(name: "diffuse: independent noise on every speaker", signal: { count, _ in
    roles714.enumerated().map { c, role in role == Role.lfe ? [Double](repeating: 0, count: count) : Noise.signal(100 + UInt64(c), count) }
}))
fixtures.append(Fixture(name: "silence", signal: { count, _ in roles714.map { _ in [Double](repeating: 0, count: count) } }))

// MARK: - Run

let exportDirectory = CommandLine.arguments.firstIndex(of: "--export").flatMap { i in
    i + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
}
let only = CommandLine.arguments.firstIndex(of: "--only").flatMap { i in i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil }
if let exportDirectory { try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true) }

var failures = 0
var report: [String] = ["fixture,frames,bands,analytic error (production),analytic error (reference),centre error,direction error deg,energy error,moment error,result"]
func degrees(_ a: V3, _ b: V3) -> Double {
    let la = length(a), lb = length(b)
    guard la > 1e-9, lb > 1e-9 else { return 0 }
    return acos(max(-1, min(1, (a * b).sum() / (la * lb)))) * 180 / .pi
}
func csv(_ s: String) -> String { "\"\(s)\"" }

print(String(format: "%-44@ %6@ %6@ %10@ %10@ %10@ %9@ %9@ %9@", "fixture" as NSString, "frames" as NSString, "bands" as NSString,
             "analytic" as NSString, "ref.anal." as NSString, "centre" as NSString, "angle°" as NSString, "energy" as NSString,
             "moment" as NSString))
for fixture in fixtures where only.map({ fixture.name.contains($0) }) ?? true {
    let geometry = fixture.geometry ?? SpatialGeometry.standard(roles: fixture.roles)
    let count = Int(fixture.seconds * fixture.rate)
    let channels = fixture.signal(count, fixture.rate)
    let frames = produce(rate: fixture.rate, roles: fixture.roles, geometry: geometry, channels: channels)
    let reference = Reference(rate: fixture.rate, length: SpectrumAnalyzer.historyLength(sampleRate: fixture.rate))
    let positions: [V3?] = fixture.roles.map { geometry.position(role: $0) }
    var worst = (analytic: 0.0, referenceAnalytic: 0.0, centre: 0.0, angle: 0.0, energy: 0.0, moment: 0.0)
    var gainOffset = 0.0
    var bandsCompared = 0
    var exportObservations: [String] = []
    var exportBins: [String] = []
    // Frames once the window is full; every second one, to bound the reference's work.
    let compared = frames.filter { Int($0.end) >= reference.n }.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    for (index, frame) in compared.enumerated() {
        let analysis = reference.analyse(channels, end: Int(frame.end), positions: positions)
        let loudest = analysis.bands.map(\.energy).max() ?? 0
        for band in 0..<96 {
            let r = analysis.bands[band], p = summary(frame.bands[band])
            if loudest > 0, r.energy >= loudest * 1e-6 {
                bandsCompared += 1
                worst.energy = max(worst.energy, abs(p.energy - r.energy) / r.energy)
                worst.centre = max(worst.centre, length(p.centre - r.centre))
                if length(r.centre) > 0.05 * geometry.extent(roles: fixture.roles) { worst.angle = max(worst.angle, degrees(p.centre, r.centre)) }
                // Relative where the spread is visible (above 1 % of the layout's radius), absolute below.
                let extent = geometry.extent(roles: fixture.roles)
                worst.moment = max(worst.moment, abs(p.moment - r.moment) / max(r.moment, 1e-4 * extent * extent))
                if let centre = fixture.gainCentre?(geometry) { gainOffset = max(gainOffset, length(r.centre - centre) / extent) }
                if let analytic = fixture.analytic?(geometry) {
                    // Every observation (not only the band's centre) where the gains put it.
                    for o in frame.bands[band] where o.energy >= r.energy * 1e-3 {
                        worst.analytic = max(worst.analytic, length(o.position - analytic) / geometry.extent(roles: fixture.roles))
                    }
                    worst.referenceAnalytic = max(worst.referenceAnalytic, length(r.centre - analytic) / geometry.extent(roles: fixture.roles))
                }
            }
            if exportDirectory != nil {
                for o in frame.bands[band] {
                    exportObservations.append(String(format: "%llu,%.6f,%d,%.9g,%.9g,%.9g,%.9g,%.3f,%.9g,%d,%@", frame.end,
                                                     Double(frame.end) / fixture.rate, band, o.position.x, o.position.y, o.position.z,
                                                     o.energy, o.frequency, o.spread, o.zone, String(geometry.hash, radix: 16)))
                }
            }
        }
        if exportDirectory != nil && index < 3 {
            for bin in analysis.bins {
                exportBins.append(String(format: "%llu,%d,%.3f,%@,%.12g,%.12g,%.12g,%.12g", frame.end, bin.band, bin.frequency,
                                         bin.amplitudes.map { String(format: "%.9g", $0) }.joined(separator: ";"),
                                         bin.position.x, bin.position.y, bin.position.z, bin.energy))
            }
        }
    }
    // Targets: analytic ≤ 1e-4, direction ≤ 0.1°, energy ≤ 1 %, moment ≤ 1 % (bands within 60 dB of the loudest).
    var ok = worst.energy <= 0.01 && worst.angle <= 0.1 && worst.moment <= 0.01
    if fixture.analytic != nil { ok = ok && worst.analytic <= 1e-4 && worst.referenceAnalytic <= 1e-6 }
    if fixture.name == "silence" { ok = bandsCompared == 0 && frames.allSatisfy { $0.bands.allSatisfy(\.isEmpty) } && !frames.isEmpty }
    if !ok { failures += 1 }
    print(String(format: "%-44@ %6d %6d %10.2e %10.2e %10.2e %9.4f %9.2e %9.2e %@%@", fixture.name as NSString, compared.count, bandsCompared,
                 worst.analytic, worst.referenceAnalytic, worst.centre, worst.angle, worst.energy, worst.moment, ok ? "ok" : "FAIL",
                 fixture.gainCentre != nil ? String(format: "  (bands' centres up to %.3f from the gains' centre)", gainOffset) : ""))
    report.append([csv(fixture.name), "\(compared.count)", "\(bandsCompared)", String(format: "%.3g", worst.analytic),
                   String(format: "%.3g", worst.referenceAnalytic), String(format: "%.3g", worst.centre), String(format: "%.4f", worst.angle),
                   String(format: "%.3g", worst.energy), String(format: "%.3g", worst.moment), ok ? "ok" : "FAIL"].joined(separator: ","))
    if let exportDirectory {
        let base = fixture.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "")
        try? ("window_end,seconds,band,x,y,z,energy,frequency,spread,zone,geometry_hash\n" + exportObservations.joined(separator: "\n"))
            .write(to: exportDirectory.appendingPathComponent("\(base)-observations.csv"), atomically: true, encoding: .utf8)
        try? ("window_end,band,frequency,amplitudes_by_channel(\(fixture.roles.map { names[$0] }.joined(separator: ";"))),x,y,z,energy\n"
              + exportBins.joined(separator: "\n"))
            .write(to: exportDirectory.appendingPathComponent("\(base)-reference-bins.csv"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Multi-resolution: each band against a reference of its own zone's window

if only == nil || "multi".contains(only!) {
    print("\nMulti-resolution window (bands from 1 kHz on a quarter, from 4 kHz on an eighth of the transform), against references of each zone's window:")
    for fixture in fixtures where ["L R 2:1", "meters: L 1.8 m R 3.2 m", "diffuse: independent noise on every speaker",
                                   "below the ear plane: Ltr Rtr at -25 deg"].contains(fixture.name) {
        let base = fixture.geometry ?? SpatialGeometry.standard(roles: fixture.roles)
        let geometry = SpatialGeometry(placements: base.placements, mapping: base.mapping, detail: base.detail, window: .multiResolution,
                                       roles: fixture.roles)
        let count = Int(fixture.seconds * fixture.rate)
        let channels = fixture.signal(count, fixture.rate)
        let frames = produce(rate: fixture.rate, roles: fixture.roles, geometry: geometry, channels: channels)
        let n = SpectrumAnalyzer.historyLength(sampleRate: fixture.rate)
        let references = [n, n / 4, n / 8].map { Reference(rate: fixture.rate, length: $0) }
        let positions: [V3?] = fixture.roles.map { geometry.position(role: $0) }
        var worst = (centre: 0.0, energy: 0.0, moment: 0.0, analytic: 0.0), compared = 0
        for frame in frames.filter({ Int($0.end) >= n }).enumerated().filter({ $0.offset % 3 == 0 }).map(\.element) {
            let analyses = references.map { $0.analyse(channels, end: Int(frame.end), positions: positions).bands }
            let loudest = analyses[0].map(\.energy).max() ?? 0
            for band in 0..<96 {
                let hz = 20 * pow(1_000, (Double(band) + 0.5) / 96)
                let zone = hz >= 4_000 ? 2 : (hz >= 1_000 ? 1 : 0)
                let r = analyses[zone][band], p = summary(frame.bands[band])
                guard loudest > 0, r.energy >= loudest * 1e-6 else { continue }
                compared += 1
                let extent = geometry.extent(roles: fixture.roles)
                worst.centre = max(worst.centre, length(p.centre - r.centre))
                worst.energy = max(worst.energy, abs(p.energy - r.energy) / r.energy)
                worst.moment = max(worst.moment, abs(p.moment - r.moment) / max(r.moment, 1e-4 * extent * extent))
                if let analytic = fixture.analytic?(geometry) {
                    for o in frame.bands[band] where o.energy >= r.energy * 1e-3 {
                        worst.analytic = max(worst.analytic, length(o.position - analytic) / extent)
                    }
                }
                if frame.bands[band].contains(where: { $0.zone != zone }) { worst.centre = .infinity }
            }
        }
        let ok = worst.centre <= 1e-4 && worst.energy <= 0.01 && worst.moment <= 0.01 && worst.analytic <= 1e-4
        if !ok { failures += 1 }
        print(String(format: "  %-44@ %5d bands: centre %.2e, energy %.2e, moment %.2e, analytic %.2e %@", fixture.name as NSString, compared,
                     worst.centre, worst.energy, worst.moment, worst.analytic, ok ? "ok" : "FAIL"))
    }
}

// MARK: - Motion: a pan from L to R, and the response to a step, standard and multi-resolution windows

/// The time (seconds after `at`) at which the centre of `band`'s observations crosses x = 0 after a jump from L to R.
func crossing(_ frames: [Frame], band: Int, rate: Double, after at: Double) -> Double? {
    for frame in frames where Double(frame.end) / rate > at {
        let s = summary(frame.bands[band])
        if s.energy > 0, s.centre.x > 0 { return Double(frame.end) / rate - at }
    }
    return nil
}
if only == nil || "motion".contains(only!) {
    print("\nResponse to a step from L to R at 1.0 s (window end at which each band's centre crosses the middle):")
    let rate = 48_000.0, total = Int(rate * 2), switchAt = Int(rate)
    let noise = Noise.signal(21, total)
    let step = roles714.map { role -> [Double] in
        switch role {
        case Role.left: return (0..<total).map { $0 < switchAt ? noise[$0] : 0 }
        case Role.right: return (0..<total).map { $0 >= switchAt ? noise[$0] : 0 }
        default: return [Double](repeating: 0, count: total)
        }
    }
    func band(_ hz: Double) -> Int { Int(log(hz / 20) / log(1_000) * 96) }
    var lines: [String] = ["window,band_hz,latency_ms"]
    for window in [SpatialGeometry.Window.standard, .multiResolution] {
        let frames = produce(rate: rate, roles: roles714, geometry: SpatialGeometry.standard(roles: roles714, window: window), channels: step)
        let readings = [250.0, 2_000, 8_000].map { hz -> String in
            let latency = crossing(frames, band: band(hz), rate: rate, after: 1.0)
            lines.append("\(window == .standard ? "standard" : "multi-resolution"),\(Int(hz)),\(latency.map { String(format: "%.1f", $0 * 1000) } ?? "")")
            return String(format: "%5.0f Hz %5.1f ms", hz, (latency ?? .nan) * 1000)
        }
        print(String(format: "  %-17@ %@", (window == .standard ? "standard" : "multi-resolution") as NSString, readings.joined(separator: "   ")))
    }
    // A linear pan from L (0 s) to R (2 s): each frame's centre against the gains at the window's end and centre.
    let pan = roles714.map { role -> [Double] in
        switch role {
        case Role.left: return (0..<total).map { noise[$0] * (1 - Double($0) / Double(total)) }
        case Role.right: return (0..<total).map { noise[$0] * Double($0) / Double(total) }
        default: return [Double](repeating: 0, count: total)
        }
    }
    let g = SpatialGeometry.standard(roles: roles714)
    let l = position(g, Role.left), r = position(g, Role.right)
    print("Linear pan L → R over 2 s, 2 kHz band (x of the centre; the gains' centre at the window's end and its middle):")
    for window in [SpatialGeometry.Window.standard, .multiResolution] {
        let frames = produce(rate: rate, roles: roles714, geometry: SpatialGeometry.standard(roles: roles714, window: window), channels: pan)
        var lagSum = 0.0, lagCount = 0
        for frame in frames where Double(frame.end) / rate > 0.4 && Double(frame.end) / rate < 1.6 {
            let s = summary(frame.bands[band(2_000)])
            guard s.energy > 0 else { continue }
            // The time whose gains put the centre there: x = (gL xL + gR xR)/(gL + gR) with gR = t/2, gL = 1 − t/2.
            let t = 2 * (s.centre.x - l.x) / (r.x - l.x)
            lagSum += Double(frame.end) / rate - t
            lagCount += 1
            lines.append("pan-\(window == .standard ? "standard" : "multi"),\(String(format: "%.4f", Double(frame.end) / rate)),\(String(format: "%.6f", s.centre.x))")
        }
        print(String(format: "  %-17@ the picture lags the audio by %.1f ms on average (window end to the time its gains describe)",
                     (window == .standard ? "standard" : "multi-resolution") as NSString, lagSum / Double(max(1, lagCount)) * 1000))
    }
    if let exportDirectory {
        try? lines.joined(separator: "\n").write(to: exportDirectory.appendingPathComponent("motion.csv"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Reductions compared at a small budget

/// Build 87–97: ≤ 32 bins per band drawn in proportion to energy (one random offset), then `draws` particles drawn
/// again from those, each with light brightness/√draws (merged where the same bin was drawn).
func legacy(_ bins: [Reference.Bin], draws: Int, seed: UInt32) -> (points: [(V3, Double)], light: Double) {
    let total = bins.reduce(0) { $0 + $1.energy }
    guard total > 0 else { return ([], 0) }
    var first: [(V3, Double)] = []
    if bins.count <= 32 { first = bins.map { ($0.position, $0.energy) } } else {
        let step = total / 32
        var next = Double(seed % 1000) / 1000 * step, cumulative = 0.0, drawn = 0
        for bin in bins where drawn < 32 {
            cumulative += bin.energy
            var taken = 0
            while next < cumulative && drawn + taken < 32 { taken += 1; next += step }
            if taken > 0 { first.append((bin.position, Double(taken) * step)); drawn += taken }
        }
    }
    let firstTotal = first.reduce(0) { $0 + $1.1 }
    let step = firstTotal / Double(draws)
    var next = Double((seed &* 7) % 1000) / 1000 * step, cumulative = 0.0, index = 0
    var points: [(V3, Double)] = []
    var light = 0.0
    for _ in 0..<draws {
        while index < first.count - 1 && cumulative + first[index].1 < next { cumulative += first[index].1; index += 1 }
        points.append((first[index].0, 1.0 / Double(draws).squareRoot()))
        light += 1.0 / Double(draws).squareRoot()
        next += step
    }
    return (points, light)
}

if only == nil || "reduction".contains(only!) {
    print("\nReductions at 4 observations per band on average (diffuse noise and two separate peaks in one treble band):")
    let rate = 48_000.0, count = Int(rate)
    var lines = ["fixture,reduction,centre_error,moment_ratio,light_per_band,peak_error"]
    let peaks = roles714.map { role -> [Double] in
        let tone = (0..<count).map { 0.4 * sin(2 * .pi * 9_000 * Double($0) / rate) }
        let other = (0..<count).map { 0.4 * sin(2 * .pi * 9_400 * Double($0) / rate) }
        let hiss = Noise.signal(UInt64(role + 50), count).map { $0 * 0.02 }
        switch role {
        case Role.left: return zip(tone, hiss).map { $0 + $1 }
        case Role.rightRearSurround: return zip(other, hiss).map { $0 + $1 }
        case Role.lfe: return [Double](repeating: 0, count: count)
        default: return hiss
        }
    }
    let diffuse = roles714.enumerated().map { c, role in role == Role.lfe ? [Double](repeating: 0, count: count) : Noise.signal(200 + UInt64(c), count) }
    let g = SpatialGeometry.standard(roles: roles714, detail: 4)
    for (name, channels) in [("diffuse", diffuse), ("two peaks at 9 kHz", peaks)] {
        let frames = produce(rate: rate, roles: roles714, geometry: g, channels: channels)
        guard let frame = frames.last else { continue }
        let reference = Reference(rate: rate, length: SpectrumAnalyzer.historyLength(sampleRate: rate))
        let analysis = reference.analyse(channels, end: Int(frame.end), positions: roles714.map { g.position(role: $0) })
        var err = (build98: (centre: 0.0, moment: 0.0), legacy: (centre: 0.0, moment: 0.0))
        var light = (build98: 0.0, legacy: 0.0), bands = 0
        for band in 60..<96 where analysis.bands[band].energy > 0 {
            let r = analysis.bands[band]
            let bins = analysis.bins.filter { $0.band == band }
            let ours = summary(frame.bands[band])
            let old = legacy(bins, draws: 20, seed: UInt32(band))
            let oldE = old.points.reduce(0) { $0 + $1.1 }
            let oldC = old.points.reduce(V3.zero) { $0 + $1.0 * $1.1 } / oldE
            let oldM = old.points.reduce(0) { $0 + $1.1 * (($1.0 - oldC) * ($1.0 - oldC)).sum() } / oldE
            err.build98.centre = max(err.build98.centre, length(ours.centre - r.centre))
            err.legacy.centre = max(err.legacy.centre, length(oldC - r.centre))
            if r.moment > 1e-9 {
                err.build98.moment += ours.moment / r.moment
                err.legacy.moment += oldM / r.moment
            }
            light.build98 += 1   // every band's particles share exactly the band's light (Σ shares = 1)
            light.legacy += old.light
            bands += 1
        }
        // The two peaks: the distance from each peak's speaker to the nearest observation of the 9 kHz bands.
        var peakError = (build98: 0.0, legacy: 0.0)
        if name.hasPrefix("two") {
            func band(_ hz: Double) -> Int { Int(log(hz / 20) / log(1_000) * 96) }
            for (role, hz) in [(Role.left, 9_000.0), (Role.rightRearSurround, 9_400.0)] {
                let at = position(g, role), b = band(hz)
                let ours = frame.bands[b].map { length($0.position - at) }.min() ?? .infinity
                let old = legacy(analysis.bins.filter { $0.band == b }, draws: 20, seed: UInt32(b)).points.map { length($0.0 - at) }.min() ?? .infinity
                peakError.build98 = max(peakError.build98, ours)
                peakError.legacy = max(peakError.legacy, old)
            }
        }
        let n = Double(max(1, bands))
        print(String(format: "  %-20@ build 98: centre error %.2e, second moment %.1f%% of the bins', light %.2f per band%@",
                     name as NSString, err.build98.centre, err.build98.moment / n * 100, light.build98 / n,
                     name.hasPrefix("two") ? String(format: ", peaks within %.4f", peakError.build98) : ""))
        print(String(format: "  %-20@ build 97: centre error %.2e, second moment %.1f%% of the bins', light %.2f per band%@",
                     "" as NSString, err.legacy.centre, err.legacy.moment / n * 100, light.legacy / n,
                     name.hasPrefix("two") ? String(format: ", peaks within %.4f", peakError.legacy) : ""))
        lines.append("\(name),build98,\(err.build98.centre),\(err.build98.moment / n),\(light.build98 / n),\(peakError.build98)")
        lines.append("\(name),build97,\(err.legacy.centre),\(err.legacy.moment / n),\(light.legacy / n),\(peakError.legacy)")
    }
    if let exportDirectory {
        try? lines.joined(separator: "\n").write(to: exportDirectory.appendingPathComponent("reductions.csv"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Research: direction descriptors for amplitude pans (no listening data: descriptive comparison only)

if only == nil || "research".contains(only!) {
    print("\nDirection descriptors of a coherent amplitude pan (azimuth from the front of the pair's bisector, degrees):")
    print("  pair           gain    amplitude centroid  energy vector  |r_E|   field image 250 Hz  field image 4 kHz  Frank width")
    var lines = ["pair,gain_db,amplitude_centroid_deg,energy_vector_deg,energy_vector_length,image_250_deg,image_4k_deg,frank_width_deg"]
    let g = SpatialGeometry.standard(roles: roles714)
    for (name, a, b) in [("L R (±30°)", Role.left, Role.right), ("L Ltf (0°→45° el.)", Role.left, Role.leftTopFront),
                         ("Ls Rs (±90°)", Role.leftSurround, Role.rightSurround)] {
        let ua = position(g, a), ub = position(g, b)
        let bisector = (ua + ub) / max(1e-9, length(ua + ub))
        // The pair's own frame: angle from the bisector toward `a`, in the plane of the two speakers.
        let toward = ua - bisector * (ua * bisector).sum()
        let axis = toward / max(1e-9, length(toward))
        func angle(_ v: V3) -> Double {
            guard length(v) > 1e-9 else { return .nan }
            return atan2((v * axis).sum(), (v * bisector).sum()) * 180 / .pi
        }
        for gainDB in [0.0, -3, -6, -10, -20] {
            let ga = 1.0, gb = pow(10, gainDB / 20)
            let amplitude = (ua * ga + ub * gb) / (ga + gb)
            let energy = (ua * ga * ga + ub * gb * gb) / (ga * ga + gb * gb)
            // The field's image model (`SpatialField.image`): velocity vector below 400 Hz, energy vector above 1.2 kHz.
            var directions = [SIMD3<Float>(Float(ua.x), Float(ua.y), Float(ua.z)), SIMD3<Float>(Float(ub.x), Float(ub.y), Float(ub.z))]
            var energies: [Float] = [Float(ga * ga), Float(gb * gb)], cosines: [Float] = [1, 1], sines: [Float] = [0, 0]
            var out250 = [Float](repeating: 0, count: SpatialField.componentFloats), out4k = out250
            SpatialField.image(count: 2, directions: &directions, energies: &energies, cosines: &cosines, sines: &sines,
                               velocityWeight: SpatialField.velocityWeight(hz: 250), into: &out250)
            SpatialField.image(count: 2, directions: &directions, energies: &energies, cosines: &cosines, sines: &sines,
                               velocityWeight: SpatialField.velocityWeight(hz: 4_000), into: &out4k)
            let i250 = V3(Double(out250[1]), Double(out250[2]), Double(out250[3])), i4k = V3(Double(out4k[1]), Double(out4k[2]), Double(out4k[3]))
            let width = 186.4 * (1 - length(energy)) + 10.7
            print(String(format: "  %-18@ %5.0f dB   %10.2f          %10.2f     %.3f   %10.2f          %10.2f        %6.1f",
                         name as NSString, gainDB, angle(amplitude), angle(energy), length(energy), angle(i250), angle(i4k), width))
            lines.append(String(format: "%@,%.0f,%.3f,%.3f,%.4f,%.3f,%.3f,%.2f", name, gainDB, angle(amplitude), angle(energy), length(energy),
                                angle(i250), angle(i4k), width))
        }
    }
    // Polarity: the amplitude centroid ignores phase; the field's stability marks energy that cancels at the listener.
    var directions = [SIMD3<Float>(Float(position(g, Role.left).x), Float(position(g, Role.left).y), 0),
                      SIMD3<Float>(Float(position(g, Role.right).x), Float(position(g, Role.right).y), 0)]
    var energies: [Float] = [1, 1], cosines: [Float] = [1, -1], sines: [Float] = [0, 0]
    var out = [Float](repeating: 0, count: SpatialField.componentFloats)
    SpatialField.image(count: 2, directions: &directions, energies: &energies, cosines: &cosines, sines: &sines,
                       velocityWeight: SpatialField.velocityWeight(hz: 250), into: &out)
    print(String(format: "  L R in opposite polarity: amplitude centroid at the middle; the field's stability %.3f (cancelling), its image %.2f from the listener",
                 out[SpatialField.Component.stability], length(V3(Double(out[1]), Double(out[2]), Double(out[3])))))
    if let exportDirectory {
        try? lines.joined(separator: "\n").write(to: exportDirectory.appendingPathComponent("direction-descriptors.csv"), atomically: true, encoding: .utf8)
    }
}

if let exportDirectory {
    try? report.joined(separator: "\n").write(to: exportDirectory.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
}
print(failures == 0 ? "\nAll fixtures within their targets" : "\n\(failures) fixture(s) outside their targets")
exit(failures == 0 ? 0 : 1)
