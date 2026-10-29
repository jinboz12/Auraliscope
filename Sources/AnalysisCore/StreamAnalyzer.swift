import Foundation

/// One audio source analysed where its audio is (an Auraliscope Bridge insert), with results sent elsewhere to be
/// shown. Owned by one thread; never called from a real-time audio thread.
///
/// It feeds `MeterPipeline` — the analyses Auraliscope runs on its DSP queue, unchanged — and ticks it by the
/// audio itself: every 1/60 s of audio closes a tick and publishes a snapshot, so each result describes exactly the
/// audio analysed however the host delivers it (steadily, in bursts ahead of playback, or late). When no audio
/// arrives, `idle(now:)` goes on ticking for a moment so the meters fall to silence as the desktop's do, then stops.
///
/// Results are latest-state (levels, loudness, spectrum, stereo image) plus two ordered series the displays keep a
/// history of: spectrogram columns (30 per second of audio) and waveform columns (240 per second). Each series has a
/// serial per generation and a bounded queue, so a display that falls behind loses the oldest columns, visibly
/// (a gap in the serials, and a `dropped` count in the next result), and never makes this object grow or wait.
package final class StreamAnalyzer {
    package static let schemaVersion: UInt32 = 1
    /// Columns kept for a display that falls behind: about 2 s of each series.
    package static let spectrogramCapacity = 64
    package static let waveformCapacity = 512
    /// At most this many ticks without audio are published before the analyser rests (0.15 s).
    package static let idleTicks = 9

    package let sampleRate: Double
    package let channels: Int
    package let generation: UInt32
    package let formatEpoch: UInt32
    private let pipeline: MeterPipeline
    /// Each channel's speaker role (`Role`), in the insert's channel order.
    package let roles: [Int]
    private var values = [Float](repeating: 0, count: SnapshotSlots.total)
    /// One value per channel, for the per-channel fields of a result.
    private var channelValues = [Float](repeating: 0, count: Role.count)

    /// Ticks published in this generation, with and without audio.
    package private(set) var ticks: UInt64 = 0
    private var audioTicks: UInt64 = 0
    package private(set) var framesAnalysed: UInt64 = 0
    /// Stream position just after the newest frame analysed (the producer's positions).
    package private(set) var timelineEnd: UInt64 = 0
    package private(set) var measuring = true
    /// Stream position just after the newest frame measured; a resume compares the next frames' position with it.
    private var measuredEnd: UInt64?
    /// Resumed since the last measured frame: the next frames may not continue them (`consume`).
    private var resumed = false
    /// A break arrived while paused: the frames after the resume do not continue the last ones measured.
    private var brokeWhilePaused = false
    package private(set) var published = false
    private var idleCount = 0
    private var lastTickTime: Double?
    private var lastAudioTime: Double?
    private var lastBlockSeconds = 0.0
    private var lastPublishedIdle = false
    package private(set) var lastBreakReasons: UInt32 = 0

    // Ordered series: fixed rings, newest `count` entries ending at serial `latest`.
    private var spectrogramRing: [Float]
    private var spectrogramCount = 0
    package private(set) var spectrogramLatest: UInt64 = 0
    private var lastSpectrogramSerial: Float = 0
    private var waveformRing: [Float]
    private var waveformCount = 0
    package private(set) var waveformLatest: UInt64 = 0
    private var lastWaveSerial = 0
    private let waveformStride: Int
    package private(set) var sequence: UInt64 = 0
    /// The observation frame the snapshot holds (`SnapshotSlots.spatialObservations`): a new number whenever its header
    /// changes (a new transform's, or none), so a display that keeps observations is sent each frame once (`encode`).
    package private(set) var observationFrame: UInt64 = 1
    private var observationHeader = [Float](repeating: 0, count: SpatialObservations.headerFloats)

    /// `roles` gives each channel's speaker role, in the insert's channel order: [L] for mono, [L, R] for stereo,
    /// up to 16 distinct roles for an immersive bus (5.1, 7.1.4, 9.1.6…). Loudness weighs each channel by its role
    /// (BS.1770: LFE excluded, side surrounds and wides +1.5 dB); the format detector decides Stereo or Immersive
    /// from the programme, as it does for an audio device, starting from Immersive when the bus has positional
    /// channels beyond L and R.
    package init?(sampleRate: Double, roles: [Int], generation: UInt32, formatEpoch: UInt32) {
        guard Self.validRoles(roles) else { return nil }
        let active = (0..<Role.count).map { roles.contains($0) }
        let immersive = roles.contains { FormatDetector.evidenceRoles.contains($0) }
        let detector = FormatDetector(initial: immersive ? .spatial : roles.count == 1 ? .mono : .stereo, canDetectSpatial: immersive)
        guard let pipeline = MeterPipeline(sampleRate: sampleRate, activeRoles: active, detector: detector,
                                           streamID: generation % 1_000_000) else { return nil }
        self.pipeline = pipeline
        // Until a display configures the observations (SPATIAL_CONFIG), the bins go out as Build 87–97 sent them.
        pipeline.spatialLegacyPoints = true
        self.roles = roles
        self.sampleRate = sampleRate
        self.channels = roles.count
        self.generation = generation
        self.formatEpoch = formatEpoch
        spectrogramRing = [Float](repeating: -120, count: Self.spectrogramCapacity * MeterSnapshot.spectrogramBandCount)
        waveformStride = roles.count * 2
        waveformRing = [Float](repeating: 0, count: Self.waveformCapacity * roles.count * 2)
    }

    /// `channels` is 1 (mono: channel 1 is L) or 2 (L, R).
    package convenience init?(sampleRate: Double, channels: Int, generation: UInt32, formatEpoch: UInt32) {
        guard (1...2).contains(channels) else { return nil }
        self.init(sampleRate: sampleRate, roles: channels == 1 ? [Role.left] : [Role.left, Role.right],
                  generation: generation, formatEpoch: formatEpoch)
    }

    /// One to 16 distinct speaker roles; a single channel is L (mono), and a bus of several carries L and R.
    package static func validRoles(_ roles: [Int]) -> Bool {
        guard (1...Role.count).contains(roles.count), roles.allSatisfy({ (0..<Role.count).contains($0) }),
              Set(roles).count == roles.count else { return false }
        return roles.count == 1 ? roles == [Role.left] : roles.contains(Role.left) && roles.contains(Role.right)
    }

    /// Frame (within this generation) at which audio tick `n` (1-based) ends: 1/60 s steps, rounded, so ticks
    /// average exactly 60 per second of audio at any rate.
    private func tickEnd(_ n: UInt64) -> UInt64 { UInt64((Double(n) * sampleRate / MeterPipeline.tickRate).rounded()) }

    /// Analyses `frames` interleaved frames whose first frame is at stream position `position`. While measurement
    /// is paused the audio is not accumulated. `now` is seconds on a monotonic clock.
    package func consume(_ samples: UnsafePointer<Float>, frames: Int, position: UInt64, now: Double) {
        guard frames > 0 else { return }
        timelineEnd = position + UInt64(frames)
        guard measuring else { return }
        if resumed {
            // The audio delivered while paused was not measured: unless the host delivered none, these frames do
            // not continue the last ones measured, and nothing that spans samples may join them (`splice`).
            resumed = false
            if brokeWhilePaused || (measuredEnd.map { $0 != position } ?? false) { pipeline.splice() }
            brokeWhilePaused = false
        }
        measuredEnd = position + UInt64(frames)
        idleCount = 0
        lastAudioTime = now
        lastBlockSeconds = Double(frames) / sampleRate
        var offset = 0
        while offset < frames {
            let end = tickEnd(audioTicks + 1)
            let count = min(frames - offset, Int(end - framesAnalysed))
            pipeline.consume(interleaved: samples + offset * channels, channels: channels, frames: count, roles: roles)
            framesAnalysed += UInt64(count)
            offset += count
            if framesAnalysed == end {
                audioTicks += 1
                publish(now: now, idle: false)
            }
        }
    }

    /// A break before the next audio: `lostFrames` missing, the host idle for `idleMilliseconds`, for `reasons`
    /// (ABR_AUDIO_AFTER_* bits). See `MeterPipeline.interrupt` for what restarts and what carries on.
    package func interrupt(lostFrames: UInt64, idleMilliseconds: UInt32, reasons: UInt32) {
        guard measuring else {
            brokeWhilePaused = true
            return
        }
        pipeline.interrupt(lostFrames: lostFrames, idleMilliseconds: idleMilliseconds)
        lastBreakReasons = reasons
    }

    /// No audio arrived: once the host has been silent for longer than it takes to deliver a block (at least
    /// 0.1 s), ticks on the clock for a moment so the meters fall to silence, then rests. Returns whether it
    /// published.
    @discardableResult
    package func idle(now: Double) -> Bool {
        guard measuring, idleCount < Self.idleTicks, let audio = lastAudioTime else { return false }
        let interval = 1 / MeterPipeline.tickRate
        guard now - audio > max(0.1, 3 * lastBlockSeconds), now - (lastTickTime ?? 0) >= interval else { return false }
        idleCount += 1
        publish(now: now, idle: true)
        return true
    }

    /// The waterfall's analysis, as the subscribed display asked for it; columns from now on follow it.
    package var spectrogramMode: SpectrogramMode {
        get { pipeline.spectrum.spectrogramMode }
        set { pipeline.spectrum.spectrogramMode = newValue }
    }

    /// What the spectrum and the waterfall sum, as the subscribed display shows Stereo (L and R) or Immersive
    /// (every channel, which also gives every channel's band energy for the immersive soundstage). Takes effect
    /// once every channel has a full transform window (≤ 170 ms), as on the desktop.
    package var spatialSpectrum: Bool {
        get { pipeline.spatialSpectrum }
        set { pipeline.spatialSpectrum = newValue }
    }

    /// The spatial field's coherence threshold, as the subscribed display asks for it (SUBSCRIBE option 4).
    package var spatialCoherence: Float {
        get { pipeline.spatialCoherence }
        set { pipeline.spatialCoherence = newValue }
    }

    /// Whether the subscribed display configured the spatial geometry (SPATIAL_CONFIG): from the next spatial transform
    /// the results carry the observations (tag 58) computed with it, instead of the Build 87–97 bins (tag 54) of the
    /// standard layout, which an unconfigured analysis makes instead of observations.
    package private(set) var spatialConfigured = false
    package var spatialGeometry: SpatialGeometry { pipeline.spatialGeometry }

    /// Applies a display's SPATIAL_CONFIG payload to this bus: its geometry from the next spatial transform on (the
    /// results already analysed keep the hash of the geometry they were made with, so the display can tell them
    /// apart), and the observations instead of the bins. Nothing changes when the payload is refused.
    package func configureSpatial(_ bytes: UnsafeRawBufferPointer) -> (outcome: SpatialConfigWire.Outcome, revision: UInt32, hash: UInt64) {
        let decoded = SpatialConfigWire.decode(bytes, roles: roles)
        guard let geometry = decoded.geometry else { return (decoded.outcome, 0, 0) }
        pipeline.spatialGeometry = geometry
        pipeline.spatialLegacyPoints = false
        spatialConfigured = true
        return (.applied, geometry.revision, geometry.hash)
    }

    /// The display that configured it went away: the standard layout and the Build 87–97 bins again, for whichever
    /// display subscribes next.
    package func resetSpatial() {
        pipeline.spatialGeometry = SpatialGeometry.standard(roles: roles)
        pipeline.spatialLegacyPoints = true
        spatialConfigured = false
    }

    /// Pausing keeps everything measured so far and accumulates nothing until resumed; resuming carries on without
    /// a break (nothing is reset, counted as a break or as missing time), as Auraliscope's Pause Capture does. The
    /// audio the host delivered meanwhile was not measured, so the frames after the resume are spliced to the last
    /// ones before it (`MeterPipeline.splice`): no filter, interpolation or window reaches across.
    package func setMeasuring(_ on: Bool) {
        if on && !measuring { resumed = true }
        measuring = on
    }

    /// Clears the held true peaks only (the TRUE PEAK reading's reset).
    package func resetTruePeaks() {
        pipeline.resetTruePeaks()
        // Commands can arrive while paused or after idle ticks have stopped. Update the
        // published state too, without ticking (which would advance/decay unrelated meters).
        for role in 0..<Role.count { values[SnapshotSlots.heldTruePeaks + role] = 0 }
    }

    private func publish(now: Double, idle: Bool) {
        ticks += 1
        lastTickTime = now
        lastPublishedIdle = idle
        values.withUnsafeMutableBufferPointer {
            pipeline.publish(into: $0.baseAddress!, now: Double(ticks) / MeterPipeline.tickRate)
        }
        published = true
        let header = SnapshotSlots.spatialObservations
        if !observationHeader.elementsEqual(values[header..<(header + SpatialObservations.headerFloats)]) {
            observationHeader.replaceSubrange(0..., with: values[header..<(header + SpatialObservations.headerFloats)])
            observationFrame += 1
        }
        let spectrogramSerial = values[SnapshotSlots.spectrogramSerial]
        if spectrogramSerial != lastSpectrogramSerial {
            lastSpectrogramSerial = spectrogramSerial
            appendSpectrogram()
        }
        let waveSerial = Int(values[SnapshotSlots.waveSerial])
        let fresh = WaveformEnvelope.newColumns(since: lastWaveSerial, latest: waveSerial)
        lastWaveSerial = waveSerial
        if fresh > 0 { appendWaveform(newest: fresh) }
    }

    private func appendSpectrogram() {
        let rows = MeterSnapshot.spectrogramBandCount
        spectrogramLatest += 1
        let slot = Int((spectrogramLatest - 1) % UInt64(Self.spectrogramCapacity))
        values.withUnsafeBufferPointer { source in
            spectrogramRing.withUnsafeMutableBufferPointer { ring in
                (ring.baseAddress! + slot * rows).update(from: source.baseAddress! + SnapshotSlots.spectrogram, count: rows)
            }
        }
        spectrogramCount = min(spectrogramCount + 1, Self.spectrogramCapacity)
    }

    /// The newest `newest` columns of the snapshot's waveform window, the insert's channels only.
    private func appendWaveform(newest: Int) {
        let columns = WaveformEnvelope.publishedColumns
        for column in (columns - newest)..<columns {
            waveformLatest += 1
            let slot = Int((waveformLatest - 1) % UInt64(Self.waveformCapacity))
            let source = SnapshotSlots.waveform + column * WaveformEnvelope.valuesPerColumn
            for (channel, role) in roles.enumerated() {
                waveformRing[slot * waveformStride + channel * 2] = values[source + role * 2]
                waveformRing[slot * waveformStride + channel * 2 + 1] = values[source + role * 2 + 1]
            }
            waveformCount = min(waveformCount + 1, Self.waveformCapacity)
        }
    }

    /// What a display needs to resume: the serials of the oldest columns still held.
    package var oldestSpectrogram: UInt64 { spectrogramLatest - UInt64(spectrogramCount) + 1 }
    package var oldestWaveform: UInt64 { waveformLatest - UInt64(waveformCount) + 1 }

    /// The newest snapshot, in `SnapshotSlots` layout (for tests and the plugin window's summary).
    package var snapshot: [Float] { values }

    package struct Encoded {
        package var bytes = 0
        /// Serials of the newest columns carried (unchanged from the `after` arguments when none were).
        package var spectrogramThrough: UInt64 = 0
        package var waveformThrough: UInt64 = 0
        /// The observation frame (`observationFrame`) the receiver holds after this result: the one it carried, the
        /// `afterObservations` argument when it was left out, 0 when the result carried none (the bins, or no field).
        package var observationsThrough: UInt64 = 0
    }

    /// Writes one RESULT payload: the latest state, and the columns of each series after `afterSpectrogram` /
    /// `afterWaveform` (serials already sent) that are still held, oldest first, up to `maxSpectrogram` /
    /// `maxWaveform` columns. The observations (tag 58) are left out when `afterObservations` is the frame the snapshot
    /// holds: the receiver keeps the observations it was sent last, and 0 (none held, or a receiver that does not keep
    /// them) has them in every result. Returns 0 bytes if nothing was published yet or `capacity` is too small.
    package func encode(into buffer: UnsafeMutableRawPointer, capacity: Int, subscription: UInt32, layout: UInt32,
                        afterSpectrogram: UInt64, afterWaveform: UInt64, afterObservations: UInt64 = 0,
                        maxSpectrogram: Int = 24, maxWaveform: Int = WaveformEnvelope.publishedColumns * 4) -> Encoded {
        var result = Encoded(spectrogramThrough: afterSpectrogram, waveformThrough: afterWaveform)
        guard published else { return result }
        sequence += 1
        var w = WireWriter(buffer, capacity: capacity)
        w.u32(ResultTag.subscription.rawValue, subscription)
        w.u32(ResultTag.schema.rawValue, Self.schemaVersion)
        w.u32(ResultTag.generation.rawValue, generation)
        w.u32(ResultTag.formatEpoch.rawValue, formatEpoch)
        w.f64(ResultTag.sampleRate.rawValue, sampleRate)
        w.u32(ResultTag.channels.rawValue, UInt32(channels))
        w.u32(ResultTag.layout.rawValue, layout)
        w.u8s(ResultTag.roles.rawValue, roles.map { UInt8($0) })
        w.u64(ResultTag.sequence.rawValue, sequence)
        w.u64(ResultTag.tick.rawValue, ticks)
        w.f64(ResultTag.tickRate.rawValue, MeterPipeline.tickRate)
        w.u64(ResultTag.timelineEnd.rawValue, timelineEnd)
        w.u64(ResultTag.framesAnalysed.rawValue, framesAnalysed)
        w.u32(ResultTag.measurement.rawValue, (measuring ? MeasurementState.measuring : .paused).rawValue)
        w.u32(ResultTag.stateFlags.rawValue, lastPublishedIdle ? ResultFlags.idle : 0)
        w.u32(ResultTag.breaks.rawValue, UInt32(values[SnapshotSlots.breaks]))
        w.f64(ResultTag.missingSeconds.rawValue, Double(values[SnapshotSlots.missing]))
        w.u32(ResultTag.lastBreakReasons.rawValue, lastBreakReasons)
        values.withUnsafeBufferPointer { v in
            let base = v.baseAddress!
            func perChannel(_ tag: ResultTag, _ slot: Int) {
                for (channel, role) in roles.enumerated() { channelValues[channel] = base[slot + role] }
                channelValues.withUnsafeBufferPointer { w.f32s(tag.rawValue, $0.baseAddress!, count: channels) }
            }
            perChannel(.peak, SnapshotSlots.peaks)
            perChannel(.rms, SnapshotSlots.rms)
            perChannel(.truePeak, SnapshotSlots.truePeaks)
            perChannel(.heldPeak, SnapshotSlots.heldPeaks)
            perChannel(.heldTruePeak, SnapshotSlots.heldTruePeaks)
            perChannel(.dcOffset, SnapshotSlots.dcOffset)
            perChannel(.infrasonic, SnapshotSlots.infrasonic)
            w.f32(ResultTag.healthStatus.rawValue, base[SnapshotSlots.healthStatus])
            w.f32(ResultTag.momentary.rawValue, base[SnapshotSlots.momentary])
            w.f32(ResultTag.shortTerm.rawValue, base[SnapshotSlots.shortTerm])
            w.f32(ResultTag.integrated.rawValue, base[SnapshotSlots.integrated])
            w.f32(ResultTag.loudnessRange.rawValue, base[SnapshotSlots.range])
            w.f32s(ResultTag.spectrum.rawValue, base + SnapshotSlots.spectrum, count: MeterSnapshot.bandCount)
            w.f32s(ResultTag.spectrumFine.rawValue, base + SnapshotSlots.spectrumFine, count: MeterSnapshot.fineBandCount)
            w.f32s(ResultTag.dominant.rawValue, base + SnapshotSlots.peakFrequency, count: 2)
            w.f32s(ResultTag.notes.rawValue, base + SnapshotSlots.notes, count: 2 * SpectrumAnalyzer.maxNotes)
            w.f32(ResultTag.correlation.rawValue, base[SnapshotSlots.correlation])
            let groups = StereoBands.groups.count
            w.f32s(ResultTag.bandCorrelation.rawValue, base + SnapshotSlots.bandCorrelation, count: groups)
            w.f32s(ResultTag.bandWidth.rawValue, base + SnapshotSlots.bandWidth, count: groups)
            w.f32s(ResultTag.bandBalance.rawValue, base + SnapshotSlots.bandBalance, count: groups)
            w.f32s(ResultTag.bandLevel.rawValue, base + SnapshotSlots.bandLevel, count: groups)
            w.f32s(ResultTag.bandPoints.rawValue, base + SnapshotSlots.bandPoints, count: StereoBands.scopeFloats)
            var power = [Float](repeating: 0, count: channels * StereoBands.count)
            for (channel, role) in roles.enumerated() {
                for band in 0..<StereoBands.count {
                    power[channel * StereoBands.count + band] = base[SnapshotSlots.roleBandPower + role * StereoBands.count + band]
                }
            }
            w.f32s(ResultTag.bandPower.rawValue, power)
            w.u32(ResultTag.detectedFormat.rawValue, UInt32(max(0, base[SnapshotSlots.format])))
            w.u32(ResultTag.spectrumChannels.rawValue, pipeline.analysedSpatial ? 1 : 0)
            // The spatial field while the display shows Immersive (every channel analysed).
            if pipeline.spatialSpectrum {
                let field = base + SnapshotSlots.spatialField
                w.bytes(ResultTag.spatialField.rawValue, count: SpatialFieldWire.size(field, channels: channels)) { out in
                    SpatialFieldWire.encode(field, roles: roles, into: out)
                }
                // The bins while they are what the newest transform made (an unconfigured plugin, or a configured one
                // until its first transform with the display's geometry); otherwise the observations, once per frame.
                let observations = base + SnapshotSlots.spatialObservations, points = base + SnapshotSlots.spatialPoints
                if !spatialConfigured || (observations[SpatialObservations.Header.status] != 1 && points[SpatialPoints.status] == 1) {
                    w.bytes(ResultTag.spatialPoints.rawValue, count: SpatialPointsWire.size(points)) { out in
                        SpatialPointsWire.encode(points, into: out)
                    }
                } else if afterObservations != observationFrame {
                    w.bytes(ResultTag.spatialObservations.rawValue, count: SpatialObservationsWire.size(observations)) { out in
                        SpatialObservationsWire.encode(observations, into: out)
                    }
                    result.observationsThrough = observationFrame
                } else {
                    result.observationsThrough = afterObservations
                }
            }
        }

        // Spectrogram columns after the last sent that are still held.
        let rows = MeterSnapshot.spectrogramBandCount
        let spectrogramFirst = max(afterSpectrogram + 1, oldestSpectrogram)
        let spectrogramColumns = spectrogramLatest >= spectrogramFirst
            ? Int(min(UInt64(maxSpectrogram), spectrogramLatest - spectrogramFirst + 1)) : 0
        w.u64(ResultTag.spectrogramFirst.rawValue, spectrogramFirst)
        w.u32(ResultTag.spectrogramRows.rawValue, UInt32(rows))
        var columns = [Float](repeating: 0, count: spectrogramColumns * rows)
        for i in 0..<spectrogramColumns {
            let slot = Int((spectrogramFirst + UInt64(i) - 1) % UInt64(Self.spectrogramCapacity))
            for row in 0..<rows { columns[i * rows + row] = spectrogramRing[slot * rows + row] }
        }
        w.f32s(ResultTag.spectrogram.rawValue, columns)
        w.u64(ResultTag.spectrogramLatest.rawValue, spectrogramLatest)
        w.u32(ResultTag.spectrogramMode.rawValue, spectrogramMode.rawValue)
        // Columns this receiver will never get: skipped because they left the queue before they could be sent.
        w.u64(ResultTag.spectrogramDropped.rawValue, afterSpectrogram > 0 ? spectrogramFirst - afterSpectrogram - 1 : 0)

        let waveformFirst = max(afterWaveform + 1, oldestWaveform)
        let waveformColumns = waveformLatest >= waveformFirst
            ? Int(min(UInt64(maxWaveform), waveformLatest - waveformFirst + 1)) : 0
        w.u64(ResultTag.waveformFirst.rawValue, waveformFirst)
        w.f64(ResultTag.waveformColumnRate.rawValue, WaveformEnvelope.columnRate)
        var envelope = [Float](repeating: 0, count: waveformColumns * waveformStride)
        for i in 0..<waveformColumns {
            let slot = Int((waveformFirst + UInt64(i) - 1) % UInt64(Self.waveformCapacity))
            for k in 0..<waveformStride { envelope[i * waveformStride + k] = waveformRing[slot * waveformStride + k] }
        }
        w.f32s(ResultTag.waveform.rawValue, envelope)
        w.u64(ResultTag.waveformLatest.rawValue, waveformLatest)
        w.u64(ResultTag.waveformDropped.rawValue, afterWaveform > 0 ? waveformFirst - afterWaveform - 1 : 0)

        w.u32(ResultTag.fftSize.rawValue, UInt32(SpectrumAnalyzer.historyLength(sampleRate: sampleRate)))
        w.u32(ResultTag.spectrumBands.rawValue, UInt32(MeterSnapshot.bandCount))
        w.f32(ResultTag.correlationTime.rawValue, Float(MeterPipeline.correlationTime))
        w.f32(ResultTag.levelWindow.rawValue, Float(Double(MeterPipeline.windowTicks) / MeterPipeline.tickRate))
        guard !w.overflowed else { return result }
        result.bytes = w.count
        if spectrogramColumns > 0 { result.spectrogramThrough = spectrogramFirst + UInt64(spectrogramColumns) - 1 }
        if waveformColumns > 0 { result.waveformThrough = waveformFirst + UInt64(waveformColumns) - 1 }
        return result
    }
}
