// Analysis at breaks in the audio, and restoration of the saved DAW plugin insert: deterministic checks of
// Auraliscope Labs' own code (the ring's break marks, the analyzers' `interrupt`, `BridgeRestoration`).
//
// Build and run: Bridge/scripts/test-analysis.sh

import AudioRing
import Foundation

private var failures = 0
private func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    print((condition ? "  ok   " : "  FAIL ") + message() + (condition ? "" : " (line \(line))"))
    if !condition { failures += 1 }
}

private let rate = 48_000.0
private let stereo = (0..<Role.count).map { $0 < 2 }

/// `count` frames of a sine on L and R from `start`, at `amplitude` (R at `rightGain` times L).
private func tone(_ frequency: Double, amplitude: Float, start: Int, count: Int, rightGain: Float = 1) -> [ChannelFrame] {
    (0..<count).map { i in
        var frame = ChannelFrame()
        frame.left = amplitude * Float(sin(2 * Double.pi * frequency * Double(start + i) / rate))
        frame.right = frame.left * rightGain
        return frame
    }
}

private func feed(_ analyzer: LoudnessAnalyzer, _ frames: [ChannelFrame]) {
    stride(from: 0, to: frames.count, by: 512).forEach { offset in
        let chunk = Array(frames[offset..<min(frames.count, offset + 512)])
        chunk.withUnsafeBufferPointer { analyzer.consume($0) }
    }
}

// ---- Ring break marks ------------------------------------------------------------------------------------------

private func ringMarks() {
    print("Ring break marks")
    guard let ring = channel_ring_create(64) else { return check(false, "ring") }
    defer { channel_ring_destroy(ring) }
    var map = [Int32](repeating: -1, count: Role.count)
    map[0] = 0
    map[1] = 1
    func write(_ values: ClosedRange<Int>) -> UInt32 {
        let samples = values.flatMap { [Float($0), -Float($0)] }
        return channel_ring_write(ring, samples, UInt32(values.count), 2, map)
    }
    var out = [ChannelFrame](repeating: ChannelFrame(), count: 128)
    var mark = ChannelRingMark()
    var marked: Int32 = 0
    func read() -> (count: UInt32, mark: ChannelRingMark?) {
        let count = channel_ring_read_marked(ring, &out, 128, &mark, &marked)
        return (count, marked != 0 ? mark : nil)
    }
    _ = write(1...10)
    channel_ring_mark(ring, 0x800, 5, 0)
    _ = write(11...20)
    let first = read()
    check(first.count == 10 && first.mark == nil && out[9].left == 10, "reading stops at the break: 10 frames, the last one 10")
    let atBreak = read(), after = read(), empty = read()
    check(atBreak.count == 0 && atBreak.mark?.reasons == 0x800 && atBreak.mark?.lost_frames == 5,
          "then the break itself, with its reasons and lost frames")
    check(after.count == 10 && out[0].left == 11 && empty.count == 0 && empty.mark == nil, "then the frames after it, then nothing")
    // The ring itself full: the frames it had to drop are a break before the next ones it takes.
    let taken = write(1...70)
    let all = read()
    check(taken == 64 && channel_ring_dropped(ring) == 6 && all.count == 64 && all.mark == nil,
          "a full ring takes 64 of 70 frames, and they read as they were")
    _ = write(71...75)
    let overflow = read(), rest = read()
    check(overflow.count == 0 && overflow.mark?.reasons == CHANNEL_RING_OVERFLOW && overflow.mark?.lost_frames == 6,
          "the 6 frames it dropped are a break before the next frames it takes")
    check(rest.count == 5 && out[0].left == 71, "…followed by those frames")
    // A consumer that never reads: marks beyond the queue merge into one.
    for index in 0..<40 { channel_ring_mark(ring, UInt32(1 << (index % 8)), 1, 0); _ = write(1...1) }
    var seen: UInt32 = 0, breaks = 0
    for _ in 0..<200 {
        let step = read()
        if let mark = step.mark { seen |= mark.reasons; breaks += 1 }
        if step.count == 0 && step.mark == nil { break }
    }
    check(seen == 0xFF && breaks <= 33, "40 marks with a stalled reader arrive as at most 33 breaks, no reason lost (\(breaks))")
    _ = write(1...3)
    channel_ring_mark(ring, 0x800, 0, 0)
    channel_ring_clear(ring)
    check(read().count == 0 && read().mark == nil, "clearing drops pending frames and breaks")
}

// ---- Loudness ---------------------------------------------------------------------------------------------------

