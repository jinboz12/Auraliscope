// A standalone receiver for checking the plugins without Auraliscope Labs: lists the instances it hears from, and
// with --verify, subscribes to one and checks its results against Auraliscope's own analysis (the shared core,
// compiled in here) of the harness signal (see HostHarness.mm): levels, loudness, spectrum, column order, and the
// timeline. It receives no audio: there is none to receive.
//
//   ResultProbe [--seconds s] [--verify <name> --instance i] [--subscribe-after s] [--controls] [--trace]
//
// --trace without --verify   once a second, every instance's state and how much its analysis has measured; at the
//                            end, whether any instance measured while it reported an offline render (it must not)
//
// --subscribe-after s   list only for s seconds, then subscribe: the plugin must already have analysed that long
// --controls            pause, resume, reset true peak and reset the instance, checking each acknowledgement
//
// Uses the default socket, so it cannot run while Auraliscope Labs is open (and says so), unless
// AURALISCOPE_BRIDGE_SOCKET points both it and the plugins' host somewhere private.

import BridgeTransport
import Foundation

final class Inbox {
    let lock = NSLock()
    var results: [(message: ResultMessage, bytes: Int, arrived: Double)] = []
    var bytes = 0
}

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.lastIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func say(_ text: String) {
    print("[probe] \(text)")
    fflush(stdout)
}

func string<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

func sources(_ server: OpaquePointer) -> [AbrSourceInfo] {
    var infos = [AbrSourceInfo](repeating: AbrSourceInfo(), count: 64)
    let count = infos.withUnsafeMutableBufferPointer { Int(abr_server_sources(server, $0.baseAddress, 64)) }
    return Array(infos.prefix(min(count, 64)))
}

func db(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-9))) }

/// Auraliscope's own analysis of the harness signal for instance `instance` (L 997 Hz at 0.5·2⁻ⁱ, R 1499 Hz at
/// 0.25·2⁻ⁱ), 8 s at `rate`, one tick at a time.
func reference(rate: Double, channels: Int, instance: Int) -> [Float] {
    let roles = channels == 1 ? [Role.left] : [Role.left, Role.right]
    let active = (0..<Role.count).map { roles.contains($0) }
    let pipeline = MeterPipeline(sampleRate: rate, activeRoles: active, detector: FormatDetector(), streamID: 1)!
    let scale = Float(pow(2.0, -Double(instance)))
    var values = [Float](repeating: 0, count: SnapshotSlots.total)
    var position = 0
    for tick in 0..<480 {
        let end = Int((Double(tick + 1) * rate / MeterPipeline.tickRate).rounded())
        var buffer = [Float](repeating: 0, count: (end - position) * channels)
        for i in 0..<(end - position) {
            let t = Double(position + i) / rate
            buffer[i * channels] = 0.5 * scale * Float(sin(2 * .pi * 997 * t))
            if channels > 1 { buffer[i * channels + 1] = 0.25 * scale * Float(sin(2 * .pi * 1499 * t)) }
        }
        buffer.withUnsafeBufferPointer {
            pipeline.consume(interleaved: $0.baseAddress!, channels: channels, frames: end - position, roles: roles)
        }
        position = end
        values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick + 1) / 60) }
    }
    return values
}

var failures = 0
func check(_ condition: Bool, _ text: String) {
    say((condition ? "ok   " : "FAIL ") + text)
    if !condition { failures += 1 }
}

let seconds = arg("--seconds").flatMap(Double.init) ?? 5
let verify = arg("--verify")
let instance = arg("--instance").flatMap(Int.init) ?? 0
let subscribeAfter = arg("--subscribe-after").flatMap(Double.init) ?? 0
/// Asks for the Enhanced spectrogram this many seconds after subscribing (the same subscription, retuned).
let enhancedAfter = arg("--enhanced-after").flatMap(Double.init)
var enhancedAsked = false
let controls = CommandLine.arguments.contains("--controls")
let trace = CommandLine.arguments.contains("--trace")

