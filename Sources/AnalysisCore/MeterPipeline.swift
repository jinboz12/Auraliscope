import AnalysisKernels
import Foundation

/// Float offsets of one published snapshot inside the C11 triple buffer (`METER_SNAPSHOT_FLOATS`).
package enum SnapshotSlots {
    package static let spectrum = 0
    package static let peaks = 64
    package static let rms = peaks + Role.count
    package static let truePeaks = rms + Role.count
    package static let heldPeaks = truePeaks + Role.count
    package static let heldTruePeaks = heldPeaks + Role.count
    package static let momentary = heldTruePeaks + Role.count
    package static let shortTerm = momentary + 1
    package static let integrated = momentary + 2
    package static let range = momentary + 3
    package static let sequence = momentary + 4
    package static let stream = momentary + 5
    package static let peakFrequency = momentary + 6
    package static let peakLevel = momentary + 7
    package static let format = momentary + 8
    package static let waveSerial = momentary + 9
    package static let correlation = momentary + 10
    package static let spectrogramSerial = momentary + 11
    package static let spectrogram = momentary + 12
    package static let bandCorrelation = spectrogram + MeterSnapshot.spectrogramBandCount
    package static let bandWidth = bandCorrelation + StereoBands.groups.count
    package static let bandBalance = bandWidth + StereoBands.groups.count
    package static let bandLevel = bandBalance + StereoBands.groups.count
    package static let bandPoints = bandLevel + StereoBands.groups.count
    package static let roleBandPower = bandPoints + StereoBands.scopeFloats
    package static let notes = roleBandPower + StereoBands.roleFloats
    package static let waveform = notes + 2 * SpectrumAnalyzer.maxNotes
    package static let breaks = waveform + WaveformEnvelope.publishedFloats
    package static let missing = breaks + 1
    package static let spectrumFine = missing + 1
    /// `SpectrogramMode` of the newest waterfall column.
    package static let spectrogramMode = spectrumFine + MeterSnapshot.fineBandCount
    /// The Immersive soundstage's spatial field (`SpatialField`), status 0 while it does not describe the audio.
    package static let spatialField = spectrogramMode + 1
    /// The same transform's bins, each where a spatial analyser places it (`SpatialPoints`), status 0 likewise.
    package static let spatialPoints = spatialField + SpatialField.floats
    /// `SignalHealthMeter`: each role's DC offset, then its infrasonic mean square, then the status (1 settled, 0.5
    /// settling, 0 not measured: a plugin before build 90).
    package static let signalHealth = spatialPoints + SpatialPoints.floats
    package static let dcOffset = signalHealth
    package static let infrasonic = signalHealth + Role.count
    package static let healthStatus = signalHealth + 2 * Role.count
    package static let total = healthStatus + 1
}

