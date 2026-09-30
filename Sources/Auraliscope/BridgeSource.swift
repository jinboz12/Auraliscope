import AudioRing
import BridgeTransport
import Foundation

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
    let secondsSinceMessage: Double
    let secondsSinceAudio: Double?
    let framesDelivered: UInt64
    let framesLost: UInt64
    /// Breaks reported to the analysis while delivering (`AbrSourceInfo.discontinuities`), and the newest one's
    /// reasons (ABR_AUDIO_AFTER_*).
    let discontinuities: UInt64
    let lastBreakReasons: UInt32
    let lastBreakLostFrames: UInt64
    let lastBreakIdleMs: UInt32
    let framesDroppedByPlugin: UInt64
    /// Breaks in the live stream the plugin saw (bypass, offline render, the host idle, a restart), and timeline
    /// jumps while playing.
    let pluginInterruptions: UInt32
    let transportJumps: UInt32
    let delivering: Bool
    /// Grows each time the user clicks "Show in Auraliscope Labs" in this instance's window.
    let focusRequests: UInt32

    var sessionKey: String { Self.hex(session) }
    var persistentKey: String { Self.hex(persistent) }
    var copiedFromKey: String? { copiedFrom.map(Self.hex) }
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

    /// A format the analysis can be configured for: mono or stereo at a real sample rate.
    var hasUsableFormat: Bool { formatEpoch > 0 && (1...2).contains(channels) && sampleRate >= 8_000 }

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
        secondsSinceMessage = info.seconds_since_message
        secondsSinceAudio = info.seconds_since_audio < 0 ? nil : info.seconds_since_audio
        framesDelivered = info.frames_delivered
        framesLost = info.frames_lost
        discontinuities = info.discontinuities
        lastBreakReasons = info.last_reasons
        lastBreakLostFrames = info.last_lost_frames
        lastBreakIdleMs = info.last_idle_ms
        framesDroppedByPlugin = info.frames_dropped_by_plugin
        pluginInterruptions = info.plugin_interruptions
        transportJumps = info.transport_jumps
        delivering = info.delivering != 0
        focusRequests = info.focus_requests
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Launched by a plugin's "Open Auraliscope Labs" button: start waiting for that plugin instead of opening the default
/// output, and skip the welcome sheet.
let launchedByBridge = CommandLine.arguments.contains("--bridge-launch")

/// The application end of the Bridge transport: listens for plugin instances from launch to quit, so they are
/// discoverable whatever source is being metered, and hands the selected one's PCM to a `ChannelRing`.
final class BridgeReceiver {
    private let server: OpaquePointer
    /// The ring and routing the server thread writes through; changed only while detached.
    private let sink: UnsafeMutablePointer<ChannelRingSink>

    /// Starts listening, or explains why it could not (another copy already receiving, a folder problem…).
    static func start() -> Result<BridgeReceiver, BridgeReceiverError> {
        var message = [CChar](repeating: 0, count: 256)
        guard let server = abr_server_start(nil, &message, message.count) else {
            return .failure(BridgeReceiverError(reason: String(cString: message)))
        }
        return .success(BridgeReceiver(server: server))
    }

    private init(server: OpaquePointer) {
        self.server = server
        sink = .allocate(capacity: 1)
        sink.initialize(to: ChannelRingSink())
    }

    deinit {
        abr_server_stop(server)
        sink.deinitialize(count: 1)
        sink.deallocate()
    }

    func sources() -> [BridgeSource] {
        var infos = [AbrSourceInfo](repeating: AbrSourceInfo(), count: 64)
        let count = infos.withUnsafeMutableBufferPointer { Int(abr_server_sources(server, $0.baseAddress, 64)) }
        return infos.prefix(min(count, 64)).map(BridgeSource.init)
    }

    /// Asks one instance for its audio (nil: none). Detaches the ring.
    func select(_ session: [UInt8]?) {
        if let session { session.withUnsafeBufferPointer { abr_server_select(server, $0.baseAddress) } }
        else { abr_server_select(server, nil) }
    }

    /// Delivers the selected instance's audio of `epoch` into `ring`, its channel n going to every role routed
    /// to input n, and marks every break in it in the ring (`channel_ring_mark`). The server thread is the ring's
    /// only producer until `detach`. `markStart`: whether a break just before the first delivered block counts
    /// (true when this continues an analysis that the break interrupted; false for a fresh one, or one the user
    /// paused and resumed).
    func attach(epoch: UInt32, ring: OpaquePointer, sourceForRole: [Int32], markStart: Bool) {
        abr_server_detach(server)
        sink.pointee.ring = ring
        withUnsafeMutableBytes(of: &sink.pointee.source_for_role) { raw in
            let roles = raw.bindMemory(to: Int32.self)
            for role in 0..<min(roles.count, sourceForRole.count) { roles[role] = sourceForRole[role] }
        }
        abr_server_attach(server, epoch, { context, samples, frames, channels in
            channel_ring_sink_write(context, samples, frames, channels)
        }, { context, reasons, lost, idle in
            channel_ring_sink_boundary(context, reasons, lost, idle)
        }, UnsafeMutableRawPointer(sink), markStart ? 1 : 0)
    }

    /// After return the server no longer writes to the ring.
    func detach() { abr_server_detach(server) }

    /// Diagnostics: closes one instance's connection, as a broken connection would be; it reconnects by itself.
    func disconnect(_ session: [UInt8], refusingFor milliseconds: UInt32) {
        session.withUnsafeBufferPointer { abr_server_disconnect(server, $0.baseAddress!, milliseconds) }
    }
}

struct BridgeReceiverError: Error { let reason: String }
