import AnalysisCore
import Foundation

/// A speaker layout the user made for one channel format: where each role's speaker sits around the listening
/// position (azimuth and elevation in degrees, distance in meters when known), whether it takes part in the spatial
/// picture, and how Radiant maps observations (speaker directions, or positions in meters). It never changes routing
/// (which input feeds which role: Settings ▸ Channels) or the channel format; it only places the roles.
///
/// Coordinates: the listening position at the origin, x to the right, y to the front, z up; azimuth clockwise from the
/// front (L at −30° is to the left), elevation up from the ear plane (negative below it).
struct SpeakerConfiguration: Codable, Equatable, Identifiable {
    struct Speaker: Codable, Equatable {
        /// `SpatialGeometry.roleNames`: L R C LFE Ls Rs Ltf Rtf Lrs Rrs Lw Rw Ltm Rtm Ltr Rtr.
        var role: String
        var azimuth: Double
        var elevation: Double
        /// Meters from the listening position; nil (null in a file) when not known, never taken for 1 m.
        var distance: Double?
        var included = true
    }
    enum Mapping: String, Codable, CaseIterable {
        case directions, positions
        var spatial: SpatialMapping { self == .positions ? .positions : .directions }
    }
    var id: UUID
    var name: String
    /// The channel format it places (`SpeakerLayout` raw value: "5.1", "7.1.4"…).
    var channelFormat: String
    var mapping: Mapping
    /// Counts the edits.
    var revision: Int
    var speakers: [Speaker]

    /// The speaker of `role`, if the configuration has one.
    func speaker(_ role: Int) -> Speaker? {
        let name = SpatialGeometry.roleNames[role]
        return speakers.first { $0.role == name }
    }

    /// The standard placements of `layout` (`SpatialGeometry.standard`) as a configuration to start from.
    static func standard(_ layout: SpeakerLayout) -> SpeakerConfiguration {
        let placements = SpatialGeometry.standardPlacements(sidesAtNinety: layout.sidesAtNinety)
        let speakers = layout.speakers.map { speaker in
            Speaker(role: SpatialGeometry.roleNames[speaker.role], azimuth: placements[speaker.role].azimuth,
                    elevation: placements[speaker.role].elevation, distance: nil, included: true)
        }
        return SpeakerConfiguration(id: UUID(), name: L("Standard %@", layout.name), channelFormat: layout.rawValue,
                                    mapping: .directions, revision: 0, speakers: speakers)
    }

    /// The placements for `layout`'s roles: this configuration's where it has them, the standard ones elsewhere.
    func placements(for layout: SpeakerLayout) -> [SpeakerPlacement] {
        var list = SpatialGeometry.standardPlacements(sidesAtNinety: layout.sidesAtNinety)
        for speaker in speakers {
            guard let role = SpatialGeometry.role(named: speaker.role), layout.contains(role) else { continue }
            list[role] = SpeakerPlacement(azimuth: speaker.azimuth, elevation: speaker.elevation, distance: speaker.distance,
                                          included: speaker.included)
        }
        return list
    }

    /// Why this configuration cannot be used as it is (empty when it can), for `layout`.
    func problems(for layout: SpeakerLayout) -> [String] {
        var notes: [String] = []
        var seen = Set<String>()
        for speaker in speakers {
            if !seen.insert(speaker.role).inserted { notes.append(L("%@ is listed twice.", speaker.role)) }
            guard SpatialGeometry.role(named: speaker.role) != nil else { notes.append(L("%@ is not a speaker role.", speaker.role)); continue }
            if !speaker.azimuth.isFinite || !speaker.elevation.isFinite { notes.append(L("%@: the angles must be numbers.", speaker.role)) }
            if speaker.elevation.isFinite && !SpatialGeometry.elevationRange.contains(speaker.elevation) {
                notes.append(L("%@: the elevation must be between −90° and 90°.", speaker.role))
            }
            if let d = speaker.distance, !(d.isFinite && SpatialGeometry.distanceRange.contains(d)) {
                notes.append(L("%@: the distance must be between 0.1 and 100 m.", speaker.role))
            }
        }
        if mapping == .positions && !SpatialGeometry.positionsComplete(placements(for: layout), roles: layout.roles) {
            notes.append(L("Speaker positions need every included speaker's distance."))
        }
        return notes
    }

