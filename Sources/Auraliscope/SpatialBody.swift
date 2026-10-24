import Accelerate
import AnalysisCore
import Foundation
import simd

/// The Immersive soundstage's body (drawn by `NebulaScene`): the level of the speaker feeds heard from each direction
/// around the listener, from the spatial field (`SpatialField`) or, from a plugin that sends none, from each channel's
/// band energy at its speaker. A display estimate from the feeds, not a measured sound field.
///
/// Every component of the field is a lobe of energy around a direction. A lobe's kernel is 1 in its own direction, so a
/// lone lobe reaches its own level there, and lobes add as energies, so the body's level in a direction is the level of
/// everything heard from it:
/// - energy only one speaker carries points at that speaker, as wide as one loudspeaker is heard (10.7°);
/// - a coherent image points where the field puts it (its velocity vector in the bass, its energy vector in the
///   treble) and is as wide, along each of its axes, as its predicted spread looks from the listener (Frank's width
///   model, `SpatialField.image`). Energy that cancels between speakers is spread wide and drawn close, so it covers a
///   wide angle; it carries its instability (1 − stability), which the body shows as a tint.
/// Every lobe is widened by one angular `Settings.smoothing`, so the body reads as one mass instead of a set of spikes:
/// at the default 30°, two uncorrelated speakers 60° apart still show as two lobes, about 7.4 dB lower between them,
/// while one coherent image between them shows as one lobe there.
///
/// Kernel, for a unit direction d: exp(−(1 − c)·(a²/S₁² + b²/S₂²)/(a² + b²)), c = u·d and a, b the components of d
/// along the lobe's two principal axes across its direction u (a² + b² = 1 − c²; where both vanish, on the lobe's axis
/// and right opposite it, a small ε keeps their mean). Near the lobe it is a Gaussian of the angles (S₁, S₂ the angular
/// standard deviations); a round one is the von Mises–Fisher kernel exp(−(1 − c)/S²), so it is defined, and smooth,
/// over the whole sphere. Directions run azimuth-major in rows of rising elevation, `step` degrees apart, from −90° (the
/// lower hemisphere, used once a speaker of the layout sits below the ear plane: `firstRow`) to +90°, the layout of the
/// volume shader's texture, in the field's frame (x right, y front, z up). Speakers stand where the geometry puts them
/// (`SpatialGeometry`, custom directions included); the radius stays the level. Allocates only when created and when
/// the layout, the geometry or the smoothing changes.
///
/// Every lobe also carries how its energy divides among the five analysis bands (`StereoBands`), and lobes add those
/// as they add their energies, so the body knows, in every direction, how loud each band is heard from there: the
/// display colours each direction by them (`NebulaScene`). A lobe's own colour by frequency (its bands' hues on the
/// spectral scale, `SpectralHue`, mixed by energy) and centre frequency name it in the pointer's reading.
final class SpatialBody {
    static let azimuthSteps = 120
    /// Rows above the ear plane (0° to 90°) and below it (−90° to −3°).
    static let elevationSteps = 30
    static let lowerSteps = 30
    static let rows = lowerSteps + elevationSteps + 1
    /// The row of the ear plane (0°).
    static let floorRow = lowerSteps
    /// Degrees between neighbouring directions.
    static let step = 3.0
    static let count = azimuthSteps * rows
    static let maxLayers = StereoBands.count

    /// The elevation (degrees) of grid row `row`.
    static func elevation(row: Int) -> Double { Double(row - lowerSteps) * step }

    /// The grid's unit directions, in the field's frame.
    static let directions: [SIMD3<Float>] = (0..<rows).flatMap { r in
        (0..<azimuthSteps).map { a in
            let d = SpeakerGeometry.direction(azimuth: Double(a) * step, elevation: elevation(row: r))
            return SIMD3(Float(d.x), Float(d.y), Float(d.z))
        }
    }
    /// The same, one component per array, for the vector arithmetic.
    static let dx = directions.map(\.x), dy = directions.map(\.y), dz = directions.map(\.z)
    /// Keeps the kernel's direction-dependent mean defined where both its axes vanish.
    static let epsilon: Float = 1e-4
    /// cos(elevation) of each row: how far a radius at that height reaches out over the floor.
    static let floorShare: [Float] = (0..<rows).map { Float(cos(elevation(row: $0) * .pi / 180)) }

