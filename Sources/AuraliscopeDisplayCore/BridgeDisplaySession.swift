import AnalysisCore
import Foundation

/// The display end of one Bridge connection (protocol 3), independent of the carrier: bytes in, bytes out. The iPad
/// feeds it what its network connection receives and sends what it returns; the tests feed it directly.
///
/// It follows the rules the desktop's BridgeServer.c follows: nothing but HELLO may come first; a plugin of another
/// protocol version is answered with this display's WELCOME (so it can say which side needs updating) and then
/// refused; results are delivered only for the current subscription (anything numbered for an earlier one was in flight
/// when it changed, and is dropped), and only when they decode completely and consistently; every COMMAND carries the
/// instance's session ID and is matched to its ACK. Every input is untrusted: sizes are bounded by the framing, every
/// field is checked by kind and size, and a broken stream ends the connection rather than being repaired.
public final class BridgeDisplaySession {
    public enum Phase: Equatable, Sendable {
        case awaitingHello
        case ready
        /// The plugin speaks another protocol version or writes a RESULT schema this display does not read.
        case incompatible(String)
        /// The stream broke the framing or the message order; the connection must close.
        case failed(String)
    }

    public enum Event: Sendable {
        case hello(BridgeHello)
        case status(BridgeStatus)
        case result(AnalysisFrame)
        case ack(BridgeAckMessage)
        case focus
    }

    public struct Counters: Equatable, Sendable {
        public var messages = 0
        public var bytes = 0
        public var results = 0
        public var resultsStale = 0          // numbered for another subscription
        public var resultsInvalid = 0        // malformed, another schema, inconsistent sizes
        public var resultsUnsubscribed = 0   // arrived while not subscribed
        public var unknownMessages = 0
    }

    public private(set) var phase = Phase.awaitingHello
    public private(set) var hello: BridgeHello?
    public private(set) var status = BridgeStatus()
    public private(set) var subscription: UInt32 = 0
    public private(set) var counters = Counters()
    public private(set) var lastAck: BridgeAckMessage?
    /// Monotonic seconds of the newest message, and of the newest result delivered.
    public private(set) var lastMessageAt: Double?
    public private(set) var lastResultAt: Double?

    private var decoder = BridgeFrameDecoder()
    private var encoder = BridgeFrameEncoder()
    private var nextCommandID: UInt32 = 1
    private var pendingCommands: [UInt32: BridgeCommandCode] = [:]
    private static var subscriptionCounter: UInt32 = 0
    private static let subscriptionLock = NSLock()

    public init() {}

    /// Outgoing bytes for the carrier, and what the received bytes meant.
    public struct Output: Sendable {
        public var send: [Data] = []
        public var events: [Event] = []
        /// The connection should close once `send` is out (incompatible peer, broken stream).
        public var close = false
    }

    /// Takes received bytes, in whatever pieces they arrived. `now` is seconds on a monotonic clock.
    public func receive(_ bytes: Data, now: Double) -> Output {
        var out = Output()
        guard !isClosed else { out.close = true; return out }
        counters.bytes += bytes.count
        let messages: [BridgeMessage]
        do {
            messages = try decoder.append(bytes)
        } catch {
            phase = .failed(Self.describe(error))
            out.close = true
            return out
        }
        for message in messages {
            counters.messages += 1
            lastMessageAt = now
            handle(message, now: now, into: &out)
            if isClosed { out.close = true; break }
        }
        return out
    }

    private var isClosed: Bool {
        switch phase {
        case .failed, .incompatible: return true
        default: return false
        }
    }

