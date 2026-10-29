import AnalysisCore
import AuraliscopeDisplayCore
import AVFoundation
import BridgeTransport
import Foundation

// Checks of the display core, run on the Mac (swift run DisplayCoreChecks). Each check prints "ok" or "FAIL"; the
// process exits non-zero when any failed. `--json` also prints the reference-signal readings for the cross-platform
// comparison with the iPad app's self-test (scripts/test-ipad.sh).

var failures = 0
func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("  ok   \(name)") } else { failures += 1; print("  FAIL \(name) \(detail())") }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

// MARK: Protocol constants against the C header the plugins and the desktop compile

print("Protocol constants")
check(BridgeProtocol.version == ABR_PROTOCOL_VERSION, "protocol version = ABR_PROTOCOL_VERSION (\(ABR_PROTOCOL_VERSION))")
check(BridgeProtocol.analysisSchema == ABR_ANALYSIS_SCHEMA, "analysis schema = ABR_ANALYSIS_SCHEMA (\(ABR_ANALYSIS_SCHEMA))")
check(BridgeProtocol.analysisSchema == StreamAnalyzer.schemaVersion, "analysis schema = StreamAnalyzer.schemaVersion")
check(BridgeProtocol.magic == ABR_MAGIC, "magic")
check(BridgeProtocol.maxPayload == Int(ABR_MAX_PAYLOAD), "max payload")
check(BridgeProtocol.maxChannels == Int(ABR_MAX_CHANNELS), "max channels")
check(BridgeProtocol.helloMinBytes == Int(ABR_HELLO_MIN_BYTES), "HELLO prefix")
check(BridgeProtocol.spatialConfigMax == Int(ABR_SPATIAL_CONFIG_MAX), "SPATIAL_CONFIG limit")
check(BridgeProtocol.serviceType == ABR_SERVICE_TYPE, "service type \(ABR_SERVICE_TYPE)")
let types: [(BridgeMessageType, Int)] = [(.hello, Int(ABR_MSG_HELLO)), (.status, Int(ABR_MSG_STATUS)), (.focus, Int(ABR_MSG_FOCUS)),
    (.result, Int(ABR_MSG_RESULT)), (.ack, Int(ABR_MSG_ACK)), (.spatialAck, Int(ABR_MSG_SPATIAL_ACK)),
    (.welcome, Int(ABR_MSG_WELCOME)), (.subscribe, Int(ABR_MSG_SUBSCRIBE)), (.unsubscribe, Int(ABR_MSG_UNSUBSCRIBE)),
    (.command, Int(ABR_MSG_COMMAND)), (.spatialConfig, Int(ABR_MSG_SPATIAL_CONFIG)),
    (.pairRequest, Int(ABR_MSG_PAIR_REQUEST)), (.pairGrant, Int(ABR_MSG_PAIR_GRANT)), (.pairDeny, Int(ABR_MSG_PAIR_DENY))]
check(types.allSatisfy { Int($0.0.rawValue) == $0.1 }, "message types")
check(BridgeCapability.results == UInt32(ABR_CAPABILITY_RESULTS) && BridgeCapability.reset == UInt32(ABR_CAPABILITY_RESET)
      && BridgeCapability.resetTruePeak == UInt32(ABR_CAPABILITY_RESET_TRUE_PEAK) && BridgeCapability.pause == UInt32(ABR_CAPABILITY_PAUSE)
      && BridgeCapability.spatialConfig == UInt32(ABR_CAPABILITY_SPATIAL_CONFIG), "capabilities")
check(BridgeCommandCode.reset.rawValue == UInt32(ABR_COMMAND_RESET) && BridgeCommandCode.pause.rawValue == UInt32(ABR_COMMAND_PAUSE)
      && BridgeCommandCode.resume.rawValue == UInt32(ABR_COMMAND_RESUME)
      && BridgeCommandCode.resetTruePeak.rawValue == UInt32(ABR_COMMAND_RESET_TRUE_PEAK), "command codes")