var error = [CChar](repeating: 0, count: 256)
guard let server = abr_server_start(nil, &error, error.count) else {
    say("cannot listen: \(String(cString: error)) (quit Auraliscope Labs first)")
    exit(2)
}
let inbox = Inbox()
abr_server_attach(server, { context, payload, length in
    let inbox = Unmanaged<Inbox>.fromOpaque(context!).takeUnretainedValue()
    let message = ResultMessage.decode(UnsafeRawBufferPointer(start: payload, count: Int(length)))
    inbox.lock.lock()
    inbox.results.append((message, Int(length), CFAbsoluteTimeGetCurrent()))
    inbox.bytes += Int(length)
    inbox.lock.unlock()
}, Unmanaged.passUnretained(inbox).toOpaque())

let start = CFAbsoluteTimeGetCurrent()
var selected: AbrSourceInfo?
var listed = Set<String>()
var subscribedAt = 0.0
var newest: AbrSourceInfo?
var lastTrace = -1.0
var offlineSeen = false
var analysedWhileOffline: UInt64 = 0
var lastAnalysed: [String: (frames: UInt64, offline: Bool)] = [:]
while CFAbsoluteTimeGetCurrent() - start < seconds {
    for info in sources(server) {
        let name = string(info.source_name)
        let key = "\(name) \(info.connection_serial)"
        if !listed.contains(key) {
            listed.insert(key)
            say(String(format: "instance \"%@\" · %@ · %.0f Hz %u ch · state %u · protocol %u", name, string(info.host_name),
                       info.sample_rate, info.channels, info.state, info.protocol_version))
        }
    }
    if let verify, selected == nil, CFAbsoluteTimeGetCurrent() - start >= subscribeAfter,
       let target = sources(server).first(where: { string($0.source_name) == verify && $0.compatible != 0 && $0.channels > 0 }) {
        selected = target
        subscribedAt = CFAbsoluteTimeGetCurrent()
        withUnsafeBytes(of: target.session_id) { abr_server_select(server, $0.bindMemory(to: UInt8.self).baseAddress) }
        say("subscribed to \"\(verify)\"")
    }
    if let after = enhancedAfter, !enhancedAsked, selected != nil, CFAbsoluteTimeGetCurrent() - subscribedAt >= after {
        enhancedAsked = true
        abr_server_set_spectrogram(server, SpectrogramMode.enhanced.rawValue)
        say("asked for the Enhanced spectrogram")
    }
    if let s = selected, let info = sources(server).first(where: { $0.connection_serial == s.connection_serial }) { newest = info }
    if trace, verify == nil {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed - lastTrace >= 1 {
            lastTrace = elapsed
            for info in sources(server) {
                let name = string(info.source_name), analysed = info.frames_analysed
                let state = ["inactive", "live", "bypassed", "offline"][Int(min(info.state, 3))]
                say(String(format: "%5.1f s  %@  %@  generation %u  analysed %.2f s", elapsed, name, state, info.generation,
                           Double(analysed) / max(1, info.sample_rate)))
                if info.state == UInt32(ABR_STATE_OFFLINE) {
                    offlineSeen = true
                    if let previous = lastAnalysed[name], analysed > previous.frames, previous.offline {
                        analysedWhileOffline += analysed - previous.frames
                    }
                }
                lastAnalysed[name] = (analysed, info.state == UInt32(ABR_STATE_OFFLINE))
            }
        }
    }
    if trace, let s = selected, let info = sources(server).first(where: { $0.connection_serial == s.connection_serial }) {
        say(String(format: "state %u, generation %u, measurement %u, analysed %.2f s, results %llu", info.state, info.generation,
                   info.measurement, Double(info.frames_analysed) / max(1, info.sample_rate), info.results_received))
    }
    Thread.sleep(forTimeInterval: trace ? 0.25 : 0.05)
}

func session(_ info: AbrSourceInfo) -> [UInt8] { withUnsafeBytes(of: info.session_id) { Array($0) } }

