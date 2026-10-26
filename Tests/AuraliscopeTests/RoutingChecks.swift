import Foundation

/// The routing rules and where routings are kept (`RoutingStore`), checked with no device and no app: the default orders
/// on devices of every size, a device's speaker configuration, routings saved per device and format (and 1.0's 5.1.2
/// routing), what a routing applied at once and a role routed by hand may hold, a plugin's immersive bus, and the log
/// summary. Saved routings go to a preference domain of the test's own, removed afterwards. The model's use of these
/// rules (which routing is captured, saved and found again) is checked in the app by `--test-model-lifecycle`.
enum RoutingChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: "routing: " + message()) }
    }

    static let left = Role.left, right = Role.right, center = Role.center, lfe = Role.lfe
    static let ls = Role.leftSurround, rs = Role.rightSurround, lrs = Role.leftRearSurround, rrs = Role.rightRearSurround
    static let ltf = Role.leftTopFront, rtf = Role.rightTopFront, ltr = Role.leftTopRear, rtr = Role.rightTopRear

    static func run() throws {
        try orders()
        print("PASS: routing: SMPTE, film and VST3 orders route input n to the n-th role, as far as the device's inputs go")
        try speakerConfiguration()
        print("PASS: routing: a device's speaker configuration routes the roles it describes; SMPTE order without one")
        let domain = "com.jinboz.SoundMeterJBZ.RoutingChecks.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure(description: "routing: no preference domain") }
        defer { defaults.removePersistentDomain(forName: domain) }
        try storage(RoutingStore(defaults: defaults))
        print("PASS: routing: saved per device and format (assign.<device>.<format>), kept to the format and the device's inputs; 1.0's routing serves 5.1.2 alone")
        try validation()
        print("PASS: routing: a routing applied at once and a role routed by hand keep to the format's roles and the device's inputs")
        try busAndSummary()
        print("PASS: routing: a plugin's immersive bus routes each channel to the role it reports; the log summary names roles in display order")
    }

    /// −1 for every role but the `routed` ones (role: input).
    static func routing(_ routed: [Int: Int32]) -> [Int32] {
        var routing = [Int32](repeating: -1, count: Role.count)
        for (role, input) in routed { routing[role] = input }
        return routing
    }

    static func orders() throws {
        for layout in SpeakerLayout.allCases {
            for order in [layout.roles, layout.filmRoles, layout.vst3Roles] {
                try require(order.count == layout.roles.count && Set(order) == Set(layout.roles), "\(layout.name): an order holds the format's roles once each")
                for channels in [0, 1, 2, 6, 8, 12, 16, 64] {
                    let routing = RoutingStore.routing(inOrder: order, channels: channels)
                    for role in 0..<Role.count {
                        let expected = order.firstIndex(of: role).flatMap { $0 < channels ? Int32($0) : nil } ?? -1
                        try require(routing.count == Role.count && routing[role] == expected,
                                    "\(layout.name), \(channels) inputs: role \(role) gets input \(routing[role]), not \(expected)")
                    }
                }
            }
        }
        try require(RoutingStore.routing(inOrder: SpeakerLayout.s51.roles, channels: 8)
                    == routing([left: 0, right: 1, center: 2, lfe: 3, ls: 4, rs: 5]), "5.1 in SMPTE order is L R C LFE Ls Rs")
        try require(RoutingStore.routing(inOrder: SpeakerLayout.s51.filmRoles, channels: 8)
                    == routing([left: 0, center: 1, right: 2, ls: 3, rs: 4, lfe: 5]), "5.1 in film order is L C R Ls Rs LFE")
        let heights: [Int: Int32] = [ltf: 8, rtf: 9, ltr: 10, rtr: 11]
        try require(RoutingStore.routing(inOrder: SpeakerLayout.s714.vst3Roles, channels: 12)
                    == routing([left: 0, right: 1, center: 2, lfe: 3, lrs: 4, rrs: 5, ls: 6, rs: 7].merging(heights) { $1 }),
                    "7.1.4 in VST3 order is L R C LFE Lrs Rrs Lss Rss, then the heights")
        try require(RoutingStore.routing(inOrder: SpeakerLayout.s714.roles, channels: 12)
                    == routing([left: 0, right: 1, center: 2, lfe: 3, ls: 4, rs: 5, lrs: 6, rrs: 7].merging(heights) { $1 }),
                    "7.1.4 in SMPTE order is L R C LFE Lss Rss Lrs Rrs, then the heights")
    }

    static func speakerConfiguration() throws {
        let configured = SpeakerMap(roles: [left, right, center, nil, ls, rs])
        try require(RoutingStore.defaultRouting(for: .s51, channels: 6, speakers: configured)
                    == routing([left: 0, right: 1, center: 2, ls: 4, rs: 5]), "a channel the configuration does not describe stays unrouted")
        try require(RoutingStore.defaultRouting(for: .s51, channels: 3, speakers: configured)
                    == routing([left: 0, right: 1, center: 2]), "only the device's inputs are routed")
        try require(RoutingStore.defaultRouting(for: .s51, channels: 4, speakers: SpeakerMap(roles: [left, right, ltf, rtf]))
                    == routing([left: 0, right: 1]), "a configured role outside the format is not routed")
        try require(RoutingStore.defaultRouting(for: .s51, channels: 6, speakers: nil)
                    == RoutingStore.routing(inOrder: SpeakerLayout.s51.roles, channels: 6), "SMPTE order without a configuration")
    }

    static func storage(_ store: RoutingStore) throws {
        let device = "out.qa.device"
        try require(RoutingStore.key(for: .s714, device: device) == "assign.out.qa.device.7.1.4", "the key names the device and the format")
        let smpte = RoutingStore.routing(inOrder: SpeakerLayout.s51.roles, channels: 8)
        let film = RoutingStore.routing(inOrder: SpeakerLayout.s51.filmRoles, channels: 8)
        try require(store.saved(for: .s51, device: device) == nil
                    && store.routing(for: .s51, device: device, channels: 8, speakers: nil) == smpte, "nothing saved: SMPTE order")
        store.save(film, for: .s51, device: device)
        try require(store.defaults.array(forKey: "assign.out.qa.device.5.1") as? [Int] == film.map(Int.init),
                    "a routing is saved as integers under its key")
        try require(store.routing(for: .s51, device: device, channels: 8, speakers: nil) == film, "the saved routing is found again")
        try require(store.routing(for: .s51, device: "out.qa.other", channels: 8, speakers: nil) == smpte
                    && store.routing(for: .s514, device: device, channels: 8, speakers: nil)
                    == RoutingStore.routing(inOrder: SpeakerLayout.s514.roles, channels: 8),
                    "another device and another format keep their own routing")
        var saved = [Int](repeating: -1, count: Role.count)
        saved[left] = 7; saved[right] = 1; saved[ltf] = 2; saved[center] = -5
        store.defaults.set(saved, forKey: RoutingStore.key(for: .s51, device: "out.qa.small"))
        try require(store.routing(for: .s51, device: "out.qa.small", channels: 4, speakers: nil) == routing([right: 1]),
                    "a saved routing keeps to the format's roles and to the inputs the device has now")
        store.defaults.set([3, 2], forKey: RoutingStore.key(for: .s51, device: "out.qa.short"))
        try require(store.routing(for: .s51, device: "out.qa.short", channels: 4, speakers: nil)
                    == routing([left: 3, right: 2, center: 2, lfe: 3]), "a shorter saved routing overrides its roles only")
        store.defaults.set([7, 6, 5, 4, 3, 2, 1, 0], forKey: "assign.out.qa.old")
        try require(store.routing(for: .s512, device: "out.qa.old", channels: 8, speakers: nil)
                    == routing([left: 7, right: 6, center: 5, lfe: 4, ls: 3, rs: 2, ltf: 1, rtf: 0]),
                    "5.1.2 takes the routing 1.0 saved under the device alone")
        try require(store.saved(for: .s514, device: "out.qa.old") == nil, "no other format takes 1.0's routing")
        let smpte512 = RoutingStore.routing(inOrder: SpeakerLayout.s512.roles, channels: 8)
        store.save(smpte512, for: .s512, device: "out.qa.old")
        try require(store.routing(for: .s512, device: "out.qa.old", channels: 8, speakers: nil) == smpte512,
                    "a routing saved since replaces 1.0's")
    }

    static func validation() throws {
        var applied = [Int32](repeating: 3, count: Role.count)
        applied[left] = -1; applied[right] = 9
        try require(RoutingStore.validated(applied, for: .s51, channels: 8) == routing([center: 3, lfe: 3, ls: 3, rs: 3]),
                    "roles outside the format and inputs the device lacks are switched off")
        try require(RoutingStore.validated([0, 1], for: .s51, channels: 8) == routing([left: 0, right: 1]),
                    "a shorter routing switches the remaining roles off")
        try require(RoutingStore.accepts(role: center, source: 7, for: .s51, channels: 8)
                    && RoutingStore.accepts(role: center, source: -1, for: .s51, channels: 8),
                    "a role of the format may take an input the device has, or be switched off")
        try require(!RoutingStore.accepts(role: center, source: 8, for: .s51, channels: 8)
                    && !RoutingStore.accepts(role: center, source: -2, for: .s51, channels: 8)
                    && !RoutingStore.accepts(role: ltf, source: 0, for: .s51, channels: 8),
                    "an input the device lacks, a negative input other than off, and a role outside the format are refused")
    }

    static func busAndSummary() throws {
        try require(RoutingStore.routing(busRoles: [left, center, right, ls, rs, lfe]) == routing([left: 0, center: 1, right: 2, ls: 3, rs: 4, lfe: 5]),
                    "each bus channel feeds the role it reports, in the bus's order")
        try require(RoutingStore.summary(routing([left: 0, center: 1, right: 2, ls: 3, rs: 4, lfe: 5]), for: .s51)
                    == "L 1 · R 3 · C 2 · LFE 6 · Ls 4 · Rs 5", "the summary lists front, LFE and surrounds, inputs from 1")
        try require(RoutingStore.summary(routing([ls: 0]), for: .s714) == "Lss 1", "a 7.x bed names its side surrounds Lss and Rss")
        try require(RoutingStore.summary(routing([:]), for: .s51) == "nothing routed", "nothing routed is said so")
    }
}