check(BridgeAckOutcome.wrongSession.rawValue == UInt32(ABR_ACK_WRONG_SESSION)
      && BridgeAckOutcome.staleGeneration.rawValue == UInt32(ABR_ACK_STALE_GENERATION)
      && BridgeAckOutcome.noAnalysis.rawValue == UInt32(ABR_ACK_NO_ANALYSIS), "ACK outcomes")
check(BridgeStatusFlags.subscribed == UInt32(ABR_STATUS_SUBSCRIBED), "status flags")
let txt = BridgeServiceTXT.record(receiverID: Array(repeating: 0xAB, count: 16), version: "2.1", pairingPort: nil)
check(txt["proto"] == String(ABR_PROTOCOL_VERSION) && txt["schema"] == String(ABR_ANALYSIS_SCHEMA),
      "TXT advertises proto=\(ABR_PROTOCOL_VERSION) schema=\(ABR_ANALYSIS_SCHEMA)", "\(txt)")

// MARK: Framing

print("Framing")
func hello(version: UInt32 = BridgeProtocol.version, schema: UInt32 = 1, session: UInt8 = 7) -> BridgeHello {
    BridgeHello(protocolVersion: version, pluginFormat: 1, sessionID: Array(repeating: session, count: 16),
                persistentID: Array(repeating: session &+ 1, count: 16), restoredID: nil, identityFlags: 0, hostPID: 4242,
                hostName: "REAPER", hostBundleID: "com.cockos.reaper", pluginVersion: "2.1 dev", schema: schema,
                capabilities: 31, deviceID: Array(repeating: 9, count: 16), computerName: "Studio Mac")
}
var pluginEncoder = BridgeFrameEncoder()
let stream = pluginEncoder.encode(.hello, hello().encoded()) + pluginEncoder.encode(.focus) + pluginEncoder.encode(.status, Data())
var allSplitsOK = true
for split in 0...stream.count {
    var decoder = BridgeFrameDecoder()
    let a = (try? decoder.append(stream.prefix(split))) ?? []
    let b = (try? decoder.append(stream.dropFirst(split))) ?? []
    if (a + b).map(\.type) != [1, 5, 2] || decoder.buffered != 0 { allSplitsOK = false }
}
check(allSplitsOK, "every split point of a 3-message stream yields the same messages")
var byteByByte = BridgeFrameDecoder(), count = 0
for byte in stream { count += ((try? byteByByte.append(Data([byte]))) ?? []).count }
check(count == 3, "byte-by-byte delivery")
var bad = BridgeFrameDecoder()
var threw: BridgeFramingError?
do { _ = try bad.append(Data([0, 1, 2, 3] + [UInt8](repeating: 0, count: 12))) } catch { threw = error }
check(threw == .badMagic(0x0302_0100), "wrong magic closes")
var long = BridgeFrameDecoder()
var header = Data()
withUnsafeBytes(of: BridgeProtocol.magic.littleEndian) { header.append(contentsOf: $0) }
header.append(contentsOf: [6, 0, 0, 0])
withUnsafeBytes(of: UInt32(BridgeProtocol.maxPayload + 1).littleEndian) { header.append(contentsOf: $0) }
header.append(contentsOf: [0, 0, 0, 0])
threw = nil
do { _ = try long.append(header) } catch { threw = error }
check(threw == .tooLong(UInt32(BridgeProtocol.maxPayload + 1)), "a declared length above 1 MiB closes before any payload is read")
check(long.buffered == 0, "nothing kept after the error")

// MARK: Display session

