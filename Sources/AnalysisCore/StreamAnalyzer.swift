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
    private let roles: [Int]
    private var values = [Float](repeating: 0, count: SnapshotSlots.total)

    /// Ticks published in this generation, with and without audio.
    package private(set) var ticks: UInt64 = 0
    private var audioTicks: UInt64 = 0
    package private(set) var framesAnalysed: UInt64 = 0
    /// Stream position just after the newest frame analysed (the producer's positions).
    package private(set) var timelineEnd: UInt64 = 0
    package private(set) var measuring = true
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

    /// `channels` is 1 (mono: channel 1 is L) or 2 (L, R).
    package init?(sampleRate: Double, channels: Int, generation: UInt32, formatEpoch: UInt32) {
        guard (1...2).contains(channels) else { return nil }
        let roles = channels == 1 ? [Role.left] : [Role.left, Role.right]
        let active = (0..<Role.count).map { roles.contains($0) }
        guard let pipeline = MeterPipeline(sampleRate: sampleRate, activeRoles: active,
                                           detector: FormatDetector(initial: channels == 1 ? .mono : .stereo, canDetectSpatial: false),
                                           streamID: generation % 1_000_000) else { return nil }
        self.pipeline = pipeline
        self.roles = roles
        self.sampleRate = sampleRate
        self.channels = channels
        self.generation = generation
        self.formatEpoch = formatEpoch
        spectrogramRing = [Float](repeating: -120, count: Self.spectrogramCapacity * MeterSnapshot.spectrogramBandCount)
        waveformStride = channels * 2
        waveformRing = [Float](repeating: 0, count: Self.waveformCapacity * channels * 2)
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
        guard measuring else { return }
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

    /// Pausing keeps everything measured so far and accumulates nothing until resumed; resuming carries on without
    /// a break, as Auraliscope's Pause Capture does.
    package func setMeasuring(_ on: Bool) { measuring = on }

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
    }

    /// Writes one RESULT payload: the latest state, and the columns of each series after `afterSpectrogram` /
    /// `afterWaveform` (serials already sent) that are still held, oldest first, up to `maxSpectrogram` /
    /// `maxWaveform` columns. Returns 0 bytes if nothing was published yet or `capacity` is too small.
    package func encode(into buffer: UnsafeMutableRawPointer, capacity: Int, subscription: UInt32, layout: UInt32,
                        afterSpectrogram: UInt64, afterWaveform: UInt64, maxSpectrogram: Int = 24,
                        maxWaveform: Int = WaveformEnvelope.publishedColumns * 4) -> Encoded {
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
                var channelValues = (Float(0), Float(0))
                channelValues.0 = base[slot + roles[0]]
                if channels > 1 { channelValues.1 = base[slot + roles[1]] }
                withUnsafePointer(to: &channelValues) {
                    $0.withMemoryRebound(to: Float.self, capacity: 2) { w.f32s(tag.rawValue, $0, count: channels) }
                }
            }
            perChannel(.peak, SnapshotSlots.peaks)
            perChannel(.rms, SnapshotSlots.rms)
            perChannel(.truePeak, SnapshotSlots.truePeaks)
            perChannel(.heldPeak, SnapshotSlots.heldPeaks)
            perChannel(.heldTruePeak, SnapshotSlots.heldTruePeaks)
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
