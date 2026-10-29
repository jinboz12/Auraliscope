import AuraliscopeDisplayCore
import Foundation
import Network
import Security

// A network display on the Mac, for automated tests of the Bridge's network carrier with the real plugin binary
// (Bridge/scripts/test-network.sh): the iPad app's receiving path (the same AuraliscopeDisplayCore session, TLS-PSK
// listener and DNS-SD advertisement), without the UI. It pairs (approving automatically), subscribes to the first
// compatible plugin, checks every result, and measures.
//
//   BridgeNetworkProbe --state <dir> --name <service name> [--pair-code ABCD1234] [--seconds 20]
//                      [--stall-at s --stall-for s] [--drop-at s] [--rtt]
//
// --stall-*: stop reading for a while (a slow or backgrounded display); TCP then holds the plugin back.
// --drop-at: close the connection (the display going away); the plugin reconnects by itself.
// --rtt: every 100 ms a COMMAND naming no instance (answered WRONG_SESSION, changing nothing); the ACK's round trip.

var arguments: [String: String] = [:]
var key: String?
for argument in CommandLine.arguments.dropFirst() {
    if argument.hasPrefix("--") { key = String(argument.dropFirst(2)); arguments[key!] = "1" } else if let k = key { arguments[k] = argument; key = nil }
}
let stateDir = URL(fileURLWithPath: arguments["state"] ?? NSTemporaryDirectory() + "bridge-probe")
let serviceName = arguments["name"] ?? "Bridge Probe"
let seconds = Double(arguments["seconds"] ?? "20") ?? 20
let stallAt = arguments["stall-at"].flatMap(Double.init), stallFor = Double(arguments["stall-for"] ?? "5") ?? 5
let dropAt = arguments["drop-at"].flatMap(Double.init)
let measureRTT = arguments["rtt"] != nil
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

struct ProbeState: Codable { var receiverID: String; var macs: [String: String] }
let stateFile = stateDir.appendingPathComponent("probe-state.json")
var state = (try? JSONDecoder().decode(ProbeState.self, from: Data(contentsOf: stateFile)))
    ?? ProbeState(receiverID: BridgePairing.hex(BridgePairing.randomBytes(16)), macs: [:])
func saveState() { try? JSONEncoder().encode(state).write(to: stateFile) }
saveState()
let receiverID = BridgePairing.bytes(hex: state.receiverID)!

func parameters(_ keys: [([UInt8], [UInt8])]) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    for (k, id) in keys {
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, k.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
                                                id.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData)
    }
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: tls, tcp: tcp)
}

let queue = DispatchQueue(label: "probe")
let start = Date()
func t() -> Double { Date().timeIntervalSince(start) }
func log(_ s: String) { print(String(format: "[%6.2f] ", t()) + s); fflush(stdout) }

// MARK: Measurements

struct Stats {
    var results = 0, invalid = 0, bytes = 0, columns = 0, columnGaps: UInt64 = 0, dropped: UInt64 = 0
    var maxGap = 0.0, lastResult: Double?, gaps: [Double] = []
    var rtts: [Double] = []
    var generations = Set<UInt32>()
    var lastSerial: UInt64 = 0
    var connections = 0, disconnects = 0, refusedHandshakes = 0
    var lastFrame: AnalysisFrame?
    var host = "", plugin = "", computer = ""
}
var stats = Stats()
var listener: NWListener!
var pairingListener: NWListener?
var connection: NWConnection?
var session = BridgeDisplaySession()
var rawDecoder = BridgeFrameDecoder()
var rawEncoder = BridgeFrameEncoder()
var rttSent: [UInt32: Double] = [:]
var stalled = false
var nextRTTID: UInt32 = 0x7000_0000

func startListener() {
    var keys = state.macs.compactMap { (device, key) in BridgePairing.bytes(hex: key).map { ($0, Array(device.utf8)) } }
    if keys.isEmpty { keys = [(BridgePairing.randomBytes(32), Array("nobody".utf8))] }
    listener?.cancel()
    listener = try! NWListener(using: parameters(keys))
    listener.service = NWListener.Service(name: serviceName, type: BridgeProtocol.serviceType, domain: nil,
                                          txtRecord: NWTXTRecord(BridgeServiceTXT.record(receiverID: receiverID, version: "probe",
                                                                                         pairingPort: pairingListener?.port?.rawValue)))
    listener.stateUpdateHandler = { s in if case .ready = s { log("listening on \(listener.port!.rawValue) as \"\(serviceName)\" rid \(state.receiverID)") } }
    listener.newConnectionHandler = { accept($0) }
    listener.start(queue: queue)
}