print("Display session")
func feed(_ session: BridgeDisplaySession, _ type: BridgeMessageType, _ payload: Data, encoder: inout BridgeFrameEncoder) -> BridgeDisplaySession.Output {
    session.receive(encoder.encode(type, payload), now: 1)
}
do {
    let s = BridgeDisplaySession()
    var e = BridgeFrameEncoder()
    let out = feed(s, .status, Data(), encoder: &e)
    check(out.close && { if case .failed = s.phase { return true }; return false }(), "anything but HELLO first closes")
}
do {
    let s = BridgeDisplaySession()
    var e = BridgeFrameEncoder()
    let out = feed(s, .hello, hello(version: 2).encoded(), encoder: &e)
    var d = BridgeFrameDecoder()
    let reply = out.send.flatMap { (try? d.append($0)) ?? [] }
    let replyVersion = reply.first.map { $0.payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
    check(out.close && reply.first?.kind == .welcome && replyVersion == 3,
          "a version-2 plugin gets this display's WELCOME (version 3), then the connection closes")
    check({ if case .incompatible = s.phase { return true }; return false }(), "… and is listed as incompatible, never subscribed")
    check(s.subscribe() == nil, "an incompatible plugin cannot be subscribed")
}
do {
    let s = BridgeDisplaySession()
    var e = BridgeFrameEncoder()
    _ = feed(s, .hello, hello(schema: 2).encoded(), encoder: &e)
    check({ if case .incompatible = s.phase { return true }; return false }(), "a plugin writing another analysis schema is refused")
}
// A real RESULT payload, from the analysis the plugins run.
func resultPayload(subscription: UInt32, frames: Int = 9_600, generation: UInt32 = 1) -> Data {
    let analyzer = StreamAnalyzer(sampleRate: 48_000, roles: [0, 1], generation: generation, formatEpoch: 1)!
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { let v = Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)); samples[2 * i] = v; samples[2 * i + 1] = v }
    samples.withUnsafeBufferPointer { analyzer.consume($0.baseAddress!, frames: frames, position: 0, now: 0) }
    var bytes = [UInt8](repeating: 0, count: 256 * 1024)
    let encoded = bytes.withUnsafeMutableBytes {
        analyzer.encode(into: $0.baseAddress!, capacity: $0.count, subscription: subscription, layout: 2, afterSpectrogram: 0, afterWaveform: 0)
    }
    return Data(bytes[0..<encoded.bytes])
}
do {
    let s = BridgeDisplaySession()
    var e = BridgeFrameEncoder()
    let out = feed(s, .hello, hello().encoded(), encoder: &e)
    var d = BridgeFrameDecoder()
    let reply = out.send.flatMap { (try? d.append($0)) ?? [] }
    check(s.phase == .ready && reply.map(\.kind) == [.welcome], "a version-3 plugin is welcomed")
    check(s.hello?.computerName == "Studio Mac" && s.hello?.deviceID == Array(repeating: 9, count: 16), "network HELLO fields read")
    _ = feed(s, .result, resultPayload(subscription: 1), encoder: &e)
    check(s.counters.resultsUnsubscribed == 1 && s.counters.results == 0, "results before SUBSCRIBE are dropped")
    let sub = s.subscribe()!
    let first = s.subscription
    let r1 = feed(s, .result, resultPayload(subscription: first), encoder: &e)
    check(r1.events.contains { if case .result = $0 { return true }; return false } && s.counters.results == 1, "a result of the subscription is delivered")
    _ = s.subscribe()
    let r2 = feed(s, .result, resultPayload(subscription: first), encoder: &e)
    check(!r2.events.contains { if case .result = $0 { return true }; return false } && s.counters.resultsStale == 1,
          "a result of an earlier subscription (in flight when it changed) is dropped")
    var corrupt = resultPayload(subscription: s.subscription)
    corrupt.removeLast(corrupt.count / 3)
    _ = feed(s, .result, corrupt, encoder: &e)
    check(s.counters.resultsInvalid == 1, "a truncated RESULT is not shown")
    _ = sub
    let (id, bytes) = s.command(.pause, generation: 1)!
    var cd = BridgeFrameDecoder()
    let command = try! cd.append(bytes).first!
    check(command.kind == .command, "COMMAND framed")
    var ack = FieldBuilderForChecks()
    ack.u32(1, id + 100); ack.u32(2, 3); ack.u32(3, 0); ack.u32(4, 1); ack.u32(5, 2)
    let a1 = feed(s, .ack, ack.data, encoder: &e)
    check(a1.events.isEmpty, "an ACK for a command never sent is ignored")
    var ack2 = FieldBuilderForChecks()
    ack2.u32(1, id); ack2.u32(2, 3); ack2.u32(3, 0); ack2.u32(4, 1); ack2.u32(5, 2); ack2.bytes(6, Array(repeating: 7, count: 16))
    let a2 = feed(s, .ack, ack2.data, encoder: &e)
    check(a2.events.count == 1 && s.lastAck?.measurement == 2, "the command's ACK is matched once")
    let a3 = feed(s, .ack, ack2.data, encoder: &e)
    check(a3.events.isEmpty, "… and only once")
    let again = feed(s, .hello, hello().encoded(), encoder: &e)
    check(again.close, "a second HELLO closes the connection")
}

