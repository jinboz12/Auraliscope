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
            say("dropped frames (status bar): \(model.droppedFrames); receiver lost \(source?.framesLost ?? 0) in \(source?.discontinuities ?? 0) gap(s)")
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
                    if !self.model.running { self.fail("the held analysis stopped") }
                }
                return self.model.measurementBreaks >= 1 && self.condition == .streaming
            }) {
                guard self.model.measurementBreaks >= 1 else { return self.finish("no break counted: \(self.model.status.text)") }
                if self.dropConnection && !held { self.fail("the held state never showed") }
                if self.model.selectedID.bridge != session { self.fail("returned under another session") }
                if self.model.captureGeneration != generation { self.fail("the analysis restarted instead of carrying on") }
                say("returned under the same session\(held ? " after being held" : ""), analysis carried on: \(self.model.status.text)")
                self.measureWhenStreaming(then: {
                    self.checkContinuity()
                    self.finish(nil)
                })
            }
        }

        func afterFirstMeasurement() {
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
