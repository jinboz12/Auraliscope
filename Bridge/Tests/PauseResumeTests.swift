// Pause → Resume of a measurement: deterministic checks that resuming never joins the audio before the pause to the
// audio after it (Bridge/BRIDGE_NETWORK.md and PROTOCOL.md: Pause keeps every measurement, accumulates nothing, and
// Resume carries on). The signal is the test host's: L 0.5 at 997 Hz, R 0.25 at 1499 Hz, a continuous stream whose
// position runs on while the measurement is paused.
//
// Build and run: Bridge/scripts/test-analysis.sh

import AudioRing
import Foundation

enum PauseResumeChecks {
    private static var failures = 0
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        print((condition ? "  ok   " : "  FAIL ") + message() + (condition ? "" : " (line \(line))"))
        if !condition { failures += 1 }
    }

    static let rate = 48_000.0
    /// The stream frame (stereo, interleaved) at position `n`.
    static func frame(_ n: Int) -> (Float, Float) {
        let t = Double(n) / rate
        return (Float(0.5 * sin(2 * Double.pi * 997 * t)), Float(0.25 * sin(2 * Double.pi * 1_499 * t)))
    }
    static func block(from start: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        for i in 0..<count { (out[2 * i], out[2 * i + 1]) = frame(start + i) }
        return out
    }

    /// What one run read, tick by tick.
    struct Run {
        var heldTruePeakL: Float = 0
        var heldPeakL: Float = 0
        var integratedBeforePause: Float = 0
        var rangeBeforePause: Float = -1
        var integrated: Float = 0
        var range: Float = 0
        var breaks: Float = 0
        /// The loudest of the top quarter of the spectrogram's bands in any column, before the pause and after it.
        var highBandsBefore: Float = -200
        var highBandsAfter: Float = -200
        var momentaryAfter: Float = -100
    }

    static let pauseAt = 240_000, skipped = 62_411, resumedFor = 96_000, chunk = 800

    /// Feeds 5 s (short-term values exist, so the loudness range has one), pauses (the stream runs on `skipped` frames, delivered and not measured, as a host keeps playing),
    /// resumes for 2 s. `pausing: false` measures the same 4 s without the pause, as a reference.
    static func run(pausing: Bool) -> Run? {
        guard let analyzer = StreamAnalyzer(sampleRate: rate, channels: 2, generation: 1, formatEpoch: 1) else { return nil }
        var result = Run()
        var lastColumn: Float = 0
        func feed(_ start: Int, _ count: Int, after: Bool) {
            var position = start
            while position < start + count {
                let n = min(chunk, start + count - position)
                let samples = block(from: position, count: n)
                samples.withUnsafeBufferPointer { analyzer.consume($0.baseAddress!, frames: n, position: UInt64(position), now: Double(position) / rate) }
                position += n
                let v = analyzer.snapshot
                if v[SnapshotSlots.spectrogramSerial] != lastColumn {
                    lastColumn = v[SnapshotSlots.spectrogramSerial]
                    let bands = MeterSnapshot.spectrogramBandCount
                    let high = (bands * 3 / 4..<bands).map { v[SnapshotSlots.spectrogram + $0] }.max() ?? -200
                    if after { result.highBandsAfter = max(result.highBandsAfter, high) } else { result.highBandsBefore = max(result.highBandsBefore, high) }
                }
            }
        }
        feed(0, pauseAt, after: false)
        result.integratedBeforePause = analyzer.snapshot[SnapshotSlots.integrated]
        result.rangeBeforePause = analyzer.snapshot[SnapshotSlots.range]
        var resumeAt = pauseAt
        if pausing {
            analyzer.setMeasuring(false)
            feed(pauseAt, skipped, after: false)
            analyzer.setMeasuring(true)
            resumeAt += skipped
        }
        feed(resumeAt, resumedFor, after: true)
        let v = analyzer.snapshot
        result.heldTruePeakL = v[SnapshotSlots.heldTruePeaks + Role.left]
        result.heldPeakL = v[SnapshotSlots.heldPeaks + Role.left]
        result.integrated = v[SnapshotSlots.integrated]
        result.range = v[SnapshotSlots.range]
        result.breaks = v[SnapshotSlots.breaks]
        result.momentaryAfter = v[SnapshotSlots.momentary]
        return result
    }

    static func run() -> Int {
        print("Pause → Resume (the plugin's analysis)")
        guard let paused = run(pausing: true), let reference = run(pausing: false) else {
            check(false, "analysers")
            return failures
        }
        let db = MeterScale.decibels
        check(paused.heldTruePeakL <= reference.heldTruePeakL * 1.001,
              "true peak after resume is the signal's own: \(db(paused.heldTruePeakL)) dBTP (continuous \(db(reference.heldTruePeakL)) dBTP)")
        check(paused.highBandsAfter <= max(paused.highBandsBefore, reference.highBandsAfter) + 3,
              "no click in the spectrogram at the resume: top-quarter bands \(paused.highBandsAfter) dB (before \(paused.highBandsBefore), continuous \(reference.highBandsAfter))")
        check(paused.heldPeakL == reference.heldPeakL, "held sample peak kept (\(db(paused.heldPeakL)) dBFS)")
        check(abs(paused.integrated - reference.integrated) < 0.05 && abs(paused.integrated - paused.integratedBeforePause) < 0.1,
              "integrated loudness carries on: \(paused.integrated) LUFS (before the pause \(paused.integratedBeforePause), continuous \(reference.integrated))")
        check(paused.rangeBeforePause >= 0 && abs(paused.range - paused.rangeBeforePause) < 0.1,
              "loudness range carries on (\(paused.range) LU; before the pause \(paused.rangeBeforePause))")
        check(abs(paused.momentaryAfter - reference.momentaryAfter) < 0.05,
              "momentary reads the tone again after resume (\(paused.momentaryAfter) LUFS)")
        check(paused.breaks == 0, "a pause is not reported as a break in the audio (\(paused.breaks))")
        idlePause()
        breakWhilePaused()
        localPipeline()
        return failures
    }

    /// The host delivered nothing while paused (transport stopped): the next frames continue the last ones measured,
    /// so nothing restarts — momentary reads on at once instead of waiting 400 ms.
    private static func idlePause() {
        guard let analyzer = StreamAnalyzer(sampleRate: rate, channels: 2, generation: 1, formatEpoch: 1) else { return check(false, "analyser") }
        func feed(_ start: Int, _ count: Int) {
            let samples = block(from: start, count: count)
            samples.withUnsafeBufferPointer { analyzer.consume($0.baseAddress!, frames: count, position: UInt64(start), now: Double(start) / rate) }
        }
        feed(0, 48_000)
        analyzer.setMeasuring(false)
        analyzer.setMeasuring(true)
        feed(48_000, 4_800)  // 100 ms
        let momentary = analyzer.snapshot[SnapshotSlots.momentary]
        check(momentary > -10, "a pause with no audio delivered meanwhile restarts nothing (momentary \(momentary) LUFS 100 ms after resume)")
    }

    /// A break reported while paused (the host dropped audio): the resume splices even if positions line up.
    private static func breakWhilePaused() {
        guard let analyzer = StreamAnalyzer(sampleRate: rate, channels: 2, generation: 1, formatEpoch: 1) else { return check(false, "analyser") }
        func feed(_ start: Int, _ count: Int) {
            let samples = block(from: start, count: count)
            samples.withUnsafeBufferPointer { analyzer.consume($0.baseAddress!, frames: count, position: UInt64(start), now: Double(start) / rate) }
        }
        feed(0, 48_000)
        analyzer.setMeasuring(false)
        analyzer.interrupt(lostFrames: 1_000, idleMilliseconds: 0, reasons: 0)
        analyzer.setMeasuring(true)
        feed(48_000, 4_800)
        let v = analyzer.snapshot
        check(v[SnapshotSlots.momentary] == -100 && v[SnapshotSlots.breaks] == 0,
              "a break while paused splices at the resume (momentary restarts) and is not counted (breaks \(v[SnapshotSlots.breaks]))")
    }

    /// Auraliscope's own Pause Capture on the Mac and the iPad: capture restarts, `DSPWorker.resume` splices the
    /// pipeline. The same jump without the splice is what every resume did before.
    private static func localPipeline() {
        print("Pause → Resume (local capture: MeterPipeline.splice)")
        let stereo = (0..<Role.count).map { $0 < 2 }
        func measure(splicing: Bool?) -> (truePeak: Float, high: Float, breaks: Float, integrated: Float)? {
            guard let pipeline = MeterPipeline(sampleRate: rate, activeRoles: stereo, detector: FormatDetector(), streamID: 1) else { return nil }
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var high: Float = -200, lastColumn: Float = 0, tick = 0
            func feed(_ start: Int, _ count: Int, after: Bool) {
                for offset in stride(from: 0, to: count, by: chunk) {
                    let frames = (0..<min(chunk, count - offset)).map { i -> ChannelFrame in
                        var f = ChannelFrame()
                        (f.left, f.right) = frame(start + offset + i)
                        return f
                    }
                    frames.withUnsafeBufferPointer { pipeline.consume($0) }
                    tick += 1
                    values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / 60) }
                    if after, values[SnapshotSlots.spectrogramSerial] != lastColumn {
                        let bands = MeterSnapshot.spectrogramBandCount
                        high = max(high, (bands * 3 / 4..<bands).map { values[SnapshotSlots.spectrogram + $0] }.max() ?? -200)
                    }
                    lastColumn = values[SnapshotSlots.spectrogramSerial]
                }
            }
            feed(0, pauseAt, after: false)
            if splicing == true { pipeline.splice() }
            feed(pauseAt + (splicing == nil ? 0 : skipped), resumedFor, after: true)
            return (values[SnapshotSlots.heldTruePeaks + Role.left], high, values[SnapshotSlots.breaks], values[SnapshotSlots.integrated])
        }
        guard let spliced = measure(splicing: true), let joined = measure(splicing: false), let continuous = measure(splicing: nil) else {
            return check(false, "pipelines")
        }
        let db = MeterScale.decibels
        check(spliced.truePeak <= continuous.truePeak * 1.001 && spliced.high <= continuous.high + 3,
              "spliced: true peak \(db(spliced.truePeak)) dBTP, top bands \(spliced.high) dB (continuous \(db(continuous.truePeak)), \(continuous.high))")
        check(joined.truePeak > continuous.truePeak * 1.001 || joined.high > continuous.high + 20,
              "joined without the splice (before this fix): true peak \(db(joined.truePeak)) dBTP, top bands \(joined.high) dB")
        check(spliced.breaks == 0 && abs(spliced.integrated - continuous.integrated) < 0.05,
              "the splice is not a break (\(spliced.breaks)) and integrated loudness carries on (\(spliced.integrated) LUFS)")
    }
}