    /// One loudspeaker's image as an angle (radians, σ): `SpatialField.speakerSpread` seen from the listener, so its
    /// half-maximum width is 10.7°.
    static let speakerAngle = Float(atan(1.1774 * Double(SpatialField.speakerSpread)) / 1.1774)

    struct Settings: Equatable {
        /// Every lobe's widening, degrees at half maximum.
        var smoothing = 30.0
        /// The share of each image's predicted spread drawn (1 as wide as it is heard).
        var spread = 1.0
        /// The smoothing's angular variance, radians².
        var blur: Float { let s = Float(smoothing * .pi / 180 / 2.354_82); return s * s }
    }

    /// The bands one layer of the body sums: a run of the field's bands, and for a source without a field the five
    /// analysis bands (`StereoBands`) it covers.
    struct Layer: Equatable {
        var bands: ClosedRange<Int>?
        var fiveBands: [Int]
    }

    /// What forms the body around a direction (the pointer's reading names the strongest).
    struct Lobe {
        enum Kind: Equatable { case speaker(Int), image }
        var kind: Kind
        /// Mean square, all its bands.
        var energy: Float
        var direction: SIMD3<Float>
        /// The principal axes across `direction`, and 1/S² along each (radians⁻²).
        var axis1: SIMD3<Float>
        var axis2: SIMD3<Float>
        var inverse1: Float
        var inverse2: Float
        /// 1 − stability: 0 for energy arriving in phase, 1 for energy that cancels at the listener.
        var instability: Float
        /// The mean coherence of an image's speakers (0 for a speaker's own energy).
        var coherence: Float
        /// The predicted perceived width (degrees at half maximum), without the display's smoothing.
        var width: Float
        /// The field bands it carries energy in.
        var bands: ClosedRange<Int>
        /// Its colour by frequency (`SpectralHue`, mixed by band energy) and its energy-weighted centre frequency, Hz.
        var hue: SIMD3<Float> = SIMD3(0.8, 0.8, 0.8)
        var centroid: Float = 1_000
        /// Its energy in each of the five analysis bands (lanes 0…4), adding up to `energy`.
        var fives = SIMD8<Float>.zero

        /// The kernel at unit direction `d`: 1 in the lobe's own direction (as `accumulate` computes it).
        func kernel(_ d: SIMD3<Float>) -> Float {
            let c = simd_dot(direction, d)
            let a = simd_dot(axis1, d), b = simd_dot(axis2, d), e = SpatialBody.epsilon
            let q = (a * a * inverse1 + b * b * inverse2 + e * 0.5 * (inverse1 + inverse2)) / (a * a + b * b + e)
            return SpatialBody.exp((c - 1) * q)
        }
    }

    private(set) var layerCount = 0
    /// The lowest row the body uses: the ear plane's, or the bottom of the sphere once a speaker of the layout sits
    /// below the ear plane. Rows below it hold nothing.
    private(set) var firstRow = SpatialBody.floorRow
    /// Per layer and direction (`count` each): the energy heard from it (mean square) and the part of it out of phase
    /// (energy × instability).
    private(set) var energy = [Float](repeating: 0, count: SpatialBody.count * SpatialBody.maxLayers)
    private(set) var unstable = [Float](repeating: 0, count: SpatialBody.count * SpatialBody.maxLayers)
    /// Per layer and direction, the energy heard from it in each of the five analysis bands: five planes,
    /// `planeStride` apart, adding up to `energy`.
    private(set) var bands = [Float](repeating: 0, count: StereoBands.count * SpatialBody.planeStride)
    static let planeStride = SpatialBody.count * SpatialBody.maxLayers
    /// Each field band's hue, log₂ centre (Hz) and analysis band, computed once.
    private let bandHue = (0..<SpatialField.bandCount).map { SpectralHue.at(hz: SpatialField.centre($0)) }
    private let bandLog = (0..<SpatialField.bandCount).map { Float(log2(SpatialField.centre($0))) }
    private let bandFive = (0..<SpatialField.bandCount).map { band in
        StereoBands.edges.lastIndex { SpatialField.centre(band) >= $0 } ?? 0
    }
    private let fiveLog = SpectralHue.centres.map { Float($0) }
    /// Per layer, the lobes that formed it.
    private(set) var lobes = [[Lobe]](repeating: [], count: SpatialBody.maxLayers)
    /// The LFE's mean square over every layer's bands: it has no direction, so it never shapes the body.
    private(set) var lfe: Float = 0

