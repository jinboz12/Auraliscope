import AudioRing
import Foundation

/// Float offsets of one published snapshot inside the C11 triple buffer (`METER_SNAPSHOT_FLOATS`).
enum SnapshotSlots {
    static let spectrum = 0
    static let peaks = 64
    static let rms = peaks + Role.count
    static let truePeaks = rms + Role.count
    static let heldPeaks = truePeaks + Role.count
    static let heldTruePeaks = heldPeaks + Role.count
    static let momentary = heldTruePeaks + Role.count
    static let shortTerm = momentary + 1
    static let integrated = momentary + 2
    static let range = momentary + 3
    static let sequence = momentary + 4
    static let stream = momentary + 5
    static let peakFrequency = momentary + 6
    static let peakLevel = momentary + 7
    static let format = momentary + 8
    static let waveSerial = momentary + 9
    static let correlation = momentary + 10
    static let spectrogramSerial = momentary + 11
    static let spectrogram = momentary + 12
    static let bandCorrelation = spectrogram + MeterSnapshot.spectrogramBandCount
    static let bandWidth = bandCorrelation + StereoBands.groups.count
    static let bandBalance = bandWidth + StereoBands.groups.count
    static let bandLevel = bandBalance + StereoBands.groups.count
    static let bandPoints = bandLevel + StereoBands.groups.count
    static let roleBandPower = bandPoints + StereoBands.scopeFloats
    static let notes = roleBandPower + StereoBands.roleFloats
    static let waveform = notes + 2 * SpectrumAnalyzer.maxNotes
    static let total = waveform + WaveformEnvelope.publishedFloats
}

/// Every analysis the DSP queue runs, from mapped PCM to one packed snapshot. Owned by one thread.
///
/// Snapshots go out at 60 Hz, one per display frame, so a level reaches the screen about 8 ms sooner on average
/// than at the former 30 Hz, and every frame has fresh data. What the meters show is unchanged:
/// - peak, RMS and true peak still cover the newest 1/30 s (the last two ticks);
/// - L/R correlation integrates L², R² and L·R with a 0.25 s time constant, weighted by energy as a hardware
///   correlation meter's integrator is, so it reads the mix rather than each tick; silence rests it and restarts
///   the average; the five `StereoBands` integrate their L/R cross spectrum the same way, once per transform;
/// - the waterfall still gains exactly 30 columns per second, each from the newest 8192-point FFT;
/// - the format detector still sees consecutive, non-overlapping 1/30 s windows at 30 Hz;
/// - loudness (M, S, I, LRA) is block-based and does not depend on the tick rate at all.
/// In Spatial monitoring the spectrum and waterfall sum every routed role instead of showing L and R.
/// Device buffers longer than a tick (a DAW at 2048 frames delivers every 43 ms) no longer publish false
/// silence between deliveries: an empty window repeats the newest audio for up to 100 ms before reading silent.
final class MeterPipeline {
    static let tickRate = 60.0
    /// Ticks per level window and per waterfall column: 1/30 s.
    static let windowTicks = 2
    /// With no audio for this many ticks (100 ms) the input reads as silence.
    static let staleTicks = 6
    /// Time constant of the L/R correlation integrator, in seconds.
    static let correlationTime = 0.25
    private static let correlationDecay = exp(-1 / (tickRate * correlationTime))

