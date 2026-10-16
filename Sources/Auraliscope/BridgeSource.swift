import AnalysisCore
import BridgeTransport
import Foundation
import QuartzCore

/// One Auraliscope Bridge plugin instance, as the receiver last heard from it. Plain values: acquisition only,
/// nothing about how it is shown.
struct BridgeSource: Equatable {
    enum State: Equatable { case inactive, live, bypassed, offline }

    /// Random per plugin instance lifetime: identifies this live insert.
    let session: [UInt8]
    /// Saved in the DAW project: the same insert after the project is reopened.
    let persistent: [UInt8]
    /// A copy (duplicated track, pasted settings, a second project with the same inserts): the identity its saved
    /// state carried, which another live insert in the same DAW already had. nil otherwise.
    let copiedFrom: [UInt8]?
    /// The persistent ID came from saved state (a project or undo), not from creating the insert.
    let restored: Bool
    /// Speaks this app's protocol; an older or newer plugin is listed so it can be named, never selected.
    let compatible: Bool
    let protocolVersion: UInt32
    let name: String
    let trackName: String
    /// The host's own unique ID for the channel, when it gives one (VST3 hosts may).
    let channelID: String
    let host: String
    let hostBundleID: String
    let hostPID: Int32
    /// "VST3", "AU" or "Test".
    let plugin: String
    let pluginVersion: String
    let state: State
    /// nil when the host does not report its transport.
    let transportPlaying: Bool?
    let formatEpoch: UInt32
    let sampleRate: Double
    let channels: Int
    /// Each channel's speaker role (`Role`), in the bus's order, as the plugin reported it (an immersive bus); empty
    /// for mono and stereo from a plugin before build 77.
    let reportedRoles: [Int]
    /// The layout as the plugin names it ("Stereo", "5.1", "7.1.4"); empty from a plugin before build 77.
    let layoutName: String
    let secondsSinceMessage: Double
    /// Since the host last gave the insert live audio (the plugin's own clock, aged by the report's delay); nil
    /// before it ever did.
    let secondsSinceAudio: Double?
    /// Since the newest result arrived here; nil before any.
    let secondsSinceResult: Double?
    /// The insert's own analysis: its generation (a new one after a reset or a format change), whether it is
    /// measuring, how much it has analysed, and how far behind it is.
    let generation: UInt32
    let measurement: UInt32
    let framesAnalysed: UInt64
    let backlogMs: UInt32
    /// Reasons (ABR_AUDIO_AFTER_*) of the newest break the insert's analysis saw.
    let lastBreakReasons: UInt32
    /// Live audio the insert's analysis could not keep up with (it still passed through).
    let framesDroppedByPlugin: UInt64
    /// Breaks in the live stream the plugin saw (bypass, offline render, the host idle, a restart), and timeline
    /// jumps while playing.
    let pluginInterruptions: UInt32
    let transportJumps: UInt32
    let resultsReceived: UInt64
    let resultsDelivered: UInt64
    let resultsStale: UInt64
    let delivering: Bool
    /// Commands the insert answered, and the newest answer.
    let acksReceived: UInt32
    let lastAck: BridgeAck
    let capabilities: UInt32
    /// Grows each time the user clicks "Show in Auraliscope" in this instance's window.
    let focusRequests: UInt32
    /// Unique per accepted connection: changes when the same live insert reconnects.
    let connectionSerial: UInt32

