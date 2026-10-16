import Foundation

/// A connected DAW plugin insert as restoration sees it: its identities and the host context it reports.
struct BridgeCandidate: Equatable {
    /// This live instance (random per plugin lifetime).
    let session: String
    /// The identity saved with the DAW project.
    let persistent: String
    /// A copy (duplicated track, pasted settings, a second project with the same inserts): the identity its saved
    /// state carried, which another live insert in the same DAW already had.
    let copiedFrom: String?
    let name: String
    let trackName: String
    /// The host's own unique ID for the channel, when it gives one.
    let channelID: String
    let hostBundleID: String
    let plugin: String
}

/// The DAW plugin insert the person chose, saved so the same insert can be found again after Auraliscope, the
/// plugin or the DAW restarts, together with the context it was chosen in.
struct BridgeSelection: Codable, Equatable {
    var session: String
    var persistent: String
    var name: String
    var trackName: String
    var channelID: String
    var hostBundleID: String
    var plugin: String
    /// Identities of copies of this insert that appeared while it was bound and connected (a duplicated track, a
    /// paste): they are known not to be it, so they never make finding it again ambiguous. Absent in selections
    /// saved before it was kept.
    var knownCopies: [String]?

    /// How many copies are remembered (the newest).
    static let knownCopiesLimit = 32

    init(_ candidate: BridgeCandidate, knownCopies: [String]? = nil) {
        session = candidate.session
        persistent = candidate.persistent
        name = candidate.name
        trackName = candidate.trackName
        channelID = candidate.channelID
        hostBundleID = candidate.hostBundleID
        plugin = candidate.plugin
        self.knownCopies = knownCopies
    }

    /// Adds the copies of this insert among `candidates` to the known ones; returns whether any was new.
    mutating func noteCopies(among candidates: [BridgeCandidate]) -> Bool {
        var known = knownCopies ?? []
        let fresh = candidates.filter { $0.copiedFrom == persistent && $0.persistent != persistent && !known.contains($0.persistent) }
        guard !fresh.isEmpty else { return false }
        known.append(contentsOf: fresh.map(\.persistent))
        knownCopies = Array(known.suffix(Self.knownCopiesLimit))
        return true
    }

    /// A selection saved before the context was kept: only the identity and the name are known.
    init(persistent: String, name: String) {
        session = ""
        self.persistent = persistent
        self.name = name
        trackName = ""
        channelID = ""
        hostBundleID = ""
        plugin = ""
    }

    /// Whether `candidate` agrees with every piece of context that both the saved selection and the candidate
    /// state. A host channel ID, when both have one, decides alone: it is unique per channel in its host.
    func agrees(with candidate: BridgeCandidate) -> Bool {
        if !channelID.isEmpty && !candidate.channelID.isEmpty { return channelID == candidate.channelID }
        func same(_ saved: String, _ reported: String) -> Bool { saved.isEmpty || reported.isEmpty || saved == reported }
        return same(plugin, candidate.plugin) && same(hostBundleID, candidate.hostBundleID)
            && same(name, candidate.name) && same(trackName, candidate.trackName)
    }

    static let defaultsKey = "bridgeSelection"

    static func load(from defaults: UserDefaults = .standard) -> BridgeSelection? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(BridgeSelection.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Which connected insert is the saved one. The rule: never pick one of several possible inserts by chance.
///
/// 1. The same live instance (its session) is the saved insert, whatever else is connected: Auraliscope
///    restarted while the DAW kept running.
/// 2. Otherwise the inserts claiming the saved identity are the ones that hold it (the project reopened, the plugin
///    reloaded) and the copies made of it (a duplicated track, pasted settings, a second copy of the project in
///    the same DAW). A copy never inherits the selection: it is a different insert. The only holder, with no copy
///    beside it, is the saved insert. Copies seen appearing while the saved insert was bound are known not to be
///    it and do not count (the host unloaded and reloaded the original, beside its copy).
/// 3. With several claimants (copies beside the holder, or holders in two DAWs), the saved context may single one
///    holder out: the host's channel ID when it gives one, else the plugin format, host, source name and track
///    name together.
/// 4. Anything else is ambiguous: nothing is analysed until the person chooses (in the source list, or with the
///    one-click button in the plugin window they mean).
enum BridgeRestoration: Equatable {
    case bind(String)
    case wait
    case ambiguous([String])

    /// `matchingSession`: whether rule 1 applies (false when re-checking a choice rule 2 or 3 already made).
    static func decide(for saved: BridgeSelection, among candidates: [BridgeCandidate],
                       matchingSession: Bool = true) -> BridgeRestoration {
        if matchingSession, !saved.session.isEmpty, let same = candidates.first(where: { $0.session == saved.session }) {
            return .bind(same.session)
        }
        let holders = candidates.filter { $0.persistent == saved.persistent }
        let known = saved.knownCopies ?? []
        let copies = candidates.filter { $0.persistent != saved.persistent && $0.copiedFrom == saved.persistent
            && !known.contains($0.persistent) }
        guard !holders.isEmpty else { return .wait }
        if holders.count == 1 && copies.isEmpty { return .bind(holders[0].session) }
        let claimants = holders + copies
        let agreeing = claimants.filter(saved.agrees)
        if agreeing.count == 1, holders.contains(agreeing[0]) { return .bind(agreeing[0].session) }
        return .ambiguous(claimants.map(\.session))
    }
}