// Untrusted input: random streams and mutated real messages never crash, never grow the buffer beyond one message,
// and either decode into valid frames or close the connection.
do {
    var rng = SystemRandomNumberGenerator()
    var survived = true
    let base = { var e = BridgeFrameEncoder(); return e.encode(.hello, hello().encoded()) + e.encode(.result, resultPayload(subscription: 1)) }()
    for round in 0..<400 {
        let s = BridgeDisplaySession()
        var data = round % 2 == 0 ? base : Data((0..<Int.random(in: 1...4096, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        if round % 2 == 0 {
            for _ in 0..<Int.random(in: 1...20, using: &rng) {
                let i = Int.random(in: 0..<data.count, using: &rng)
                data[i] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        var offset = 0
        while offset < data.count {
            let n = min(data.count - offset, Int.random(in: 1...700, using: &rng))
            let out = s.receive(data.subdata(in: offset..<(offset + n)), now: 0)
            offset += n
            if out.close { break }
        }
        if s.counters.results > 0, s.subscription == 0 { survived = false }
    }
    check(survived, "400 random and mutated streams: no crash, no unsubscribed result delivered")
}

// MARK: Messages

print("Messages")
do {
    let h = hello()
    let parsed = try! BridgeHello.parse(h.encoded())
    check(parsed == h, "HELLO round trip")
    var weird = hello()
    weird.hostName = "REAP\u{0007}ER\n"
    check((try! BridgeHello.parse(weird.encoded())).hostName == "REAPER", "control characters in names are dropped")
    var status = BridgeStatus()
    var sb = FieldBuilderForChecks()
    sb.u32(1, 1); sb.f64(3, 96_000); sb.u32(4, 12); sb.u8s(21, [0, 1, 2, 3, 4, 5, 8, 9, 6, 7, 14, 15]); sb.text(22, "7.1.4"); sb.text(12, "Mix bus")
    status.apply(sb.data)
    check(status.sampleRate == 96_000 && status.roles.count == 12 && status.layoutName == "7.1.4" && status.sourceName == "Mix bus",
          "STATUS fields read, roles kept in the bus's order")
    var oversized = FieldBuilderForChecks()
    oversized.u8s(21, [UInt8](repeating: 0, count: 40))
    status.apply(oversized.data)
    check(status.roles.count == 12, "an oversized role list is ignored")
}

// MARK: Local analysis: reference signals

print("Local analysis (reference signals)")
func sine(_ frequency: Double, dbfs: Double, seconds: Double, rate: Double, channels: Int, invertRight: Bool = false) -> [Float] {
    let frames = Int(seconds * rate)
    let amplitude = pow(10, dbfs / 20)
    var out = [Float](repeating: 0, count: frames * channels)
    for i in 0..<frames {
        let v = Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / rate))
        for c in 0..<channels { out[i * channels + c] = (invertRight && c == 1) ? -v : v }
    }
    return out
}
struct Reading: Codable { var name: String; var integrated: Float; var range: Float; var momentary: Float; var peakDB: Float; var truePeakDB: Float; var correlation: Float?; var dominant: Float? }
var readings: [Reading] = []
func analyse(_ name: String, _ samples: [Float], rate: Double, roles: [Int], block: Int = 512) -> AnalysisFrame? {
    guard let session = LocalAnalysisSession(sampleRate: rate, roles: roles, generation: 1) else { return nil }
    let channels = roles.count
    var last: AnalysisFrame?
    samples.withUnsafeBufferPointer { p in
        var offset = 0
        let frames = samples.count / channels
        while offset < frames {
            let n = min(block, frames - offset)
            session.consume(p.baseAddress! + offset * channels, frames: n, now: Double(offset) / rate)
            if let f = session.takeFrame() { last = f }
            offset += n
        }
    }
    if let last {
        readings.append(Reading(name: name, integrated: last.integrated, range: last.loudnessRange, momentary: last.momentary,
                                peakDB: decibels(last.maxHeldPeak), truePeakDB: decibels(last.maxHeldTruePeak),
                                correlation: last.correlation, dominant: last.dominantFrequency))
    }
    return last
}
// EBU Tech 3341 case 1: stereo 1 kHz at −23 dBFS per channel reads −23.0 LUFS (±0.1).
if let f = analyse("ebu-3341-1", sine(1000, dbfs: -23, seconds: 20, rate: 48_000, channels: 2), rate: 48_000, roles: [0, 1]) {
    check(near(Double(f.integrated), -23, 0.1), "EBU 3341 case 1: integrated −23.0 LUFS", "\(f.integrated)")
    check(near(Double(f.momentary), -23, 0.1) && near(Double(f.shortTerm), -23, 0.1), "… momentary and short-term −23.0", "\(f.momentary) \(f.shortTerm)")
    check(near(Double(decibels(f.maxHeldPeak)), -23, 0.05), "… sample peak −23.0 dBFS", "\(decibels(f.maxHeldPeak))")
    check(near(Double(decibels(f.maxHeldTruePeak)), -23, 0.2), "… true peak ≈ −23 dBTP", "\(decibels(f.maxHeldTruePeak))")
    check(f.correlation.map { $0 > 0.99 } ?? false, "… identical channels correlate at +1", "\(String(describing: f.correlation))")
    check(f.dominantFrequency.map { near(Double($0), 1000, 15) } ?? false, "… dominant peak at 1 kHz", "\(String(describing: f.dominantFrequency))")
    check(f.channels.map(\.name) == ["L", "R"], "stereo channels named L, R")
}
// EBU Tech 3341 case 2: −33 dBFS reads −33.0 LUFS.
if let f = analyse("ebu-3341-2", sine(1000, dbfs: -33, seconds: 20, rate: 48_000, channels: 2), rate: 48_000, roles: [0, 1]) {
    check(near(Double(f.integrated), -33, 0.1), "EBU 3341 case 2: integrated −33.0 LUFS", "\(f.integrated)")
}
if let f = analyse("anti-phase", sine(500, dbfs: -20, seconds: 3, rate: 44_100, channels: 2, invertRight: true), rate: 44_100, roles: [0, 1]) {
    check(f.correlation.map { $0 < -0.99 } ?? false, "polarity-inverted channels correlate at −1", "\(String(describing: f.correlation))")
}
if let f = analyse("mono-96k", sine(1000, dbfs: -20, seconds: 5, rate: 96_000, channels: 1), rate: 96_000, roles: [0]) {
    // A mono 1 kHz sine at −20 dBFS: one channel at weight 1, −20 − 3.01 + K-weighting at 1 kHz.
    check(near(Double(f.momentary), -23.0, 0.15), "mono at 96 kHz: −20 dBFS sine reads ≈ −23.0 LUFS momentary", "\(f.momentary)")
    check(f.channels.count == 1 && f.channels[0].name == "M", "mono is one channel, M")
}
if let f = analyse("5.1-lfe", {
    var s = sine(60, dbfs: -10, seconds: 4, rate: 48_000, channels: 6)
    for i in 0..<(s.count / 6) { for c in 0..<6 where c != 3 { s[i * 6 + c] = 0 } }
    return s
}(), rate: 48_000, roles: [0, 1, 2, 3, 4, 5]) {
    check(f.momentary < -60, "5.1 with only the LFE fed: the LFE does not count toward loudness (BS.1770)", "\(f.momentary)")
    check(f.channels.map(\.name) == ["L", "R", "C", "LFE", "Ls", "Rs"] && f.channels[3].heldPeak > 0.3, "5.1 roles kept in order; LFE level measured")
}

// The local path (encode, decode) changes no value: the frame equals the analysis' own snapshot, bit for bit.
do {
    let samples = sine(1000, dbfs: -12, seconds: 3, rate: 48_000, channels: 2)
    let analyzer = StreamAnalyzer(sampleRate: 48_000, roles: [0, 1], generation: 1, formatEpoch: 1)!
    analyzer.consume(samples, frames: samples.count / 2, position: 0, now: 0)
    let session = LocalAnalysisSession(sampleRate: 48_000, roles: [0, 1], generation: 1)!
    session.consume(samples, frames: samples.count / 2, now: 0)
    let frame = session.takeFrame()!
    let v = analyzer.snapshot
    check(frame.integrated.bitPattern == v[SnapshotSlots.integrated].bitPattern
          && frame.momentary.bitPattern == v[SnapshotSlots.momentary].bitPattern
          && frame.channels[0].truePeak.bitPattern == v[SnapshotSlots.truePeaks].bitPattern
          && frame.spectrum.elementsEqual(v[SnapshotSlots.spectrum..<(SnapshotSlots.spectrum + 64)], by: { $0.bitPattern == $1.bitPattern }),
          "local results are the analysis' own values, bit for bit (no smoothing, no rescaling)")
}

// MARK: File analysis

print("File analysis")
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("auraliscope-ebu-\(getpid()).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let samples = sine(1000, dbfs: -23, seconds: 20, rate: 48_000, channels: 2)
    let frames = samples.count / 2
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = samples[2 * i]; buffer.floatChannelData![1][i] = samples[2 * i + 1] }
    do {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                                             AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                                             AVLinearPCMIsFloatKey: true])
        try file.write(from: buffer)
    } catch { check(false, "write the reference file", "\(error)") }
    if let m = try? FileAnalyzer.analyse(url, progress: { _ in true }) {
        check(near(Double(m.integrated), -23, 0.1) && near(Double(m.samplePeak), -23, 0.05), "a 20 s EBU reference file: −23.0 LUFS, −23.0 dBFS",
              "\(m.integrated) \(m.samplePeak)")
        check(m.momentary.count == 200 || m.momentary.count == 201, "10 Hz loudness readings over 20 s", "\(m.momentary.count)")
        check(m.overs == 0 && m.codec == "WAV" && m.channels == 2, "no overs; WAV, 2 channels")
        check(m.finalFrame?.integrated == m.integrated, "the final frame carries the same integrated value")
    } else { check(false, "analyse the reference file") }
    try? FileManager.default.removeItem(at: url)
    let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("auraliscope-garbage-\(getpid()).wav")
    try? Data((0..<5000).map { UInt8($0 % 251) }).write(to: garbage)
    var error: FileAnalysisError?
    do { _ = try FileAnalyzer.analyse(garbage, progress: { _ in true }) } catch let e as FileAnalysisError { error = e } catch {}
    check(error == .unreadable, "a file that is not audio is reported as unreadable")
    try? FileManager.default.removeItem(at: garbage)
}

