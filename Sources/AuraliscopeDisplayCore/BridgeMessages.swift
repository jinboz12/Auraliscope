import AnalysisCore
import Foundation

/// A plugin instance as its HELLO describes it (PROTOCOL.md, *HELLO fields*).
public struct BridgeHello: Equatable, Sendable {
    public var protocolVersion: UInt32
    public var pluginFormat: UInt32
    public var sessionID: [UInt8]
    public var persistentID: [UInt8]
    public var restoredID: [UInt8]?
    public var identityFlags: UInt32
    public var hostPID: Int64?
    public var hostName: String
    public var hostBundleID: String
    public var pluginVersion: String
    public var schema: UInt32
    public var capabilities: UInt32
    /// Network only: the sending Mac's pairing ID and its name (absent on the local socket and from older plugins).
    public var deviceID: [UInt8]?
    public var computerName: String?

    public init(protocolVersion: UInt32, pluginFormat: UInt32, sessionID: [UInt8], persistentID: [UInt8], restoredID: [UInt8]? = nil,
                identityFlags: UInt32, hostPID: Int64? = nil, hostName: String, hostBundleID: String, pluginVersion: String,
                schema: UInt32, capabilities: UInt32, deviceID: [UInt8]? = nil, computerName: String? = nil) {
        self.protocolVersion = protocolVersion
        self.pluginFormat = pluginFormat
        self.sessionID = sessionID
        self.persistentID = persistentID
        self.restoredID = restoredID
        self.identityFlags = identityFlags
        self.hostPID = hostPID
        self.hostName = hostName
        self.hostBundleID = hostBundleID
        self.pluginVersion = pluginVersion
        self.schema = schema
        self.capabilities = capabilities
        self.deviceID = deviceID
        self.computerName = computerName
    }

    /// A short, stable form of the persistent ID, as the plugin window shows it ("Auraliscope Bridge 3FA2C1").
    public var instanceTag: String { persistentID.prefix(3).map { String(format: "%02X", $0) }.joined() }

    public enum ParseError: Error, Equatable { case tooShort, missingSessionID }

    /// Reads a HELLO payload. Only the fixed prefix and the session ID are required; anything else may be absent.
    public static func parse(_ payload: Data) throws(ParseError) -> BridgeHello {
        guard payload.count >= BridgeProtocol.helloMinBytes else { throw .tooShort }
        let version = payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let format = payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let fields = FieldTable(payload.dropFirst(BridgeProtocol.helloMinBytes))
        guard let session = fields.id16(HelloTag.sessionID) else { throw .missingSessionID }
        return BridgeHello(protocolVersion: version, pluginFormat: format, sessionID: session,
                           persistentID: fields.id16(HelloTag.persistentID) ?? session,
                           restoredID: fields.id16(HelloTag.restoredID),
                           identityFlags: fields.u32s[HelloTag.identityFlags] ?? 0,
                           hostPID: fields.i64s[HelloTag.hostPID],
                           hostName: Self.clean(fields.texts[HelloTag.hostName], 63),
                           hostBundleID: Self.clean(fields.texts[HelloTag.hostBundleID], 95),
                           pluginVersion: Self.clean(fields.texts[HelloTag.pluginVersion], 31),
                           schema: fields.u32s[HelloTag.schema] ?? 0,
                           capabilities: fields.u32s[HelloTag.capabilities] ?? 0,
                           deviceID: fields.id16(HelloTag.deviceID),
                           computerName: fields.texts[HelloTag.computerName].map { Self.clean($0, 63) })
    }

    /// Text from the network is shown, never interpreted: control characters are dropped and the length bounded.
    static func clean(_ text: String?, _ limit: Int) -> String {
        guard let text else { return "" }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        return String(kept.prefix(limit))
    }

    /// Writes a HELLO as a plugin does (for tests and the protocol fixtures).
    public func encoded() -> Data {
        var prefix = FieldBuilder.le(protocolVersion) + FieldBuilder.le(pluginFormat)
        prefix.reserveCapacity(8)
        var b = FieldBuilder(capacity: 600, prefix: prefix)
        b.bytes(HelloTag.sessionID, sessionID)
        b.bytes(HelloTag.persistentID, persistentID)
        if let restoredID { b.bytes(HelloTag.restoredID, restoredID) }
        b.u32(HelloTag.identityFlags, identityFlags)
        if let hostPID { b.i64(HelloTag.hostPID, hostPID) }
        b.text(HelloTag.hostName, hostName, limit: 63)
        b.text(HelloTag.hostBundleID, hostBundleID, limit: 95)
        b.text(HelloTag.pluginVersion, pluginVersion, limit: 31)
        b.u32(HelloTag.schema, schema)
        b.u32(HelloTag.capabilities, capabilities)
        if let deviceID { b.bytes(HelloTag.deviceID, deviceID) }
        if let computerName { b.text(HelloTag.computerName, computerName, limit: 63) }
        return b.data
    }
}

/// A plugin instance's STATUS (PROTOCOL.md, *STATUS fields*). Fields not sent keep the previous STATUS's values.
public struct BridgeStatus: Equatable, Sendable {
    public var state: UInt32 = 0
    public var formatEpoch: UInt32 = 0
    public var sampleRate: Double = 0
    public var channels: UInt32 = 0
    public var layout: UInt32 = 0
    public var roles: [Int] = []
    public var layoutName = ""
    public var maxBlock: UInt32 = 0
    public var flags: UInt32 = 0
    public var framesProcessed: UInt64 = 0
    public var framesDropped: UInt64 = 0
    public var interruptions: UInt32 = 0
    public var transportJumps: UInt32 = 0
    public var sourceName = ""
    public var trackName = ""
    public var channelID = ""
    public var generation: UInt32 = 0
    public var measurement: UInt32 = 0
    public var framesAnalysed: UInt64 = 0
    public var lastBreak: UInt32 = 0
    public var backlogMs: UInt32 = 0
    public var secondsSinceAudio: Double = -1