    let loudness: LoudnessAnalyzer
    let spectrum: SpectrumAnalyzer
    let waveform: WaveformEnvelope
    let splitter: StereoBandSplitter
    private var detector: FormatDetector
    private let streamID: Float
    /// Spatial monitoring: spectrum and waterfall sum every routed role; otherwise they show L and R.
    /// Set by the owner; takes effect once every routed role has a full FFT window (≤ 170 ms).
    var spatialSpectrum = false {
        didSet { spectrum.recordsSpatial = spatialSpectrum }
    }
    private var analysedSpatial = false
    /// Newest slice at `head`; older ones behind it.
    private var slices = [LevelSlice](repeating: LevelSlice(), count: MeterPipeline.staleTicks)
    private var head = 0
    private var heldPeak = [Float](repeating: 0, count: Role.count)
    private var heldTruePeak = [Float](repeating: 0, count: Role.count)
    private var bands = [Float](repeating: -120, count: MeterSnapshot.bandCount)
    private var column = [Float](repeating: -120, count: MeterSnapshot.spectrogramBandCount)
    private var dominant: (frequency: Float, level: Float) = (0, -120)
    private var windowRMS = [Float](repeating: 0, count: Role.count)
    /// Exponentially integrated L², R² and L·R sums (see `correlationTime`).
    private var correlationSums = (left: 0.0, right: 0.0, product: 0.0)
    /// The same integrator per stereo band, fed with each new transform's band sums.
    private var bandSums = [(left: Double, right: Double, cross: Double)](repeating: (0, 0, 0), count: StereoBands.count)
    /// Each role's band mean square, smoothed with the correlation time constant (see `roleBandPower`).
    private var roleBands = [Float](repeating: 0, count: StereoBands.roleFloats)
    /// Band mean square below this (−80 dBFS RMS) reads as a silent band.
    private static let bandGate = 1e-8
    private var format: ChannelFormat
    private var tick = 0
    private var sequence = 0
    private var spectrogramSerial = 0
    private var lastDetectorTime: Double?
    /// Loudest sample peak of the newest tick, for the "signal confirmed" diagnostic.
    private(set) var newestPeak: Float = 0

    init?(sampleRate: Double, activeRoles: [Bool], detector: FormatDetector, streamID: UInt32) {
        guard let spectrum = SpectrumAnalyzer(sampleRate: sampleRate, recording: activeRoles),
              let loudness = LoudnessAnalyzer(sampleRate: sampleRate, activeRoles: activeRoles),
              let splitter = StereoBandSplitter(sampleRate: sampleRate) else { return nil }
        self.splitter = splitter
        self.spectrum = spectrum
        self.loudness = loudness
        waveform = WaveformEnvelope(sampleRate: sampleRate, activeRoles: activeRoles)
        self.detector = detector
        format = detector.format
        self.streamID = Float(streamID)
    }

    func consume(_ frames: UnsafeBufferPointer<ChannelFrame>) {
        guard !frames.isEmpty else { return }
        loudness.consume(frames)
        waveform.consume(frames)
        spectrum.consume(frames)
        frames.baseAddress!.withMemoryRebound(to: Float.self, capacity: frames.count * Role.count) {
            splitter.consume($0, stride: Role.count, count: frames.count, leftOffset: Role.left, rightOffset: Role.right)
        }
    }

    private func slice(_ age: Int) -> Int { (head - age + Self.staleTicks) % Self.staleTicks }

    /// Folds the newest tick into the correlation integrator and returns its reading. A level window without
    /// signal on both sides (silence, one silent side, or no audio for 100 ms) reads `noCorrelation` and clears
    /// the integrator, so the next passage is never averaged with the last one (and a non-finite sample never
    /// outlives the window it arrived in).
    private func integrateCorrelation(windowHasSignal: Bool) -> Float {
        guard windowHasSignal else {
            correlationSums = (0, 0, 0)
            return MeterSnapshot.noCorrelation
        }
        let decay = Self.correlationDecay
        correlationSums.left = correlationSums.left * decay + slices[head].left
        correlationSums.right = correlationSums.right * decay + slices[head].right
        correlationSums.product = correlationSums.product * decay + slices[head].product
        let energy = correlationSums.left * correlationSums.right
        guard energy > 0, energy.isFinite else { return MeterSnapshot.noCorrelation }
        return Float(max(-1, min(1, correlationSums.product / energy.squareRoot())))
    }

    /// Clears the held true peaks only (the TRUE PEAK reading's reset); held sample peaks stay.
    func resetTruePeaks() {
        for role in 0..<Role.count { heldTruePeak[role] = 0 }
    }