// MARK: Pairing

print("Pairing")
check(BridgePairing.normalise("7k2m-9qxa") == "7K2M9QXA" && BridgePairing.normalise("7K2M 9QXA") == "7K2M9QXA", "codes ignore case, dashes, spaces")
check(BridgePairing.normalise("OIL00000") == "01100000", "O reads as 0, I and L as 1")
check(BridgePairing.normalise("7K2M9QX") == nil && BridgePairing.normalise("7K2M9QXU") == nil, "short codes and U are refused")
let key = BridgePairing.pairingKey(code: "7K2M-9QXA", receiverID: Array(0..<16))
check(key.map(BridgePairing.hex) == "b4169fb2e49c245f030b67b61200e68362dba2cb75d51564bc96bcf4f05be319",
      "pairing key = PBKDF2-HMAC-SHA256(code, salt, 200000) (Python hashlib vector)")
let codes = Set((0..<200).map { _ in BridgePairing.newCode() })
check(codes.count == 200 && codes.allSatisfy { BridgePairing.normalise($0) == $0 }, "new codes are valid and distinct")
let request = BridgePairingMessages.Request(deviceID: Array(repeating: 3, count: 16), computerName: "Studio Mac", hostName: "REAPER", pluginVersion: "2.1")
check(BridgePairingMessages.Request.parse(request.encoded()) == request, "PAIR_REQUEST round trip")
let grant = BridgePairingMessages.Grant(receiverID: Array(repeating: 1, count: 16), receiverName: "iPad", key: Array(repeating: 2, count: 32))
check(BridgePairingMessages.Grant.parse(BridgePairingMessages.grant(receiverID: grant.receiverID, receiverName: grant.receiverName, key: grant.key)) == grant,
      "PAIR_GRANT round trip")
