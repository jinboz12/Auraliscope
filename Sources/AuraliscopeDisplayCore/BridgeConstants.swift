import Foundation

/// Protocol 3 of the Auraliscope Bridge (Bridge/PROTOCOL.md), as a display on any platform needs it. The values are
/// those of `Sources/BridgeTransport/include/BridgeProtocol.h`; `scripts/test-display-core.sh` checks every one
/// against that header, so the two can never drift apart.
public enum BridgeProtocol {
    public static let version: UInt32 = 3
    /// The RESULT field set a display reads (ResultProtocol.swift).
    public static let analysisSchema: UInt32 = 1
    public static let magic: UInt32 = 0x4752_4241   // "ABRG" in memory order
    public static let headerBytes = 16
    public static let maxPayload = 1 << 20
    public static let maxChannels = 16
    public static let helloMinBytes = 8
    public static let statusIntervalMs = 250
    public static let spatialConfigMax = 1000

    /// DNS-SD service type of a receiver (BridgeDiscovery.h).
    public static let serviceType = "_auraliscope._tcp"
}

public enum BridgeMessageType: UInt16 {
    case hello = 1, status = 2, focus = 5, result = 6, ack = 7, spatialAck = 8
    case welcome = 16, subscribe = 17, unsubscribe = 18, command = 19, spatialConfig = 20
    /// Network pairing (BRIDGE_NETWORK.md): only on a pairing connection, never on a display connection.
    case pairRequest = 32, pairGrant = 33, pairDeny = 34
}

public enum BridgeState: UInt32 { case inactive = 0, live = 1, bypassed = 2, offline = 3 }
public enum BridgeLayout: UInt32 { case unknown = 0, mono = 1, stereo = 2, speakers = 3 }
public enum BridgePluginFormat: UInt32 { case vst3 = 1, au = 2, test = 99 }

public enum BridgeCapability {
    public static let results: UInt32 = 1 << 0
    public static let reset: UInt32 = 1 << 1
    public static let resetTruePeak: UInt32 = 1 << 2
    public static let pause: UInt32 = 1 << 3
    public static let spatialConfig: UInt32 = 1 << 4
}

public enum BridgeCommandCode: UInt32 { case reset = 1, resetTruePeak = 2, pause = 3, resume = 4 }

public enum BridgeAckOutcome: UInt32 {
    case done = 0, wrongSession = 1, staleGeneration = 2, unsupported = 3, noAnalysis = 4
}

public enum BridgeIdentityFlags {
    public static let restored: UInt32 = 1 << 0
    public static let copy: UInt32 = 1 << 1
}

public enum BridgeStatusFlags {
    public static let transportKnown: UInt32 = 1 << 0
    public static let transportPlaying: UInt32 = 1 << 1
    public static let subscribed: UInt32 = 1 << 16
}

enum HelloTag {
    static let sessionID: UInt16 = 1, persistentID: UInt16 = 2, restoredID: UInt16 = 3, identityFlags: UInt16 = 4
    static let hostPID: UInt16 = 5, hostName: UInt16 = 6, hostBundleID: UInt16 = 7, pluginVersion: UInt16 = 8
    static let schema: UInt16 = 9, capabilities: UInt16 = 10
    /// Over the network only (BRIDGE_NETWORK.md): the sending Mac's pairing ID and its name. A display that does not
    /// know them skips them (unknown tags), so they need no new protocol version.
    static let deviceID: UInt16 = 11, computerName: UInt16 = 12
}

enum WelcomeTag { static let schema: UInt16 = 1, capabilities: UInt16 = 2 }

enum StatusTag {
    static let state: UInt16 = 1, formatEpoch: UInt16 = 2, sampleRate: UInt16 = 3, channels: UInt16 = 4
    static let layout: UInt16 = 5, maxBlock: UInt16 = 6, flags: UInt16 = 7, framesProcessed: UInt16 = 8
    static let framesDropped: UInt16 = 9, interruptions: UInt16 = 10, transportJumps: UInt16 = 11
    static let sourceName: UInt16 = 12, trackName: UInt16 = 13, channelID: UInt16 = 14, generation: UInt16 = 15
    static let measurement: UInt16 = 16, framesAnalysed: UInt16 = 17, lastBreak: UInt16 = 18, backlogMs: UInt16 = 19
    static let secondsSinceAudio: UInt16 = 20, roles: UInt16 = 21, layoutName: UInt16 = 22
}

enum SubscribeTag {
    static let subscription: UInt16 = 1, spectrogram: UInt16 = 2, spectrum: UInt16 = 3, coherence: UInt16 = 4
}

enum CommandTag { static let id: UInt16 = 1, code: UInt16 = 2, sessionID: UInt16 = 3, generation: UInt16 = 4 }

enum AckTag {
    static let commandID: UInt16 = 1, code: UInt16 = 2, outcome: UInt16 = 3, generation: UInt16 = 4
    static let measurement: UInt16 = 5, sessionID: UInt16 = 6
}

/// Pairing messages (BRIDGE_NETWORK.md).
enum PairTag {
    // PAIR_REQUEST (plugin → display)
    static let deviceID: UInt16 = 1, computerName: UInt16 = 2, hostName: UInt16 = 3, pluginVersion: UInt16 = 4
    // PAIR_GRANT (display → plugin)
    static let receiverID: UInt16 = 1, receiverName: UInt16 = 2, key: UInt16 = 3
    // PAIR_DENY (display → plugin)
    static let reason: UInt16 = 1
}