    var sessionKey: String { Self.hex(session) }
    var persistentKey: String { Self.hex(persistent) }
    var copiedFromKey: String? { copiedFrom.map(Self.hex) }
    /// The insert's measurement is paused (by a command from Labs or its own window).
    var measurementPaused: Bool { measurement == UInt32(ABR_MEASUREMENT_PAUSED) }
    /// The newest break's reasons, for the diagnostic log.
    var lastBreakReasonNames: String {
        let names: [(Int, String)] = [(ABR_AUDIO_AFTER_DROP, "frames dropped"), (ABR_AUDIO_AFTER_IDLE, "host idle"),
                                      (ABR_AUDIO_AFTER_BYPASS, "bypass"), (ABR_AUDIO_AFTER_OFFLINE, "offline render"),
                                      (ABR_AUDIO_AFTER_RESTART, "restart"), (ABR_AUDIO_STREAM_START, "stream start")]
        return names.filter { lastBreakReasons & UInt32($0.0) != 0 }.map(\.1).joined(separator: ", ")
    }
    /// Short form of the persistent ID, the plugin window shows the same.
    var tag: String { String(persistentKey.prefix(6)) }
    var displayName: String { name.isEmpty ? "Auraliscope Bridge \(tag)" : name }
    /// The host as people know it: the application's name for its bundle, else its process name.
    var hostName: String {
        switch hostBundleID {
        case "com.cockos.reaper": return "REAPER"
        case "com.apple.logic10": return "Logic Pro"
        case "com.apple.garageband10": return "GarageBand"
        case "com.ableton.live": return "Live"
        case let id where id.hasPrefix("com.steinberg.cubase"): return "Cubase"
        case let id where id.hasPrefix("com.image-line.flstudio"): return "FL Studio"
        default: return host.isEmpty ? "DAW" : host
        }
    }
    var candidate: BridgeCandidate {
        BridgeCandidate(session: sessionKey, persistent: persistentKey, copiedFrom: copiedFromKey, name: displayName,
                        trackName: trackName, channelID: channelID, hostBundleID: hostBundleID, plugin: plugin)
    }

    /// How this insert is named in lists and the status line: its name, its host and format, the track when it
    /// says more than the name, and the short identity when another connected insert has the same name.
    func label(among others: [BridgeSource]) -> String {
        var parts = [displayName, "\(hostName) \(plugin)"]
        if !trackName.isEmpty && trackName != displayName { parts.append(L("track %@", trackName)) }
        if others.contains(where: { $0.sessionKey != sessionKey && $0.displayName == displayName }) { parts.append("#\(tag)") }
        if let copied = copiedFromKey { parts.append(L("copy of #%@", String(copied.prefix(6)))) }
        return parts.joined(separator: " · ")
    }

    /// Each channel's speaker role: as reported, or L for mono and L, R for stereo; nil when the plugin measures no
    /// layout the display can show.
    var roles: [Int]? {
        if reportedRoles.isEmpty { return channels == 1 ? [Role.left] : channels == 2 ? [Role.left, Role.right] : nil }
        return reportedRoles.count == channels && StreamAnalyzer.validRoles(reportedRoles) ? reportedRoles : nil
    }

    /// An immersive bus (positional channels beyond L and R): the smallest Immersive format holding every one of its
    /// speakers, which the displays draw (a 7.0.4 bus is drawn in 7.1.4 with LFE off). nil for mono and stereo.
    var immersiveLayout: SpeakerLayout? {
        guard let roles, roles.count > 2 else { return nil }
        return SpeakerLayout.containing(roles)
    }

