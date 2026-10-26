import AnalysisCore
import Foundation

/// Which device input feeds each speaker role, and where a routing is kept. A routing (`sourceForRole`) holds an input
/// index per role, −1 for none. It is saved per device and per Immersive format; without one, the device's speaker
/// configuration in Audio MIDI Setup routes it, else input n feeds the format's n-th role in SMPTE order. 5.1.2 also
/// takes the eight-role routing 1.0 saved per device. The store holds no routing itself: the model's `sourceForRole`
/// is the one in use. Key names are permanent (users' settings and presets use them).
struct RoutingStore {
    var defaults: UserDefaults = .standard

    /// The routing for `layout` on a device known by `deviceKey` with `channels` inputs: the saved one over the
    /// default, keeping only the format's roles and the inputs the device has.
    func routing(for layout: SpeakerLayout, device deviceKey: String, channels: Int, speakers: SpeakerMap?) -> [Int32] {
        var routing = Self.defaultRouting(for: layout, channels: channels, speakers: speakers)
        if let saved = saved(for: layout, device: deviceKey) {
            for (role, source) in saved.enumerated() where role < Role.count {
                routing[role] = source >= 0 && source < channels ? Int32(source) : -1
            }
        }
        for role in 0..<Role.count where !layout.contains(role) { routing[role] = -1 }
        return routing
    }

    /// The routing saved for this device and format (5.1.2 also the eight-role routing saved by 1.0), if any.
    func saved(for layout: SpeakerLayout, device deviceKey: String) -> [Int]? {
        let legacy = layout == .s512 ? defaults.array(forKey: "assign.\(deviceKey)") as? [Int] : nil
        return defaults.array(forKey: Self.key(for: layout, device: deviceKey)) as? [Int] ?? legacy
    }

    func save(_ routing: [Int32], for layout: SpeakerLayout, device deviceKey: String) {
        defaults.set(routing.map(Int.init), forKey: Self.key(for: layout, device: deviceKey))
    }

    static func key(for layout: SpeakerLayout, device deviceKey: String) -> String { "assign.\(deviceKey).\(layout.rawValue)" }

    /// The routing a device without a saved one gets: its speaker configuration, or SMPTE order.
    static func defaultRouting(for layout: SpeakerLayout, channels: Int, speakers: SpeakerMap?) -> [Int32] {
        speakers.map { $0.routing(for: layout, channels: channels) } ?? routing(inOrder: layout.roles, channels: channels)
    }

    /// Input n to the n-th role of `order` (SMPTE, film or VST3 order), for the device's `channels` inputs.
    static func routing(inOrder order: [Int], channels: Int) -> [Int32] {
        var routing = [Int32](repeating: -1, count: Role.count)
        for (index, role) in order.enumerated() where index < channels { routing[role] = Int32(index) }
        return routing
    }

    /// A DAW plugin's immersive bus routes itself: each channel feeds the speaker role it reports.
    static func routing(busRoles roles: [Int]) -> [Int32] {
        var routing = [Int32](repeating: -1, count: Role.count)
        for (channel, role) in roles.enumerated() { routing[role] = Int32(channel) }
        return routing
    }

    /// A routing applied at once (Settings ▸ Apply): roles outside the format, and inputs the device lacks, are off.
    static func validated(_ routing: [Int32], for layout: SpeakerLayout, channels: Int) -> [Int32] {
        var next = [Int32](repeating: -1, count: Role.count)
        for role in 0..<min(Role.count, routing.count) where layout.contains(role) {
            next[role] = routing[role] >= 0 && routing[role] < Int32(channels) ? routing[role] : -1
        }
        return next
    }

    /// Whether one role of `layout` may be routed by hand to `source` (−1: off) on a device with `channels` inputs.
    static func accepts(role: Int, source: Int32, for layout: SpeakerLayout, channels: Int) -> Bool {
        layout.contains(role) && (source == -1 || (source >= 0 && source < Int32(channels)))
    }

    /// Each routed role and its input (1-based), in the format's display order: "L 1 · R 2 · C 3 …".
    static func summary(_ routing: [Int32], for layout: SpeakerLayout) -> String {
        let names = layout.speakers.compactMap { speaker -> String? in
            let source = routing[speaker.role]
            return source >= 0 ? "\(speaker.name) \(source + 1)" : nil
        }
        return names.isEmpty ? "nothing routed" : names.joined(separator: " · ")
    }
}