    /// Folds the newest transform's band sums into the band integrators (`fresh`), or clears them (`nil`).
    private func integrateBands(fresh: Bool?) {
        guard let fresh else {
            bandSums = Array(repeating: (0, 0, 0), count: StereoBands.count)
            for i in roleBands.indices { roleBands[i] = 0 }
            return
        }
        guard fresh else { return }
        let decay = Self.correlationDecay
        let blend = Float(1 - decay)
        for i in roleBands.indices { roleBands[i] += (spectrum.roleBandPower[i] - roleBands[i]) * blend }
        for band in 0..<StereoBands.count {
            let new = spectrum.bandSums[band]
            // A silent band restarts its average, like the broadband integrator in silence.
            if (new.left + new.right) / 2 * spectrum.bandPowerScale < Self.bandGate {
                bandSums[band] = (0, 0, 0)
            } else {
                bandSums[band] = (bandSums[band].left * decay + new.left, bandSums[band].right * decay + new.right,
                                  bandSums[band].cross * decay + new.cross)
            }
        }
    }

    /// Writes the readings of every band group from the integrators; a group's sums are its bands' sums.
    private func writeBands(into v: UnsafeMutablePointer<Float>) {
        for (band, members) in StereoBands.groups.enumerated() {
            let sums = members.reduce((left: 0.0, right: 0.0, cross: 0.0)) {
                ($0.left + bandSums[$1].left, $0.right + bandSums[$1].right, $0.cross + bandSums[$1].cross)
            }
            let total = sums.left + sums.right
            let energy = sums.left * sums.right
            let meanSquare = total / 2 * spectrum.bandPowerScale * (1 - Self.correlationDecay)
            guard total > 0, total.isFinite, energy > 0 else {
                v[SnapshotSlots.bandCorrelation + band] = MeterSnapshot.noCorrelation
                v[SnapshotSlots.bandWidth + band] = 0
                v[SnapshotSlots.bandBalance + band] = 0
                v[SnapshotSlots.bandLevel + band] = -120
                continue
            }
            v[SnapshotSlots.bandCorrelation + band] = Float(max(-1, min(1, sums.cross / energy.squareRoot())))
            v[SnapshotSlots.bandWidth + band] = Float(max(0, min(1, (total - 2 * sums.cross) / (2 * total))))
            v[SnapshotSlots.bandBalance + band] = Float(max(-1, min(1, (sums.right - sums.left) / total)))
            v[SnapshotSlots.bandLevel + band] = Float(max(-120, 10 * log10(max(meanSquare, 1e-12))))
        }
    }