    // Speaker kernels for the layout, geometry and smoothing last used: speaker-major, `count` each.
    private var speakerKey: (layout: SpeakerLayout, geometry: UInt64, smoothing: Double)?
    private var speakers: [(role: Int, direction: SIMD3<Float>)] = []
    private var speakerKernels: [Float] = []
    private var speakerInverse: Float = 1

    // Coherent images merged per grid direction and phase (in phase, out of phase): their energy and its moments.
    private static let cells = SpatialBody.count * 2
    private var cellEnergy = [Float](repeating: 0, count: SpatialBody.cells)
    private var cellPosition = [SIMD3<Float>](repeating: .zero, count: SpatialBody.cells)
    /// Σ e (Σ + p pᵀ): xx xy xz yy yz zz per cell.
    private var cellMoments = [Float](repeating: 0, count: SpatialBody.cells * 6)
    private var cellStability = [Float](repeating: 0, count: SpatialBody.cells)
    private var cellCoherence = [Float](repeating: 0, count: SpatialBody.cells)
    private var cellBands = [ClosedRange<Int>](repeating: 0...0, count: SpatialBody.cells)
    /// Σ e·hue, Σ e·log₂(centre) and the energy in each analysis band, per cell.
    private var cellHue = [SIMD3<Float>](repeating: .zero, count: SpatialBody.cells)
    private var cellLog = [Float](repeating: 0, count: SpatialBody.cells)
    private var cellFives = [SIMD8<Float>](repeating: .zero, count: SpatialBody.cells)
    private var touched: [Int] = []
    /// Four rows of scratch for `accumulate`.
    private var work = [Float](repeating: 0, count: SpatialBody.count * 4)

    init() {
        touched.reserveCapacity(SpatialField.bandCount * SpatialField.coherentSlots)
        for layer in 0..<Self.maxLayers { lobes[layer].reserveCapacity(Role.count + 32) }
    }

    /// The grid direction nearest `d` (a unit vector).
    static func nearest(_ d: SIMD3<Float>) -> Int {
        let azimuth = atan2(Double(d.x), Double(d.y)) * 180 / .pi
        let elevation = asin(Double(max(-1, min(1, d.z)))) * 180 / .pi
        let a = (Int((azimuth / step).rounded()) % azimuthSteps + azimuthSteps) % azimuthSteps
        let e = max(0, min(rows - 1, Int((elevation / step).rounded()) + lowerSteps))
        return e * azimuthSteps + a
    }

    /// e^x for x ≤ 0, within 2e-5 of it (0.0001 dB): the integer part of x·log₂e as the exponent's bits, the rest by
    /// a polynomial. The body takes tens of thousands of these per frame.
    @inline(__always) static func exp(_ x: Float) -> Float {
        guard x > -87 else { return 0 }
        let y = x * 1.442_695_04
        let n = y.rounded(.down)
        let f = (y - n) * 0.693_147_18
        let p = 1 + f * (1 + f * (0.5 + f * (0.166_666_67 + f * (0.041_666_67 + f * (0.008_333_33 + f * 0.001_388_89)))))
        return Float(bitPattern: UInt32(Int32(n) + 127) << 23) * p
    }

