import AudioRing
import BridgeTransport
import Foundation

/// One Auraliscope Bridge plugin instance, as the receiver last heard from it. Plain values: acquisition only,
/// nothing about how it is shown.
struct BridgeSource: Equatable {
    enum State: Equatable { case inactive, live, bypassed, offline }

    /// Random per plugin instance lifetime: identifies this live insert.
    let session: [UInt8]
    /// Saved in the DAW project: the same insert after the project is reopened (copies of it share the ID).
    let persistent: [UInt8]
    let name: String
    let trackName: String
    let host: String
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
    let discontinuities: UInt64
    let framesDroppedByPlugin: UInt64
    let delivering: Bool
    /// Grows each time the user clicks "Show in Auraliscope Labs" in this instance's window.
    let focusRequests: UInt32

    var sessionKey: String { Self.hex(session) }
    var persistentKey: String { Self.hex(persistent) }
    /// Short form of the persistent ID, the plugin window shows the same.
    var tag: String { String(persistentKey.prefix(6)) }
    var displayName: String { name.isEmpty ? "Auraliscope Bridge \(tag)" : name }
    /// A format the analysis can be configured for: mono or stereo at a real sample rate.
    var hasUsableFormat: Bool { formatEpoch > 0 && (1...2).contains(channels) && sampleRate >= 8_000 }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    init(_ info: AbrSourceInfo) {
        session = withUnsafeBytes(of: info.session_id) { Array($0) }
        persistent = withUnsafeBytes(of: info.persistent_id) { Array($0) }
        name = Self.string(info.source_name)
        trackName = Self.string(info.track_name)
        host = Self.string(info.host_name)
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
        framesDroppedByPlugin = info.frames_dropped_by_plugin
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
    /// to input n. The server thread is the ring's only producer until `detach`.
    func attach(epoch: UInt32, ring: OpaquePointer, sourceForRole: [Int32]) {
        abr_server_detach(server)
        sink.pointee.ring = ring
        withUnsafeMutableBytes(of: &sink.pointee.source_for_role) { raw in
            let roles = raw.bindMemory(to: Int32.self)
            for role in 0..<min(roles.count, sourceForRole.count) { roles[role] = sourceForRole[role] }
        }
        abr_server_attach(server, epoch, { context, samples, frames, channels in
            channel_ring_sink_write(context, samples, frames, channels)
        }, UnsafeMutableRawPointer(sink))
    }

    /// After return the server no longer writes to the ring.
    func detach() { abr_server_detach(server) }
}

struct BridgeReceiverError: Error { let reason: String }
