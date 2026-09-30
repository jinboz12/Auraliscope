// Plugin-side analysis and result delivery, without a plugin: the Bridge's StreamAnalyzer against the desktop
// pipeline on identical audio, the RESULT encoding against its specification, and the display-side assembly
// (ordering, gaps, pacing, generations, mono and stereo).
//
// Built and run with the analysis checks: Bridge/scripts/test-analysis.sh

import Foundation

enum ResultChecks {
    private static var failures = 0
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        print((condition ? "  ok   " : "  FAIL ") + message() + (condition ? "" : " (line \(line))"))
        if !condition { failures += 1 }
    }

    /// The test signal of the transport tests and the harness: L 997 Hz at 0.5, R 1499 Hz at 0.25.
    private static func signal(_ channel: Int, _ n: Int, _ rate: Double) -> Float {
        channel == 0 ? Float(0.5 * sin(2 * .pi * 997 * Double(n) / rate)) : Float(0.25 * sin(2 * .pi * 1499 * Double(n) / rate))
    }

    private static func interleaved(channels: Int, start: Int, count: Int, rate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: channels * count)
        for i in 0..<count { for c in 0..<channels { samples[i * channels + c] = signal(c, start + i, rate) } }
        return samples
    }

    static func run() -> Int {
        equivalence()
        codec()
        assembly()
        lifecycle()
        midStreamStart()
        return failures
    }

    /// The Bridge analyses with exactly the desktop's pipeline: fed the same audio in any block sizes, every
    /// snapshot it publishes equals the one the pipeline publishes when fed one tick at a time, as the desktop's DSP
    /// queue is at a steady rate.
    private static func equivalence() {
        print("Plugin-side analysis equals the desktop analysis")
        for (rate, channels) in [(48_000.0, 2), (44_100.0, 1), (96_000.0, 2)] {
            let roles = channels == 1 ? [Role.left] : [Role.left, Role.right]
            let active = (0..<Role.count).map { roles.contains($0) }
            guard let bridge = StreamAnalyzer(sampleRate: rate, channels: channels, generation: 1, formatEpoch: 1),
                  let desktop = MeterPipeline(sampleRate: rate, activeRoles: active,
                                              detector: FormatDetector(initial: channels == 1 ? .mono : .stereo, canDetectSpatial: false),
                                              streamID: 1) else { return check(false, "analysers") }
            let seconds = 6.0
            let total = Int(rate * seconds)
            let audio = interleaved(channels: channels, start: 0, count: total, rate: rate)
            // Bridge: irregular host blocks, as DAWs deliver them.
            let blocks = [37, 512, 1024, 64, 4096, 333, 2048, 128]
            var offset = 0, index = 0
            var bridgeSnapshots: [[Float]] = []
            var lastTicks: UInt64 = 0
            while offset < total {
                let count = min(blocks[index % blocks.count], total - offset)
                audio.withUnsafeBufferPointer { bridge.consume($0.baseAddress! + offset * channels, frames: count, position: UInt64(offset), now: 0) }
                // Several ticks can close within one block; the analyser keeps the newest (what a display would see).
                if bridge.ticks != lastTicks { lastTicks = bridge.ticks; bridgeSnapshots.append(bridge.snapshot) }
                offset += count
                index += 1
            }
            // Desktop: one tick of audio per publish.
            var desktopValues = [Float](repeating: 0, count: SnapshotSlots.total)
            var tick = 0, position = 0, maxDelta: Float = 0, compared = 0, identical = 0
            var worstSlot = -1
            let finalBridge = bridge.snapshot
            while true {
                let end = Int((Double(tick + 1) * rate / MeterPipeline.tickRate).rounded())
                guard end <= total else { break }
                audio.withUnsafeBufferPointer {
                    desktop.consume(interleaved: $0.baseAddress! + position * channels, channels: channels, frames: end - position, roles: roles)
                }
                position = end
                tick += 1
                desktopValues.withUnsafeMutableBufferPointer { desktop.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
            }
            // The final snapshots describe the same audio and the same number of ticks.
            for slot in 0..<SnapshotSlots.total where slot != SnapshotSlots.stream && slot != SnapshotSlots.sequence {
                let delta = abs(finalBridge[slot] - desktopValues[slot])
                if delta.isNaN || delta > maxDelta { maxDelta = delta.isNaN ? .infinity : delta; worstSlot = slot }
                if finalBridge[slot] == desktopValues[slot] { identical += 1 }
                compared += 1
            }
            // Bit-identical except where a sum is split differently by the host's blocks (the L/R correlation
            // integrator): float rounding only.
            check(bridge.ticks == UInt64(tick) && maxDelta <= 1e-6,
                  String(format: "%.0f Hz %d ch, irregular blocks: %d ticks each; %d of %d values bit-identical, largest difference %g (slot %d)",
                         rate, channels, tick, identical, compared, maxDelta, worstSlot))
            _ = bridgeSnapshots
        }
    }

    /// A RESULT carries what its specification says, and a receiver reads it back without the sender's types.
    private static func codec() {
        print("RESULT encoding")
        guard let a = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 7, formatEpoch: 3) else { return check(false, "analyser") }
        let audio = interleaved(channels: 2, start: 0, count: 48_000 * 4, rate: 48_000)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000 * 4, position: 1000, now: 0) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        let encoded = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 42, layout: 2, afterSpectrogram: 0, afterWaveform: 0)
        }
        let m = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<encoded.bytes])) }
        let v = a.snapshot
        check(encoded.bytes > 0 && encoded.bytes % 4 == 0 && m.valid && !m.malformed && m.rejectedFields == 0,
              "a \(encoded.bytes)-byte payload of whole, aligned fields decodes as valid")
        check(m.subscription == 42 && m.schema == 1 && m.generation == 7 && m.formatEpoch == 3 && m.sampleRate == 48_000
                  && m.channels == 2 && m.layout == 2 && m.tick == 240 && m.framesAnalysed == 192_000 && m.timelineEnd == 193_000,
              "identity and timing: subscription, schema, generation, epoch, rate, channels, 240 ticks, frames and timeline")
        check(m.peak == [v[SnapshotSlots.peaks], v[SnapshotSlots.peaks + 1]] && m.heldTruePeak == [v[SnapshotSlots.heldTruePeaks], v[SnapshotSlots.heldTruePeaks + 1]]
                  && m.integrated == v[SnapshotSlots.integrated] && m.momentary == v[SnapshotSlots.momentary]
                  && m.loudnessRange == v[SnapshotSlots.range],
              "levels and loudness equal the analyser's values exactly (integrated \(m.integrated) LUFS)")
        check(m.spectrum == Array(v[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + 64)])
                  && m.bandPoints == Array(v[SnapshotSlots.bandPoints..<(SnapshotSlots.bandPoints + StereoBands.scopeFloats)])
                  && m.correlation == v[SnapshotSlots.correlation] && m.notes.count == 12,
              "spectrum, stereometer points, correlation and notes carried in full")
        check(m.spectrogramFirst == m.spectrogramLatest - UInt64(StreamAnalyzer.spectrogramCapacity) + 1 && m.spectrogramColumns == 24
                  && m.waveformFirst == m.waveformLatest - UInt64(StreamAnalyzer.waveformCapacity) + 1 && m.waveformColumns == 256,
              "a new receiver starts from the oldest columns held (spectrogram \(m.spectrogramFirst) of \(m.spectrogramLatest), waveform \(m.waveformFirst) of \(m.waveformLatest)), at most 24 and 256 per result")
        // The next result carries only what is new.
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 800, position: 193_000, now: 0) }
        let next = buffer.withUnsafeMutableBytes {
            a.encode(into: $0.baseAddress!, capacity: $0.count, subscription: 42, layout: 2,
                     afterSpectrogram: encoded.spectrogramThrough, afterWaveform: encoded.waveformThrough)
        }
        let n = buffer.withUnsafeBytes { ResultMessage.decode(UnsafeRawBufferPointer(rebasing: $0[0..<next.bytes])) }
        check(n.waveformFirst == encoded.waveformThrough + 1 && n.spectrogramFirst == encoded.spectrogramThrough + 1
                  && n.spectrogramDropped == 0 && n.waveformDropped == 0,
              "the next result continues each series where the last one stopped (waveform from \(n.waveformFirst), spectrogram from \(n.spectrogramFirst))")

        // Robustness: unknown fields are skipped; malformed ones end the payload; wrong kinds are ignored.
        var extended = Array(buffer[0..<next.bytes])
        extended += [0xE7, 0x03, 2, 0, 1, 0, 0, 0, 9, 9, 9, 9]   // tag 999, u32 1: a later schema's field
        let withUnknown = extended.withUnsafeBytes { ResultMessage.decode($0) }
        check(withUnknown.valid && withUnknown.rejectedFields == 0, "an unknown field is skipped")
        var truncated = Array(buffer[0..<next.bytes])
        truncated += [0x14, 0, 5, 0, 200, 0, 0, 0, 1, 2, 3, 4]   // tag 20 claiming 200 floats with 4 bytes present
        let cut = truncated.withUnsafeBytes { ResultMessage.decode($0) }
        check(cut.malformed && !cut.valid, "a field that runs past the payload makes it malformed (not used)")
        var wrongKind = Array(buffer[0..<next.bytes])
        wrongKind += [0x20, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0]     // integrated (32) as u32: the wrong kind
        let kind = wrongKind.withUnsafeBytes { ResultMessage.decode($0) }
        check(kind.rejectedFields == 1 && kind.integrated == n.integrated, "a known field of the wrong kind is ignored")
        var other = n
        other.schema = 2
        check(!other.valid, "another analysis schema is not shown as this one")
        other = n
        other.peak = [0.5]
        check(!other.valid, "per-channel values must match the channel count")
    }

    private static func message(generation: UInt32 = 1, channels: Int = 2, spectrogram: [UInt64] = [], waveform: [UInt64] = [],
                                level: Float = 0.5) -> ResultMessage {
        var m = ResultMessage()
        m.schema = 1
        m.generation = generation
        m.sampleRate = 48_000
        m.channels = channels
        m.peak = [Float](repeating: level, count: channels)
        m.rms = m.peak
        m.truePeak = m.peak
        m.heldPeak = m.peak
        m.heldTruePeak = m.peak
        m.integrated = -10
        if let first = spectrogram.first {
            m.spectrogramFirst = first
            m.spectrogram = spectrogram.flatMap { serial in [Float](repeating: -Float(serial), count: ResultMessage.spectrogramRows) }
        }
        if let first = waveform.first {
            m.waveformFirst = first
            m.waveform = waveform.flatMap { serial in (0..<(channels * 2)).map { k in Float(serial) + Float(k) / 10 } }
        }
        return m
    }

    /// Results back into the snapshots the displays read.
    private static func assembly() {
        print("Display assembly")
        let a = ResultAssembler()
        check(a.receive(message(spectrogram: [1, 2, 3], waveform: [1, 2, 3, 4]), source: 1), "a result is taken")
        check(a.publish(), "…and published")
        var v = a.values
        let stream = v[SnapshotSlots.stream]
        check(v[SnapshotSlots.peaks] == 0.5 && v[SnapshotSlots.peaks + 1] == 0.5 && v[SnapshotSlots.peaks + 2] == 0
                  && v[SnapshotSlots.integrated] == -10,
              "stereo levels land on L and R, nothing on other roles")
        check(v[SnapshotSlots.spectrogramSerial] == 1 && v[SnapshotSlots.spectrogram] == -1, "one spectrogram column per tick (serial 1 first)")
        a.publish()
        a.publish()
        v = a.values
        check(v[SnapshotSlots.spectrogramSerial] == 3 && v[SnapshotSlots.spectrogram] == -3, "…in order, one per tick")
        check(a.publish() == false, "nothing new: nothing published")
        let wave = WaveformEnvelope.publishedColumns - 1
        check(v[SnapshotSlots.waveSerial] == 4 && v[SnapshotSlots.waveform + wave * WaveformEnvelope.valuesPerColumn] == 4
                  && v[SnapshotSlots.waveform + wave * WaveformEnvelope.valuesPerColumn + 3] == 4.3,
              "waveform columns enter the display window newest last, L (min, max) then R")
        // Replayed and older columns are ignored; a gap leaves blanks.
        a.receive(message(spectrogram: [2, 3]), source: 1)
        check(!a.hasPending || a.publish() && a.values[SnapshotSlots.spectrogramSerial] == 3, "columns already shown are not shown again")
        a.receive(message(spectrogram: [6], waveform: [7]), source: 1)
        a.publish()
        v = a.values
        check(v[SnapshotSlots.spectrogram] == -120 && a.spectrogramGaps == 2 && a.waveformGaps == 2,
              "a gap of 2 leaves 2 blank columns in each series")
        a.publish(); a.publish()
        check(a.values[SnapshotSlots.spectrogram] == -6, "…then the next real column")
        check(a.values[SnapshotSlots.stream] == stream, "the same generation stays one stream")
        // A backlog is skipped down to a short queue so the waterfall stays current.
        a.receive(message(spectrogram: Array(7...40)), source: 1)
        a.publish()
        check(a.spectrogramSkipped == UInt64(34 - ResultAssembler.spectrogramLag),
              "a burst of 34 columns keeps the newest \(ResultAssembler.spectrogramLag) (\(a.spectrogramSkipped) skipped for latency)")
        // Bounded while nobody publishes (a paused display): only what could still be shown is kept.
        let idle = ResultAssembler()
        for n in 0..<200 {
            idle.receive(message(spectrogram: [UInt64(n + 1)], waveform: (0..<8).map { UInt64(n * 8 + $0 + 1) }), source: 1)
        }
        check(idle.spectrogramSkipped == UInt64(200 - ResultAssembler.spectrogramLag)
                  && idle.waveformSkipped == UInt64(1600 - StreamAnalyzer.waveformCapacity),
              "with no display reading, the queues stay bounded (\(ResultAssembler.spectrogramLag) and \(StreamAnalyzer.waveformCapacity) columns)")
        // A new generation is a new stream: histories clear.
        a.receive(message(generation: 2, spectrogram: [1]), source: 1)
        a.publish()
        check(a.values[SnapshotSlots.stream] != stream && a.values[SnapshotSlots.spectrogramSerial] == 1,
              "a new generation starts a new stream for the displays")
        // Mono: channel 1 is L; R stays silent.
        let mono = ResultAssembler()
        mono.receive(message(channels: 1, waveform: [1]), source: 1)
        mono.publish()
        check(mono.values[SnapshotSlots.peaks] == 0.5 && mono.values[SnapshotSlots.peaks + 1] == 0
                  && mono.values[SnapshotSlots.waveform + wave * WaveformEnvelope.valuesPerColumn + 2] == 0,
              "mono lands on L only")
        // An invalid result changes nothing.
        var bad = message()
        bad.peak = [1, 1, 1]
        check(!mono.receive(bad, source: 1) && mono.rejected == 1, "an invalid result is rejected")
        // Silence after the source goes quiet keeps what was measured.
        mono.silenceTransients()
        mono.publish()
        check(mono.values[SnapshotSlots.peaks] == 0 && mono.values[SnapshotSlots.integrated] == -10,
              "going quiet silences the instantaneous readings and keeps integrated loudness")
    }

    /// True peak of a stream that starts in the middle of a waveform (a reset, a capture started while playing):
    /// the plugin and the desktop pipeline must agree, whatever the interpolator does at the first sample.
    private static func midStreamStart() {
        print("Stream starting mid-waveform")
        for start in [0, 12_345, 777] {
            guard let bridge = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 1, formatEpoch: 1),
                  let desktop = MeterPipeline(sampleRate: 48_000, activeRoles: (0..<Role.count).map { $0 < 2 },
                                              detector: FormatDetector(), streamID: 1) else { return check(false, "analysers") }
            let audio = interleaved(channels: 2, start: start, count: 48_000 * 2, rate: 48_000)
            audio.withUnsafeBufferPointer { bridge.consume($0.baseAddress!, frames: 96_000, position: 0, now: 0) }
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var position = 0
            for tick in 0..<120 {
                audio.withUnsafeBufferPointer {
                    desktop.consume(interleaved: $0.baseAddress! + position * 2, channels: 2, frames: 800, roles: [0, 1])
                }
                position += 800
                values.withUnsafeMutableBufferPointer { desktop.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
            }
            let b = bridge.snapshot
            func db(_ v: Float) -> Double { 20 * log10(Double(v)) }
            print(String(format: "  info start %6d: held true peak L %.3f R %.3f dBTP (sample peaks -6.021, -12.041)",
                         start, db(b[SnapshotSlots.heldTruePeaks]), db(b[SnapshotSlots.heldTruePeaks + 1])))
            check(b[SnapshotSlots.heldTruePeaks] == values[SnapshotSlots.heldTruePeaks]
                      && b[SnapshotSlots.heldTruePeaks + 1] == values[SnapshotSlots.heldTruePeaks + 1],
                  "start at sample \(start): plugin and desktop hold the same true peak")
        }
    }

    /// Measurement pause, breaks and idle ticks in the plugin's analyser.
    private static func lifecycle() {
        print("Measurement lifecycle")
        guard let a = StreamAnalyzer(sampleRate: 48_000, channels: 2, generation: 1, formatEpoch: 1) else { return check(false, "analyser") }
        let audio = interleaved(channels: 2, start: 0, count: 48_000 * 2, rate: 48_000)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000, position: 0, now: 1) }
        let integrated = a.snapshot[SnapshotSlots.integrated]
        a.setMeasuring(false)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress! + 96_000, frames: 48_000, position: 48_000, now: 2) }
        check(a.framesAnalysed == 48_000 && a.timelineEnd == 96_000 && !a.idle(now: 5),
              "paused: nothing accumulates (the timeline still advances), and no idle ticks")
        a.setMeasuring(true)
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 48_000, position: 96_000, now: 3) }
        check(a.framesAnalysed == 96_000 && a.snapshot[SnapshotSlots.breaks] == 0 && abs(a.snapshot[SnapshotSlots.integrated] - integrated) < 0.01,
              "resumed: carries on without a break (the release's Pause semantics)")
        a.interrupt(lostFrames: 4_800, idleMilliseconds: 0, reasons: UInt32(1 << 9))
        check(a.snapshot[SnapshotSlots.breaks] == 0, "a break takes effect with the next tick")
        audio.withUnsafeBufferPointer { a.consume($0.baseAddress!, frames: 800, position: 148_800, now: 3.1) }
        check(a.snapshot[SnapshotSlots.breaks] == 1 && abs(a.snapshot[SnapshotSlots.missing] - 0.1) < 0.001 && a.lastBreakReasons == 1 << 9,
              "…counted, with 0.1 s missing and its reasons")
        let ticks = a.ticks
        var idle = 0
        for step in 1...60 where a.idle(now: 3.1 + Double(step) / 60) { idle += 1 }
        check(idle == StreamAnalyzer.idleTicks && a.ticks == ticks + UInt64(idle) && a.snapshot[SnapshotSlots.peaks] == 0,
              "with no audio it ticks \(idle) times, the meters fall to silence, then it rests")
    }
}
