import AnalysisCore
import BridgeTransport
import Foundation

/// The app's end of the DAW plugin link, as the model uses it: the receiver and the plugins it reports (offered as
/// sources, or named as needing an update), the commands sent to a plugin and their acknowledgements, a plugin's breaks
/// and focus requests, the speaker layout a plugin refused, and the insert chosen last with how restoration finds it
/// again (`BridgeRestoration`, with its settle delay and provisional span). `MeterModel`, which owns this link, acts on
/// what it finds: the selection, the status and the analysis stay there. Main thread.
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

    /// The name of the insert chosen last, shown while it is away. The key is permanent.
    static let nameKey = "bridgeSourceName"
    /// A new instance of the saved insert is bound only once it has claimed the saved identity this long, so the
    /// others of a project that is still loading can arrive.
    static let restorationSettle: TimeInterval = 1.0
    /// For this long after restoration chose an insert, another one claiming the saved identity makes it ambiguous.
    static let provisionalSpan: TimeInterval = 5.0
    /// The insert chosen last, saved with its context so the same insert can be found again (`BridgeRestoration`).
    private(set) var saved: BridgeSelection?
    /// Chosen by restoration rather than by the person: until then another insert claiming the saved identity
    /// makes the choice ambiguous again, and analysis stops.
    private var provisionalUntil: Date?
    /// When an insert claiming the saved identity first appeared.
    private var claimSeen: Date?

    /// Where restoration found the saved insert while nothing bound is connected.
    enum Restoration {
        /// The same live instance (for good), or a new instance after the settle delay (provisionally).
        case bind(BridgeSource, provisional: Bool)
        /// A new instance claims the saved identity, and the settle delay has not passed yet.
        case settling
        /// No connected insert claims it.
        case wait
        /// Several could be it: the person must choose.
        case ambiguous([String])
        /// The insert restoration names is not connected as a compatible one: nothing changes.
        case unchanged
    }

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

    // MARK: The insert chosen last

    /// At launch, a DAW plugin was the source: the insert with this persistent identity, with its saved context, or
    /// only its name when an older version saved it.
    func restoreSaved(persistent: String) {
        saved = BridgeSelection.load().flatMap { $0.persistent == persistent ? $0 : nil }
            ?? BridgeSelection(persistent: persistent, name: UserDefaults.standard.string(forKey: Self.nameKey) ?? "")
    }

    /// The person chose a source: final, no longer provisional. A connected insert is remembered with its context; a
    /// device, or Host plugins with no insert chosen, forgets the saved one.
    func choose(_ id: SourceID) {
        provisionalUntil = nil
        claimSeen = nil
        if let session = id.bridge, let source = sources.first(where: { $0.sessionKey == session }) {
            remember(source)
        } else if id.bridge == nil || id == .anyPlugin {
            saved = nil
        }
    }

    /// Remembers `source` as the chosen insert, with its current context (kept up to date while it is bound).
    func remember(_ source: BridgeSource) {
        var selection = BridgeSelection(source.candidate,
                                        knownCopies: saved?.persistent == source.persistentKey ? saved?.knownCopies : nil)
        if selection.noteCopies(among: sources.filter(\.compatible).map(\.candidate)) {
            DiagnosticLog.event("DAW plugin \"\(source.displayName)\" was copied; the copy is known not to be it")
        }
        guard selection != saved else { return }
        saved = selection
        selection.save()
        UserDefaults.standard.set(bridgeUIDPrefix + source.persistentKey, forKey: MeterModel.inputDeviceUIDKey)
        UserDefaults.standard.set(false, forKey: MeterModel.inputDeviceIsOutputKey)
        UserDefaults.standard.set(source.displayName, forKey: Self.nameKey)
    }

    /// The bound insert is connected. While restoration's choice is provisional: the sessions that now make it
    /// ambiguous (another insert claiming the saved identity arrived), or nil. Otherwise its context is kept current.
    func checkBound(_ source: BridgeSource, now: Date = Date()) -> [String]? {
        if let until = provisionalUntil {
            if now > until {
                provisionalUntil = nil
            } else if let saved {
                let decision = BridgeRestoration.decide(for: saved, among: sources.filter(\.compatible).map(\.candidate),
                                                        matchingSession: false)
                if case let .ambiguous(sessions) = decision { return sessions }
            }
        }
        if provisionalUntil == nil { remember(source) }
        return nil
    }

    /// Nothing bound is connected: where the saved insert is among the connected ones, or nil with none saved.
    func findSaved(now: Date = Date()) -> Restoration? {
        guard let saved else { return nil }
        let candidates = sources.filter(\.compatible)
        switch BridgeRestoration.decide(for: saved, among: candidates.map(\.candidate)) {
        case let .bind(session):
            guard let source = candidates.first(where: { $0.sessionKey == session }) else { return .unchanged }
            // The same live insert: Auraliscope restarted, or its connection came back.
            if session == saved.session { return .bind(source, provisional: false) }
            // A new instance of the saved insert (the project reopened, the plugin reloaded). A project still loading
            // may bring more claimants, so the choice waits a moment, and stays provisional after that.
            if claimSeen == nil { claimSeen = now }
            if now.timeIntervalSince(claimSeen!) < Self.restorationSettle { return .settling }
            return .bind(source, provisional: true)
        case .wait:
            claimSeen = nil
            return .wait
        case let .ambiguous(sessions):
            claimSeen = nil
            return .ambiguous(sessions)
        }
    }

    /// Restoration bound `source`: for good, or provisionally for `provisionalSpan`.
    func bound(_ source: BridgeSource, provisional: Bool, now: Date = Date()) {
        claimSeen = nil
        provisionalUntil = provisional ? now.addingTimeInterval(Self.provisionalSpan) : nil
        if !provisional { remember(source) }
    }

    /// The saved insert became ambiguous: no choice stands, provisional or not, until the person's.
    func becameAmbiguous() {
        provisionalUntil = nil
    }
}