private func loudness() {
    print("Loudness across a break")
    guard let continuous = LoudnessAnalyzer(sampleRate: rate, activeRoles: stereo),
          let broken = LoudnessAnalyzer(sampleRate: rate, activeRoles: stereo) else { return check(false, "analyzers") }
    let first = tone(997, amplitude: 0.1, start: 0, count: 240_000)
    feed(continuous, first)
    feed(broken, first)
    let before = broken.loudnessValues()
    broken.interrupt()
    let after = broken.loudnessValues()
    check(after.momentary == -100 && after.shortTerm == -100, "momentary and short-term read no value at the break")
    check(after.integrated == before.integrated && after.range == before.range,
          "integrated (\(before.integrated) LUFS) and loudness range are kept")
    feed(broken, tone(997, amplitude: 0.1, start: 0, count: 16_800))
    check(broken.loudnessValues().momentary == -100, "momentary still has no value after 350 ms of new audio")
    feed(broken, tone(997, amplitude: 0.1, start: 16_800, count: 2_400))
    check(abs(broken.loudnessValues().momentary - before.momentary) < 0.05,
          "after 400 ms it reads the tone again (\(broken.loudnessValues().momentary) vs \(before.momentary) LUFS)")
    check(broken.loudnessValues().shortTerm == -100, "short-term waits for 3 s of new audio")
    let second = tone(997, amplitude: 0.1, start: 19_200, count: 220_800)
    feed(broken, second)
    feed(continuous, tone(997, amplitude: 0.1, start: 240_000, count: 240_000))
    let a = continuous.loudnessValues().integrated, b = broken.loudnessValues().integrated
    check(abs(a - b) < 0.02, "a steady tone integrates the same with or without the break (\(b) vs \(a) LUFS)")
    check(broken.loudnessValues().shortTerm > -100, "short-term reads again after 3 s")

    // No window spans the break: 2.05 s of a loud tone, a break in the middle of a 100 ms segment, then 0.4 s
    // of a quiet one. Momentary then reads the quiet tone alone, exactly as an analysis that only ever heard it.
    guard let spanning = LoudnessAnalyzer(sampleRate: rate, activeRoles: stereo),
          let separate = LoudnessAnalyzer(sampleRate: rate, activeRoles: stereo),
          let fresh = LoudnessAnalyzer(sampleRate: rate, activeRoles: stereo) else { return }
    let loud = tone(997, amplitude: 0.5, start: 0, count: 98_400), quiet = tone(1499, amplitude: 0.05, start: 0, count: 19_200)
    feed(separate, loud)
    separate.interrupt()
    feed(separate, quiet)
    feed(fresh, quiet)
    feed(spanning, loud)
    feed(spanning, quiet)
    let alone = fresh.loudnessValues().momentary, split = separate.loudnessValues().momentary,
        joined = spanning.loudnessValues().momentary
    check(abs(split - alone) < 0.001, "after a break, momentary is the quiet tone's alone (\(split) = \(alone) LUFS)")
    check(abs(joined - alone) > 0.5, "without the break a 100 ms segment would span both tones (\(joined) LUFS)")
}

// ---- True peak --------------------------------------------------------------------------------------------------

private func truePeak() {
    print("True peak at a break")
    // A 10 kHz sine at 0.9 (faded in, so its own start does not ring), cut off at a crest; after the break the
    // same sine inverted. Each side reads 0.9; a meter that joined them, or padded the cut with silence, would
    // read an overshoot the audio never had.
    let fade = 2_000, length = 9_600
    func signal(_ sign: Float, fadeIn: Bool) -> [Float] {
        (0..<length).map { n in
            let envelope = fadeIn && n < fade ? Float(0.5 - 0.5 * cos(Double.pi * Double(n) / Double(fade))) : 1
            return sign * 0.9 * envelope * Float(sin(2 * Double.pi * 10_000 * Double(n) / rate + 0.3))
        }
    }
    let a = signal(1, fadeIn: true), b = signal(-1, fadeIn: false)
    func measure(breaking: Bool) -> Float {
        let detector = TruePeakDetector(sampleRate: rate, capacity: 1_024)
        var held: Float = 0
        for part in [a, b] {
            if breaking && part == b { detector.interrupt() }
            part.withUnsafeBufferPointer { buffer in
                for offset in stride(from: 0, to: buffer.count, by: 1_024) {
                    let count = min(1_024, buffer.count - offset)
                    let peak = buffer[offset..<(offset + count)].map(abs).max() ?? 0
                    detector.process(role: 0, signal: buffer.baseAddress! + offset, count: count, samplePeak: peak)
                    held = max(held, detector.take(role: 0))
                }
            }
        }
        return held
    }
    let separate = measure(breaking: true), joined = measure(breaking: false)
    check(separate <= 0.9 * 1.002 && separate >= 0.9 * 0.998,
          "with the break, the true peak is the sine's own (\(MeterScale.decibels(separate)) dBTP, crest \(MeterScale.decibels(0.9)))")
    check(joined > 0.9 * 1.01, "joined across the cut, the interpolation would overshoot (\(MeterScale.decibels(joined)) dBTP)")
}