    /// Closes the current tick and writes a full snapshot (`SnapshotSlots.total` floats) to `v`.
    /// `now` is in seconds on any monotonic clock; it paces the format detector.
    func publish(into v: UnsafeMutablePointer<Float>, now: Double) {
        tick += 1
        head = (head + 1) % Self.staleTicks
        loudness.take(into: &slices[head])
        let sums = spectrum.takeStereoSums()
        slices[head].left = sums.left
        slices[head].right = sums.right
        slices[head].product = sums.product
        let fresh = slices[head].frames > 0
        newestPeak = slices[head].peak.max() ?? 0
        for role in 0..<Role.count {
            heldPeak[role] = max(heldPeak[role], slices[head].peak[role])
            heldTruePeak[role] = max(heldTruePeak[role], slices[head].truePeak[role], slices[head].peak[role])
        }

        // Level window: the newest two ticks; if they hold no audio, the newest delivery within 100 ms.
        var ages = 0..<Self.windowTicks
        var frames = ages.reduce(0) { $0 + slices[slice($1)].frames }
        if frames == 0, let age = (Self.windowTicks..<Self.staleTicks).first(where: { slices[slice($0)].frames > 0 }) {
            ages = age..<(age + 1)
            frames = slices[slice(age)].frames
        }
        let stale = frames == 0
        var left = 0.0, right = 0.0, product = 0.0
        for role in 0..<Role.count {
            var peak: Float = 0, truePeak: Float = 0, energy = 0.0
            for age in ages {
                let s = slice(age)
                peak = max(peak, slices[s].peak[role])
                truePeak = max(truePeak, slices[s].truePeak[role])
                energy += slices[s].sumSquares[role]
            }
            v[SnapshotSlots.peaks + role] = peak
            v[SnapshotSlots.rms + role] = frames > 0 ? Float(sqrt(energy / Double(frames))) : 0
            v[SnapshotSlots.truePeaks + role] = truePeak
            v[SnapshotSlots.heldPeaks + role] = heldPeak[role]
            v[SnapshotSlots.heldTruePeaks + role] = heldTruePeak[role]
        }
        for age in ages {
            left += slices[slice(age)].left
            right += slices[slice(age)].right
            product += slices[slice(age)].product
        }
        v[SnapshotSlots.correlation] = integrateCorrelation(windowHasSignal:
            SpectrumAnalyzer.correlation(left: left, right: right, product: product) != MeterSnapshot.noCorrelation)

        // Spectrum: a new transform whenever new audio arrived or the monitoring mode changed; otherwise the
        // newest one stands.
        if stale || !spectrum.ready {
            for i in bands.indices { bands[i] = -120 }
            dominant = (0, -120)
            integrateBands(fresh: nil)
        } else {
            let spatial = spatialSpectrum && spectrum.spatialReady
            let transform = fresh || spatial != analysedSpatial
            if transform {
                dominant = spectrum.refreshSpectrum(into: &bands, roles: spatial ? spectrum.spatialRoles : [Role.left, Role.right])
                analysedSpatial = spatial
            }
            integrateBands(fresh: transform)
        }
        writeBands(into: v)
        splitter.writePoints(into: v + SnapshotSlots.bandPoints, silent: stale)
        for i in 0..<StereoBands.roleFloats { v[SnapshotSlots.roleBandPower + i] = roleBands[i] }
        for i in 0..<MeterSnapshot.bandCount { v[SnapshotSlots.spectrum + i] = bands[i] }
        v[SnapshotSlots.peakFrequency] = dominant.frequency
        v[SnapshotSlots.peakLevel] = dominant.level
        if stale || !spectrum.ready {
            for i in 0..<(2 * SpectrumAnalyzer.maxNotes) { v[SnapshotSlots.notes + i] = i.isMultiple(of: 2) ? 0 : -120 }
        } else {
            spectrum.packedNotes(into: v + SnapshotSlots.notes)
        }

        // Waterfall column and format detector at 30 Hz, on strictly consecutive 1/30 s windows as before.
        if tick % Self.windowTicks == 0 {
            if stale || !spectrum.ready {
                for i in column.indices { column[i] = -120 }
            } else {
                spectrum.spectrogram(into: &column)
            }
            spectrogramSerial = spectrogramSerial % 999_999 + 1
            let strict = (0..<Self.windowTicks).reduce(0) { $0 + slices[slice($1)].frames }
            for role in 0..<Role.count {
                let energy = (0..<Self.windowTicks).reduce(0.0) { $0 + slices[slice($1)].sumSquares[role] }
                windowRMS[role] = strict > 0 ? Float(sqrt(energy / Double(strict))) : 0
            }
            let delta = Float(now - (lastDetectorTime ?? (now - 1 / 30)))
            lastDetectorTime = now
            format = detector.update(rms: windowRMS, deltaTime: delta)
        }
        for i in 0..<MeterSnapshot.spectrogramBandCount { v[SnapshotSlots.spectrogram + i] = column[i] }
        v[SnapshotSlots.spectrogramSerial] = Float(spectrogramSerial)
        v[SnapshotSlots.format] = Float(format.rawValue)

        let loudness = loudness.loudnessValues()
        v[SnapshotSlots.momentary] = loudness.momentary
        v[SnapshotSlots.shortTerm] = loudness.shortTerm
        v[SnapshotSlots.integrated] = loudness.integrated
        v[SnapshotSlots.range] = loudness.range
        // 1…999,999: zero stays reserved for "no snapshot yet".
        sequence = sequence % 999_999 + 1
        v[SnapshotSlots.sequence] = Float(sequence)
        v[SnapshotSlots.stream] = streamID
        v[SnapshotSlots.waveSerial] = Float(waveform.serial)
        waveform.write(into: v + SnapshotSlots.waveform)
    }
}