    /// log10 for positive normal floats, within 0.0001 (0.001 dB): the exponent plus a polynomial for the mantissa.
    @inline(__always) static func log10(_ x: Float) -> Float {
        let bits = x.bitPattern
        let exponent = Float(Int32(bitPattern: (bits >> 23) & 0xFF) - 127)
        let m = Float(bitPattern: (bits & 0x007F_FFFF) | 0x3F80_0000) // 1 ≤ m < 2
        let t = (m - 1) / (m + 1) // log2(m) = 2/ln2 · atanh(t)
        let t2 = t * t
        let log2m = t * (2.885_390_08 + t2 * (0.961_796_69 + t2 * (0.577_078_02 + t2 * 0.412_198_57)))
        return (exponent + log2m) * 0.301_029_996
    }

    /// The angular σ (radians) of a spread σ (speaker radii) at `distance` from the listener: the half-maximum width
    /// 2·atan(1.1774 σ / distance), as `SpatialField.width` measures it, over 2·1.1774.
    @inline(__always) static func angle(sigma: Float, distance: Float) -> Float {
        atan2f(1.1774 * sigma, max(1e-3, distance)) / 1.1774
    }

    private func prepareSpeakers(layout: SpeakerLayout, geometry: SpatialGeometry, settings: Settings) {
        if let key = speakerKey, key.layout == layout, key.geometry == geometry.hash, key.smoothing == settings.smoothing { return }
        speakerKey = (layout, geometry.hash, settings.smoothing)
        firstRow = geometry.reachesBelow(roles: layout.roles) ? 0 : Self.floorRow
        speakers = layout.speakers.compactMap { speaker in
            guard speaker.group != .lfe, let d = geometry.direction(role: speaker.role) else { return nil }
            return (speaker.role, SIMD3(Float(d.x), Float(d.y), Float(d.z)))
        }
        speakerInverse = 1 / (Self.speakerAngle * Self.speakerAngle + settings.blur)
        speakerKernels = [Float](repeating: 0, count: speakers.count * Self.count)
        for (s, speaker) in speakers.enumerated() {
            for (i, d) in Self.directions.enumerated() {
                speakerKernels[s * Self.count + i] = Self.exp(-(1 - simd_dot(speaker.direction, d)) * speakerInverse)
            }
        }
    }