// ---- Spectrum, waveform, pipeline -------------------------------------------------------------------------------

private func displays() {
    print("Spectrum, waveform and the pipeline at a break")
    guard let spectrum = SpectrumAnalyzer(sampleRate: rate, recording: stereo) else { return check(false, "spectrum") }
    func consume(_ frames: [ChannelFrame]) { frames.withUnsafeBufferPointer { spectrum.consume($0) } }
    consume(tone(1_000, amplitude: 0.5, start: 0, count: 16_384))
    check(spectrum.ready, "a full FFT window before the break")
    spectrum.interrupt()
    consume(tone(3_000, amplitude: 0.5, start: 0, count: SpectrumAnalyzer.fftSize - 1))
    check(!spectrum.ready, "after it, no transform until the window holds new audio alone")
    consume(tone(3_000, amplitude: 0.5, start: SpectrumAnalyzer.fftSize - 1, count: 1))
    var bands = [Float](repeating: -120, count: MeterSnapshot.bandCount)
    let dominant = spectrum.refreshSpectrum(into: &bands, roles: [Role.left, Role.right])
    check(spectrum.ready && abs(dominant.frequency - 3_000) < 30, "then the new tone alone (\(Int(dominant.frequency)) Hz)")

    let waveform = WaveformEnvelope(sampleRate: rate, activeRoles: stereo)
    let constant = [ChannelFrame](repeating: { var f = ChannelFrame(); f.left = 0.5; f.right = 0.5; return f }(), count: 480)
    constant.withUnsafeBufferPointer { waveform.consume($0) }
    let serial = waveform.serial
    waveform.interrupt(missingFrames: 0)
    var columns = [Float](repeating: 0, count: WaveformEnvelope.publishedFloats)
    columns.withUnsafeMutableBufferPointer { waveform.write(into: $0.baseAddress!) }
    let per = WaveformEnvelope.valuesPerColumn, last = WaveformEnvelope.publishedColumns - 1
    let notch = (0..<12).allSatisfy { columns[(last - $0) * per + 1] == 0 }
    check(waveform.serial == serial + 13 && notch && columns[(last - 12) * per + 1] == 0.5,
          "the waveform closes its column and adds a 12-column (50 ms) notch")
    let before = waveform.serial
    waveform.interrupt(missingFrames: 48_000)
    check(waveform.serial == before + WaveformEnvelope.notchColumns.upperBound,
          "a second known missing marks at most \(WaveformEnvelope.notchColumns.upperBound) columns (200 ms)")

    guard let pipeline = MeterPipeline(sampleRate: rate, activeRoles: stereo, detector: FormatDetector(), streamID: 1) else {
        return check(false, "pipeline")
    }
    var values = [Float](repeating: 0, count: SnapshotSlots.total)
    tone(997, amplitude: 0.5, start: 0, count: 4_800).withUnsafeBufferPointer { pipeline.consume($0) }
    values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: 0) }
    check(values[SnapshotSlots.breaks] == 0, "no break reported before one happens")
    pipeline.interrupt(lostFrames: 4_800, idleMilliseconds: 500)
    pipeline.interrupt(lostFrames: 0, idleMilliseconds: 0)
    values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: 1 / 60) }
    check(values[SnapshotSlots.breaks] == 2 && abs(values[SnapshotSlots.missing] - 0.6) < 0.0001,
          "the snapshot counts the breaks (\(values[SnapshotSlots.breaks])) and the time known missing (\(values[SnapshotSlots.missing]) s)")
    check(SnapshotSlots.total == Int(METER_SNAPSHOT_FLOATS), "snapshot layout and C buffer agree (\(SnapshotSlots.total) floats)")
}

// ---- Restoration ------------------------------------------------------------------------------------------------