/// Every analysis the DSP queue runs, from mapped PCM to one packed snapshot. Owned by one thread.
///
/// Snapshots go out at 60 Hz, one per display frame, so a level reaches the screen about 8 ms sooner on average
/// than at the former 30 Hz, and every frame has fresh data. What the meters show is unchanged:
/// - peak, RMS and true peak still cover the newest 1/30 s (the last two ticks);
/// - L/R correlation integrates L², R² and L·R with a 0.25 s time constant, weighted by energy as a hardware
///   correlation meter's integrator is, so it reads the mix rather than each tick; silence rests it and restarts
///   the average; the five `StereoBands` integrate their L/R cross spectrum the same way, once per transform;
/// - the waterfall still gains exactly 30 columns per second, each a multi-resolution analysis of the newest audio
///   (`SpectrogramAnalyzer`: 8192-point windows in the bass down to 512 in the treble, centred on one instant);
/// - the format detector still sees consecutive, non-overlapping 1/30 s windows at 30 Hz;
/// - loudness (M, S, I, LRA) is block-based and does not depend on the tick rate at all.
/// In Spatial monitoring the spectrum and waterfall sum every routed role instead of showing L and R.
/// Device buffers longer than a tick (a DAW at 2048 frames delivers every 43 ms) no longer publish false
/// silence between deliveries: an empty window repeats the newest audio for up to 100 ms before reading silent.
///
/// A break in the audio (`interrupt`: frames lost, the source stopped delivering, a bypass or an offline render in
/// between) ends one stretch of signal and starts the next. No analysis window spans a break: the filters, the
/// 100 ms loudness segment, the momentary (400 ms) and short-term (3 s) windows, the FFT window, the true-peak
/// interpolator and the correlation integrators start again after it, and momentary and short-term read "no
/// value" until their windows refill. What is made of complete windows carries on: integrated loudness and
/// loudness range keep their blocks, the held peaks keep their maxima, the waterfall and the waveform keep their
/// history (with a notch at the break). Every break is counted in the snapshot, with the time known missing, so
/// a reading that spans breaks never passes for one continuous measurement.
package final class MeterPipeline {
    package static let tickRate = 60.0
    /// Ticks per level window and per waterfall column: 1/30 s.
    package static let windowTicks = 2
    /// With no audio for this many ticks (100 ms) the input reads as silence.
    package static let staleTicks = 6
    /// Time constant of the L/R correlation integrator, in seconds.
    package static let correlationTime = 0.25
    private static let correlationDecay = exp(-1 / (tickRate * correlationTime))

    package let loudness: LoudnessAnalyzer
    package let spectrum: SpectrumAnalyzer
    package let waveform: WaveformEnvelope
    package let splitter: StereoBandSplitter
    package let health: SignalHealthMeter
    private var detector: FormatDetector
    private let streamID: Float
    private let sampleRate: Double
    /// Breaks since the analysis started, and the seconds of audio known to be missing at them.
    package private(set) var breaks = 0
    package private(set) var missingSeconds = 0.0
    /// Spatial monitoring: spectrum and waterfall sum every routed role; otherwise they show L and R.
    /// Set by the owner; takes effect once every routed role has a full FFT window (≤ 170 ms).
    package var spatialSpectrum = false {
        didSet {
            spectrum.recordsSpatial = spatialSpectrum
            spectrum.buildsSpatialField = spatialSpectrum
        }
    }
    /// The spatial field's coherence threshold (`SpatialFieldAnalyzer.coherenceThreshold`), set by the display.
    package var spatialCoherence: Float {
        get { spectrum.spatialField.coherenceThreshold }
        set { spectrum.spatialField.coherenceThreshold = newValue }
    }
    /// Side surrounds at ±90° in the spatial field, as in the layout the display shows.
    package var spatialSidesAtNinety: Bool {
        get { spectrum.spatialField.sidesAtNinety }
        set { spectrum.spatialField.sidesAtNinety = newValue }
    }
    /// Whether the newest spectrum (and the waterfall column made from it) summed every routed role.
    package private(set) var analysedSpatial = false
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
    /// Frames de-interleaved at a time (`consume`).
    private static let planarCapacity = 4096
    private var planar = [Float](repeating: 0, count: Role.count * MeterPipeline.planarCapacity)
    private let planarRoles: [Int]
    /// Loudest sample peak of the newest tick, for the "signal confirmed" diagnostic.
    package private(set) var newestPeak: Float = 0

    package init?(sampleRate: Double, activeRoles: [Bool], detector: FormatDetector, streamID: UInt32) {
        guard let spectrum = SpectrumAnalyzer(sampleRate: sampleRate, recording: activeRoles),
              let loudness = LoudnessAnalyzer(sampleRate: sampleRate, activeRoles: activeRoles),
              let splitter = StereoBandSplitter(sampleRate: sampleRate) else { return nil }
        self.splitter = splitter
        health = SignalHealthMeter(sampleRate: sampleRate, activeRoles: activeRoles)
        self.spectrum = spectrum
        self.loudness = loudness
        waveform = WaveformEnvelope(sampleRate: sampleRate, activeRoles: activeRoles)
        self.detector = detector
        format = detector.format
        self.streamID = Float(streamID)
        self.sampleRate = sampleRate
        planarRoles = (0..<Role.count).filter { $0 == Role.left || $0 == Role.right || ($0 < activeRoles.count && activeRoles[$0]) }
    }

    package func consume(_ frames: UnsafeBufferPointer<ChannelFrame>) {
        guard !frames.isEmpty else { return }
        // One de-interleave for every analysis: the routed roles, and L and R, which the spectrum and the band
        // splitter always read (they hold silence when unrouted).
        planar.withUnsafeMutableBufferPointer { storage in
            PlanarBlock.deinterleave(frames, roles: planarRoles, into: storage.baseAddress!, capacity: Self.planarCapacity) { block in
                analyse(block)
            }
        }
    }

    /// The same analyses, fed with `frames` interleaved frames of `channels` source channels, channel c going to
    /// role `roles[c]`. Every other role the analyses read holds silence, as an unrouted role of a `ChannelFrame`
    /// does. For producers without 16-role frames (the Bridge plugins).
    package func consume(interleaved samples: UnsafePointer<Float>, channels: Int, frames: Int, roles: [Int]) {
        guard frames > 0, channels > 0, roles.count == channels else { return }
        planar.withUnsafeMutableBufferPointer { buffer in
            let storage = buffer.baseAddress!
            let capacity = Self.planarCapacity
            var position = 0
            while position < frames {
                let count = min(capacity, frames - position)
                for role in planarRoles where !roles.contains(role) {
                    (storage + role * capacity).update(repeating: 0, count: count)
                }
                for (channel, role) in roles.enumerated() where (0..<Role.count).contains(role) {
                    audio_gather_strided(samples + position * channels + channel, UInt32(channels),
                                         storage + role * capacity, UInt32(count))
                }
                analyse(PlanarBlock(base: storage, stride: capacity, count: count))
                position += count
            }
        }
    }

    private func analyse(_ block: PlanarBlock) {
        loudness.consume(block)
        waveform.consume(block)
        spectrum.consume(block)
        splitter.consume(left: block.channel(Role.left), right: block.channel(Role.right), count: block.count)
        health.consume(block)
    }

    /// A break in the audio before the next frames (see the type's notes): `lostFrames` are known to be missing
    /// and the source did not deliver for `idleMilliseconds`, where the producer knows.
    package func interrupt(lostFrames: UInt64, idleMilliseconds: UInt32) {
        loudness.interrupt()
        spectrum.interrupt()
        splitter.interrupt()
        health.interrupt()
        correlationSums = (0, 0, 0)
        integrateBands(fresh: nil)
        let missing = Double(lostFrames) / sampleRate + Double(idleMilliseconds) / 1000
        waveform.interrupt(missingFrames: Int(min(missing, 60) * sampleRate))
        breaks += 1
        missingSeconds += missing
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
    package func resetTruePeaks() {
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
            guard total > 0, total.isFinite else {
                v[SnapshotSlots.bandCorrelation + band] = MeterSnapshot.noCorrelation
                v[SnapshotSlots.bandWidth + band] = 0
                v[SnapshotSlots.bandBalance + band] = 0
                v[SnapshotSlots.bandLevel + band] = -120
                continue
            }
            // A silent side has no correlation, but the sounding side still has a level and a pan position.
            // Gate each side separately so FFT roundoff on a silent channel cannot invent a correlation.
            let scale = spectrum.bandPowerScale * (1 - Self.correlationDecay)
            let correlated = sums.left * scale >= Self.bandGate && sums.right * scale >= Self.bandGate
            v[SnapshotSlots.bandCorrelation + band] = correlated && energy > 0
                ? Float(max(-1, min(1, sums.cross / energy.squareRoot()))) : MeterSnapshot.noCorrelation
            v[SnapshotSlots.bandWidth + band] = Float(max(0, min(1, (total - 2 * sums.cross) / (2 * total))))
            v[SnapshotSlots.bandBalance + band] = Float(max(-1, min(1, (sums.right - sums.left) / total)))
            v[SnapshotSlots.bandLevel + band] = Float(max(-120, 10 * log10(max(meanSquare, 1e-12))))
        }
    }

    /// Closes the current tick and writes a full snapshot (`SnapshotSlots.total` floats) to `v`.
    /// `now` is in seconds on any monotonic clock; it paces the format detector.
    package func publish(into v: UnsafeMutablePointer<Float>, now: Double) {
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
        let fine = stale || !spectrum.ready ? nil : spectrum.fineSpectrum
        for i in 0..<MeterSnapshot.fineBandCount { v[SnapshotSlots.spectrumFine + i] = fine?[i] ?? -120 }
        // The spatial field of the newest Spatial transform; status 0 (and nothing in it) otherwise.
        let field = v + SnapshotSlots.spatialField, points = v + SnapshotSlots.spatialPoints
        if stale || !spectrum.ready || !analysedSpatial || !spectrum.spatialFieldBuilt {
            field.update(repeating: 0, count: SpatialField.floats)
            points.update(repeating: 0, count: SpatialPoints.floats)
        } else {
            field.update(from: spectrum.spatialField.fieldValues, count: SpatialField.floats)
            points.update(from: spectrum.spatialField.pointValues, count: SpatialPoints.floats)
        }
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
        v[SnapshotSlots.spectrogramMode] = Float(spectrum.spectrogramMode.rawValue)
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
        v[SnapshotSlots.breaks] = Float(breaks)
        v[SnapshotSlots.missing] = Float(missingSeconds)
        health.write(into: v + SnapshotSlots.signalHealth)
    }
}
