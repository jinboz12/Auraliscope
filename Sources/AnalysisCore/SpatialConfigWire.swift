import Foundation

/// The spatial geometry as a Bridge display sends it to a plugin (message SPATIAL_CONFIG, Bridge/PROTOCOL.md), in the
/// same tagged fields as every other message. The plugin checks the hash it recomputes against the one sent and
/// acknowledges what it applied (SPATIAL_ACK).
package enum SpatialConfigWire {
    package static let version: UInt32 = 1
    package enum Tag {
        package static let revision: UInt16 = 1, hash: UInt16 = 2, mapping: UInt16 = 3, azimuth: UInt16 = 4
        package static let elevation: UInt16 = 5, distance: UInt16 = 6, included: UInt16 = 7, detail: UInt16 = 8
        package static let window: UInt16 = 9, version: UInt16 = 10
    }
    /// Outcomes in SPATIAL_ACK (`ABR_SPATIAL_*` in BridgeProtocol.h).
    package enum Outcome: UInt32 {
        case applied = 0
        case invalid = 1          // a field missing, malformed or out of range: nothing changed
        case hashMismatch = 2     // the content does not match its hash: nothing changed
        case unsupported = 3      // a version or option this plugin does not know: nothing changed
    }
    /// Largest payload `encode` writes (16 roles): it must stay well under the 1 KB a plugin's control buffer holds.
    package static let largest = 400

    package static func encode(_ g: SpatialGeometry) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: largest)
        let count = out.withUnsafeMutableBytes { raw -> Int in
            var w = WireWriter(raw.baseAddress!, capacity: raw.count)
            w.u32(Tag.version, version)
            w.u32(Tag.revision, g.revision)
            w.u64(Tag.hash, g.hash)
            w.u32(Tag.mapping, UInt32(g.mapping.rawValue))
            w.f32s(Tag.azimuth, g.placements.map { Float($0.azimuth) })
            w.f32s(Tag.elevation, g.placements.map { Float($0.elevation) })
            w.f32s(Tag.distance, g.placements.map { Float($0.distance ?? 0) })
            w.u8s(Tag.included, g.placements.map { $0.included ? 1 : 0 })
            w.u32(Tag.detail, UInt32(g.detail))
            w.u32(Tag.window, UInt32(g.window.rawValue))
            return w.overflowed ? 0 : w.count
        }
        return Array(out.prefix(count))
    }

    /// The geometry `bytes` describe for a bus of `roles`, or why not.
    package static func decode(_ bytes: UnsafeRawBufferPointer, roles: [Int]) -> (geometry: SpatialGeometry?, outcome: Outcome) {
        var reader = WireReader(bytes)
        var revision: UInt32?, hash: UInt64?, mapping: UInt32?, detail: UInt32?, window: UInt32 = 0, v: UInt32 = 1
        var azimuth: [Float]?, elevation: [Float]?, distance: [Float]?, included: [UInt8]?
        while let field = reader.next() {
            switch field.tag {
            case Tag.version: v = field.u32 ?? 0
            case Tag.revision: revision = field.u32
            case Tag.hash: hash = field.u64
            case Tag.mapping: mapping = field.u32
            case Tag.azimuth: azimuth = field.f32s(limit: Role.count)
            case Tag.elevation: elevation = field.f32s(limit: Role.count)
            case Tag.distance: distance = field.f32s(limit: Role.count)
            case Tag.included: included = field.u8s(limit: Role.count)
            case Tag.detail: detail = field.u32
            case Tag.window: window = field.u32 ?? 0
            default: continue
            }
        }
        guard !reader.malformed else { return (nil, .invalid) }
        guard v == version else { return (nil, .unsupported) }
        guard let revision, let hash, let mapping, let azimuth, let elevation, let distance, let included, let detail,
              azimuth.count == Role.count, elevation.count == Role.count, distance.count == Role.count, included.count == Role.count,
              azimuth.allSatisfy(\.isFinite), elevation.allSatisfy({ $0.isFinite && $0 >= -90 && $0 <= 90 }),
              distance.allSatisfy({ $0.isFinite && ($0 == 0 || SpatialGeometry.distanceRange.contains(Double($0))) }),
              SpatialGeometry.detailRange.contains(Int(detail)) else { return (nil, .invalid) }
        guard let map = SpatialMapping(rawValue: UInt8(clamping: mapping)), mapping <= 255,
              let windowChoice = SpatialGeometry.Window(rawValue: UInt8(clamping: window)), window <= 255 else { return (nil, .unsupported) }
        let placements = (0..<Role.count).map { role in
            SpeakerPlacement(azimuth: Double(azimuth[role]), elevation: Double(elevation[role]),
                             distance: distance[role] > 0 ? Double(distance[role]) : nil, included: included[role] != 0)
        }
        let geometry = SpatialGeometry(placements: placements, mapping: map, detail: Int(detail), window: windowChoice,
                                       revision: revision, roles: roles)
        // A positions mapping the bus cannot use (a distance missing) is refused rather than quietly changed.
        guard geometry.mapping == map else { return (nil, .invalid) }
        guard geometry.hash == hash else { return (nil, .hashMismatch) }
        return (geometry, .applied)
    }
}