func accept(_ c: NWConnection) {
    if let old = connection { old.cancel() }
    connection = c
    session = BridgeDisplaySession()
    rawDecoder = BridgeFrameDecoder()
    c.stateUpdateHandler = { s in
        switch s {
        case .ready: stats.connections += 1; log("connection ready"); receive(c)
        case .failed(let e), .waiting(let e):
            if case .tls = e { stats.refusedHandshakes += 1 }
            log("connection failed: \(e)")
        case .cancelled: if connection === c { stats.disconnects += 1 }
        default: break
        }
    }
    c.start(queue: queue)
}

func send(_ data: Data) { connection?.send(content: data, completion: .contentProcessed { _ in }) }

func receive(_ c: NWConnection) {
    guard !stalled else { queue.asyncAfter(deadline: .now() + 0.05) { receive(c) }; return }
    c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
        guard c === connection else { return }
        if let data {
            stats.bytes += data.count
            let now = ProcessInfo.processInfo.systemUptime
            let out = session.receive(data, now: now)
            out.send.forEach(send)
            if let raw = try? rawDecoder.append(data) {
                for m in raw where m.kind == .ack {
                    if let ack = BridgeAckMessage.parse(m.payload), let sent = rttSent.removeValue(forKey: ack.commandID) {
                        stats.rtts.append(now - sent)
                    }
                }
            }
            for event in out.events {
                switch event {
                case .hello(let h):
                    stats.host = h.hostName; stats.plugin = h.pluginVersion; stats.computer = h.computerName ?? ""
                    log("HELLO protocol \(h.protocolVersion) schema \(h.schema) from \(h.computerName ?? "?") \(h.hostName) \(h.pluginVersion) instance \(h.instanceTag) phase \(session.phase)")
                    // A new subscription starts from the oldest column the plugin holds (PROTOCOL.md): serials start over.
                    stats.lastSerial = 0
                    if session.phase == .ready, let bytes = session.subscribe() { send(bytes); log("SUBSCRIBE \(session.subscription)") }
                case .result(let f):
                    stats.results += 1
                    if let last = stats.lastResult { let gap = now - last; stats.maxGap = max(stats.maxGap, gap); stats.gaps.append(gap) }
                    stats.lastResult = now
                    stats.generations.insert(f.generation)
                    stats.columns += f.spectrogramColumns.count
                    stats.dropped += f.spectrogramDropped
                    if !f.spectrogramColumns.isEmpty {
                        if stats.lastSerial != 0 && f.spectrogramFirst > stats.lastSerial + 1 { stats.columnGaps += f.spectrogramFirst - stats.lastSerial - 1 }
                        if f.spectrogramFirst <= stats.lastSerial && stats.lastSerial != 0 && stats.generations.count == 1 { stats.invalid += 1 }
                        stats.lastSerial = f.spectrogramFirst + UInt64(f.spectrogramColumns.count) - 1
                    }
                    stats.lastFrame = f
                case .status, .ack, .focus: break
                }
            }
            if out.close { log("session closed: \(session.phase)"); c.cancel(); return }
        }
        if complete || error != nil { log("connection ended \(String(describing: error))"); c.cancel(); return }
        receive(c)
    }
}

// MARK: Pairing (approved automatically)