    /// A format the analysis can be configured for: a layout it measures at a real sample rate.
    var hasUsableFormat: Bool { formatEpoch > 0 && roles != nil && sampleRate >= 8_000 }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    init(_ info: AbrSourceInfo) {
        session = withUnsafeBytes(of: info.session_id) { Array($0) }
        persistent = withUnsafeBytes(of: info.persistent_id) { Array($0) }
        copiedFrom = info.identity_flags & UInt32(ABR_IDENTITY_COPY) != 0
            ? withUnsafeBytes(of: info.restored_id) { Array($0) } : nil
        restored = info.identity_flags & UInt32(ABR_IDENTITY_RESTORED) != 0
        compatible = info.compatible != 0
        protocolVersion = info.protocol_version
        name = Self.string(info.source_name)
        trackName = Self.string(info.track_name)
        channelID = Self.string(info.channel_id)
        host = Self.string(info.host_name)
        hostBundleID = Self.string(info.host_bundle_id)
        hostPID = info.host_pid
        switch Int(info.plugin_format) {
        case Int(ABR_FORMAT_VST3): plugin = "VST3"
        case Int(ABR_FORMAT_AU): plugin = "AU"
        default: plugin = "Test"
        }
        pluginVersion = Self.string(info.plugin_version)
        switch Int(info.state) {
        case Int(ABR_STATE_LIVE): state = .live
        case Int(ABR_STATE_BYPASSED): state = .bypassed
        case Int(ABR_STATE_OFFLINE): state = .offline
        default: state = .inactive
        }
        transportPlaying = info.status_flags & UInt32(ABR_TRANSPORT_KNOWN) == 0 ? nil
            : info.status_flags & UInt32(ABR_TRANSPORT_PLAYING) != 0
        formatEpoch = info.format_epoch
        sampleRate = info.sample_rate
        channels = Int(info.channels)
        reportedRoles = withUnsafeBytes(of: info.roles) { Array($0.prefix(Int(min(info.role_count, 16)))).map(Int.init) }
        layoutName = Self.string(info.layout_name)
        secondsSinceMessage = info.seconds_since_message
        secondsSinceAudio = info.plugin_seconds_since_audio < 0 ? nil : info.plugin_seconds_since_audio + info.seconds_since_message
        secondsSinceResult = info.seconds_since_result < 0 ? nil : info.seconds_since_result
        generation = info.generation
        measurement = info.measurement
        framesAnalysed = info.frames_analysed
        backlogMs = info.backlog_ms
        lastBreakReasons = info.last_break_reasons
        framesDroppedByPlugin = info.frames_dropped_by_plugin
        pluginInterruptions = info.plugin_interruptions
        transportJumps = info.transport_jumps
        resultsReceived = info.results_received
        resultsDelivered = info.results_delivered
        resultsStale = info.results_stale
        delivering = info.delivering != 0
        acksReceived = info.acks_received
        lastAck = BridgeAck(id: info.last_ack_id, command: info.last_ack_command, outcome: info.last_ack_outcome,
                            generation: info.last_ack_generation, measurement: info.last_ack_measurement)
        capabilities = info.capabilities
        focusRequests = info.focus_requests
        connectionSerial = info.connection_serial
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// A plugin's answer to a command: which one, what came of it (ABR_ACK_*), and the analysis generation and
/// measurement state after it.
struct BridgeAck: Equatable {
    var id: UInt32 = 0
    var command: UInt32 = 0
    var outcome: UInt32 = 0
    var generation: UInt32 = 0
    var measurement: UInt32 = 0

    var outcomeName: String {
        switch Int(outcome) {
        case Int(ABR_ACK_DONE): return "done"
        case Int(ABR_ACK_WRONG_SESSION): return "refused: another instance"
        case Int(ABR_ACK_STALE_GENERATION): return "refused: obsolete generation"
        case Int(ABR_ACK_UNSUPPORTED): return "unsupported"
        case Int(ABR_ACK_NO_ANALYSIS): return "no analysis yet"
        default: return "outcome \(outcome)"
        }
    }
}

/// Launched by a plugin's "Open Auraliscope" button: start waiting for that plugin instead of opening the default
/// output, and skip the welcome sheet.
let launchedByBridge = CommandLine.arguments.contains("--bridge-launch")

/// Where the selected insert's results land: decoded on the receiver thread and handed to a `ResultAssembler`,
/// which the display worker reads at its own pace. The lock is held for a decode's hand-over and a snapshot's
/// assembly only.
final class ResultInbox {
    private let lock = NSLock()
    private let assembler: ResultAssembler
    /// Distinguishes attachments, so results of an earlier source never continue a later one's stream.
    private var source = 0
    private(set) var lastReceived: CFTimeInterval = 0
    private var silenced = false

    init(streamSeed: UInt32) { assembler = ResultAssembler(streamSeed: streamSeed) }

    /// A new attachment: whatever arrives from now on is a new stream for the displays.
    func begin() {
        lock.lock()
        source += 1
        lastReceived = 0
        silenced = false
        lock.unlock()
    }

    /// Receiver thread.
    func take(_ payload: UnsafeRawBufferPointer) {
        let message = ResultMessage.decode(payload)
        lock.lock()
        assembler.receive(message, source: source)
        lastReceived = CACurrentMediaTime()
        silenced = false
        lock.unlock()
    }

    /// Display worker: the next snapshot into `values`, when there is one. With nothing received for `staleAfter`
    /// seconds, the instantaneous readings fall to silence first.
    func publish(into values: inout [Float], staleAfter: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !silenced, lastReceived > 0, CACurrentMediaTime() - lastReceived > staleAfter {
            assembler.silenceTransients()
            silenced = true
        }
        guard assembler.publish() else { return false }
        values = assembler.values
        return true
    }

    /// The newest result as received (tests and diagnostics).
    var latest: ResultMessage? {
        lock.lock()
        defer { lock.unlock() }
        return assembler.latest
    }

    var counters: (received: Int, rejected: Int, spectrogramGaps: UInt64, spectrogramSkipped: UInt64, waveformGaps: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (assembler.received, assembler.rejected, assembler.spectrogramGaps, assembler.spectrogramSkipped,
                assembler.waveformGaps)
    }
}

/// The application end of the Bridge transport: listens for plugin instances from launch to quit, so they are
/// discoverable whatever source is being metered, and hands the selected one's analysis results to a
/// `ResultInbox`. Nothing here receives or analyses audio.
final class BridgeReceiver {
    private let server: OpaquePointer

    /// Starts listening, or explains why it could not (another copy already receiving, a folder problem…).
    static func start() -> Result<BridgeReceiver, BridgeReceiverError> {
        var message = [CChar](repeating: 0, count: 256)
        guard let server = abr_server_start(nil, &message, message.count) else {
            return .failure(BridgeReceiverError(reason: String(cString: message)))
        }
        return .success(BridgeReceiver(server: server))
    }

    private init(server: OpaquePointer) { self.server = server }

    deinit { abr_server_stop(server) }

    func sources() -> [BridgeSource] {
        var infos = [AbrSourceInfo](repeating: AbrSourceInfo(), count: 64)
        let count = infos.withUnsafeMutableBufferPointer { Int(abr_server_sources(server, $0.baseAddress, 64)) }
        return infos.prefix(min(count, 64)).map(BridgeSource.init)
    }

    /// Asks one instance for its results (nil: none).
    func select(_ session: [UInt8]?) {
        if let session { session.withUnsafeBufferPointer { abr_server_select(server, $0.baseAddress) } }
        else { abr_server_select(server, nil) }
    }

    /// The waterfall analysis every subscription asks for; a change reaches the subscribed instance at once.
    func setSpectrogram(_ mode: SpectrogramMode) {
        guard mode != spectrogram else { return }
        spectrogram = mode
        abr_server_set_spectrogram(server, mode.rawValue)
    }
    private var spectrogram = SpectrogramMode.classic

    /// Whether every subscription's spectrum sums every channel of the bus (the display shows Immersive) or L and R;
    /// a change reaches the subscribed instance at once.
    func setSpectrum(everyChannel: Bool) {
        guard everyChannel != spectrumEveryChannel else { return }
        spectrumEveryChannel = everyChannel
        abr_server_set_spectrum(server, everyChannel ? 1 : 0)
    }
    private var spectrumEveryChannel = false

    /// The spatial field's coherence threshold every subscription asks for (0 to 1); a change reaches the subscribed
    /// instance at once.
    func setCoherence(_ threshold: Float) {
        let thousandths = UInt32(max(50, min(950, (threshold * 1000).rounded())))
        guard thousandths != coherence else { return }
        coherence = thousandths
        abr_server_set_coherence(server, thousandths)
    }
    private var coherence: UInt32 = 0

    /// Delivers the selected instance's results into `inbox` until `detach`. The inbox must outlive the attachment.
    func attach(_ inbox: ResultInbox) {
        abr_server_detach(server)
        inbox.begin()
        abr_server_attach(server, { context, payload, length in
            guard let context else { return }
            Unmanaged<ResultInbox>.fromOpaque(context).takeUnretainedValue()
                .take(UnsafeRawBufferPointer(start: payload, count: Int(length)))
        }, Unmanaged.passUnretained(inbox).toOpaque())
    }

    /// After return the server no longer calls the inbox.
    func detach() { abr_server_detach(server) }

    /// Sends a command (ABR_COMMAND_*) to one instance, for `generation` (0: its current one). Returns the command's
    /// ID, which its acknowledgement carries (`BridgeSource.lastAck`), or 0 when the instance is not connected.
    @discardableResult
    func command(_ session: [UInt8], _ command: Int32, generation: UInt32 = 0) -> UInt32 {
        session.withUnsafeBufferPointer { abr_server_command(server, $0.baseAddress!, UInt32(command), generation) }
    }

    /// Diagnostics: closes one instance's connection, as a broken connection would be; it reconnects by itself.
    func disconnect(_ session: [UInt8], refusingFor milliseconds: UInt32) {
        session.withUnsafeBufferPointer { abr_server_disconnect(server, $0.baseAddress!, milliseconds) }
    }
}

struct BridgeReceiverError: Error { let reason: String }
