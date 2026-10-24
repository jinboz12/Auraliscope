import Foundation

/// How Radiant's observations (`SpatialObservations`) place a frequency between the speakers.
/// - `directions`: at the amplitude-weighted centre of gravity of the speakers' unit directions (Build 97's frame:
///   every speaker on the unit sphere). The radius is a property of that average, never a distance.
/// - `positions`: at the amplitude-weighted centre of gravity of the speakers' positions in meters (direction ×
///   distance). It shows how the feeds distribute the signal over the actual layout; it is not a measurement of where
///   a source is, nor of how far away it sounds.
package enum SpatialMapping: UInt8, CaseIterable {
    case directions = 0
    case positions = 1
}

/// One speaker role's place around the listening position: azimuth in degrees clockwise from the front, elevation in
/// degrees up from the ear plane (negative below it), and, when known, its distance in meters. `included` false leaves
/// the speaker out of the spatial picture (its feed still counts in every level and loudness reading).
package struct SpeakerPlacement: Equatable {
    package var azimuth: Double
    package var elevation: Double
    package var distance: Double?
    package var included: Bool

    package init(azimuth: Double, elevation: Double, distance: Double? = nil, included: Bool = true) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.distance = distance
        self.included = included
    }
}

/// The speaker geometry one spatial analysis uses: where every role sits, how observations are mapped, and the
/// analysis options that change what is measured (`detail`, `window`). An immutable, validated value, made once per
/// change on the display's side and sent as is to a Bridge plugin (`SpatialConfigWire`), so both ends compute with the
/// same numbers: angles and distances are rounded to `Float` when the geometry is made, which is what the wire carries.
///
/// Frame: the listening position at the origin, x to the right, y to the front, z up. A role's unit direction is
/// u = (sin az · cos el, cos az · cos el, sin el); its position is u in `directions` mapping and distance · u in
/// `positions` mapping. The LFE never has a direction: it takes no part in the picture whatever its placement says.
///
/// `hash` identifies the content (mapping, placements and the analysis options, not the revision): every set of
/// observations carries the hash of the geometry it was computed with, and a display draws only observations whose
/// hash is the one it draws its speakers with.
package struct SpatialGeometry: Equatable {
    /// The engineering limits a placement is checked against.
    package static let distanceRange = 0.1...100.0
    package static let elevationRange = -90.0...90.0
    /// Observations a band may keep on average (`detail`), and the frame's total.
    package static let detailRange = 2...32
    package static let defaultDetail = 20

    /// Spatial analysis windows: the spectrum's own transform for every band (Build 97's, about 170 ms), or a shorter
    /// transform above 1 kHz and above 4 kHz (`SpatialObservations` zones), for a faster response in the treble.
    package enum Window: UInt8, CaseIterable {
        case standard = 0
        case multiResolution = 1
    }

    /// One placement per role (`Role.count`, in role order).
    package private(set) var placements: [SpeakerPlacement]
    package private(set) var mapping: SpatialMapping
    /// Observations per band on average (`detailRange`): how finely `SpatialFieldAnalyzer` keeps each band's detail.
    package private(set) var detail: Int
    package private(set) var window: Window
    /// Counts the changes the display made (acknowledgements, diagnostics); not part of `hash`.
    package var revision: UInt32
    package private(set) var hash: UInt64 = 0

    /// `placements` in role order (missing roles take the standard placement); values are clamped into range and
    /// rounded to `Float`. A `positions` mapping whose speakers do not all have a distance falls back to `directions`
    /// (`positionsComplete` says why a display could not use it).
    package init(placements given: [SpeakerPlacement], mapping: SpatialMapping = .directions, detail: Int = SpatialGeometry.defaultDetail,
                 window: Window = .standard, revision: UInt32 = 0, roles: [Int]? = nil) {
        var list = Self.standardPlacements(sidesAtNinety: roles.map(SpeakerGeometry.sidesAtNinety) ?? false)
        for role in 0..<min(Role.count, given.count) { list[role] = Self.canonical(given[role]) }
        placements = list
        self.detail = min(Self.detailRange.upperBound, max(Self.detailRange.lowerBound, detail))
        self.window = window
        self.revision = revision
        self.mapping = .directions
        let complete = Self.positionsComplete(list, roles: roles ?? Array(0..<Role.count))
        self.mapping = mapping == .positions && complete ? .positions : .directions
        hash = Self.contentHash(placements: placements, mapping: self.mapping, detail: self.detail, window: window)
    }

    /// The standard (schematic) placements of Build 97 and earlier (`SpeakerGeometry`): ear layer at 0°, every upper
    /// speaker at 45°, side surrounds at ±110°, or ±90° when the layout has rear surrounds; no distances.
    package static func standard(roles: [Int], detail: Int = defaultDetail, window: Window = .standard) -> SpatialGeometry {
        SpatialGeometry(placements: standardPlacements(sidesAtNinety: SpeakerGeometry.sidesAtNinety(roles)), detail: detail,
                        window: window, roles: roles)
    }

    package static func standardPlacements(sidesAtNinety: Bool) -> [SpeakerPlacement] {
        (0..<Role.count).map { role in
            SpeakerPlacement(azimuth: SpeakerGeometry.azimuth(role: role, sidesAtNinety: sidesAtNinety) ?? 0,
                             elevation: SpeakerGeometry.elevation(role: role))
        }
    }

    /// Whether every placement is the standard one for `roles` (the mapping, detail and window aside).
    package func isStandard(roles: [Int]) -> Bool {
        let standard = Self.standardPlacements(sidesAtNinety: SpeakerGeometry.sidesAtNinety(roles)).map(Self.canonical)
        return mapping == .directions && roles.allSatisfy { role in
            guard (0..<Role.count).contains(role) else { return true }
            let a = placements[role], b = standard[role]
            return a.azimuth == b.azimuth && a.elevation == b.elevation && a.included == b.included
        }
    }

    /// A placement as the analysis uses it: the azimuth wrapped into (−180, 180], the elevation clamped to ±90°, a
    /// distance outside `distanceRange` (or not finite) unknown, every value rounded to `Float`.
    package static func canonical(_ p: SpeakerPlacement) -> SpeakerPlacement {
        var azimuth = p.azimuth.isFinite ? p.azimuth.truncatingRemainder(dividingBy: 360) : 0
        if azimuth > 180 { azimuth -= 360 }
        if azimuth <= -180 { azimuth += 360 }
        let elevation = p.elevation.isFinite ? min(90, max(-90, p.elevation)) : 0
        let distance = p.distance.flatMap { $0.isFinite && distanceRange.contains($0) ? Double(Float($0)) : nil }
        return SpeakerPlacement(azimuth: Double(Float(azimuth)), elevation: Double(Float(elevation)), distance: distance,
                                included: p.included)
    }

    /// Whether every included full-range speaker of `roles` has a distance, so the `positions` mapping can be used.
    package static func positionsComplete(_ placements: [SpeakerPlacement], roles: [Int]) -> Bool {
        roles.allSatisfy { role in
            role == Role.lfe || !(0..<Role.count).contains(role) || !placements[role].included || placements[role].distance != nil
        }
    }
    package func positionsComplete(roles: [Int]) -> Bool { Self.positionsComplete(placements, roles: roles) }

    /// The role's unit direction (x right, y front, z up); nil for the LFE and for a speaker left out.
    package func direction(role: Int) -> SIMD3<Double>? {
        guard (0..<Role.count).contains(role), role != Role.lfe, placements[role].included else { return nil }
        return SpeakerGeometry.direction(azimuth: placements[role].azimuth, elevation: placements[role].elevation)
    }

    /// Where the observations put the role: its unit direction, or (`positions`) its position in meters.
    package func position(role: Int) -> SIMD3<Double>? {
        guard let u = direction(role: role) else { return nil }
        return mapping == .positions ? u * (placements[role].distance ?? 1) : u
    }

    /// The largest distance of a speaker of `roles` from the listener in this mapping (1 for directions): the radius a
    /// display fits, so the picture's scale follows the layout and never the signal.
    package func extent(roles: [Int]) -> Double {
        guard mapping == .positions else { return 1 }
        let largest = roles.compactMap { position(role: $0).map { ($0 * $0).sum().squareRoot() } }.max() ?? 1
        return max(largest, 0.1)
    }

    /// Whether any speaker of `roles` sits below the ear plane: the picture then needs the lower hemisphere.
    package func reachesBelow(roles: [Int]) -> Bool {
        roles.contains { role in direction(role: role).map { $0.z < -1e-6 } ?? false }
    }

    /// The same geometry with left and right exchanged: every azimuth negated (each role keeps its own placement
    /// mirrored; a display mirrors the pairs' values between them, see `mirroredPairs`).
    package func mirrored() -> SpatialGeometry {
        var list = placements
        for role in 0..<Role.count { list[role].azimuth = -list[role].azimuth }
        return SpatialGeometry(placements: list, mapping: mapping, detail: detail, window: window, revision: revision &+ 1)
    }

    /// The same geometry turned by `degrees` about the vertical (clockwise seen from above).
    package func rotated(by degrees: Double) -> SpatialGeometry {
        var list = placements
        for role in 0..<Role.count { list[role].azimuth += degrees }
        return SpatialGeometry(placements: list, mapping: mapping, detail: detail, window: window, revision: revision &+ 1)
    }

    /// The canonical bytes `hash` covers: mapping, detail, window, then per role azimuth, elevation and distance
    /// (`Float` bit patterns, 0 for an unknown distance) and whether it is included.
    package static func canonicalBytes(placements: [SpeakerPlacement], mapping: SpatialMapping, detail: Int, window: Window) -> [UInt8] {
        var bytes: [UInt8] = [mapping.rawValue, UInt8(clamping: detail), window.rawValue, 0]
        func put(_ value: Float) { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        for p in placements.prefix(Role.count) {
            put(Float(p.azimuth))
            put(Float(p.elevation))
            put(Float(p.distance ?? 0))
            bytes.append(p.included ? 1 : 0)
        }
        return bytes
    }

    /// FNV-1a over `canonicalBytes`, never 0 (0 stands for "no geometry": a Bridge plugin before build 98).
    package static func contentHash(placements: [SpeakerPlacement], mapping: SpatialMapping, detail: Int, window: Window) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in canonicalBytes(placements: placements, mapping: mapping, detail: detail, window: window) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash == 0 ? 1 : hash
    }

    /// Stable identifiers of the roles in files and the wire's documentation.
    package static let roleNames = ["L", "R", "C", "LFE", "Ls", "Rs", "Ltf", "Rtf", "Lrs", "Rrs", "Lw", "Rw", "Ltm", "Rtm", "Ltr", "Rtr"]
    package static func role(named name: String) -> Int? { roleNames.firstIndex(of: name) }
    /// Left/right role pairs, for mirroring a layout.
    package static let mirroredPairs: [(Int, Int)] = [
        (Role.left, Role.right), (Role.leftSurround, Role.rightSurround), (Role.leftTopFront, Role.rightTopFront),
        (Role.leftRearSurround, Role.rightRearSurround), (Role.leftWide, Role.rightWide),
        (Role.leftTopMiddle, Role.rightTopMiddle), (Role.leftTopRear, Role.rightTopRear),
    ]
}
