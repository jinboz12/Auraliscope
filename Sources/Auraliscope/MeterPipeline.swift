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
    static let waveform = spectrogram + MeterSnapshot.spectrogramBandCount
    static let total = waveform + WaveformEnvelope.publishedFloats
}

/// Every analysis the DSP queue runs, from mapped PCM to one packed snapshot. Owned by one thread.
///
/// Snapshots go out at 60 Hz, one per display frame, so a level reaches the screen about 8 ms sooner on average
/// than at the former 30 Hz, and every frame has fresh data. What the meters show is unchanged:
/// - peak, RMS, true peak and L/R correlation still cover the newest 1/30 s (the last two ticks);
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

    let loudness: LoudnessAnalyzer
    let spectrum: SpectrumAnalyzer
    let waveform: WaveformEnvelope
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
    private var format: ChannelFormat
    private var tick = 0
    private var sequence = 0
    private var spectrogramSerial = 0
    private var lastDetectorTime: Double?
    /// Loudest sample peak of the newest tick, for the "signal confirmed" diagnostic.
    private(set) var newestPeak: Float = 0

    init?(sampleRate: Double, activeRoles: [Bool], detector: FormatDetector, streamID: UInt32) {
        guard let spectrum = SpectrumAnalyzer(sampleRate: sampleRate, recording: activeRoles),
              let loudness = LoudnessAnalyzer(sampleRate: sampleRate, activeRoles: activeRoles) else { return nil }
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
    }

    private func slice(_ age: Int) -> Int { (head - age + Self.staleTicks) % Self.staleTicks }

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
        v[SnapshotSlots.correlation] = SpectrumAnalyzer.correlation(left: left, right: right, product: product)

        // Spectrum: a new transform whenever new audio arrived or the monitoring mode changed; otherwise the
        // newest one stands.
        if stale || !spectrum.ready {
            for i in bands.indices { bands[i] = -120 }
            dominant = (0, -120)
        } else {
            let spatial = spatialSpectrum && spectrum.spatialReady
            if fresh || spatial != analysedSpatial {
                dominant = spectrum.refreshSpectrum(into: &bands, roles: spatial ? spectrum.spatialRoles : [Role.left, Role.right])
                analysedSpatial = spatial
            }
        }
        for i in 0..<MeterSnapshot.bandCount { v[SnapshotSlots.spectrum + i] = bands[i] }
        v[SnapshotSlots.peakFrequency] = dominant.frequency
        v[SnapshotSlots.peakLevel] = dominant.level

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