    /// Left and right exchanged in place: `source`'s side mirrored onto the other (each pair's other speaker takes the
    /// source speaker's place with its azimuth negated), the centre's azimuth set to 0.
    func mirrored(from left: Bool) -> SpeakerConfiguration {
        var copy = self
        for (l, r) in SpatialGeometry.mirroredPairs {
            let from = left ? l : r, to = left ? r : l
            guard let source = speaker(from) else { continue }
            let name = SpatialGeometry.roleNames[to]
            if let index = copy.speakers.firstIndex(where: { $0.role == name }) {
                copy.speakers[index].azimuth = -source.azimuth
                copy.speakers[index].elevation = source.elevation
                copy.speakers[index].distance = source.distance
                copy.speakers[index].included = source.included
            }
        }
        copy.revision += 1
        return copy
    }
}

/// Reading a layout written by hand: the fields that only add detail may be left out (docs/SPEAKER_LAYOUT_FORMAT.md).
/// Written out, every field is stated, an unknown distance as null.
extension SpeakerConfiguration.Speaker {
    private enum CodingKeys: String, CodingKey { case role, azimuth, elevation, distance, included }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        azimuth = try c.decode(Double.self, forKey: .azimuth)
        elevation = try c.decode(Double.self, forKey: .elevation)
        distance = try c.decodeIfPresent(Double.self, forKey: .distance)
        included = try c.decodeIfPresent(Bool.self, forKey: .included) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(azimuth, forKey: .azimuth)
        try c.encode(elevation, forKey: .elevation)
        try c.encode(distance, forKey: .distance)
        try c.encode(included, forKey: .included)
    }
}

extension SpeakerConfiguration {
    private enum CodingKeys: String, CodingKey { case id, name, channelFormat, mapping, revision, speakers }

    /// Only the channel format and the speakers are needed; a missing identity is made, the name is the format's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelFormat = try c.decode(String.self, forKey: .channelFormat)
        speakers = try c.decode([Speaker].self, forKey: .speakers)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? channelFormat
        mapping = try c.decodeIfPresent(Mapping.self, forKey: .mapping) ?? .directions
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}

/// A speaker layout as a file (`.json`): the configuration and, for whoever reads it, what its numbers mean.
struct SpeakerLayoutDocument: Codable {
    static let kind = "auraliscope.speaker-layout"
    static let schema = 1
    struct Coordinates: Codable, Equatable {
        var origin = "listening position"
        var x = "right"
        var y = "front"
        var z = "up"
        var azimuth = "degrees, clockwise from the front"
        var elevation = "degrees, up from the ear plane (negative below it)"
        var distance = "meters from the listening position; null when not known"
    }
    var format = SpeakerLayoutDocument.kind
    var schemaVersion = SpeakerLayoutDocument.schema
    var coordinates = Coordinates()
    var layout: SpeakerConfiguration

    init(layout: SpeakerConfiguration) { self.layout = layout }

    private enum CodingKeys: String, CodingKey { case format, schemaVersion, coordinates, layout }

    /// The coordinates' description is for people: a file may leave it out or word it otherwise.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        coordinates = (try? c.decodeIfPresent(Coordinates.self, forKey: .coordinates)) ?? Coordinates()
        layout = try c.decode(SpeakerConfiguration.self, forKey: .layout)
    }

    enum ImportError: Error, CustomStringConvertible {
        case notALayout, newerSchema(Int), unknownFormat(String), invalid([String])
        var description: String {
            switch self {
            case .notALayout: return L("This file is not an Auraliscope speaker layout.")
            case .newerSchema(let v): return L("This layout was saved by a newer Auraliscope (format version %d).", v)
            case .unknownFormat(let f): return L("Channel format %@ is not one Auraliscope shows.", f)
            case .invalid(let notes): return notes.joined(separator: " ")
            }
        }
    }

    static func encode(_ configuration: SpeakerConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SpeakerLayoutDocument(layout: configuration))
    }

    /// A configuration read from `data`, with a new identity, and what was left out or completed on the way.
    static func decode(_ data: Data) throws -> (configuration: SpeakerConfiguration, notes: [String]) {
        guard let document = try? JSONDecoder().decode(SpeakerLayoutDocument.self, from: data), document.format == kind else {
            throw ImportError.notALayout
        }
        guard document.schemaVersion <= schema else { throw ImportError.newerSchema(document.schemaVersion) }
        var configuration = document.layout
        guard let layout = SpeakerLayout(rawValue: configuration.channelFormat) else {
            throw ImportError.unknownFormat(configuration.channelFormat)
        }
        var notes: [String] = []
        // Speakers of roles the format does not have are left out; roles it has but the file lacks keep the standard.
        let extra = configuration.speakers.filter { speaker in SpatialGeometry.role(named: speaker.role).map { !layout.contains($0) } ?? true }
        if !extra.isEmpty {
            notes.append(L("Left out (not in %@): %@.", layout.name, extra.map(\.role).joined(separator: ", ")))
            configuration.speakers.removeAll { speaker in extra.contains(speaker) }
        }
        let missing = layout.speakers.filter { configuration.speaker($0.role) == nil }
        if !missing.isEmpty {
            notes.append(L("Standard places for: %@.", missing.map(\.name).joined(separator: ", ")))
            let standard = SpeakerConfiguration.standard(layout)
            for speaker in missing { if let s = standard.speaker(speaker.role) { configuration.speakers.append(s) } }
        }
        let problems = configuration.problems(for: layout)
        guard problems.isEmpty else { throw ImportError.invalid(problems) }
        configuration.id = UUID()
        return (configuration, notes)
    }
}