check(BridgePairingMessages.Grant.parse(BridgePairingMessages.grant(receiverID: grant.receiverID, receiverName: "x", key: [1, 2])) == nil,
      "a grant with a short key is refused")

// MARK: History and freshness

print("History and freshness")
do {
    let samples = sine(440, dbfs: -12, seconds: 2, rate: 48_000, channels: 2)
    let session = LocalAnalysisSession(sampleRate: 48_000, roles: [0, 1], generation: 1)!
    var history = SpectrogramHistory(capacity: 100)
    var columns = 0
    samples.withUnsafeBufferPointer { p in
        for offset in stride(from: 0, to: samples.count / 2, by: 1024) {
            session.consume(p.baseAddress! + offset * 2, frames: min(1024, samples.count / 2 - offset), now: 0)
            if let f = session.takeFrame() { columns += f.spectrogramColumns.count; history.append(f, source: "local") }
        }
    }
    check(columns >= 58 && columns <= 61 && history.columns.count == columns, "2 s of audio → about 60 waterfall columns, in order", "\(columns)")
    let other = LocalAnalysisSession(sampleRate: 44_100, roles: [0, 1], generation: 1)!
    let s2 = sine(440, dbfs: -12, seconds: 0.5, rate: 44_100, channels: 2)
    other.consume(s2, frames: s2.count / 2, now: 0)
    history.append(other.takeFrame()!, source: "remote:abc")
    check(history.columns.count < 20, "another source starts an empty history (nothing of the previous source kept)")
}
var st = BridgeStatus(); st.state = 1
check(RemoteFreshness.evaluate(connected: true, sinceResult: 0.1, sinceMessage: 0.1, status: st) == .live, "fresh results: Live")
check(RemoteFreshness.evaluate(connected: true, sinceResult: 3, sinceMessage: 0.2, status: st) == .idle("No audio from the host"), "status but no results: idle")
check(RemoteFreshness.evaluate(connected: true, sinceResult: 3, sinceMessage: 2.5, status: st) == .stale(seconds: 2.5), "nothing for 2.5 s: stale")
check(RemoteFreshness.evaluate(connected: false, sinceResult: 0, sinceMessage: 0, status: st) == .disconnected, "disconnected")

