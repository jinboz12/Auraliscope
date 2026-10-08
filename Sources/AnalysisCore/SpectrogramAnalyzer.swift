import Accelerate
import AnalysisKernels
import Foundation

/// The waterfall's columns: a multi-resolution, time-aligned short-time Fourier analysis on the log-frequency rows of
/// `MeterSnapshot.spectrogram`.
///
/// One FFT length cannot serve a 20 Hz…20 kHz log axis. 8192 points resolve the bass (5.9 Hz bins at 48 kHz) but
/// average 170 ms, which smears every onset in the treble; 512 points are sharp in time but useless below 1 kHz.
/// So each row is analysed with the shortest Hann window that still resolves pitch there: an N-point window has
/// bins `sampleRate / N` wide and a main lobe ±2 bins wide, and keeping `frequency / binWidth ≥ resolvingPower`
/// (64) holds that lobe within about ±½ semitone at every row, so neighbouring notes stay apart while the treble
/// gains up to 16 times the time resolution. Resolutions run from `SpectrumAnalyzer.fftSize` down to 512 points.
///
/// - Zones: rows from the frequency where the shorter window first meets `resolvingPower` up to half an octave above
///   it blend the two zones' levels in dB, so the change of resolution never shows as a seam. Below a boundary the
///   longer window is always used: no row is ever analysed more coarsely than the rule allows.
/// - Time: every window is centred on the same instant, the middle of the longest window, so a broadband onset
///   (a kick's click and its body) lands in one column instead of reaching the treble rows first.
/// - Coverage: a column stands for 1/30 s of audio. A window shorter than twice that would sample the interval with
///   gaps, and a hi-hat could fall between columns, so short windows are repeated across the interval at 50 %
///   overlap (where Hann windows sum to a constant, so every sample counts equally) and their powers averaged (a
///   Welch estimate, which also steadies the noise floor).
/// - Calibration: levels are in dBFS for a sine (amplitude-normalised windows), the same scale as the spectrum, and
///   the display power is the sum over the analysed roles, halved, so it is referenced to a stereo pair.
/// - Rows: a row stands for its slice of frequency and shows the loudest level in it. A row wider than 1.5 bins reads
///   its loudest bin, corrected for the window's scalloping when a tone peaks inside the row; a narrower one reads
///   the tone's level where the tone lies inside it, and the main lobe's flank where it does not
///   (`SpectrumAnalyzer.interpolatedLevel`, `hannPeak`). A sine reads its level within 0.05 dB in every zone.
package final class SpectrogramAnalyzer {
    /// Frequency over bin width that every row keeps (see the type's notes).
    package static let resolvingPower = 64.0
    /// Shortest window analysed.
    package static let minimumLength = 512
    /// Rows above a zone boundary that blend the two zones, in octaves.
    package static let blendOctaves = 0.5
    /// Columns per second (`MeterPipeline`: one per two 60 Hz ticks).
    package static let columnRate = 30.0

    /// One window length and what it needs: its FFT, window, frames per column and the rows it serves.
    private final class Zone {
        let length: Int
        let setup: OpaquePointer
        /// The Hann window halved: the conjugate-symmetric split's ¼ rides on it (see `packed_pair_powers`).
        var window: [Float]
        /// dB per unit of |X|² for a sine: (2 / Σw)².
        let scale: Float
        /// Start of each frame in the analysis span (oldest sample first).
        let starts: [Int]
        var real: [Float], imaginary: [Float], outReal: [Float], outImaginary: [Float]
        var powerA: [Float], powerB: [Float]
        /// Display power per bin, then its dB.
        var power: [Float]
        var decibels: [Float]
        /// The row → bin mapping of this zone's resolution.
        var maps: [SpectrumAnalyzer.BandMap] = []
        var used = false

        init?(length: Int, span: Int, hop: Int) {
            guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else { return nil }
            self.length = length
            self.setup = setup
            var full = [Float](repeating: 0, count: length)
            vDSP_hann_window(&full, vDSP_Length(length), Int32(vDSP_HANN_DENORM))
            var sum: Float = 0
            vDSP_sve(full, 1, &sum, vDSP_Length(length))
            scale = (2 / sum) * (2 / sum)
            window = full.map { $0 * 0.5 }
            // Enough frames that their 50 %-overlapped windows tile the column's interval.
            let frames = max(1, Int((Double(hop) / Double(length / 2)).rounded(.up)))
            starts = (0..<frames).map { frame in
                let offset = ((Double(frame) + 0.5) / Double(frames) - 0.5) * Double(hop)
                return max(0, min(span - length, span / 2 + Int(offset.rounded()) - length / 2))
            }
            real = [Float](repeating: 0, count: length)
            imaginary = real
            outReal = real
            outImaginary = real
            powerA = [Float](repeating: 0, count: length / 2)
            powerB = powerA
            power = powerA
            decibels = powerA
        }

        deinit { vDSP_DFT_DestroySetup(setup) }
    }

    /// Which zone (and, in a blend, which second zone with what weight) each row reads.
    private struct RowPlan {
        let zone: Int
        let next: Int
        let blend: Float
    }

    package let sampleRate: Double
    package let rows: Int
    /// Samples the analysis looks back over: the longest window.
    private let span: Int
    private var zones: [Zone] = []
    private var plan: [RowPlan] = []

    /// `span` is the length of the history rings it reads (`SpectrumAnalyzer.fftSize`).
    package init?(sampleRate: Double, rows: Int = MeterSnapshot.spectrogramBandCount, span: Int = SpectrumAnalyzer.fftSize) {
        guard sampleRate.isFinite, sampleRate > 100, rows > 0, span >= Self.minimumLength else { return nil }
        self.sampleRate = sampleRate
        self.rows = rows
        self.span = span
        let hop = Int((sampleRate / Self.columnRate).rounded())
        var length = span
        while length >= Self.minimumLength {
            guard let zone = Zone(length: length, span: span, hop: hop) else { return nil }
            zones.append(zone)
            length /= 2
        }
        let upper = min(20_000, sampleRate / 2)
        let edges = (0...rows).map { 20 * pow(upper / 20, Double($0) / Double(rows)) }
        // Lowest frequency at which zone z's window meets the resolving power; zone 0 serves everything below.
        func floor(_ zone: Int) -> Double { zone == 0 ? 0 : Self.resolvingPower * sampleRate / Double(zones[zone].length) }
        plan = (0..<rows).map { row in
            let centre = (edges[row] * edges[row + 1]).squareRoot()
            let zone = zones.indices.last { floor($0) <= centre } ?? 0
            // Just above a boundary the previous (longer) zone fades out over `blendOctaves`.
            guard zone > 0 else { return RowPlan(zone: 0, next: -1, blend: 0) }
            let position = log2(centre / floor(zone)) / Self.blendOctaves
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

    /// Window lengths in use, longest first, and the frames each analyses per column (diagnostics and tests).
    package var resolutions: [(length: Int, frames: Int)] {
        zones.filter(\.used).map { ($0.length, $0.starts.count) }
    }

    /// The window length a row is analysed with (the shorter one in a blend).
    package func length(ofRow row: Int) -> Int { zones[plan[row].next >= 0 ? plan[row].next : plan[row].zone].length }

    /// Fills `output` (`rows` dBFS values) from the history rings: ring `role` starts at `rings + role · span` and its
    /// oldest sample is at `cursor`. `roles` are summed (and halved); an empty list writes silence. `longest`, when
    /// given, is that display power already transformed over the whole span with the same Hann window (the
    /// spectrum's, `span / 2` bins), and stands in for the longest zone's own transforms.
    package func column(rings: UnsafePointer<Float>, cursor: Int, roles: [Int], longest: UnsafePointer<Float>? = nil,
                        into output: UnsafeMutablePointer<Float>) {
        guard !roles.isEmpty else {
            output.update(repeating: -120, count: rows)
            return
        }
        for zone in zones where zone.used {
            if let longest, zone.length == span {
                zone.power.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: longest, count: span / 2) }
                decibels(zone, frames: 1, halved: true)
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
        let bins = vDSP_Length(n / 2)
        vDSP_vclr(&zone.power, 1, bins)
        for start in zone.starts {
            var index = 0
            while index < roles.count {
                let pair = index + 1 < roles.count
                windowed(rings + roles[index] * span, cursor: cursor, start: start, zone: zone, into: &zone.real)
                if pair {
                    windowed(rings + roles[index + 1] * span, cursor: cursor, start: start, zone: zone, into: &zone.imaginary)
                } else {
                    vDSP_vclr(&zone.imaginary, 1, vDSP_Length(n))
                }
                vDSP_DFT_Execute(zone.setup, zone.real, zone.imaginary, &zone.outReal, &zone.outImaginary)
                zone.outReal.withUnsafeBufferPointer { r in
                    zone.outImaginary.withUnsafeBufferPointer { i in
                        zone.powerA.withUnsafeMutableBufferPointer { a in
                            zone.powerB.withUnsafeMutableBufferPointer { b in
                                packed_pair_powers(r.baseAddress!, i.baseAddress!, UInt32(n), a.baseAddress!, b.baseAddress!)
                                a[0] = 4 * r[0] * r[0]
                                b[0] = 4 * i[0] * i[0]
                            }
                        }
                    }
                }
                vDSP_vadd(zone.power, 1, zone.powerA, 1, &zone.power, 1, bins)
                if pair { vDSP_vadd(zone.power, 1, zone.powerB, 1, &zone.power, 1, bins) }
                index += 2
            }
        }
        decibels(zone, frames: zone.starts.count, halved: false)
    }

    /// `zone.power` (summed over the roles, or already `halved`) averaged over `frames`, then to dB for a sine,
    /// floored at −120.
    private func decibels(_ zone: Zone, frames: Int, halved: Bool) {
        let n = zone.length
        let bins = vDSP_Length(n / 2)
        var factor = (halved ? 1 : 0.5) / Float(frames) * zone.scale
        var floor: Float = 1e-12
        var ceiling = Float.greatestFiniteMagnitude
        var ten: Float = 10
        var count = Int32(n / 2)
        vDSP_vsmul(zone.power, 1, &factor, &zone.decibels, 1, bins)
        vDSP_vclip(zone.decibels, 1, &floor, &ceiling, &zone.decibels, 1, bins)
        zone.decibels.withUnsafeMutableBufferPointer { d in
            vvlog10f(d.baseAddress!, d.baseAddress!, &count)
            vDSP_vsmul(d.baseAddress!, 1, &ten, d.baseAddress!, 1, bins)
        }
    }

    /// `zone.length` samples of a ring from `start` (oldest-first position in the span), times the window.
    private func windowed(_ ring: UnsafePointer<Float>, cursor: Int, start: Int, zone: Zone, into out: inout [Float]) {
        let n = zone.length
        let first = (cursor + start) % span
        let run = min(n, span - first)
        zone.window.withUnsafeBufferPointer { w in
            out.withUnsafeMutableBufferPointer { o in
                vDSP_vmul(ring + first, 1, w.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(run))
                if run < n {
                    vDSP_vmul(ring, 1, w.baseAddress! + run, 1, o.baseAddress! + run, 1, vDSP_Length(n - run))
                }
            }
        }
    }

    /// A row's level at `zone`'s resolution (see the type's notes).
    private func level(_ zone: Zone, row: Int) -> Float {
        let map = zone.maps[row]
        let d = zone.decibels
        guard map.interpolated else {
            var peak = map.first
            for bin in map.first...map.last where d[bin] > d[peak] { peak = bin }
            // A tone between two bins reads up to 1.4 dB low in either (the Hann window's scalloping). Where the
            // loudest bin is a local maximum, `SpectrumAnalyzer.hannPeak` restores the tone's level, provided the
            // tone lies inside this row; otherwise the row is only the tone's flank.
            guard peak > 0, peak + 1 < d.count, d[peak] >= d[peak - 1], d[peak] >= d[peak + 1] else { return d[peak] }
            let estimate = SpectrumAnalyzer.hannPeak(d[peak - 1], d[peak], d[peak + 1])
            let tone = Float(peak) + estimate.offset
            guard d[peak] > -120, tone >= Float(map.first) - 0.5, tone <= Float(map.last) + 0.5 else { return d[peak] }
            return estimate.level
        }
        return d.withUnsafeBufferPointer { SpectrumAnalyzer.interpolatedLevel($0, at: map.position, halfWidth: map.halfWidth) }
    }
}