if controls, let target = selected {
    // Commands, each acknowledged, with its effect on the results.
    func current() -> AbrSourceInfo? { sources(server).first { $0.connection_serial == target.connection_serial } }
    func latest() -> ResultMessage? { inbox.lock.lock(); defer { inbox.lock.unlock() }; return inbox.results.last?.message }
    func send(_ command: Int32, _ label: String, generation: UInt32 = 0) -> AbrSourceInfo? {
        let id = session(target).withUnsafeBufferPointer { abr_server_command(server, $0.baseAddress!, UInt32(command), generation) }
        let end = CFAbsoluteTimeGetCurrent() + 2
        while CFAbsoluteTimeGetCurrent() < end {
            if let info = current(), info.last_ack_id == id {
                say("\(label): acknowledged, outcome \(info.last_ack_outcome), generation \(info.last_ack_generation), measurement \(info.last_ack_measurement)")
                return info
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        check(false, "\(label): no acknowledgement")
        return nil
    }
    let generation = latest()?.generation ?? 0
    let paused = send(Int32(ABR_COMMAND_PAUSE), "pause")
    Thread.sleep(forTimeInterval: 0.2)
    let frozen = latest()?.framesAnalysed ?? 0
    Thread.sleep(forTimeInterval: 0.6)
    check(paused?.last_ack_measurement == UInt32(ABR_MEASUREMENT_PAUSED) && latest()?.framesAnalysed == frozen,
          "paused: nothing accumulates")
    _ = send(Int32(ABR_COMMAND_RESUME), "resume")
    Thread.sleep(forTimeInterval: 0.5)
    check((latest()?.framesAnalysed ?? 0) > frozen && latest()?.generation == generation, "resumed in the same generation")
    _ = send(Int32(ABR_COMMAND_RESET_TRUE_PEAK), "reset true peak")
    let reset = send(Int32(ABR_COMMAND_RESET), "reset", generation: generation)
    Thread.sleep(forTimeInterval: 0.5)
    check(reset?.last_ack_generation == generation + 1 && latest()?.generation == generation + 1, "reset: a new generation")
    let stale = send(Int32(ABR_COMMAND_RESET), "reset for the obsolete generation", generation: generation)
    check(stale?.last_ack_outcome == UInt32(ABR_ACK_STALE_GENERATION), "a command for an obsolete generation is refused")
    Thread.sleep(forTimeInterval: 2.5)
}

abr_server_detach(server)
guard let verify else {
    abr_server_stop(server)
    if trace {
        say("offline render seen: \(offlineSeen ? "yes" : "no"); frames analysed while offline: \(analysedWhileOffline)")
    }
    exit(0)
}
guard let target = selected else {
    say("FAIL no instance named \"\(verify)\" appeared")
    exit(1)
}
inbox.lock.lock()
let results = inbox.results
let bytes = inbox.bytes
inbox.lock.unlock()
let final = sources(server).first { $0.connection_serial == target.connection_serial } ?? newest ?? target
abr_server_stop(server)
guard let last = results.last?.message else {
    say("FAIL no results")
    exit(1)
}
let span = (results.last!.arrived - results.first!.arrived)
say(String(format: "%d results in %.1f s (%.1f per s, %.1f KB each), %.0f Hz %d ch, generation %u, %.2f s analysed",
           results.count, span, Double(results.count) / max(span, 0.001), Double(bytes) / Double(results.count) / 1024,
           last.sampleRate, last.channels, last.generation, Double(last.framesAnalysed) / last.sampleRate))
check(results.allSatisfy { $0.message.valid }, "every result is valid (schema \(last.schema), no malformed field)")
check(Double(results.count) / max(span, 0.001) > 45, "results arrive at the display rate")
if subscribeAfter > 0, let first = results.first?.message {
    check(Double(first.framesAnalysed) / first.sampleRate >= subscribeAfter - 1,
          String(format: "the first result covers what was analysed before subscribing (%.2f s)",
                 Double(first.framesAnalysed) / first.sampleRate))
}
// Order: every column serial once, in order, within a generation.
var gaps: UInt64 = 0, repeats = 0, specLast: UInt64 = 0, waveLast: UInt64 = 0, generation: UInt32 = 0, timelineBack = 0
var previousTimeline: UInt64 = 0
for r in results.map(\.message) {
    if r.generation != generation { generation = r.generation; specLast = 0; waveLast = 0; previousTimeline = 0 }
    for i in 0..<r.spectrogramColumns {
        let s = r.spectrogramFirst + UInt64(i)
        if specLast > 0 && s <= specLast { repeats += 1 } else if specLast > 0 && s > specLast + 1 { gaps += s - specLast - 1 }
        specLast = max(specLast, s)
    }
    for i in 0..<r.waveformColumns {
        let s = r.waveformFirst + UInt64(i)
        if waveLast > 0 && s <= waveLast { repeats += 1 } else if waveLast > 0 && s > waveLast + 1 { gaps += s - waveLast - 1 }
        waveLast = max(waveLast, s)
    }
    if r.timelineEnd < previousTimeline { timelineBack += 1 }
    previousTimeline = r.timelineEnd
}
if enhancedAfter != nil {
    let modes = results.map { $0.message.spectrogramMode ?? 0 }
    let switched = modes.firstIndex(of: SpectrogramMode.enhanced.rawValue)
    check(switched != nil && modes[switched!...].allSatisfy { $0 == SpectrogramMode.enhanced.rawValue },
          "the plugin switched to the Enhanced spectrogram and stayed there (from result \(switched ?? -1) of \(modes.count))")
    // Columns of the Enhanced stretch (the last results may follow the audio's end, all silence).
    let columns = results[(switched ?? results.count)...].flatMap(\.message.spectrogram)
    check(!columns.isEmpty && columns.allSatisfy { $0.isFinite && $0 >= -120 && $0 <= 12 } && columns.contains { $0 > -60 },
          "Enhanced columns hold calibrated levels (loudest \(columns.max() ?? -120) dBFS)")
}
check(gaps == 0 && repeats == 0 && timelineBack == 0,
      "spectrogram and waveform columns in order, the timeline never going back (gaps \(gaps), repeats \(repeats))")
// Values against Auraliscope's own analysis of the same signal.
if !controls {
    let v = reference(rate: last.sampleRate, channels: last.channels, instance: instance)
    let roles = last.channels == 1 ? [Role.left] : [Role.left, Role.right]
    var worst = 0.0
    func compare(_ name: String, _ plugin: Double, _ ref: Double, _ tolerance: Double) {
        worst = max(worst, abs(plugin - ref) / tolerance)
        check(abs(plugin - ref) <= tolerance, String(format: "%@: %.3f (reference %.3f)", name, plugin, ref))
    }
    for (c, role) in roles.enumerated() {
        compare("peak ch\(c + 1) dBFS", db(last.peak[c]), db(v[SnapshotSlots.peaks + role]), 0.05)
        compare("true peak max ch\(c + 1) dBTP", db(last.heldTruePeak[c]), db(v[SnapshotSlots.heldTruePeaks + role]), 0.05)
    }
    compare("momentary LUFS", Double(last.momentary), Double(v[SnapshotSlots.momentary]), 0.05)
    compare("integrated LUFS", Double(last.integrated), Double(v[SnapshotSlots.integrated]), 0.05)
    compare("dominant Hz", Double(last.dominant.first ?? 0), Double(v[SnapshotSlots.peakFrequency]), 1)
    let spectrum = (0..<MeterSnapshot.bandCount).filter { v[SnapshotSlots.spectrum + $0] > -60 }
        .map { abs(Double(last.spectrum[$0]) - Double(v[SnapshotSlots.spectrum + $0])) }.max() ?? 0
    check(spectrum <= 0.5, String(format: "spectrum within %.3f dB of the reference", spectrum))
}
say(String(format: "plugin: state %u, unanalysed %llu frames, breaks %u, results sent %llu, stale dropped %llu",
           final.state, final.frames_dropped_by_plugin, last.breaks, final.results_received, final.results_stale))
check(final.frames_dropped_by_plugin == 0, "nothing went unanalysed")
say(failures == 0 ? "PASS" : "FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