    public init() {}

    public var isPlaying: Bool {
        flags & BridgeStatusFlags.transportKnown != 0 && flags & BridgeStatusFlags.transportPlaying != 0
    }

    /// Applies a STATUS payload over this one.
    public mutating func apply(_ payload: Data) {
        let f = FieldTable(payload)
        if let v = f.u32s[StatusTag.state] { state = v }
        if let v = f.u32s[StatusTag.formatEpoch] { formatEpoch = v }
        if let v = f.f64s[StatusTag.sampleRate], v.isFinite { sampleRate = v }
        if let v = f.u32s[StatusTag.channels] { channels = min(v, UInt32(BridgeProtocol.maxChannels)) }
        if let v = f.u32s[StatusTag.layout] { layout = v }
        if let v = f.blobs[StatusTag.roles], v.count <= BridgeProtocol.maxChannels { roles = v.map(Int.init) }
        if let v = f.texts[StatusTag.layoutName] { layoutName = BridgeHello.clean(v, 15) }
        if let v = f.u32s[StatusTag.maxBlock] { maxBlock = v }
        if let v = f.u32s[StatusTag.flags] { flags = v }
        if let v = f.u64s[StatusTag.framesProcessed] { framesProcessed = v }
        if let v = f.u64s[StatusTag.framesDropped] { framesDropped = v }
        if let v = f.u32s[StatusTag.interruptions] { interruptions = v }
        if let v = f.u32s[StatusTag.transportJumps] { transportJumps = v }
        if let v = f.texts[StatusTag.sourceName] { sourceName = BridgeHello.clean(v, 127) }
        if let v = f.texts[StatusTag.trackName] { trackName = BridgeHello.clean(v, 127) }
        if let v = f.texts[StatusTag.channelID] { channelID = BridgeHello.clean(v, 63) }
        if let v = f.u32s[StatusTag.generation] { generation = v }
        if let v = f.u32s[StatusTag.measurement] { measurement = v }
        if let v = f.u64s[StatusTag.framesAnalysed] { framesAnalysed = v }
        if let v = f.u32s[StatusTag.lastBreak] { lastBreak = v }
        if let v = f.u32s[StatusTag.backlogMs] { backlogMs = v }
        if let v = f.f64s[StatusTag.secondsSinceAudio], v.isFinite { secondsSinceAudio = v }
    }
}

/// The outcome of one COMMAND (PROTOCOL.md, *COMMAND and ACK fields*).
public struct BridgeAckMessage: Equatable, Sendable {
    public var commandID: UInt32
    public var code: UInt32
    public var outcome: UInt32
    public var generation: UInt32
    public var measurement: UInt32
    public var sessionID: [UInt8]?

    public static func parse(_ payload: Data) -> BridgeAckMessage? {
        let f = FieldTable(payload)
        guard let id = f.u32s[AckTag.commandID], let outcome = f.u32s[AckTag.outcome] else { return nil }
        return BridgeAckMessage(commandID: id, code: f.u32s[AckTag.code] ?? 0, outcome: outcome,
                         generation: f.u32s[AckTag.generation] ?? 0, measurement: f.u32s[AckTag.measurement] ?? 0,
                         sessionID: f.id16(AckTag.sessionID))
    }
}

/// The messages a display sends.
public enum BridgeDisplayMessages {
    /// WELCOME: this display's protocol version, then its schema and capabilities. A display that keeps a RESULT's
    /// spatial observations would announce `ABR_DISPLAY_KEEPS_OBSERVATIONS`; the iPad display does not draw them yet,
    /// so it announces nothing and the plugin sends what an older display gets.
    public static func welcome(capabilities: UInt32 = 0) -> Data {
        var b = FieldBuilder(capacity: 64, prefix: FieldBuilder.le(BridgeProtocol.version) + FieldBuilder.le(UInt32(0)))
        b.u32(WelcomeTag.schema, BridgeProtocol.analysisSchema)
        b.u32(WelcomeTag.capabilities, capabilities)
        return b.data
    }

    /// SUBSCRIBE: `everyChannel` asks the spectrum, spectrogram and band energies to sum every channel of the bus
    /// (Immersive) instead of L and R.
    public static func subscribe(_ subscription: UInt32, enhancedSpectrogram: Bool = false, everyChannel: Bool = false) -> Data {
        var b = FieldBuilder(capacity: 64)
        b.u32(SubscribeTag.subscription, subscription)
        b.u32(SubscribeTag.spectrogram, enhancedSpectrogram ? 1 : 0)
        b.u32(SubscribeTag.spectrum, everyChannel ? 1 : 0)
        return b.data
    }

    public static func command(id: UInt32, code: BridgeCommandCode, sessionID: [UInt8], generation: UInt32) -> Data {
        var b = FieldBuilder(capacity: 96)
        b.u32(CommandTag.id, id)
        b.u32(CommandTag.code, code.rawValue)
        b.bytes(CommandTag.sessionID, sessionID)
        b.u32(CommandTag.generation, generation)
        return b.data
    }
}