    /// Builds every layer's energy per direction from `field` (`SpatialField` layout; its status says whether it is
    /// one, or `SpatialFieldWire.unsupported` for a source with only `roleBandPower`, each role's five band powers).
    /// `shown`: per role, whether its speaker is drawn. Lobes whose energy stays below `floor` (dBFS) everywhere are
    /// left out.
    func evaluate(field: UnsafeBufferPointer<Float>, roleBandPower: [Float], layout: SpeakerLayout,
                  geometry: SpatialGeometry? = nil, shown: [Bool], layers: [Layer], settings: Settings, floor: Float,
                  metadataOnly: Bool = false) {
        let geometry = geometry ?? SpatialGeometry.standard(roles: layout.roles)
        let count = Self.count
        layerCount = min(Self.maxLayers, layers.count)
        // Radiant only needs the layer count and the separate LFE reading. Its points already carry positions.
        if metadataOnly {
            lfe = 0
            let status = field.count == SpatialField.floats ? field[SpatialField.status] : 0
            if shown.indices.contains(Role.lfe), shown[Role.lfe] {
                for layer in layers.prefix(layerCount) {
                    if status == 1, let range = layer.bands {
                        for band in range { lfe += max(0, field[SpatialField.independent(band: band, role: Role.lfe)]) }
                    } else if status == SpatialFieldWire.unsupported {
                        for five in layer.fiveBands {
                            let i = Role.lfe * StereoBands.count + five
                            if roleBandPower.indices.contains(i) { lfe += max(0, roleBandPower[i]) }
                        }
                    }
                }
            }
            if !lfe.isFinite { lfe = 0 }
            return
        }
        prepareSpeakers(layout: layout, geometry: geometry, settings: settings)
        lfe = 0
        let used = layerCount * count
        energy.withUnsafeMutableBufferPointer { UnsafeMutableBufferPointer(rebasing: $0[0..<used]).update(repeating: 0) }
        unstable.withUnsafeMutableBufferPointer { UnsafeMutableBufferPointer(rebasing: $0[0..<used]).update(repeating: 0) }
        bands.withUnsafeMutableBufferPointer { planes in
            for f in 0..<StereoBands.count {
                (planes.baseAddress! + f * Self.planeStride).update(repeating: 0, count: used)
            }
        }
        for layer in 0..<Self.maxLayers { lobes[layer].removeAll(keepingCapacity: true) }
        let status = field.count == SpatialField.floats ? field[SpatialField.status] : 0
        guard status == 1 || status == SpatialFieldWire.unsupported else { return }
        let floorEnergy = Float(pow(10, Double(floor) / 10))
        func isShown(_ role: Int) -> Bool { shown.indices.contains(role) && shown[role] }
        func bandPower(_ role: Int, _ five: Int) -> Float {
            let i = role * StereoBands.count + five
            guard roleBandPower.indices.contains(i), roleBandPower[i].isFinite else { return 0 }
            return max(0, roleBandPower[i])
        }
        let speakerWidth = SpatialField.width(position: SIMD3(0, 1, 0), spread: 0)
        for (l, layer) in layers.prefix(layerCount).enumerated() {
            let base = l * count
            // Each speaker's own energy: its kernel scaled by its level.
            for (s, speaker) in speakers.enumerated() where isShown(speaker.role) {
                var e: Float = 0, tint = SIMD3<Float>.zero, logSum: Float = 0, fives = SIMD8<Float>.zero
                if status == 1, let range = layer.bands {
                    for band in range {
                        let b = max(0, field[SpatialField.independent(band: band, role: speaker.role)])
                        e += b; tint += bandHue[band] * b; logSum += bandLog[band] * b; fives[bandFive[band]] += b
                    }
                } else if status == SpatialFieldWire.unsupported {
                    for five in layer.fiveBands {
                        let b = bandPower(speaker.role, five)
                        e += b; tint += SpectralHue.bands[five] * b; logSum += fiveLog[five] * b; fives[five] += b
                    }
                }
                guard e.isFinite, tint.x.isFinite, e > floorEnergy * 0.001 else { continue }
                // Only the rows the body uses: below the ear plane only while a speaker of the layout is there.
                let lowest = firstRow * Self.azimuthSteps
                speakerKernels.withUnsafeBufferPointer { kernels in
                energy.withUnsafeMutableBufferPointer { energy in
                bands.withUnsafeMutableBufferPointer { planes in
                    let kernel = kernels.baseAddress! + s * count + lowest, n = vDSP_Length(count - lowest)
                    let out = energy.baseAddress! + base + lowest
                    vDSP_vsma(kernel, 1, &e, out, 1, out, 1, n)
                    for f in 0..<StereoBands.count where fives[f] > 0 {
                        var part = fives[f]
                        let plane = planes.baseAddress! + f * Self.planeStride + base + lowest
                        vDSP_vsma(kernel, 1, &part, plane, 1, plane, 1, n)
                    }
                }}}
                let mix = simd_clamp(tint / e, .zero, SIMD3(repeating: 1))
                let across = Self.across(speaker.direction)
                lobes[l].append(Lobe(kind: .speaker(speaker.role), energy: e, direction: speaker.direction, axis1: across.0,
                                     axis2: across.1, inverse1: speakerInverse, inverse2: speakerInverse, instability: 0,
                                     coherence: 0, width: speakerWidth, bands: layer.bands ?? 0...(SpatialField.bandCount - 1),
                                     hue: mix, centroid: exp2f(logSum / e), fives: fives))
            }
            if isShown(Role.lfe) {
                if status == 1, let bands = layer.bands {
                    for band in bands { lfe += max(0, field[SpatialField.independent(band: band, role: Role.lfe)]) }
                } else if status == SpatialFieldWire.unsupported {
                    for five in layer.fiveBands { lfe += bandPower(Role.lfe, five) }
                }
            }
            guard status == 1, let bands = layer.bands else { continue }
            mergeImages(field: field, bands: bands, floorEnergy: floorEnergy)
            addImages(layer: l, settings: settings, floorEnergy: floorEnergy)
        }
        if !lfe.isFinite { lfe = 0 }
    }

