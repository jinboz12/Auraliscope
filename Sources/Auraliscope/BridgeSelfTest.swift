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
        var failures = 0
        var timer: Timer?

        init(model: MeterModel) { self.model = model }

        func start() {
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
        }

        func afterFirstMeasurement() {
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
            let end = Date().addingTimeInterval(seconds)
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
                MainActor.assumeIsolated {
                    if let condition, seen.last != "\(condition)" {
                        seen.append("\(condition)")
                        say("status: \(model.status.text)")
                    }
                    guard Date() >= end else { return }
                    timer.invalidate()
                    say("conditions seen, in order: \(seen.joined(separator: " → "))")
                    for expected in expectedSeen where !seen.contains(expected) { fail("never showed \(expected)") }
                    finish(nil)
                }
            }
        }

        func awaitReturn() {
            say("waiting for the source to disconnect")
            poll(timeout: 30, until: { self.condition == .disconnected }) {
                guard self.condition == .disconnected else { return self.finish("never reported disconnected") }
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
