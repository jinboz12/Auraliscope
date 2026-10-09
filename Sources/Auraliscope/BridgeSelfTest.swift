import AnalysisCore
import BridgeTransport
import Foundation

/// End-to-end check of a DAW plugin source through the real app: discovery, selection, the analysis pipeline and
/// the status line. A test host (Bridge/Tools/HostHarness) or a DAW plays a known signal into Auraliscope Bridge;
/// this reads what the meters show.
///
///   --bridge-selftest [name]        select the plugin instance with this name (default: the first one)
///   --expect-peak-db L[,R]          expected sample peak per channel in dBFS (±0.05 dB)
///   --expect-rate Hz                expected stream sample rate
///   --expect-channels n             expected channel count
///   --measure-seconds s             how long to measure (default 2)
///   --then-reconnect                afterwards, wait for the source to disconnect and return, and measure again
///   --then-rate Hz                  afterwards, wait for the stream to change to this rate, and measure again
///   --watch s --expect-seen a,b     afterwards, record the status conditions shown for s seconds; each listed
///                                   one (streaming, noAudio, bypassed, offline, inactive, disconnected) must appear
///   --no-measure                    with --watch: select and watch only (for sources that never stream, such as
///                                   an offline render)
///   --expect-breaks n               with --watch or --then-hold: the analysis reports at least n breaks, and its
///                                   integrated loudness carries on across them (not reset)
///   --then-hold                     afterwards, wait for the same live insert to reconnect (a break in its audio),
///                                   and check the analysis carried on: same session, not restarted, integrated kept
///   --drop-connection               with --then-hold: break the connection first, so the held state shows
///   --log-sources                   with --watch: print the plugin list whenever it changes
///   --measure-at-end                with --watch: measure again afterwards, with the same expectations
///   --restore                       do not select: Labs must find the saved insert by itself; then measure
///   --expect-ambiguous n            do not select: the saved insert must be ambiguous between n connected inserts,
///                                   with nothing analysed; then choose the copy (as a person would) and measure it
///   --list-bridge-sources           print the plugin instances seen within 1.5 s, then quit
///   --expect-analysed-min s         at the first measurement the plugin has analysed at least s seconds in this
///                                   generation (it measured before Labs connected, or while Labs was away)
///   --compare-reference             compare the plugin's results with Auraliscope's own analysis of the same
///                                   test signal (997 Hz and 1499 Hz sines at the --expect-peak-db levels)
///   --then-controls                 afterwards: pause, resume, reset true peak and reset the plugin's measurement
///                                   from Labs, checking each acknowledgement and its effect
///
/// Every measurement also checks that the display shows the plugin's own results: nothing is analysed here.
///
/// Prints one line per step and exits 0 when every expectation holds.
@MainActor
enum BridgeSelfTest {
    private static let arguments = CommandLine.arguments

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }

    private static func say(_ line: String) {
        print("[bridge-selftest] \(line)")
        fflush(stdout)
    }

    static func runIfRequested(model: MeterModel) {
        if arguments.contains("--list-bridge-sources") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let error = model.bridgeError { say("receiver unavailable: \(error)") }
                for source in model.bridgeSources {
                    say(String(format: "%@\t%@ %@\t%@\t%.0f Hz\t%d ch\t%@\tsession %@", source.displayName, source.host,
                               source.plugin, source.pluginVersion, source.sampleRate, source.channels,
                               "\(source.state)", String(source.sessionKey.prefix(8))))
                }
                exit(0)
            }
        }
        guard arguments.contains("--bridge-selftest") else { return }
        Run(model: model).start()
    }

    @MainActor private final class Run {
        let model: MeterModel
        let name = value(after: "--bridge-selftest")
        let expectedPeaks = value(after: "--expect-peak-db")?.split(separator: ",").compactMap { Double($0) } ?? []
        let expectedRate = value(after: "--expect-rate").flatMap(Double.init)
        let expectedChannels = value(after: "--expect-channels").flatMap(Int.init)
        let measureSeconds = value(after: "--measure-seconds").flatMap(Double.init) ?? 2
        let reconnect = arguments.contains("--then-reconnect")
        let nextRate = value(after: "--then-rate").flatMap(Double.init)
        let watchSeconds = value(after: "--watch").flatMap(Double.init)
        let expectedSeen = value(after: "--expect-seen")?.split(separator: ",").map(String.init) ?? []
        let expectedBreaks = value(after: "--expect-breaks").flatMap(Int.init)
        let hold = arguments.contains("--then-hold")
        let dropConnection = arguments.contains("--drop-connection")
        let logSources = arguments.contains("--log-sources")
        let measureAtEnd = arguments.contains("--measure-at-end")
        let restore = arguments.contains("--restore")
        let expectedAmbiguity = value(after: "--expect-ambiguous").flatMap(Int.init)
        let analysedMinimum = value(after: "--expect-analysed-min").flatMap(Double.init)
        let compareReference = arguments.contains("--compare-reference")
        let controls = arguments.contains("--then-controls")
        /// Integrated loudness at the end of the first measurement, to check it carries on across breaks.
        var firstIntegrated: Float?
        var failures = 0
        var timer: Timer?

        init(model: MeterModel) { self.model = model }

        func start() {
            if let expectedAmbiguity { return awaitAmbiguity(expectedAmbiguity) }
            if restore { return awaitRestore() }
            say("waiting for \(name.map { "\"\($0)\"" } ?? "a DAW plugin")")
            poll(timeout: 20, until: { self.target != nil }) {
                guard let device = self.target else { return self.finish("no matching plugin instance appeared") }
                say("found \"\(device.name)\" (\(device.detail), \(device.channels) ch); selecting it")
                self.model.select(device.id)
                if arguments.contains("--no-measure"), let seconds = self.watchSeconds { return self.watch(seconds) }
                self.measureWhenStreaming(then: { self.afterFirstMeasurement() })
            }
        }

        var target: InputDevice? {
            model.devices.first { $0.isBridge && (name == nil || $0.name == name) }
        }

        var condition: BridgeCondition? {
            if case let .bridge(_, condition, _, _) = model.status { return condition }
            return nil
        }

        func measureWhenStreaming(then next: @escaping () -> Void) {
            poll(timeout: 10, until: { self.condition == .streaming }) {
                guard self.condition == .streaming else { return self.finish("never streaming: \(self.model.status.text)") }
                say("streaming: \(self.model.status.text)")
                // Let the level windows fill with the new stream before measuring.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.measure(then: next) }
            }
        }

        func measure(then next: @escaping () -> Void) {
            var peaks = [Float](repeating: 0, count: 2), rmsSum = [Double](repeating: 0, count: 2)
            var samples = 0
            let end = Date().addingTimeInterval(measureSeconds)
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
                MainActor.assumeIsolated {
                    let snapshot = model.pollSnapshot()
                    for channel in 0..<2 {
                        peaks[channel] = max(peaks[channel], snapshot.channelPeaks[channel])
                        rmsSum[channel] += Double(snapshot.channelRMS[channel])
                    }
                    samples += 1
                    guard Date() >= end else { return }
                    timer.invalidate()
                    report(peaks: peaks, rms: rmsSum.map { Float($0 / Double(max(samples, 1))) })
                    next()
                }
            }
        }

        func report(peaks: [Float], rms: [Float]) {
            func db(_ value: Float) -> Double { value > 0 ? 20 * log10(Double(value)) : -.infinity }
            let channels = model.captureChannels
            let source = model.bridgeSources.first { $0.sessionKey == model.selectedID.bridge }
            say(String(format: "stream: %.0f Hz, %d ch, %@ (%@)", model.sampleRate, channels, source?.plugin ?? "?",
                       source?.host ?? "?"))
            say(String(format: "peak L %.3f dBFS, R %.3f dBFS · RMS L %.3f dBFS, R %.3f dBFS", db(peaks[0]), db(peaks[1]),
                       db(rms[0]), db(rms[1])))
            say("unanalysed frames (status bar): \(model.droppedFrames)")
            if !model.showingBridgeResults { fail("the display is not showing the plugin's results") }
            if let source, let result = model.latestBridgeResult {
                let seconds = Double(result.framesAnalysed) / max(1, result.sampleRate)
                let counters = model.bridgeResultCounters
                say(String(format: "plugin analysis: generation %u, %.1f s analysed, %@; results received %llu, shown %d, stale %llu, rejected %d; spectrogram gaps %llu, skipped %llu; waveform gaps %llu",
                           result.generation, seconds, result.measurement == .paused ? "paused" : "measuring",
                           source.resultsReceived, counters?.received ?? 0, source.resultsStale, counters?.rejected ?? 0,
                           counters?.spectrogramGaps ?? 0, counters?.spectrogramSkipped ?? 0, counters?.waveformGaps ?? 0))
                if (counters?.rejected ?? 0) > 0 { fail("results were rejected as malformed") }
                if let analysedMinimum, firstIntegrated == nil, seconds < analysedMinimum {
                    fail(String(format: "the plugin had analysed %.1f s, expected at least %.1f s", seconds, analysedMinimum))
                }
                if compareReference { compare(result) }
            } else {
                fail("no result from the plugin")
            }
            if let expectedRate, model.sampleRate != expectedRate { fail("sample rate \(model.sampleRate), expected \(expectedRate)") }
            if let expectedChannels, channels != expectedChannels { fail("\(channels) channels, expected \(expectedChannels)") }
            for (channel, expected) in expectedPeaks.enumerated() where channel < 2 {
                if abs(db(peaks[channel]) - expected) > 0.05 {
                    fail(String(format: "channel %d peak %.3f dBFS, expected %.3f", channel + 1, db(peaks[channel]), expected))
                }
            }
            // With one channel the analysis sees it on L only; R must stay silent (nothing invented).
            if channels == 1 && peaks[1] > 0 { fail("mono source produced signal on R") }
            let snapshot = model.pollSnapshot()
            say(String(format: "integrated %.2f LUFS · breaks %d · %.2f s missing", snapshot.integratedLUFS,
                       model.measurementBreaks, model.missingSeconds))
            if firstIntegrated == nil { firstIntegrated = snapshot.integratedLUFS }
        }

        /// Breaks counted and integrated loudness carried on (neither reset nor lost) since the first measurement.
        func checkContinuity() {
            let integrated = model.pollSnapshot().integratedLUFS
            say(String(format: "after the breaks: integrated %.2f LUFS (first measurement %.2f) · breaks %d · %.2f s missing",
                       integrated, firstIntegrated ?? -100, model.measurementBreaks, model.missingSeconds))
            if let expectedBreaks, model.measurementBreaks < expectedBreaks {
                fail("\(model.measurementBreaks) break(s) reported, expected at least \(expectedBreaks)")
            }
            if let first = firstIntegrated, first > -70, !(integrated > -70 && abs(integrated - first) < 0.5) {
                fail(String(format: "integrated loudness did not carry on across the breaks (%.2f → %.2f LUFS)", first, integrated))
            }
        }

        /// Labs finds the saved insert by itself (nothing is selected here), and analyses it.
        func awaitRestore() {
            say("waiting for the saved insert to be found and analysed")
            poll(timeout: 30, until: { self.condition == .streaming }) {
                guard self.condition == .streaming else { return self.finish("never restored: \(self.model.status.text)") }
                say("restored: \(self.model.status.text)")
                say("listed: \(self.model.devices.filter(\.isBridge).map(\.detail).joined(separator: " | "))")
                self.measureWhenStreaming(then: { self.finish(nil) })
            }
        }

        /// The saved insert has copies nothing tells apart: Labs must not pick one. Then the person picks the copy.
        func awaitAmbiguity(_ count: Int) {
            say("waiting for the saved insert to be ambiguous between \(count) inserts")
            poll(timeout: 20, until: { self.condition == .ambiguous(count) }) {
                guard self.condition == .ambiguous(count) else { return self.finish("never ambiguous: \(self.model.status.text)") }
                say("ambiguous: \(self.model.status.text)")
                // Give restoration time to (wrongly) pick one, then check it did not.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.model.running || self.condition != .ambiguous(count) {
                        return self.finish("analysis started without a choice: \(self.model.status.text)")
                    }
                    say("still ambiguous after 3 s, nothing analysed; listed: \(self.model.devices.filter(\.isBridge).map(\.detail).joined(separator: " | "))")
                    let copies = Set(self.model.bridgeSources.filter { $0.copiedFrom != nil }.map(\.sessionKey))
                    guard let copy = self.model.devices.first(where: { $0.bridgeSession.map(copies.contains) ?? false }) else {
                        return self.finish("no copy listed")
                    }
                    say("choosing the copy: \(copy.detail)")
                    self.model.select(copy.id)
                    self.measureWhenStreaming(then: { self.finish(nil) })
                }
            }
        }

        /// The same live insert goes away and comes back: the analysis waits (held) and carries on with a break,
        /// under the same session, without restarting.
        func awaitHold() {
            let session = model.selectedID.bridge, generation = model.captureGeneration
            let heldResult = model.latestBridgeResult
            let serial = model.bridgeSources.first { $0.sessionKey == session }?.connectionSerial
            var held = false
            if dropConnection {
                say("breaking the connection")
                model.dropBridgeConnection()
            }
            say("waiting for the same insert to reconnect")
            poll(timeout: 20, until: {
                if self.condition == .disconnectedHeld && !held {
                    held = true
                    say("held: \(self.model.status.text)")
                    if !self.model.running { self.fail("the held display stopped") }
                }
                let reconnected = self.model.bridgeSources.first { $0.sessionKey == session }.map { $0.connectionSerial != serial } ?? false
                return reconnected && (held || !self.dropConnection) && self.condition == .streaming
            }) {
                guard self.condition == .streaming else { return self.finish("never returned: \(self.model.status.text)") }
                if self.dropConnection && !held { self.fail("the held state never showed") }
                if self.model.selectedID.bridge != session { self.fail("returned under another session") }
                if self.model.captureGeneration != generation { self.fail("the display restarted instead of carrying on") }
                // The plugin went on measuring while the connection was away: the same generation, more analysed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let before = heldResult, let after = self.model.latestBridgeResult {
                        say(String(format: "plugin measurement across the reconnection: generation %u → %u, analysed %.1f s → %.1f s",
                                   before.generation, after.generation, Double(before.framesAnalysed) / before.sampleRate,
                                   Double(after.framesAnalysed) / after.sampleRate))
                        if after.generation != before.generation { self.fail("the plugin's measurement restarted") }
                        if after.framesAnalysed <= before.framesAnalysed { self.fail("the plugin's measurement did not carry on") }
                    } else {
                        self.fail("no results to compare across the reconnection")
                    }
                    say("returned under the same session\(held ? " after being held" : ""), measurement carried on: \(self.model.status.text)")
                    self.measureWhenStreaming(then: {
                        self.checkContinuity()
                        self.finish(nil)
                    })
                }
            }
        }

        func afterFirstMeasurement() {
            if controls { return runControls() }
            if hold { return awaitHold() }
            if reconnect { return awaitReturn() }
            if let nextRate { return awaitRate(nextRate) }
            if let watchSeconds { return watch(watchSeconds) }
            finish(nil)
        }

        func awaitRate(_ rate: Double) {
            say("waiting for the stream to change to \(Int(rate)) Hz")
            poll(timeout: 20, until: { self.model.sampleRate == rate && self.condition == .streaming }) {
                guard self.model.sampleRate == rate else { return self.finish("rate stayed \(self.model.sampleRate)") }
                say("analysis reconfigured: \(self.model.status.text)")
                self.measureWhenStreaming(then: { self.finish(nil) })
            }
        }

        func watch(_ seconds: Double) {
            var seen: [String] = []
            var listed = ""
            var analysedFormat = ""
            let end = Date().addingTimeInterval(seconds)
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
                MainActor.assumeIsolated {
                    if let condition, seen.last != "\(condition)" {
                        seen.append("\(condition)")
                        say("status: \(model.status.text)")
                    }
                    if logSources {
                        let now = model.devices.filter(\.isBridge).map { "\($0.detail) (\($0.bridgeSession == model.selectedID.bridge ? "analysed" : "listed"))" }
                            .joined(separator: " | ")
                        if now != listed { listed = now; say("sources: \(now.isEmpty ? "none" : now)") }
                        if let source = model.bridgeSources.first(where: { $0.sessionKey == model.selectedID.bridge }) {
                            let format = String(format: "%.0f Hz, %d ch, epoch %u; timeline jumps %u, plugin breaks %u",
                                                source.sampleRate, source.channels, source.formatEpoch,
                                                source.transportJumps, source.pluginInterruptions)
                            if format != analysedFormat { analysedFormat = format; say("analysed format: \(format)") }
                        }
                    }
                    guard Date() >= end else { return }
                    timer.invalidate()
                    say("conditions seen, in order: \(seen.joined(separator: " → "))")
                    for expected in expectedSeen where !seen.contains(expected) { fail("never showed \(expected)") }
                    if let source = model.bridgeSources.first(where: { $0.sessionKey == model.selectedID.bridge }) {
                        say("analysed insert: \(source.label(among: model.bridgeSources)); timeline jumps \(source.transportJumps), plugin breaks \(source.pluginInterruptions)")
                    }
                    if expectedBreaks != nil { checkContinuity() }
                    if measureAtEnd { return measureWhenStreaming(then: { self.finish(nil) }) }
                    finish(nil)
                }
            }
        }

        func awaitReturn() {
            say("waiting for the source to disconnect")
            poll(timeout: 30, until: { self.condition == .disconnected || self.condition == .disconnectedHeld }) {
                guard self.condition == .disconnected || self.condition == .disconnectedHeld else {
                    return self.finish("never reported disconnected")
                }
                say("disconnected: \(self.model.status.text)")
                say("waiting for it to return")
                self.poll(timeout: 30, until: { self.condition == .streaming }) {
                    self.measureWhenStreaming(then: { self.finish(nil) })
                }
            }
        }

        /// The plugin's measurement against Auraliscope's own analysis (the same shared analysis core) of the test
        /// signal, generated here at the insert's rate and levels. Steady sines: after the windows fill, every reading
        /// is independent of where the two analyses started.
        func compare(_ result: ResultMessage) {
            let amplitudes = expectedPeaks.map { Float(pow(10, $0 / 20)) }
            guard !amplitudes.isEmpty else { return fail("--compare-reference needs --expect-peak-db") }
            let channels = result.channels, rate = result.sampleRate
            let active = (0..<Role.count).map { channels == 1 ? $0 == Role.left : $0 <= Role.right }
            guard let pipeline = MeterPipeline(sampleRate: rate, activeRoles: active, detector: FormatDetector(), streamID: 1) else {
                return fail("could not build the reference analysis")
            }
            let seconds = 8.0, block = Int((rate / MeterPipeline.tickRate).rounded())
            var buffer = [Float](repeating: 0, count: block * channels)
            var values = [Float](repeating: 0, count: SnapshotSlots.total)
            var n = 0
            for tick in 0..<Int(seconds * MeterPipeline.tickRate) {
                for i in 0..<block {
                    let time = Double(n + i) / rate
                    buffer[i * channels] = amplitudes[0] * Float(sin(2 * .pi * 997 * time))
                    if channels > 1 { buffer[i * channels + 1] = amplitudes[min(1, amplitudes.count - 1)] * Float(sin(2 * .pi * 1499 * time)) }
                }
                buffer.withUnsafeBufferPointer {
                    pipeline.consume(interleaved: $0.baseAddress!, channels: channels, frames: block,
                                     roles: channels == 1 ? [Role.left] : [Role.left, Role.right])
                }
                n += block
                values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick) / MeterPipeline.tickRate) }
            }
            func db(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-9))) }
            var worst = (name: "", delta: 0.0)
            func check(_ name: String, _ plugin: Double, _ reference: Double, _ tolerance: Double) {
                let delta = abs(plugin - reference)
                say(String(format: "  %@: plugin %.3f, reference %.3f (Δ %.3f, tolerance %.3f)", name, plugin, reference, delta, tolerance))
                if delta > tolerance { fail("\(name) differs from the reference analysis") }
                if delta > worst.delta { worst = (name, delta) }
            }
            say("compared with Auraliscope's own analysis of the same signal:")
            for c in 0..<channels {
                let role = c == 0 ? Role.left : Role.right
                check("peak ch\(c + 1) dBFS", db(result.peak[c]), db(values[SnapshotSlots.peaks + role]), 0.05)
                check("RMS ch\(c + 1) dBFS", db(result.rms[c]), db(values[SnapshotSlots.rms + role]), 0.05)
                // The current window's true peak: the held maximum also holds the shared detector's onset overshoot
                // of a measurement started mid-waveform (after a reset while playing), which the reference lacks.
                check("true peak ch\(c + 1) dBTP", db(result.truePeak[c]), db(values[SnapshotSlots.truePeaks + role]), 0.05)
            }
            check("momentary LUFS", Double(result.momentary), Double(values[SnapshotSlots.momentary]), 0.05)
            check("short-term LUFS", Double(result.shortTerm), Double(values[SnapshotSlots.shortTerm]), 0.05)
            check("integrated LUFS", Double(result.integrated), Double(values[SnapshotSlots.integrated]), 0.05)
            check("dominant frequency Hz", Double(result.dominant.first ?? 0), Double(values[SnapshotSlots.peakFrequency]), 1.0)
            if channels > 1 {
                check("correlation", Double(result.correlation), Double(values[SnapshotSlots.correlation]), 0.05)
            }
            let spectrum = (0..<MeterSnapshot.bandCount).map { abs(Double(result.spectrum[$0]) - Double(values[SnapshotSlots.spectrum + $0])) }
            let loud = (0..<MeterSnapshot.bandCount).filter { values[SnapshotSlots.spectrum + $0] > -60 }
            let spectrumDelta = loud.map { spectrum[$0] }.max() ?? 0
            say(String(format: "  spectrum: %d bands above −60 dBFS, largest difference %.3f dB (tolerance 0.5)", loud.count, spectrumDelta))
            if spectrumDelta > 0.5 { fail("spectrum differs from the reference analysis") }
            // The fine bands the live curve draws (result tag 51; a plugin before build 71 sends none).
            if result.spectrumFine.count == MeterSnapshot.fineBandCount {
                let loudFine = (0..<MeterSnapshot.fineBandCount).filter { values[SnapshotSlots.spectrumFine + $0] > -60 }
                let fineDelta = loudFine.map { abs(Double(result.spectrumFine[$0]) - Double(values[SnapshotSlots.spectrumFine + $0])) }.max() ?? 0
                say(String(format: "  fine spectrum: %d bands above −60 dBFS, largest difference %.3f dB (tolerance 0.5)", loudFine.count, fineDelta))
                if loudFine.isEmpty || fineDelta > 0.5 { fail("fine spectrum differs from the reference analysis") }
            } else {
                say("  fine spectrum: not sent by this plugin (before build 71)")
            }
        }

        /// Controls from Labs, each acknowledged by the plugin: pause (nothing accumulates), resume (carries on),
        /// reset true peak, reset (a new generation, measuring afresh).
        func runControls() {
            guard let session = model.selectedID.bridge,
                  let first = model.bridgeSources.first(where: { $0.sessionKey == session }) else { return finish("no bound insert") }
            let generation = first.generation
            func ack(after previous: UInt32, _ check: @escaping (BridgeAck) -> Bool, _ label: String, then next: @escaping () -> Void) {
                poll(timeout: 5, until: {
                    guard let s = self.model.bridgeSources.first(where: { $0.sessionKey == session }) else { return false }
                    return s.acksReceived > previous
                }) {
                    guard let s = self.model.bridgeSources.first(where: { $0.sessionKey == session }), s.acksReceived > previous else {
                        return self.finish("no acknowledgement for \(label)")
                    }
                    say("\(label): acknowledged (\(s.lastAck.outcomeName), generation \(s.lastAck.generation), \(s.lastAck.measurement == UInt32(ABR_MEASUREMENT_PAUSED) ? "paused" : "measuring"))")
                    if s.lastAck.outcome != UInt32(ABR_ACK_DONE) || !check(s.lastAck) { self.fail("\(label): unexpected acknowledgement") }
                    next()
                }
            }
            var acks: UInt32 { model.bridgeSources.first(where: { $0.sessionKey == session })?.acksReceived ?? 0 }
            var analysed: UInt64 { model.latestBridgeResult?.framesAnalysed ?? 0 }
            say("controls: pausing the plugin's measurement from Labs")
            let a0 = acks
            model.toggleCapture()
            ack(after: a0, { $0.measurement == UInt32(ABR_MEASUREMENT_PAUSED) && $0.generation == generation }, "pause") {
                let frozen = analysed
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let later = self.model.latestBridgeResult
                    say(String(format: "while paused: analysed %.2f s → %.2f s, measurement %@", Double(frozen) / (later?.sampleRate ?? 1),
                               Double(later?.framesAnalysed ?? 0) / (later?.sampleRate ?? 1), later?.measurement == .paused ? "paused" : "measuring"))
                    if (later?.framesAnalysed ?? 0) != frozen { self.fail("the measurement went on accumulating while paused") }
                    if !self.model.frozen { self.fail("the display did not hold its picture") }
                    let a1 = acks
                    self.model.toggleCapture()
                    ack(after: a1, { $0.measurement == UInt32(ABR_MEASUREMENT_MEASURING) && $0.generation == generation }, "resume") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            if analysed <= frozen { self.fail("the measurement did not carry on after resuming") }
                            let a2 = acks
                            self.model.resetTruePeak()
                            ack(after: a2, { $0.generation == generation }, "reset true peak") {
                                let a3 = acks
                                let before = self.model.latestBridgeResult?.framesAnalysed ?? 0
                                self.model.resetMeasurements()
                                ack(after: a3, { $0.generation == generation + 1 }, "reset") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        let r = self.model.latestBridgeResult
                                        say(String(format: "after reset: generation %u, analysed %.2f s (was %.2f s)", r?.generation ?? 0,
                                                   Double(r?.framesAnalysed ?? 0) / (r?.sampleRate ?? 1), Double(before) / (r?.sampleRate ?? 1)))
                                        if r?.generation != generation + 1 { self.fail("results are not of the new generation") }
                                        if (r?.framesAnalysed ?? .max) >= before { self.fail("the measurement did not start afresh") }
                                        self.measureWhenStreaming(then: { self.finish(nil) })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func fail(_ message: String) {
            failures += 1
            say("FAIL \(message)")
        }

        func finish(_ error: String?) {
            if let error { fail(error) }
            say(failures == 0 ? "PASS" : "FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }

        func poll(timeout: TimeInterval, until condition: @escaping () -> Bool, then next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func check() {
                if condition() || Date() > deadline { next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
            }
            check()
        }
    }
}