func openPairing(code: String) {
    let key = BridgePairing.pairingKey(code: code, receiverID: receiverID)!
    let p = try! NWListener(using: parameters([(key, BridgePairing.pairingIdentity)]))
    pairingListener = p
    p.stateUpdateHandler = { s in if case .ready = s { log("pairing open on \(p.port!.rawValue), code \(code)"); startListener() } }
    p.newConnectionHandler = { c in
        var decoder = BridgeFrameDecoder(maxPayload: 4096)
        var encoder = BridgeFrameEncoder()
        c.stateUpdateHandler = { s in if case .failed(let e) = s { log("pairing handshake failed: \(e)") } }
        c.start(queue: queue)
        func next() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let data, let messages = try? decoder.append(data) {
                    for m in messages where m.kind == .pairRequest {
                        guard let request = BridgePairingMessages.Request.parse(m.payload) else { continue }
                        let mac = BridgePairing.randomBytes(32)
                        state.macs[BridgePairing.hex(request.deviceID)] = BridgePairing.hex(mac)
                        saveState()
                        log("paired \(request.computerName) (\(BridgePairing.hex(request.deviceID)))")
                        c.send(content: encoder.encode(.pairGrant, BridgePairingMessages.grant(receiverID: receiverID, receiverName: serviceName, key: mac)),
                               completion: .contentProcessed { _ in
                                   queue.asyncAfter(deadline: .now() + 0.2) { c.cancel(); p.cancel(); pairingListener = nil; startListener() }
                               })
                        return
                    }
                }
                if error == nil { next() }
            }
        }
        next()
    }
    p.start(queue: queue)
}

if let code = arguments["pair-code"] { openPairing(code: code) } else { startListener() }

// MARK: Schedule

var lastLog = 0.0, lastResults = 0, lastBytes = 0
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
timer.setEventHandler {
    let now = t()
    if let stallAt, !stalled, now >= stallAt, now < stallAt + stallFor { stalled = true; log("STALL: not reading for \(stallFor) s") }
    if stalled, let stallAt, now >= stallAt + stallFor { stalled = false; log("STALL over") }
    if let dropAt, now >= dropAt, now < dropAt + 0.1, let c = connection { log("DROP: closing the connection"); c.cancel(); connection = nil }
    if measureRTT, !stalled, session.phase == .ready {
        nextRTTID &+= 1
        rttSent[nextRTTID] = ProcessInfo.processInfo.systemUptime
        send(rawEncoder.encode(.command, BridgeDisplayMessages.command(id: nextRTTID, code: .resetTruePeak, sessionID: [UInt8](repeating: 0, count: 16), generation: 0)))
    }
    if now - lastLog >= 1 {
        let f = stats.lastFrame
        log(String(format: "%3d results/s %7.1f kB/s · I %@ LUFS M %@ · gen %@ · ch %d · cols %d",
                   stats.results - lastResults, Double(stats.bytes - lastBytes) / 1000 / (now - lastLog),
                   f.map { String(format: "%.1f", $0.integrated) } ?? "-", f.map { String(format: "%.1f", $0.momentary) } ?? "-",
                   f.map { String($0.generation) } ?? "-", f?.channels.count ?? 0, stats.columns))
        lastLog = now; lastResults = stats.results; lastBytes = stats.bytes
    }
    if now >= seconds {
        let sortedGaps = stats.gaps.sorted(), rtts = stats.rtts.sorted()
        func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] * 1000 }
        let summary: [String: Any] = [
            "results": stats.results, "invalidResults": stats.invalid + session.counters.resultsInvalid,
            "staleResults": session.counters.resultsStale, "bytes": stats.bytes, "resultsPerSecond": Double(stats.results) / seconds,
            "kBPerSecond": Double(stats.bytes) / 1000 / seconds, "maxGapMs": stats.maxGap * 1000, "p50GapMs": pct(sortedGaps, 0.5),
            "p99GapMs": pct(sortedGaps, 0.99), "rttCount": rtts.count, "rttP50Ms": pct(rtts, 0.5), "rttP95Ms": pct(rtts, 0.95),
            "rttMaxMs": (rtts.last ?? 0) * 1000, "spectrogramColumns": stats.columns, "columnGaps": stats.columnGaps,
            "columnsDroppedBySender": stats.dropped, "generations": stats.generations.count, "connections": stats.connections,
            "refusedHandshakes": stats.refusedHandshakes, "host": stats.host, "plugin": stats.plugin, "computer": stats.computer,
            "lastIntegrated": stats.lastFrame.map { Double($0.integrated) } ?? -100,
            "lastChannels": stats.lastFrame?.channels.map(\.name) ?? [], "lastPeakDB": stats.lastFrame.map { $0.channels.map { Double(decibels($0.heldPeak)) } } ?? [],
        ]
        let json = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("SUMMARY " + String(decoding: json, as: UTF8.self))
        exit(0)
    }
}
timer.resume()
dispatchMain()