/// The speaker layouts the user has made, and which one each channel format uses (none: the standard placements).
/// Kept in the user defaults as JSON (`layoutsKey`) and a format → layout map (`activeKey`), so every display and the
/// analysis read the same geometry, and a change reaches them like any other setting.
@MainActor
final class SpeakerLayoutStore: ObservableObject {
    static let shared = SpeakerLayoutStore()
    nonisolated static let layoutsKey = "soundstage.speakerLayouts"
    nonisolated static let activeKey = "soundstage.speakerLayout.active"
    /// Counts every change of a geometry in use (the analysis' revision; not part of its hash).
    nonisolated static let revisionKey = "soundstage.speakerLayout.revision"

    @Published private(set) var configurations: [SpeakerConfiguration] = []
    @Published private(set) var active: [String: UUID] = [:]
    @Published private(set) var revision = 0
    /// The format whose layout the editor shows, and a request to open the editor's window (the panel's settings).
    @Published var editing: SpeakerLayout?
    @Published var windowRequest = false
    private struct GeometryKey: Hashable {
        var layout: SpeakerLayout
        var detail: Int
        var window: SpatialGeometry.Window
    }
    private var geometryCache: [GeometryKey: SpatialGeometry] = [:]

    func openEditor(for layout: SpeakerLayout) {
        editing = layout
        windowRequest = true
    }

    private init() { reload() }

    func reload() {
        geometryCache.removeAll(keepingCapacity: true)
        let defaults = UserDefaults.standard
        configurations = defaults.data(forKey: Self.layoutsKey).flatMap { try? JSONDecoder().decode([SpeakerConfiguration].self, from: $0) } ?? []
        let map = defaults.dictionary(forKey: Self.activeKey) as? [String: String] ?? [:]
        active = map.compactMapValues(UUID.init(uuidString:))
        revision = defaults.integer(forKey: Self.revisionKey)
    }

    private func persist() {
        geometryCache.removeAll(keepingCapacity: true)
        let defaults = UserDefaults.standard
        revision += 1
        if let data = try? JSONEncoder().encode(configurations) { defaults.set(data, forKey: Self.layoutsKey) }
        defaults.set(active.mapValues(\.uuidString), forKey: Self.activeKey)
        defaults.set(revision, forKey: Self.revisionKey)
    }

    func layouts(for layout: SpeakerLayout) -> [SpeakerConfiguration] { configurations.filter { $0.channelFormat == layout.rawValue } }

    /// The configuration `layout` uses, or nil for the standard placements.
    func configuration(for layout: SpeakerLayout) -> SpeakerConfiguration? {
        guard let id = active[layout.rawValue] else { return nil }
        return configurations.first { $0.id == id && $0.channelFormat == layout.rawValue }
    }

    /// The geometry the analysis and the display use for `layout`, with the nebula's detail and analysis window. A
    /// configuration with problems (none can be saved, but defaults can be edited by hand) gives the standard one.
    func geometry(for layout: SpeakerLayout, nebula: NebulaSettings) -> SpatialGeometry {
        let key = GeometryKey(layout: layout, detail: Int(nebula.particles.rounded()), window: nebula.window)
        if let cached = geometryCache[key] { return cached }
        let geometry = Self.geometry(for: layout, configuration: configuration(for: layout), revision: revision, nebula: nebula)
        geometryCache[key] = geometry
        return geometry
    }

