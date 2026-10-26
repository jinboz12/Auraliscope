import AnalysisCore
import BridgeTransport
import Foundation

/// The app's end of the DAW plugin link, as the model uses it: the receiver and the plugins it reports (offered as
/// sources, or named as needing an update), the commands sent to a plugin and their acknowledgements, a plugin's breaks
/// and focus requests, and the speaker layout a plugin refused. Which insert is analysed, and when, stays with
/// `MeterModel`, which owns this link; main thread.
@MainActor
final class BridgeLink {
    /// Nil when the receiver could not start (`error` says why).
    let receiver: BridgeReceiving?
    let error: String?
    /// Newest report of every connected plugin instance (polled, not published: counters change constantly).
    private(set) var sources: [BridgeSource] = []
    /// Focus requests already acted on, per session.
    private var focusHandled: [String: UInt32] = [:]
    /// Breaks of the bound insert already written to the diagnostic log (session, count).
    private var breaksLogged: (session: String, count: UInt64)?
    /// The newest command sent to the bound plugin, until its acknowledgement is logged.
    private var pendingCommand: (session: String, id: UInt32, name: String)?
    /// The user's layout a plugin refused (its session and the layout's hash): the standard one is used meanwhile.
    private var refusedGeometry: (session: String, hash: UInt64)?

    init(_ started: Result<BridgeReceiving, BridgeReceiverError>) {
        switch started {
        case let .success(receiver): self.receiver = receiver; error = nil
        case let .failure(failure): receiver = nil; error = failure.reason
        }
    }

    /// Takes the receiver's newest report of every plugin.
    func refresh() {
        guard let receiver else { return }
        sources = receiver.sources()
    }

    /// Connected plugin instances as sources, in connection order. One of another protocol version is left out
    /// (Settings names it as needing an update).
    var devices: [InputDevice] {
        let compatible = sources.filter(\.compatible)
        return compatible.map { source in
            InputDevice(device: 0, name: source.displayName, channels: UInt32(max(source.channels, 0)),
                        uid: bridgeUIDPrefix + source.persistentKey, bridgeSession: source.sessionKey,
                        detail: source.label(among: compatible))
        }
    }

    /// Plugins of another protocol version, by host: named in Settings as needing an update.
    var incompatible: [BridgeSource] { sources.filter { !$0.compatible } }

    /// The plugins whose window asked to be shown since they were last taken ("Show in / Open Auraliscope"); the
    /// requests of plugins that went away are forgotten.
    func takeFocusRequests() -> [BridgeSource] {
        var requests: [BridgeSource] = []
        for source in sources where source.compatible && source.focusRequests > focusHandled[source.sessionKey, default: 0] {
            focusHandled[source.sessionKey] = source.focusRequests
            requests.append(source)
        }
        let live = Set(sources.map(\.sessionKey))
        focusHandled = focusHandled.filter { live.contains($0.key) }
        return requests
    }

    /// Writes each new break the bound insert's analysis saw to the diagnostic log, with its reasons (only the
    /// newest is known when several arrive between two refreshes), and each command's acknowledgement.
    func logBreaks(_ source: BridgeSource) {
        if let pending = pendingCommand, pending.session == source.sessionKey, source.lastAck.id == pending.id {
            DiagnosticLog.event(String(format: "DAW plugin \"%@\": %@ %@ · generation %u · %@", source.displayName, pending.name,
                                       source.lastAck.outcomeName, source.lastAck.generation,
                                       source.lastAck.measurement == UInt32(ABR_MEASUREMENT_PAUSED) ? "paused" : "measuring"))
            pendingCommand = nil
        }
        let count = UInt64(source.pluginInterruptions)
        guard let logged = breaksLogged, logged.session == source.sessionKey else {
            breaksLogged = (source.sessionKey, count)
            return
        }
        guard count > logged.count else { return }
        DiagnosticLog.event(String(format: "DAW plugin \"%@\": %llu break(s) (newest: %@; timeline jumps %u)",
                                   source.displayName, count - logged.count, source.lastBreakReasonNames, source.transportJumps))
        breaksLogged = (source.sessionKey, count)
    }

    /// Sends a command to a connected DAW plugin; returns whether it went out. Its acknowledgement is logged.
    @discardableResult
    func send(_ command: Int, name: String, to session: String) -> Bool {
        guard let receiver, let source = sources.first(where: { $0.sessionKey == session }) else { return false }
        let id = receiver.command(source.session, Int32(command))
        guard id != 0 else { return false }
        pendingCommand = (session, id, name)
        DiagnosticLog.event("DAW plugin \"\(source.displayName)\": \(name) sent (command \(id))")
        return true
    }

    /// Whether `source` refused `configured`, the user's layout for the format shown.
    func refused(_ configured: SpatialGeometry, by source: BridgeSource) -> Bool {
        refusedGeometry?.session == source.sessionKey && refusedGeometry?.hash == configured.hash
    }

    /// A plugin's answer to the geometry it was sent: a refusal of the user's layout makes the dome (and the plugin)
    /// use the standard one, with a note, until the layout changes.
    func noteSpatialAnswer(of source: BridgeSource, to configured: SpatialGeometry) {
        guard let ack = source.spatialAck else { return }
        if ack.revision == configured.revision, ack.outcome != SpatialConfigWire.Outcome.applied.rawValue,
           refusedGeometry?.hash != configured.hash {
            refusedGeometry = (source.sessionKey, configured.hash)
            DiagnosticLog.event("The plugin refused the speaker layout (outcome \(ack.outcome)); showing the standard layout")
        }
    }
}