if CommandLine.arguments.contains("--json"), let json = try? JSONEncoder().encode(readings) {
    print("READINGS " + String(decoding: json, as: UTF8.self))
}
print(failures == 0 ? "All display core checks passed" : "\(failures) display core check(s) FAILED")
exit(failures == 0 ? 0 : 1)

/// A field writer for the checks (the core's own builder is internal).
struct FieldBuilderForChecks {
    var data = Data()
    private mutating func field(_ tag: UInt16, _ kind: UInt8, _ count: Int, _ value: [UInt8]) {
        data += [UInt8(tag & 0xFF), UInt8(tag >> 8), kind, 0]
        data += (0..<4).map { UInt8(truncatingIfNeeded: UInt32(count) >> (8 * UInt32($0))) }
        data += value
        data += [UInt8](repeating: 0, count: ((value.count + 3) & ~3) - value.count)
    }
    mutating func u32(_ tag: UInt16, _ v: UInt32) { field(tag, 2, 1, (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) }) }
    mutating func f64(_ tag: UInt16, _ v: Double) { field(tag, 6, 1, (0..<8).map { UInt8(truncatingIfNeeded: v.bitPattern >> (8 * UInt64($0))) }) }
    mutating func u8s(_ tag: UInt16, _ v: [UInt8]) { field(tag, 1, v.count, v) }
    mutating func bytes(_ tag: UInt16, _ v: [UInt8]) { field(tag, 8, v.count, v) }
    mutating func text(_ tag: UInt16, _ v: String) { field(tag, 7, v.utf8.count, Array(v.utf8)) }
}