    /// Two unit vectors across `u` (any, for a round lobe).
    private static func across(_ u: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        var t = simd_cross(SIMD3<Float>(0, 0, 1), u)
        let length = simd_length(t)
        t = length > 1e-3 ? t / length : SIMD3(1, 0, 0)
        return (t, simd_cross(u, t))
    }

    /// The layer's coherent images, merged where they image in the same grid direction with the same phase (across
    /// bands one image recurs in nearly the same place): energies add, positions and spreads are energy-weighted, and
    /// the spread grows by the members' own scatter, so the merged lobe is as wide as their sum.
    private func mergeImages(field: UnsafeBufferPointer<Float>, bands: ClosedRange<Int>, floorEnergy: Float) {
        for band in bands {
            for slot in 0..<SpatialField.coherentSlots {
                let o = SpatialField.component(band: band, slot: slot)
                let e = field[o + SpatialField.Component.energy]
                guard e.isFinite, e > floorEnergy * 0.01 else { continue }
                let p = SIMD3(field[o + SpatialField.Component.x], field[o + SpatialField.Component.y], field[o + SpatialField.Component.z])
                let distance = simd_length(p)
                let stability = max(0, min(1, field[o + SpatialField.Component.stability]))
                let cell = Self.nearest(distance > 1e-4 ? p / distance : SIMD3(0, 1, 0)) * 2 + (stability < 0.5 ? 1 : 0)
                if cellEnergy[cell] == 0 {
                    touched.append(cell)
                    cellBands[cell] = band...band
                } else {
                    cellBands[cell] = cellBands[cell].lowerBound...band
                }
                cellEnergy[cell] += e
                cellPosition[cell] += p * e
                let m = cell * 6, s = o + SpatialField.Component.xx
                cellMoments[m] += e * (field[s] + p.x * p.x)
                cellMoments[m + 1] += e * (field[s + 1] + p.x * p.y)
                cellMoments[m + 2] += e * (field[s + 2] + p.x * p.z)
                cellMoments[m + 3] += e * (field[s + 3] + p.y * p.y)
                cellMoments[m + 4] += e * (field[s + 4] + p.y * p.z)
                cellMoments[m + 5] += e * (field[s + 5] + p.z * p.z)
                cellStability[cell] += e * stability
                cellCoherence[cell] += e * max(0, min(1, field[o + SpatialField.Component.coherence]))
                cellHue[cell] += bandHue[band] * e
                cellLog[cell] += bandLog[band] * e
                cellFives[cell][bandFive[band]] += e
            }
        }
    }