    private func handle(_ message: BridgeMessage, now: Double, into out: inout Output) {
        guard let kind = message.kind else { counters.unknownMessages += 1; return }
        if phase == .awaitingHello {
            guard kind == .hello else { phase = .failed("expected HELLO first"); return }
            do {
                let hello = try BridgeHello.parse(message.payload)
                self.hello = hello
                if hello.protocolVersion != BridgeProtocol.version {
                    // A version-2 or later plugin waits for a WELCOME to say which side needs updating.
                    if hello.protocolVersion >= 2 { out.send.append(encoder.encode(.welcome, BridgeDisplayMessages.welcome())) }
                    phase = .incompatible(hello.protocolVersion < BridgeProtocol.version
                        ? "The plugin speaks Bridge protocol \(hello.protocolVersion); update Auraliscope Bridge on the Mac."
                        : "The plugin speaks Bridge protocol \(hello.protocolVersion); update Auraliscope on this iPad.")
                    out.events.append(.hello(hello))
                    return
                }
                out.send.append(encoder.encode(.welcome, BridgeDisplayMessages.welcome()))
                if hello.schema != BridgeProtocol.analysisSchema {
                    phase = .incompatible("The plugin writes analysis schema \(hello.schema); this display reads schema \(BridgeProtocol.analysisSchema).")
                } else {
                    phase = .ready
                }
                out.events.append(.hello(hello))
            } catch {
                phase = .failed("unreadable HELLO")
            }
            return
        }
        switch kind {
        case .status:
            status.apply(message.payload)
            out.events.append(.status(status))
        case .result:
            guard subscription != 0 else { counters.resultsUnsubscribed += 1; return }
            let result = message.payload.withUnsafeBytes { ResultMessage.decode($0) }
            guard result.subscription == subscription else { counters.resultsStale += 1; return }
            guard result.valid else { counters.resultsInvalid += 1; return }
            counters.results += 1
            lastResultAt = now
            out.events.append(.result(AnalysisFrame(result)))
        case .ack:
            guard let ack = BridgeAckMessage.parse(message.payload) else { return }
            // Only acknowledgements of commands this display sent, from the instance they were sent to.
            guard pendingCommands.removeValue(forKey: ack.commandID) != nil,
                  ack.sessionID == nil || ack.sessionID == hello?.sessionID else { return }
            lastAck = ack
            out.events.append(.ack(ack))
        case .focus:
            out.events.append(.focus)
        case .spatialAck:
            break  // the iPad display sends no SPATIAL_CONFIG yet
        case .hello:
            phase = .failed("a second HELLO")
        case .welcome, .subscribe, .unsubscribe, .command, .spatialConfig, .pairRequest, .pairGrant, .pairDeny:
            // Display-to-plugin or pairing messages have no business arriving here.
            phase = .failed("unexpected message \(kind)")
        }
    }

    /// Starts sending results with a new subscription number (also to re-subscribe after a change of options), or
    /// stops them. Returns the bytes to send; nil before the plugin was welcomed.
    public func subscribe(enhancedSpectrogram: Bool = false, everyChannel: Bool = false) -> Data? {
        guard phase == .ready, hello.map({ $0.capabilities & BridgeCapability.results != 0 }) ?? false else { return nil }
        Self.subscriptionLock.lock()
        Self.subscriptionCounter = Self.subscriptionCounter == UInt32.max ? 1 : Self.subscriptionCounter + 1
        subscription = Self.subscriptionCounter
        Self.subscriptionLock.unlock()
        return encoder.encode(.subscribe, BridgeDisplayMessages.subscribe(subscription, enhancedSpectrogram: enhancedSpectrogram,
                                                                           everyChannel: everyChannel))
    }

    public func unsubscribe() -> Data? {
        guard phase == .ready, subscription != 0 else { return nil }
        subscription = 0
        return encoder.encode(.unsubscribe)
    }

    /// A COMMAND to this instance, for `generation` (0: whichever is current). It changes the plugin's own analysis,
    /// for every display of it. nil when the plugin does not carry it out.
    public func command(_ code: BridgeCommandCode, generation: UInt32) -> (id: UInt32, bytes: Data)? {
        guard phase == .ready, let hello else { return nil }
        let needed: UInt32 = switch code {
        case .reset: BridgeCapability.reset
        case .resetTruePeak: BridgeCapability.resetTruePeak
        case .pause, .resume: BridgeCapability.pause
        }
        guard hello.capabilities & needed != 0 else { return nil }
        let id = nextCommandID
        nextCommandID = nextCommandID == UInt32.max ? 1 : nextCommandID + 1
        if pendingCommands.count > 32 { pendingCommands.removeAll() }  // never acknowledged: a stuck peer
        pendingCommands[id] = code
        return (id, encoder.encode(.command, BridgeDisplayMessages.command(id: id, code: code, sessionID: hello.sessionID,
                                                                           generation: generation)))
    }

    static func describe(_ error: BridgeFramingError) -> String {
        switch error {
        case .badMagic(let magic): return String(format: "not a Bridge stream (magic %08X)", magic)
        case .tooLong(let length): return "a message of \(length) bytes, above the limit"
        }
    }
}
