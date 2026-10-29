// A standalone receiver for checking the plugins without Auraliscope Labs: lists the instances it hears from, and
// with --verify, subscribes to one and checks its results against Auraliscope's own analysis (the shared core,
// compiled in here) of the harness signal (see HostHarness.mm): levels, loudness, spectrum, column order, and the
// timeline. It receives no audio: there is none to receive.
//
//   ResultProbe [--seconds s] [--verify <name> --instance i] [--subscribe-after s] [--controls] [--trace]
//               [--expect-roles 0,1,2,…] [--expect-layout <name>] [--immersive-after s]
//
// --expect-roles, --expect-layout   the speaker role of every channel, and the layout's name, that STATUS and the
//                                   results must carry (an immersive bus: see HostHarness --layout)
// --immersive-after s               this many seconds after subscribing, ask for every channel in the spectrum (the
//                                   display showing Immersive): the results must say so, carry every channel's band
//                                   energy, and the spectrum must equal the reference's sum of every channel
// --true-peak-onset dB              a DAW's playback starts as a step out of silence, whose inter-sample overshoot the
//                                   held true peak keeps: it may exceed the reference's continuous sine by up to this
//                                   much (never read below it); 0.05 dB otherwise
//
// --geometry below|meters        this many seconds after subscribing (--geometry-after, default 3), send a speaker
//                                 geometry (SPATIAL_CONFIG): the plugin must acknowledge it, its results must switch to the
//                                 observations (tag 58) with its hash and never return to an earlier one, put each
//                                 channel's tone at its configured place, and equal Auraliscope's own analysis with it;
//                                 this probe keeps the observations (WELCOME capability 1), so each frame must come once
//                                 and the newest received must always be the plugin's newest
// --reconfigure-after s           send a second geometry then; results must follow it and never go back
// --reconnect-after s             drop the connection then (the plugin reconnects); the geometry must come back
// --expect-legacy                 an older plugin (before build 98): no geometry is sent to it and its results keep the
//                                 bins (tag 54)
// --observations-every-result     a plugin of build 98, which sends the observations in every result whatever the
//                                 display keeps
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
func session(_ info: AbrSourceInfo) -> [UInt8] { withUnsafeBytes(of: info.session_id) { Array($0) } }