    /// Turns the merged images into lobes, adds them to `layer` and clears the cells.
    private func addImages(layer l: Int, settings: Settings, floorEnergy: Float) {
        let base = l * Self.count
        let blur = settings.blur, gain = Float(max(0, settings.spread))
        let speaker2 = SpatialField.speakerSpread * SpatialField.speakerSpread
        for cell in touched {
            let e = cellEnergy[cell]
            let p = cellPosition[cell] / e
            let m = cell * 6
            // Σ = E[Σᵢ + pᵢpᵢᵀ] − p̄p̄ᵀ, the members' spreads and their scatter.
            let xx = cellMoments[m] / e - p.x * p.x, xy = cellMoments[m + 1] / e - p.x * p.y
            let xz = cellMoments[m + 2] / e - p.x * p.z, yy = cellMoments[m + 3] / e - p.y * p.y
            let yz = cellMoments[m + 4] / e - p.y * p.z, zz = cellMoments[m + 5] / e - p.z * p.z
            let distance = simd_length(p)
            let u = distance > 1e-4 ? p / distance : SIMD3<Float>(0, 1, 0)
            let (t1, t2) = Self.across(u)
            // The spread across the direction (seen from the listener), and its principal axes.
            func quadratic(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
                a.x * (xx * b.x + xy * b.y + xz * b.z) + a.y * (xy * b.x + yy * b.y + yz * b.z) + a.z * (xz * b.x + yz * b.y + zz * b.z)
            }
            let a = quadratic(t1, t1), b = quadratic(t1, t2), c = quadratic(t2, t2)
            let mid = (a + c) / 2, half = (((a - c) / 2) * ((a - c) / 2) + b * b).squareRoot()
            let major = max(0, mid + half), minor = max(0, mid - half)
            let phi = 0.5 * atan2f(2 * b, a - c)
            let axis1 = t1 * cosf(phi) + t2 * sinf(phi), axis2 = t2 * cosf(phi) - t1 * sinf(phi)
            let s1 = Self.angle(sigma: (speaker2 + gain * major).squareRoot(), distance: distance)
            let s2 = Self.angle(sigma: (speaker2 + gain * minor).squareRoot(), distance: distance)
            let lobe = Lobe(kind: .image, energy: e, direction: u, axis1: axis1, axis2: axis2,
                            inverse1: 1 / (s1 * s1 + blur), inverse2: 1 / (s2 * s2 + blur),
                            instability: 1 - cellStability[cell] / e, coherence: cellCoherence[cell] / e,
                            width: SpatialField.width(position: p, spread: major), bands: cellBands[cell],
                            hue: simd_clamp(cellHue[cell] / e, .zero, SIMD3(repeating: 1)), centroid: exp2f(cellLog[cell] / e),
                            fives: cellFives[cell])
            lobes[l].append(lobe)
            // Only the rows within reach: beyond the angle where even the widest axis has fallen 6 dB under the floor,
            // nothing it adds could show.
            let reach = 1 - Foundation.log(max(1, e / floorEnergy * 4)) / min(lobe.inverse1, lobe.inverse2)
            let angle = Double(acosf(max(-1, min(1, reach)))), elevation = Double(asinf(max(-1, min(1, u.z))))
            let first = max(firstRow, Int(((elevation - angle) * 180 / .pi / Self.step).rounded(.down)) + Self.lowerSteps)
            let last = min(Self.rows - 1, Int(((elevation + angle) * 180 / .pi / Self.step).rounded(.up)) + Self.lowerSteps)
            if first <= last {
                accumulate(lobe, from: base + first * Self.azimuthSteps, count: (last - first + 1) * Self.azimuthSteps)
            }
            cellEnergy[cell] = 0
            cellPosition[cell] = .zero
            for k in 0..<6 { cellMoments[m + k] = 0 }
            cellStability[cell] = 0
            cellCoherence[cell] = 0
            cellHue[cell] = .zero
            cellLog[cell] = 0
            cellFives[cell] = .zero
        }
        touched.removeAll(keepingCapacity: true)
    }

