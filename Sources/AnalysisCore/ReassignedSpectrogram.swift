import Accelerate
import Foundation

/// How the waterfall's columns are analysed: `SpectrogramAnalyzer` (Classic) or `ReassignedSpectrogram` (Enhanced).
/// Sent by the display in SUBSCRIBE and echoed with every RESULT's columns (see PROTOCOL.md).
package enum SpectrogramMode: UInt32 {
    case classic = 0
    case enhanced = 1
}

/// The waterfall's Enhanced analysis: a reassigned spectrogram on the same rows and columns as `SpectrogramAnalyzer`.
///
/// A short-time Fourier transform spreads every component over its window: a tone over the main lobe's bins, an onset
/// over the window's length. Reassignment (Kodera, Gendrin and de Villedary; Auger and Flandrin) moves each bin's
/// energy to the centre of gravity of the component that produced it, read from the phase: two more transforms of
/// the same samples, with the window weighted by time and with its derivative, give each bin's true frequency and time.
/// A tone's main lobe collapses onto its frequency, a click's energy onto its instant, and noise, having no centre to
/// converge on, scatters into fine grain. Visu and other analysers call this an "enhanced" or "reassigned" view.
///
/// - Windows: Hann, whose derivative is smooth. Each zone serves the rows where its main lobe (±2 bins) stays within
///   1/`resolvingPower` of the frequency, a looser rule than Classic's because reassignment, not the bin width,
///   gives the precision: at 48 kHz 8192 points below 375 Hz, then 4096, 2048, 1024 and 512 from 3 kHz. A zone keeps
///   only the energy reassigned into its own rows, so zones never count a component twice.
/// - Time: frames lie on a lattice `hop / frames` apart, less than half a window, so the squared windows sum to a
///   constant and every instant weighs the same. A column keeps the energy reassigned into its own 1/30 s, so it also analyses the frames up to
///   half a window either side whose energy may land there (as far as the analysis span allows). Every column is
///   computed from the history alone: the same delay as Classic, no state between columns. The longest zone, a
///   single window as long as the span, is reassigned in frequency only (see `Zone.timed`).
/// - Calibration: a stationary sine reads its level in dBFS (each frame's main-lobe energy, normalised by the energy
///   of the window and the frames per column). Broadband sound reads the power in each row's slice of frequency:
///   rows are equally wide in log frequency, so pink noise reads level and the zones join without a step.
package final class ReassignedSpectrogram {
    /// Frequency over main-lobe half-width that every row keeps (see the type's notes).
    package static let resolvingPower = 16.0
    /// The shortest zone, as a fraction of the span (512 points at 48 kHz).
    package static let zoneCount = 5
    /// Bins beyond a zone's rows that are still analysed: a component's lobe can reach in from there.
    static let marginBins = 3
    /// Weakest bin, as display power, worth reassigning (−130 dBFS).
    static let floorPower: Float = 1e-13

    /// One window length: its transform, windows, frame lattice and the slice of frequency it serves.
    private final class Zone {
        let length: Int
        let setup: OpaquePointer
        /// Frequencies whose energy this zone keeps, Hz.
        let low: Float, high: Float
        let firstBin: Int, lastBin: Int
        /// Each frame's first sample (oldest-first span position) and its centre's offset from the column's instant.
        let starts: [Int]
        let offsets: [Float]
        /// Display power per unit of |X|²: 4 / (frames per column · N · Σh²).
        let scale: Float
        /// Whether energy is kept only where it lands in the column's own interval. A window as long as the span has
        /// room for a single frame, with no neighbours to share an instant's energy with: it keeps all of it, each
        /// bin moved in frequency only (the bass, where a column is shorter than any window that resolves it).
        let timed: Bool
        private let block: UnsafeMutablePointer<Float>
        /// h, t·h (samples from the centre) and dh/dt (per sample).
        let window, timeWindow, slopeWindow: UnsafeMutablePointer<Float>
        let inReal, inImaginary, outReal, outImaginary: UnsafeMutablePointer<Float>
        let slopeReal, slopeImaginary, slopeOutReal, slopeOutImaginary: UnsafeMutablePointer<Float>

        init?(length: Int, span: Int, hop: Int, sampleRate: Double, low: Double, high: Double) {
            guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else { return nil }
            self.length = length
            self.setup = setup
            self.low = Float(low)
            self.high = Float(high)
            let binWidth = sampleRate / Double(length)
            firstBin = max(1, Int(low / binWidth) - ReassignedSpectrogram.marginBins)
            lastBin = min(length / 2 - 1, Int((min(high, sampleRate / 2) / binWidth).rounded(.up)) + ReassignedSpectrogram.marginBins)
            block = .allocate(capacity: 11 * length)
            block.initialize(repeating: 0, count: 11 * length)
            window = block
            timeWindow = block + length
            slopeWindow = block + 2 * length
            inReal = block + 3 * length
            inImaginary = block + 4 * length
            outReal = block + 5 * length
            outImaginary = block + 6 * length
            slopeReal = block + 7 * length
            slopeImaginary = block + 8 * length
            slopeOutReal = block + 9 * length
            slopeOutImaginary = block + 10 * length
            var energy: Float = 0
            let n = Float(length)
            for i in 0..<length {
                let phase = 2 * Float.pi * Float(i) / n
                window[i] = 0.5 - 0.5 * cos(phase)
                timeWindow[i] = (Float(i) - n / 2) * window[i]
                slopeWindow[i] = Float.pi / n * sin(phase)
                energy += window[i] * window[i]
            }
            // The lattice: the fewest frames per column that keep neighbouring windows less than half a window apart,
            // where the squared Hann windows add to a constant (their spectrum ends at 2 / N), so every instant weighs
            // the same; then every frame within half a window of the column's interval that fits in the span.
            let frames = 2 * hop / length + 1
            let spacing = Double(hop) / Double(frames)
            let reach = Int((Double(length) / 2 / spacing).rounded(.up))
            var starts: [Int] = [], offsets: [Float] = []
            for j in -reach..<(frames + reach) {
                let offset = ((Double(j) + 0.5) / Double(frames) - 0.5) * Double(hop)
                let start = span / 2 + Int(offset.rounded()) - length / 2
                guard start >= 0, start + length <= span else { continue }
                starts.append(start)
                offsets.append(Float(start + length / 2 - span / 2))
            }
            // A window as long as the span has room for one frame only, centred on the column.
            timed = starts.count > 1
            self.starts = starts
            self.offsets = offsets
            scale = 4 / (Float(frames) * n * energy)
        }

        deinit {
            vDSP_DFT_DestroySetup(setup)
            block.deallocate()
        }
    }

    package let sampleRate: Double
    package let rows: Int
    private let span: Int
    private let hop: Int
    private var zones: [Zone] = []
    /// Row position per unit of ln(f / 20 Hz).
    private let rowScale: Float
    private var energy: [Float]

    package init?(sampleRate: Double, rows: Int = MeterSnapshot.spectrogramBandCount, span: Int = SpectrumAnalyzer.fftSize) {
        guard sampleRate.isFinite, sampleRate > 100, rows > 0, span >= 1 << Self.zoneCount else { return nil }
        self.sampleRate = sampleRate
        self.rows = rows
        self.span = span
        hop = Int((sampleRate / SpectrogramAnalyzer.columnRate).rounded())
        let upper = min(20_000, sampleRate / 2)
        rowScale = Float(Double(rows) / log(upper / 20))
        energy = [Float](repeating: 0, count: rows)
        let lengths = (0..<Self.zoneCount).map { span >> $0 }
        // A zone serves from where its main lobe (±2 bins) meets the rule; the longest from the bottom of the axis.
        let floors = lengths.enumerated().map { index, length in index == 0 ? 0 : 2 * Self.resolvingPower * sampleRate / Double(length) }
        for (index, length) in lengths.enumerated() {
            let high = index + 1 < lengths.count ? floors[index + 1] : sampleRate / 2
            guard let zone = Zone(length: length, span: span, hop: hop, sampleRate: sampleRate, low: floors[index], high: high) else { return nil }
            zones.append(zone)
        }
    }

    /// Window lengths, frames analysed per column and the lowest frequency each serves (diagnostics and tests).
    package var resolutions: [(length: Int, frames: Int, low: Double)] {
        zones.map { ($0.length, $0.starts.count, Double($0.low)) }
    }

    /// Fills `output` (`rows` dBFS values) from the history rings, as `SpectrogramAnalyzer.column` does: ring `role`
    /// starts at `rings + role · span`, its oldest sample at `cursor`; `roles` are summed and halved.
    package func column(rings: UnsafePointer<Float>, cursor: Int, roles: [Int], into output: UnsafeMutablePointer<Float>) {
        guard !roles.isEmpty else {
            output.update(repeating: -120, count: rows)
            return
        }
        energy.withUnsafeMutableBufferPointer { energy in
            energy.update(repeating: 0)
            for zone in zones {
                for (start, offset) in zip(zone.starts, zone.offsets) {
                    var index = 0
                    while index < roles.count {
                        let second = index + 1 < roles.count ? roles[index + 1] : nil
                        transform(zone, rings: rings, cursor: cursor, start: start, first: roles[index], second: second)
                        deposit(zone, offset: offset, slopeOfSecond: false, into: energy.baseAddress!)
                        if second != nil {
                            // The second role's own window and time-window transform, into the first's buffers.
                            windowed(rings + second! * span, cursor: cursor, start: start, zone: zone)
                            deposit(zone, offset: offset, slopeOfSecond: true, into: energy.baseAddress!)
                        }
                        index += 2
                    }
                }
            }
            for row in 0..<rows {
                output[row] = energy[row] > 0 ? max(-120, 10 * log10(0.5 * energy[row])) : -120
            }
        }
    }

    /// One frame of up to two roles: the first's transform with h (real part) and t·h (imaginary part) in `out`, and
    /// both roles' transforms with dh/dt, the first's in the real part, the second's in the imaginary part, in
    /// `slopeOut`.
    private func transform(_ zone: Zone, rings: UnsafePointer<Float>, cursor: Int, start: Int, first: Int, second: Int?) {
        let n = vDSP_Length(zone.length)
        copy(rings + first * span, cursor: cursor, start: start, count: zone.length, into: zone.slopeReal)
        if let second {
            copy(rings + second * span, cursor: cursor, start: start, count: zone.length, into: zone.slopeImaginary)
        } else {
            vDSP_vclr(zone.slopeImaginary, 1, n)
        }
        // The first role's samples, still unweighted, for h and t·h.
        vDSP_vmul(zone.slopeReal, 1, zone.window, 1, zone.inReal, 1, n)
        vDSP_vmul(zone.slopeReal, 1, zone.timeWindow, 1, zone.inImaginary, 1, n)
        vDSP_vmul(zone.slopeReal, 1, zone.slopeWindow, 1, zone.slopeReal, 1, n)
        vDSP_vmul(zone.slopeImaginary, 1, zone.slopeWindow, 1, zone.slopeImaginary, 1, n)
        vDSP_DFT_Execute(zone.setup, zone.inReal, zone.inImaginary, zone.outReal, zone.outImaginary)
        vDSP_DFT_Execute(zone.setup, zone.slopeReal, zone.slopeImaginary, zone.slopeOutReal, zone.slopeOutImaginary)
    }

    /// The second role's h and t·h transform into `out` (its dh/dt transform is already in `slopeOut`).
    private func windowed(_ ring: UnsafePointer<Float>, cursor: Int, start: Int, zone: Zone) {
        let n = vDSP_Length(zone.length)
        copy(ring, cursor: cursor, start: start, count: zone.length, into: zone.slopeReal)
        vDSP_vmul(zone.slopeReal, 1, zone.window, 1, zone.inReal, 1, n)
        vDSP_vmul(zone.slopeReal, 1, zone.timeWindow, 1, zone.inImaginary, 1, n)
        vDSP_DFT_Execute(zone.setup, zone.inReal, zone.inImaginary, zone.outReal, zone.outImaginary)
    }

    /// Reassigns the bins of one role's frame and adds the energy that lands in this column and this zone's slice of
    /// frequency to its rows. The transforms pack two real signals each (Z = A + iB), separated per bin by
    /// A[k] = (Z[k] + Z*[N−k]) / 2 and B[k] = (Z[k] − Z*[N−k]) / 2i.
    private func deposit(_ zone: Zone, offset: Float, slopeOfSecond: Bool, into energy: UnsafeMutablePointer<Float>) {
        let n = zone.length
        let binHz = Float(sampleRate) / Float(n)
        let toBins = Float(n) / (2 * Float.pi)
        let half = Float(hop) / 2
        let lastRow = rows - 1
        for k in zone.firstBin...zone.lastBin {
            let a = zone.outReal[k], b = zone.outImaginary[k]
            let c = zone.outReal[n - k], d = zone.outImaginary[n - k]
            // h and t·h of this role.
            let xr = 0.5 * (a + c), xi = 0.5 * (b - d)
            let power = xr * xr + xi * xi
            guard power * zone.scale > Self.floorPower else { continue }
            let tr = 0.5 * (b + d), ti = 0.5 * (c - a)
            // dh/dt of this role: the real part's signal for the first role, the imaginary part's for the second.
            let p = zone.slopeOutReal[k], q = zone.slopeOutImaginary[k]
            let r = zone.slopeOutReal[n - k], s = zone.slopeOutImaginary[n - k]
            let dr = slopeOfSecond ? 0.5 * (q + s) : 0.5 * (p + r)
            let di = slopeOfSecond ? 0.5 * (r - p) : 0.5 * (q - s)
            // Time: Re(X_th · X*) / |X|², samples from the frame's centre; frequency: −Im(X_dh · X*) / |X|², radians
            // per sample from the bin.
            if zone.timed {
                let time = offset + (tr * xr + ti * xi) / power
                guard abs(time) < half else { continue }
            }
            let frequency = (Float(k) - (di * xr - dr * xi) / power * toBins) * binHz
            guard frequency >= zone.low, frequency < zone.high, frequency > 20 else { continue }
            let row = Int(log(frequency / 20) * rowScale)
            guard row <= lastRow else { continue }
            energy[row] += power * zone.scale
        }
    }

    /// `count` samples of a ring from `start` (oldest-first position in the span).
    private func copy(_ ring: UnsafePointer<Float>, cursor: Int, start: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        let first = (cursor + start) % span
        let run = min(count, span - first)
        out.update(from: ring + first, count: run)
        if run < count { (out + run).update(from: ring, count: count - run) }
    }
}