private func restoration() {
    print("Finding the saved insert again")
    func insert(_ session: String, _ persistent: String, copiedFrom: String? = nil, name: String = "Vocals",
                track: String = "Vocals", channel: String = "", host: String = "com.cockos.reaper", plugin: String = "VST3") -> BridgeCandidate {
        BridgeCandidate(session: session, persistent: persistent, copiedFrom: copiedFrom, name: name, trackName: track,
                        channelID: channel, hostBundleID: host, plugin: plugin)
    }
    let original = insert("S1", "P1")
    var saved = BridgeSelection(original)
    func decide(_ candidates: [BridgeCandidate], matchingSession: Bool = true) -> BridgeRestoration {
        BridgeRestoration.decide(for: saved, among: candidates, matchingSession: matchingSession)
    }
    check(decide([]) == .wait, "nothing connected: wait")
    check(decide([insert("S9", "P9"), original]) == .bind("S1"), "the same live insert is bound at once (Labs restarted)")
    check(decide([insert("S2", "P1")]) == .bind("S2"), "the only insert holding the saved identity is bound (project reopened)")
    check(decide([insert("S3", "P3", copiedFrom: "P1")]) == .wait, "a copy alone never inherits the selection")
    check(decide([insert("S2", "P1"), insert("S3", "P3", copiedFrom: "P1")]) == .ambiguous(["S2", "S3"]),
          "the holder beside an indistinguishable copy: ambiguous, nothing picked")
    check(decide([insert("S2", "P1"), insert("S3", "P3", copiedFrom: "P1", track: "Vocals 2")]) == .bind("S2"),
          "…unless the saved track name singles the holder out")
    check(decide([insert("S2", "P1", track: "Vocals copy"), insert("S3", "P3", copiedFrom: "P1")]) == .ambiguous(["S2", "S3"]),
          "…and never binds a copy that the context happens to prefer")
    check(decide([insert("S2", "P1"), insert("S4", "P1", host: "com.steinberg.cubase15")]) == .bind("S2"),
          "two DAWs hold the identity: the saved host decides")
    check(decide([insert("S2", "P1"), insert("S4", "P1")]) == .ambiguous(["S2", "S4"]),
          "two identical holders in two DAWs: ambiguous")
    saved = BridgeSelection(insert("S1", "P1", channel: "track-17"))
    check(decide([insert("S2", "P1", track: "Renamed", channel: "track-17"), insert("S4", "P1", channel: "track-18")]) == .bind("S2"),
          "a host channel ID, when both have one, decides alone (even after a rename)")
    saved = BridgeSelection(original)
    check(decide([original, insert("S3", "P3", copiedFrom: "P1")], matchingSession: false) == .ambiguous(["S1", "S3"]),
          "re-checking an automatic choice ignores the session: a copy arriving makes it ambiguous")
    var watched = BridgeSelection(original)
    check(watched.noteCopies(among: [original, insert("S3", "P3", copiedFrom: "P1"), insert("S5", "P5")]) && watched.knownCopies == ["P3"],
          "a copy appearing beside the bound insert is noted (and nothing else is)")
    check(!watched.noteCopies(among: [original, insert("S3", "P3", copiedFrom: "P1")]), "…once")
    saved = watched
    check(decide([insert("S2", "P1"), insert("S3", "P3", copiedFrom: "P1")]) == .bind("S2"),
          "the original reloaded beside a copy seen being made: the copy is known, the holder is bound")
    check(decide([insert("S2", "P1"), insert("S3", "P3", copiedFrom: "P1"), insert("S6", "P6", copiedFrom: "P1")]) == .ambiguous(["S2", "S6"]),
          "…but a copy never seen stays a claimant")
    check(decide([insert("S3", "P3", copiedFrom: "P1")]) == .wait, "…and a known copy alone still never inherits it")
    for n in 0..<40 { _ = watched.noteCopies(among: [insert("C\(n)", "Q\(n)", copiedFrom: "P1")]) }
    check(watched.knownCopies?.count == BridgeSelection.knownCopiesLimit && watched.knownCopies?.last == "Q39",
          "the known copies are bounded (the newest kept)")
    let legacy = BridgeSelection(persistent: "P1", name: "Vocals")
    check(BridgeRestoration.decide(for: legacy, among: [insert("S2", "P1", track: "Anything")]) == .bind("S2"),
          "a selection saved by build 1 (identity and name only) still finds its insert")
    let defaults = UserDefaults(suiteName: "AnalysisBreakTests.\(getpid())")!
    saved.save(to: defaults)
    check(BridgeSelection.load(from: defaults) == saved, "the selection survives saving and loading")
    defaults.set(Data(#"{"session":"S1","persistent":"P1","name":"Vocals","trackName":"","channelID":"","hostBundleID":"","plugin":""}"#.utf8),
                 forKey: BridgeSelection.defaultsKey)
    check(BridgeSelection.load(from: defaults)?.knownCopies == nil, "a selection saved without known copies still loads")
    defaults.removePersistentDomain(forName: "AnalysisBreakTests.\(getpid())")
}

@main
struct AnalysisBreakTests {
    static func main() {
        ringMarks()
        loudness()
        truePeak()
        displays()
        restoration()
        print(failures == 0 ? "\nAll analysis checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