    /// Adds the lobe's energy × its kernel (and × its instability, the part out of phase) to `count` directions of the
    /// layer arrays from `start`, all at once with Accelerate: the three projections, the kernel's exponent, its
    /// exponential and the sums.
    private func accumulate(_ lobe: Lobe, from start: Int, count: Int) {
        let row = start % Self.count, n = vDSP_Length(count)
        var ux = lobe.direction.x, uy = lobe.direction.y, uz = lobe.direction.z
        var ax = lobe.axis1.x, ay = lobe.axis1.y, az = lobe.axis1.z
        var bx = lobe.axis2.x, by = lobe.axis2.y, bz = lobe.axis2.z
        var i1 = lobe.inverse1, i2 = lobe.inverse2
        var epsilon = Self.epsilon, mean = Self.epsilon * 0.5 * (lobe.inverse1 + lobe.inverse2)
        var minusOne: Float = -1, low: Float = -87, high: Float = 0
        var e = lobe.energy, unsteady = lobe.energy * lobe.instability
        var length = Int32(count)
        Self.dx.withUnsafeBufferPointer { X in
        Self.dy.withUnsafeBufferPointer { Y in
        Self.dz.withUnsafeBufferPointer { Z in
        work.withUnsafeMutableBufferPointer { w in
        energy.withUnsafeMutableBufferPointer { out in
        unstable.withUnsafeMutableBufferPointer { phase in
        bands.withUnsafeMutableBufferPointer { planes in
            let x = X.baseAddress! + row, y = Y.baseAddress! + row, z = Z.baseAddress! + row
            let c = w.baseAddress!, a = c + Self.count, b = a + Self.count, q = b + Self.count
            vDSP_vsmsma(x, 1, &ux, y, 1, &uy, c, 1, n); vDSP_vsma(z, 1, &uz, c, 1, c, 1, n)
            vDSP_vsmsma(x, 1, &ax, y, 1, &ay, a, 1, n); vDSP_vsma(z, 1, &az, a, 1, a, 1, n)
            vDSP_vsmsma(x, 1, &bx, y, 1, &by, b, 1, n); vDSP_vsma(z, 1, &bz, b, 1, b, 1, n)
            vDSP_vsq(a, 1, a, 1, n); vDSP_vsq(b, 1, b, 1, n)
            // q = (a²/S₁² + b²/S₂² + ε·mean)/(a² + b² + ε), the exponent (c − 1)·q, its exponential.
            vDSP_vsmsma(a, 1, &i1, b, 1, &i2, q, 1, n); vDSP_vsadd(q, 1, &mean, q, 1, n)
            vDSP_vadd(a, 1, b, 1, a, 1, n); vDSP_vsadd(a, 1, &epsilon, a, 1, n)
            vDSP_vdiv(a, 1, q, 1, q, 1, n)
            vDSP_vsadd(c, 1, &minusOne, c, 1, n); vDSP_vmul(c, 1, q, 1, q, 1, n)
            vDSP_vclip(q, 1, &low, &high, q, 1, n)
            vvexpf(q, q, &length)
            vDSP_vsma(q, 1, &e, out.baseAddress! + start, 1, out.baseAddress! + start, 1, n)
            if unsteady > 0 { vDSP_vsma(q, 1, &unsteady, phase.baseAddress! + start, 1, phase.baseAddress! + start, 1, n) }
            for f in 0..<StereoBands.count where lobe.fives[f] > 0 {
                var part = lobe.fives[f]
                let plane = planes.baseAddress! + f * Self.planeStride + start
                vDSP_vsma(q, 1, &part, plane, 1, plane, 1, n)
            }
        }}}}}}}
    }

    /// How loud each analysis band is heard by `layer` from grid direction `index` (mean squares, lanes 0…4).
    func fives(layer: Int, index: Int) -> SIMD8<Float> {
        var result = SIMD8<Float>.zero
        for f in 0..<StereoBands.count { result[f] = bands[f * Self.planeStride + layer * Self.count + index] }
        return result
    }

    /// The layer's level (dBFS) toward the grid direction nearest (`azimuth`, `elevation`), degrees.
    func level(layer: Int, azimuth: Double, elevation: Double) -> Float {
        let d = SpeakerGeometry.direction(azimuth: azimuth, elevation: elevation)
        let i = Self.nearest(SIMD3(Float(d.x), Float(d.y), Float(d.z)))
        let e = energy[layer * Self.count + i]
        return e > 0 ? 10 * Foundation.log10(e) : -.infinity
    }

    /// The lobe of `layer` that adds the most energy toward unit direction `d` (field frame), and how much.
    func strongest(layer: Int, toward d: SIMD3<Float>) -> (lobe: Lobe, energy: Float)? {
        guard layer < layerCount else { return nil }
        var best: (Lobe, Float)?
        for lobe in lobes[layer] {
            let e = lobe.energy * lobe.kernel(d)
            if e > (best?.1 ?? 0) { best = (lobe, e) }
        }
        return best
    }
}