/// Auraliscope's own analysis of the harness signal for instance `instance` (channel c: 0.5/(c+1)·2⁻ⁱ at
/// 997 + 502c Hz, so L 997 Hz at 0.5, R 1499 Hz at 0.25), channel c on speaker role `roles[c]`, 8 s at `rate`, one
/// tick at a time; with `spatial`, the spectrum sums every channel.
/// The harness signal through Auraliscope's own pipeline for `ticks` 1/60 s ticks (8 s by default; longer when the
/// observations at a later window end are wanted).
func reference(rate: Double, roles: [Int], instance: Int, spatial: Bool = false, geometry: SpatialGeometry? = nil,
               spatialFrom: Int = 0, observationsAt: Set<UInt64> = [], ticks: Int = 480,
               observed: ((UInt64, [Float]) -> Void)? = nil) -> [Float] {
    let channels = roles.count
    let active = (0..<Role.count).map { roles.contains($0) }
    let pipeline = MeterPipeline(sampleRate: rate, activeRoles: active, detector: FormatDetector(), streamID: 1)!
    pipeline.spatialSpectrum = spatial && spatialFrom == 0
    if let geometry { pipeline.spatialGeometry = geometry }
    let scale = pow(2.0, -Double(instance))
    var values = [Float](repeating: 0, count: SnapshotSlots.total)
    var position = 0
    for tick in 0..<ticks {
        // A plugin turns the spatial analysis on when a display asks for it: its fields fall on the ticks counted from there.
        if spatial && tick == spatialFrom && spatialFrom > 0 { pipeline.spatialSpectrum = true }
        let end = Int((Double(tick + 1) * rate / MeterPipeline.tickRate).rounded())
        var buffer = [Float](repeating: 0, count: (end - position) * channels)
        for i in 0..<(end - position) {
            let t = Double(position + i) / rate
            for c in 0..<channels {
                buffer[i * channels + c] = Float(0.5 / Double(c + 1) * scale * sin(2 * .pi * (997 + 502 * Double(c)) * t))
            }
        }
        buffer.withUnsafeBufferPointer {
            pipeline.consume(interleaved: $0.baseAddress!, channels: channels, frames: end - position, roles: roles)
        }
        position = end
        values.withUnsafeMutableBufferPointer { pipeline.publish(into: $0.baseAddress!, now: Double(tick + 1) / 60) }
        if let observed {
            let o = SnapshotSlots.spatialObservations
            let end = values.withUnsafeBufferPointer { SpatialObservations.windowEnd($0.baseAddress! + o) }
            if values[o] == 1, observationsAt.contains(end) {
                let count = Int(values[o + SpatialObservations.Header.count])
                observed(end, Array(values[o..<(o + SpatialObservations.first + count * SpatialObservations.fields)]))
            }
        }
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
/// Asks for every channel in the spectrum this many seconds after subscribing (likewise).
let immersiveAfter = arg("--immersive-after").flatMap(Double.init)
let truePeakOnset = arg("--true-peak-onset").flatMap(Double.init)
var immersiveAsked = false
let expectedRoles = arg("--expect-roles").map { $0.split(separator: ",").compactMap { Int($0) } }
let expectedLayout = arg("--expect-layout")
let controls = CommandLine.arguments.contains("--controls")
let trace = CommandLine.arguments.contains("--trace")
let geometryKind = arg("--geometry")
let geometryAfter = arg("--geometry-after").flatMap(Double.init) ?? 3
let reconfigureAfter = arg("--reconfigure-after").flatMap(Double.init)
let reconnectAfter = arg("--reconnect-after").flatMap(Double.init)
let expectLegacy = CommandLine.arguments.contains("--expect-legacy")
let observationsEveryResult = CommandLine.arguments.contains("--observations-every-result")
var geometrySent: [SpatialGeometry] = []
var reconnected = false

/// The probe's layouts for a bus of `roles`: the rear heights (or R) below the ear plane, or every speaker in meters.
func probeGeometry(_ kind: String, roles: [Int], revision: UInt32) -> SpatialGeometry {
    var p = SpatialGeometry.standardPlacements(sidesAtNinety: SpeakerGeometry.sidesAtNinety(roles))
    p[Role.left] = SpeakerPlacement(azimuth: -38, elevation: 4, distance: 1.9)
    p[Role.right] = SpeakerPlacement(azimuth: 33, elevation: -12, distance: 2.6)
    p[Role.leftTopRear] = SpeakerPlacement(azimuth: -140, elevation: -25, distance: 2.8)
    p[Role.rightTopRear] = SpeakerPlacement(azimuth: 128, elevation: -30, distance: 3.1)
    for role in 0..<Role.count where p[role].distance == nil { p[role].distance = 2.4 + 0.05 * Double(role) }
    return SpatialGeometry(placements: p, mapping: kind == "meters" ? .positions : .directions, detail: kind == "meters" ? 28 : 20,
                           revision: revision, roles: roles)
}

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
    if let after = immersiveAfter, !immersiveAsked, selected != nil, CFAbsoluteTimeGetCurrent() - subscribedAt >= after {
        immersiveAsked = true
        abr_server_set_spectrum(server, 1)
        // And a coherence threshold of its own (SUBSCRIBE option 4), which the spatial field must report back.
        abr_server_set_coherence(server, 500)
        say("asked for every channel in the spectrum")
    }
    if let kind = geometryKind, selected != nil, let info = newest, info.role_count > 0 || info.channels > 0 {
        let elapsed = CFAbsoluteTimeGetCurrent() - subscribedAt
        let roles = info.role_count > 0 ? withUnsafeBytes(of: info.roles) { Array($0.prefix(Int(info.role_count))).map(Int.init) }
            : (info.channels == 1 ? [Role.left] : [Role.left, Role.right])
        if geometrySent.isEmpty && elapsed >= geometryAfter
            || geometrySent.count == 1 && reconfigureAfter.map({ elapsed >= $0 }) == true {
            let other = geometrySent.isEmpty ? kind : (kind == "meters" ? "below" : "meters")
            let geometry = probeGeometry(other, roles: roles, revision: UInt32(geometrySent.count + 1))
            let bytes = SpatialConfigWire.encode(geometry)
            bytes.withUnsafeBufferPointer { abr_server_set_spatial_config(server, $0.baseAddress, UInt32($0.count), geometry.revision) }
            geometrySent.append(geometry)
            say("sent the \(other) geometry, revision \(geometry.revision), hash \(String(geometry.hash, radix: 16)) (\(bytes.count) bytes)")
        }
        if let after = reconnectAfter, !reconnected, elapsed >= after, let s = selected {
            reconnected = true
            withUnsafeBytes(of: s.session_id) { abr_server_disconnect(server, $0.bindMemory(to: UInt8.self).baseAddress!, 300) }
            say("dropped the connection")
        }
    }
    if let s = selected, let info = sources(server).first(where: { session($0) == session(s) && $0.compatible != 0 }) {
        if info.connection_serial != s.connection_serial {
            // The plugin reconnected (a new connection of the same insert): select it again.
            selected = info
            withUnsafeBytes(of: info.session_id) { abr_server_select(server, $0.bindMemory(to: UInt8.self).baseAddress) }
            say("reconnected; selected again")
        }
        newest = info
    }
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
    // The test host's tones are steady: their held true peaks are reached long before the pause.
    let heldBefore = latest()?.heldTruePeak ?? []
    let paused = send(Int32(ABR_COMMAND_PAUSE), "pause")
    Thread.sleep(forTimeInterval: 0.2)
    let frozen = latest()?.framesAnalysed ?? 0
    Thread.sleep(forTimeInterval: 0.6)
    check(paused?.last_ack_measurement == UInt32(ABR_MEASUREMENT_PAUSED) && latest()?.framesAnalysed == frozen,
          "paused: nothing accumulates")
    _ = send(Int32(ABR_COMMAND_RESUME), "resume")
    Thread.sleep(forTimeInterval: 0.5)
    check((latest()?.framesAnalysed ?? 0) > frozen && latest()?.generation == generation, "resumed in the same generation")
    // The host played on while paused, so the audio after the resume does not continue the audio before it: a true
    // peak interpolated across the join would overshoot the tones' own (a click). Each channel's held true peak stays.
    let heldAfter = latest()?.heldTruePeak ?? []
    let rises = zip(heldBefore, heldAfter).map { before, after in after / max(before, 1e-9) }
    check(!heldBefore.isEmpty && heldAfter.count == heldBefore.count && rises.allSatisfy { $0 <= 1.001 },
          String(format: "resumed: no channel's held true peak rose across the resume (largest change %+.3f dB)",
                 20 * log10(Double(rises.max() ?? 1))))
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
let final = sources(server).first { session($0) == session(target) } ?? newest ?? target
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
var previousTimeline: UInt64 = 0, subscription: UInt32 = 0
for r in results.map(\.message) {
    // A new generation, or a new subscription after a reconnection (it starts from the oldest columns still held).
    if r.generation != generation || r.subscription != subscription {
        generation = r.generation; subscription = r.subscription; specLast = 0; waveLast = 0; previousTimeline = 0
    }
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
// The layout: every channel's speaker role, in STATUS and in every result of the final generation.
if let expectedRoles {
    let statusRoles = withUnsafeBytes(of: final.roles) { Array($0.prefix(Int(final.role_count))).map(Int.init) }
    check(statusRoles == expectedRoles && final.layout == UInt32(ABR_LAYOUT_SPEAKERS) && final.channels == UInt32(expectedRoles.count),
          "STATUS: \(final.channels) channels, layout \(final.layout), roles \(statusRoles)")
    let generationResults = results.map(\.message).filter { $0.generation == last.generation }
    check(generationResults.allSatisfy { $0.roles == expectedRoles && $0.channelRoles == expectedRoles && $0.layout == UInt32(ABR_LAYOUT_SPEAKERS) },
          "every result carries the roles \(last.roles)")
}
if let expectedLayout {
    check(string(final.layout_name) == expectedLayout, "the plugin names its layout \"\(string(final.layout_name))\"")
}
if immersiveAfter != nil {
    // In the final generation: a new one sums every channel once each has a full transform window (≤ 170 ms).
    let flags = results.filter { $0.message.generation == last.generation }.map { $0.message.spectrumChannels ?? 0 }
    let switched = flags.firstIndex(of: 1)
    check(switched != nil && flags[switched!...].allSatisfy { $0 == 1 },
          "the spectrum switched to every channel and stayed there (from result \(switched ?? -1) of \(flags.count) in generation \(last.generation))")
    let roles = last.channelRoles ?? []
    let silentBands = roles.indices.filter { c in
        (0..<StereoBands.count).allSatisfy { last.bandPower[c * StereoBands.count + $0] <= 0 }
    }
    check(last.bandPower.count == roles.count * StereoBands.count && silentBands.isEmpty,
          "every channel's band energy is carried (\(roles.count) channels, silent: \(silentBands))")
    // The spatial field (tag 53): it decodes for these channels, uses the threshold asked for, and puts each channel's
    // own tone (0.5/(c+1) at 997 + 502c Hz, an independent signal) at its speaker at its level, with no image.
    var field = [Float](repeating: 0, count: SpatialField.floats)
    let decoded = last.spatialField.map { bytes in
        bytes.withUnsafeBytes { raw in field.withUnsafeMutableBufferPointer { SpatialFieldWire.decode(raw, roles: roles, into: $0.baseAddress!) } }
    } ?? false
    check(decoded && field[SpatialField.status] == 1, "the spatial field arrives and decodes (\(last.spatialField?.count ?? 0) bytes)")
    check(abs(field[SpatialField.threshold] - 0.5) < 0.001, String(format: "…with the coherence threshold asked for (%.3f)", field[SpatialField.threshold]))
    var worst = 0.0, images = 0
    for (c, role) in roles.enumerated() where role != Role.lfe {
        let hz = 997.0 + 502 * Double(c)
        let band = Int(log(hz / 20) / log(1_000) * Double(SpatialField.bandCount))
        var energy: Float = 0
        for b in max(0, band - 1)...min(SpatialField.bandCount - 1, band + 1) { energy += field[SpatialField.independent(band: b, role: role)] }
        let expected = 10 * log10(0.125 / Double((c + 1) * (c + 1)))
        worst = max(worst, abs(10 * log10(Double(max(energy, 1e-20))) - expected))
    }
    for band in 0..<SpatialField.bandCount {
        for slot in 0..<SpatialField.coherentSlots where field[SpatialField.component(band: band, slot: slot)] > 0 { images += 1 }
    }
    check(worst <= 0.6 && images == 0,
          String(format: "each channel's tone at its own speaker within %.2f dB of its level, %d coherent images", worst, images))
    // Its bins (tag 54, build 87), while no geometry was sent (afterwards the observations, checked below). Every channel
    // carries only its own tone, so every bin sits on a speaker: each tone's energy at its own speaker at its level, and
    // next to nothing between speakers (where neighbouring tones' window tails meet, far below them).
    if geometrySent.isEmpty {
    var points = [Float](repeating: 0, count: SpatialPoints.floats)
    let binsDecoded = last.spatialPoints.map { bytes in
        bytes.withUnsafeBytes { raw in points.withUnsafeMutableBufferPointer { SpatialPointsWire.decode(raw, into: $0.baseAddress!) } }
    } ?? false
    check(binsDecoded && points[SpatialPoints.status] == 1, "the bins arrive and decode (\(last.spatialPoints?.count ?? 0) bytes)")
    let ninety = SpeakerGeometry.sidesAtNinety(roles)
    let speakers: [(role: Int, at: SIMD3<Float>)] = roles.compactMap { role in
        SpeakerGeometry.direction(role: role, sidesAtNinety: ninety).map { (role, SIMD3(Float($0.x), Float($0.y), Float($0.z))) }
    }
    func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }
    var worstLevel = 0.0, between: Float = 0, all: Float = 0
    for b in 0..<SpatialField.bandCount {
        for index in 0..<Int(points[SpatialPoints.count(band: b)]) {
            let o = SpatialPoints.point(band: b, index: index)
            let p = SIMD3(points[o], points[o + 1], points[o + 2])
            all += points[o + 3]
            if !speakers.contains(where: { distance($0.at, p) < 0.01 }) { between += points[o + 3] }
        }
    }
    for (c, role) in roles.enumerated() {
        guard let speaker = speakers.first(where: { $0.role == role })?.at else { continue }
        let hz = 997.0 + 502 * Double(c)
        let band = Int(log(hz / 20) / log(1_000) * Double(SpatialField.bandCount))
        var energy: Float = 0
        for b in max(0, band - 1)...min(SpatialField.bandCount - 1, band + 1) {
            for index in 0..<Int(points[SpatialPoints.count(band: b)]) {
                let o = SpatialPoints.point(band: b, index: index)
                if distance(SIMD3(points[o], points[o + 1], points[o + 2]), speaker) < 0.01 { energy += points[o + 3] }
            }
        }
        worstLevel = max(worstLevel, abs(10 * log10(Double(max(energy, 1e-20))) - 10 * log10(0.125 / Double((c + 1) * (c + 1)))))
    }
    check(worstLevel <= 0.6 && between <= 1e-4 * all,
          String(format: "each channel's tone's bins on its own speaker at its level (within %.2f dB); between speakers %.1f dB below the rest",
                 worstLevel, 10 * log10(Double(max(between, 1e-30) / max(all, 1e-30)))))
    }
}
// The spatial geometry: acknowledged, results switching to its observations and never back, each tone where its
// speaker is, and the same observations as Auraliscope's own analysis with that geometry.
if geometryKind != nil || expectLegacy {
    func hash(_ m: ResultMessage) -> UInt64? {
        guard let bytes = m.spatialObservations, bytes.count >= SpatialObservationsWire.headerBytes else { return nil }
        return bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
    }
    /// The observation frame a result carries (status, serial, window end, hash), from tag 58's header.
    struct Frame: Equatable { var status: UInt8; var serial: UInt32; var end: UInt64; var hash: UInt64 }
    func frame(_ m: ResultMessage) -> Frame? {
        guard let bytes = m.spatialObservations, bytes.count >= SpatialObservationsWire.headerBytes else { return nil }
        return bytes.withUnsafeBytes {
            Frame(status: $0[1], serial: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self)),
                  end: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)),
                  hash: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
    }
    let spatialResults = results.map(\.message).filter { $0.spatialField != nil }
    if expectLegacy {
        check(final.spatial_revision_sent == 0 && final.spatial_acks_received == 0 && (final.capabilities & UInt32(ABR_CAPABILITY_SPATIAL_CONFIG)) == 0,
              "an older plugin (no SPATIAL_CONFIG capability) is sent no geometry")
        check(!spatialResults.isEmpty && spatialResults.allSatisfy { $0.spatialObservations == nil && $0.spatialPoints != nil },
              "…and keeps sending the bins of the standard layout (tag 54), \(spatialResults.count) results")
    } else if let last = geometrySent.last {
        check(final.spatial_acks_received >= UInt32(geometrySent.count) && final.spatial_ack_revision == last.revision
                  && final.spatial_ack_outcome == UInt32(ABR_SPATIAL_APPLIED) && final.spatial_ack_hash == last.hash,
              "the plugin acknowledged revision \(final.spatial_ack_revision) with its hash (\(final.spatial_acks_received) acknowledgements)")
        // Order: legacy bins until a geometry is in force (from a plugin of build 98, the standard layout's observations
        // in flight), then each geometry's, never back. A result without observations or bins keeps the newest
        // observations (each frame is sent once); the bins after a configured geometry's observations went back, and so
        // would an earlier hash. A frame of no observations (status 0: no audio) has no geometry to order.
        let known = [SpatialGeometry.standard(roles: last.channelRolesForProbe(final)).hash] + geometrySent.map(\.hash)
        var stage = -1, regressions = 0, unknown = 0, subscription: UInt32 = 0, final_stage = -1
        for m in spatialResults {
            // A reconnection is a new subscription: the plugin starts afresh from the standard layout and its bins, and
            // takes the geometry again.
            if m.subscription != subscription { subscription = m.subscription; stage = -1 }
            guard let f = frame(m) else {
                if m.spatialPoints != nil && stage > 0 { regressions += 1 }
                continue
            }
            guard f.status == 1 else { continue }
            guard let index = known.firstIndex(of: f.hash) else { unknown += 1; continue }
            if index < stage { regressions += 1 }
            stage = max(stage, index)
            final_stage = stage
        }
        check(regressions == 0 && unknown == 0 && final_stage == known.count - 1,
              "results switch to each geometry in turn and never go back (\(spatialResults.count) results, \(regressions) regressions, \(unknown) unknown hashes)")
        // Each frame once to this probe, which keeps the observations (a plugin of build 98: in every result), and the
        // newest received always the plugin's newest: a frame is made every second tick, so it ends less than two ticks
        // before the frames a result says were analysed (an older one would be two ticks further behind).
        let twoTicks = UInt64((2 * (spatialResults.last?.sampleRate ?? 48_000) / MeterPipeline.tickRate).rounded())
        var newest: Frame?, generation: UInt32 = 0
        var carried = 0, configured = 0, repeats = 0, behind = 0, lag: UInt64 = 0
        subscription = 0
        for m in spatialResults {
            if m.subscription != subscription || m.generation != generation { subscription = m.subscription; generation = m.generation; newest = nil }
            if m.spatialPoints != nil { newest = nil; continue }  // the bins: not configured (yet, or again)
            if let f = frame(m) {
                if f == newest { repeats += 1 }
                newest = f
                carried += 1
            }
            guard let n = newest else { continue }
            configured += 1
            guard n.status == 1, m.flags & ResultFlags.idle == 0 else { continue }
            let since = m.framesAnalysed > n.end ? m.framesAnalysed - n.end : 0
            lag = max(lag, since)
            if since >= twoTicks { behind += 1 }
        }
        if observationsEveryResult {
            check(configured > 0 && carried == configured,
                  "a plugin of build 98: every configured result carries the observations (\(carried) of \(configured))")
        } else {
            check(configured > 0 && carried < configured && repeats == 0,
                  "each observation frame comes once: \(carried) of \(configured) configured results carried them, none repeating a frame")
        }
        check(behind == 0, "after every result the newest frame received is the plugin's newest (at most \(lag) frames behind the analysis; a frame every \(twoTicks))")
        // The newest result with the last geometry: each channel's tone at its speaker's configured place.
        if let m = spatialResults.last(where: { hash($0) == last.hash }), let bytes = m.spatialObservations, let roles = m.channelRoles {
            var v = [Float](repeating: 0, count: SpatialObservations.floats)
            let decoded = bytes.withUnsafeBytes { raw in v.withUnsafeMutableBufferPointer { SpatialObservationsWire.decode(raw, sampleRate: m.sampleRate, into: $0.baseAddress!) } }
            check(decoded && v[SpatialObservations.Header.mapping] == Float(last.mapping.rawValue), "the observations decode, in the geometry's mapping")
            var starts = [Int](repeating: 0, count: SpatialField.bandCount + 1)
            for b in 0..<SpatialField.bandCount { starts[b + 1] = starts[b] + Int(v[SpatialObservations.counts + b]) }
            var worst: Double = 0
            for (c, role) in roles.enumerated() where role != Role.lfe {
                guard let expected = last.position(role: role) else { continue }
                let hz = 997.0 + 502 * Double(c)
                let band = Int(log(hz / 20) / log(1_000) * Double(SpatialField.bandCount))
                // The band's strongest observation: the tone's own.
                var best: (Float, SIMD3<Double>) = (0, .zero)
                for i in starts[band]..<starts[band + 1] {
                    let o = SpatialObservations.observation(i)
                    if v[o + 3] > best.0 { best = (v[o + 3], SIMD3(Double(v[o]), Double(v[o + 1]), Double(v[o + 2]))) }
                }
                let d = best.1 - expected
                worst = max(worst, (d * d).sum().squareRoot() / last.extent(roles: roles))
            }
            check(worst <= 1e-3, String(format: "each channel's tone at its speaker's configured place, within %.2e of the layout's radius", worst))
            // Auraliscope's own analysis with the same geometry, at the same window end.
            let end = SpatialObservations.windowEnd(v)
            var local: [Float]?
            // Spatial analysis switched on later, on either parity of ticks, as the plugin's was; as far as that window end.
            let ticks = max(480, Int((Double(end) / m.sampleRate * MeterPipeline.tickRate).rounded(.up)) + 2)
            for from in [0, 20, 21] where local == nil {
                _ = reference(rate: m.sampleRate, roles: roles, instance: instance, spatial: true, geometry: last, spatialFrom: from,
                              observationsAt: [end], ticks: ticks) { _, o in local = o }
            }
            if let local {
                var worstCentre: Double = 0, worstEnergy: Double = 0
                var at = (plugin: 0, local: 0)
                // Bands within 60 dB of the loudest: below that, float rounding of the loud tones dominates either side.
                var loudest = 0.0
                for b in 0..<SpatialField.bandCount {
                    var e = 0.0
                    var start = 0
                    for k in 0..<b { start += Int(local[SpatialObservations.counts + k]) }
                    for i in start..<(start + Int(local[SpatialObservations.counts + b])) { e += Double(local[SpatialObservations.observation(i) + 3]) }
                    loudest = max(loudest, e)
                }
                for b in 0..<SpatialField.bandCount {
                    let np = Int(v[SpatialObservations.counts + b]), nl = Int(local[SpatialObservations.counts + b])
                    func summary(_ x: [Float], _ start: Int, _ n: Int) -> (Double, SIMD3<Double>) {
                        var e = 0.0, c = SIMD3<Double>.zero
                        for i in start..<(start + n) {
                            let o = SpatialObservations.observation(i)
                            e += Double(x[o + 3]); c += SIMD3(Double(x[o]), Double(x[o + 1]), Double(x[o + 2])) * Double(x[o + 3])
                        }
                        return (e, e > 0 ? c / e : .zero)
                    }
                    let p = summary(v, at.plugin, np), l = summary(local, at.local, nl)
                    at.plugin += np; at.local += nl
                    guard l.0 > loudest * 1e-6 else { continue }
                    worstEnergy = max(worstEnergy, abs(p.0 - l.0) / l.0)
                    let d = p.1 - l.1
                    worstCentre = max(worstCentre, (d * d).sum().squareRoot() / last.extent(roles: roles))
                }
                check(worstEnergy <= 1e-4 && worstCentre <= 1e-5,
                      String(format: "the plugin's observations equal Auraliscope's own (bands within 60 dB: energy within %.1e, centres within %.1e of the radius)",
                             worstEnergy, worstCentre))
            } else {
                check(false, "Auraliscope's own analysis has a frame ending where the plugin's does (\(end))")
            }
        } else {
            check(false, "a result with the last geometry arrived")
        }
    }
}
// Values against Auraliscope's own analysis of the same signal.
if !controls {
    let roles = last.channelRoles ?? [Role.left]
    let v = reference(rate: last.sampleRate, roles: roles, instance: instance, spatial: (last.spectrumChannels ?? 0) == 1)
    var worst = 0.0
    func compare(_ name: String, _ plugin: Double, _ ref: Double, _ tolerance: Double) {
        worst = max(worst, abs(plugin - ref) / tolerance)
        check(abs(plugin - ref) <= tolerance, String(format: "%@: %.3f (reference %.3f)", name, plugin, ref))
    }
    for (c, role) in roles.enumerated() {
        compare("peak ch\(c + 1) dBFS", db(last.peak[c]), db(v[SnapshotSlots.peaks + role]), 0.05)
        let held = db(last.heldTruePeak[c]), reference = db(v[SnapshotSlots.heldTruePeaks + role])
        if let onset = truePeakOnset, held > reference {
            check(held - reference <= onset, String(format: "true peak max ch%d dBTP: %.3f (reference %.3f, onset overshoot within %.2f dB)",
                                                    c + 1, held, reference, onset))
        } else {
            compare("true peak max ch\(c + 1) dBTP", held, reference, 0.05)
        }
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


extension SpatialGeometry {
    /// The roles of the probed bus, as its STATUS reports them.
    func channelRolesForProbe(_ info: AbrSourceInfo) -> [Int] {
        info.role_count > 0 ? withUnsafeBytes(of: info.roles) { Array($0.prefix(Int(info.role_count))).map(Int.init) }
            : (info.channels == 1 ? [Role.left] : [Role.left, Role.right])
    }
}