    nonisolated static func geometry(for layout: SpeakerLayout, configuration: SpeakerConfiguration?, revision: Int,
                                     nebula: NebulaSettings) -> SpatialGeometry {
        let detail = Int(nebula.particles.rounded())
        var g: SpatialGeometry
        if let c = configuration, c.problems(for: layout).isEmpty {
            g = SpatialGeometry(placements: c.placements(for: layout), mapping: c.mapping.spatial, detail: detail,
                                window: nebula.window, roles: layout.roles)
        } else {
            g = SpatialGeometry.standard(roles: layout.roles, detail: detail, window: nebula.window)
        }
        g.revision = Self.revision(revision, hash: g.hash)
        return g
    }

    /// The revision a geometry is sent to a plugin with: the store's count of changes mixed with the geometry's own
    /// hash, so every different geometry (another layout, channel format, Particles or Spatial window) has its own, and
    /// a plugin's acknowledgement names exactly the one it answers. Never 0.
    nonisolated static func revision(_ count: Int, hash: UInt64) -> UInt32 {
        let mixed = (UInt64(truncatingIfNeeded: count) &* 0x9E37_79B9_7F4A_7C15) ^ hash
        let folded = UInt32(truncatingIfNeeded: mixed ^ (mixed >> 32))
        return folded == 0 ? 1 : folded
    }

    /// The same, read straight from the user defaults: for work off the main thread (previews, file analysis).
    nonisolated static func storedGeometry(for layout: SpeakerLayout, nebula: NebulaSettings) -> SpatialGeometry {
        let defaults = UserDefaults.standard
        let configurations = defaults.data(forKey: layoutsKey).flatMap { try? JSONDecoder().decode([SpeakerConfiguration].self, from: $0) } ?? []
        let map = defaults.dictionary(forKey: activeKey) as? [String: String] ?? [:]
        let id = map[layout.rawValue].flatMap(UUID.init(uuidString:))
        let configuration = configurations.first { $0.id == id && $0.channelFormat == layout.rawValue }
        return geometry(for: layout, configuration: configuration, revision: defaults.integer(forKey: revisionKey), nebula: nebula)
    }

    /// Uses `id` for `layout` (nil: the standard placements).
    func select(_ id: UUID?, for layout: SpeakerLayout) {
        active[layout.rawValue] = id
        persist()
    }

    /// Stores `configuration` (new or edited); returns it as stored.
    @discardableResult
    func save(_ configuration: SpeakerConfiguration) -> SpeakerConfiguration {
        var c = configuration
        if let index = configurations.firstIndex(where: { $0.id == c.id }) {
            guard configurations[index] != c else { return c }
            c.revision = max(c.revision, configurations[index].revision + 1)
            configurations[index] = c
        } else {
            configurations.append(c)
        }
        persist()
        return c
    }

    /// A copy under a new name and identity, stored and selected for its format.
    @discardableResult
    func duplicate(_ configuration: SpeakerConfiguration, name: String? = nil) -> SpeakerConfiguration {
        var copy = configuration
        copy.id = UUID()
        copy.revision = 0
        copy.name = name ?? L("%@ copy", configuration.name)
        configurations.append(copy)
        active[copy.channelFormat] = copy.id
        persist()
        return copy
    }

    func delete(_ id: UUID) {
        configurations.removeAll { $0.id == id }
        for (format, value) in active where value == id { active[format] = nil }
        persist()
    }

    /// Reads a layout file: stored under a new identity, selected for its format; returns it with the notes of what
    /// was completed or left out.
    func importLayout(from url: URL) throws -> (SpeakerConfiguration, [String]) {
        let data = try Data(contentsOf: url)
        let (configuration, notes) = try SpeakerLayoutDocument.decode(data)
        configurations.append(configuration)
        active[configuration.channelFormat] = configuration.id
        persist()
        return (configuration, notes)
    }

    func export(_ configuration: SpeakerConfiguration, to url: URL) throws {
        try SpeakerLayoutDocument.encode(configuration).write(to: url, options: .atomic)
    }
}
