import Accelerate
import Foundation

/// Where each speaker role sits around the listener: the schematic positions every immersive display and the spatial
/// field share. Azimuth in degrees clockwise from the front (ITU-R BS.2051 / Dolby layouts), elevation 0 for the ear
/// layer and a schematic 45° for every upper speaker, because a channel map carries roles, not measured angles.
/// Side surrounds sit at ±110° in 5.x and quad, at ±90° once rear surrounds join them.
package enum SpeakerGeometry {
    package static func azimuth(role: Int, sidesAtNinety: Bool) -> Double? {
        let side = sidesAtNinety ? 90.0 : 110
        switch role {
        case Role.left: return -30
        case Role.right: return 30
        case Role.center: return 0
        case Role.leftSurround: return -side
        case Role.rightSurround: return side
        case Role.leftTopFront: return -45
        case Role.rightTopFront: return 45
        case Role.leftRearSurround: return -150
        case Role.rightRearSurround: return 150
        case Role.leftWide: return -60
        case Role.rightWide: return 60
        case Role.leftTopMiddle: return -90
        case Role.rightTopMiddle: return 90
        case Role.leftTopRear: return -135
        case Role.rightTopRear: return 135
        default: return nil  // the LFE
        }
    }

    package static func isHeight(_ role: Int) -> Bool {
        role == Role.leftTopFront || role == Role.rightTopFront || role == Role.leftTopMiddle
            || role == Role.rightTopMiddle || role == Role.leftTopRear || role == Role.rightTopRear
    }

    package static func elevation(role: Int) -> Double { isHeight(role) ? 45 : 0 }

    /// Whether a set of roles places its side surrounds at ±90° (a 7.x or 9.x bed, which has rear surrounds).
    package static func sidesAtNinety(_ roles: [Int]) -> Bool {
        roles.contains(Role.leftRearSurround) || roles.contains(Role.rightRearSurround)
    }

    /// The spatial field's frame (listener at the origin, unit radius at the speakers): x to the right, y to the
    /// front, z up.
    package static func direction(azimuth: Double, elevation: Double) -> SIMD3<Double> {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        return SIMD3(sin(a) * cos(e), cos(a) * cos(e), sin(e))
    }

    /// nil for the LFE, which has no direction.
    package static func direction(role: Int, sidesAtNinety: Bool) -> SIMD3<Double>? {
        azimuth(role: role, sidesAtNinety: sidesAtNinety).map { direction(azimuth: $0, elevation: elevation(role: role)) }
    }
}

/// The frequency-dependent spatial energy field of the loudspeaker feeds, as published in every snapshot
/// (`SnapshotSlots.spatialField`) and, compactly, in RESULT tag 53. An estimate of where each band's feed energy would
/// image, not a reconstruction of the acoustic sound field.
///
/// For each of `bandCount` log-spaced bands from 20 Hz to 20 kHz it holds a small Gaussian mixture of the band's
/// energy: one compact component at every speaker for the energy that is independent there (its mean square in that
/// band, per role; the LFE's is its own, non-directional energy), and up to `coherentSlots` coherent components for
/// energy that several speakers share coherently (a phantom image, or an anti-phase spread). The parts never
/// overlap: a speaker's band energy is split between its independent part and the coherent components it belongs to,
/// so the mixture's energies add up to the band's feed energy.
///
/// Layout: `headerFloats` (status, coherence threshold, speakers analysed, spare), then per band `Role.count`
/// independent energies in role order, then the coherent slots of `componentFloats` each: energy (mean square),
/// position x y z (x right, y front, z up; the speakers on the unit sphere), its predicted spread as a covariance
/// (xx xy xz yy yz zz, beyond the `speakerSpread` of one loudspeaker's image; `image`), stability (1 when the shared
/// energy arrives in phase, 0 when it cancels at the listener) and the mean coherence of its speakers. A coherent slot
/// keeps its place from one snapshot to the next while its image lasts, so a display can smooth it; an empty slot has
/// energy 0 and keeps its last position.
package enum SpatialField {
    package static let bandCount = 96
    package static let lowestFrequency = 20.0
    package static let highestFrequency = 20_000.0
    package static let coherentSlots = 3
    package static let componentFloats = 12
    package static let headerFloats = 4
    package static let bandFloats = Role.count + coherentSlots * componentFloats
    package static let floats = headerFloats + bandCount * bandFloats

    /// Header fields: 1 while the field describes the newest audio, the coherence threshold it used, and the
    /// full-range speakers it analysed.
    package static let status = 0, threshold = 1, speakers = 2
    /// Fields of a coherent component.
    package enum Component {
        package static let energy = 0, x = 1, y = 2, z = 3, xx = 4, xy = 5, xz = 6, yy = 7, yz = 8, zz = 9
        package static let stability = 10, coherence = 11
    }

    /// Edge `index` (0…`bandCount`) of the bands, in Hz: `bandCount` equal steps of log frequency.
    package static func edge(_ index: Int) -> Double {
        lowestFrequency * pow(highestFrequency / lowestFrequency, Double(index) / Double(bandCount))
    }
    /// Geometric centre of a band, in Hz.
    package static func centre(_ band: Int) -> Double { (edge(band) * edge(band + 1)).squareRoot() }
    /// Offset of a band's independent energy of `role`.
    package static func independent(band: Int, role: Int) -> Int { headerFloats + band * bandFloats + role }
    /// Offset of a coherent slot of a band.
    package static func component(band: Int, slot: Int) -> Int {
        headerFloats + band * bandFloats + Role.count + slot * componentFloats
    }
    /// The default coherence threshold: below it two speakers share no image.
    package static let defaultThreshold: Float = 0.3
    package static let thresholdRange: ClosedRange<Float> = 0.05...0.95

    // MARK: Image model

    /// One loudspeaker's image as a Gaussian, σ in speaker radii: its half-maximum width, 2·1.1774·σ ≈ 0.187 rad, is
    /// the 10.7° Frank's regression (below) gives a single loudspeaker. Displays draw independent energy at this size.
    package static let speakerSpread: Float = 0.0795
    /// Energy that cancels at the listener (stability 0): the share of its speakers' scatter it spreads over, the
    /// isotropic variance it adds, and how far it is drawn toward the listener, where anti-phase sound is heard.
    package static let unstableSpread: Float = 0.5
    package static let diffuseSpread: Float = 0.02
    package static let inHead: Float = 0.5
    /// Below `velocityBelow` Hz an image takes its velocity vector's direction, above `energyAbove` its energy
    /// vector's, between them a mix along log frequency (Gerzon's ≈ 700 Hz crossover at its middle).
    package static let velocityBelow = 400.0, energyAbove = 1_200.0

    /// How much of an image's direction comes from the velocity vector at `hz`: 1 in the bass, 0 in the treble.
    package static func velocityWeight(hz: Double) -> Float {
        let t = max(0, min(1, log(hz / velocityBelow) / log(energyAbove / velocityBelow)))
        return Float(1 - t * t * (3 - 2 * t))
    }

    /// Where a coherent component images and how wide, from its speakers: `count` members with unit `directions`,
    /// coherent energies `energies` (any scale) and phases `cosines`/`sines` relative to any one of them. Writes
    /// position, spread (`Component.xx`…`zz`) and stability into `out`, a component in the `SpatialField` layout.
    ///
    /// - Direction: Gerzon's energy vector r_E = Σ wᵢuᵢ / Σ wᵢ above `energyAbove`; below `velocityBelow` the velocity
    ///   vector r_V = Σ uᵢ Re(gᵢ p*) / |p|² of the complex gains gᵢ and their sum p (the tangent law for a pair), as far
    ///   as the image is stable: when the gains cancel, r_V has no meaning and r_E stands.
    /// - Stability |p|² / (Σ |gᵢ|)²: 1 in phase, 0 when the shared energy cancels at the listener.
    /// - Width: the members' energy-weighted scatter around r_E (trace 1 − |r_E|², along the line the speakers span),
    ///   scaled so that, with `speakerSpread` added, the image's half-maximum width seen from the listener follows
    ///   Frank's regression of perceived source width on |r_E|, α = 186.4°·(1 − |r_E|) + 10.7° (M. Frank, Archives of
    ///   Acoustics 38(3), 2013; R² 0.97, from frontal pairs 10° to 80° apart with and without a centre speaker, pink
    ///   noise): 0.054 + 0.292·arccos|r_E|, within 2 % of it for pairs 20° to 120° apart. In phase, a pair 60° apart
    ///   images about 36° wide where one speaker is 10.7°. Lateral, rear and height images use the same relation.
    /// - Out of phase (instability u = 1 − stability), the image has no stable direction: its spread grows toward
    ///   `unstableSpread` of the scatter plus `diffuseSpread` all round, and it is drawn toward the listener by
    ///   `inHead`·u², as anti-phase sound is heard wide and close, often inside the head.
    package static func image(count: Int, directions: UnsafePointer<SIMD3<Float>>, energies: UnsafePointer<Float>,
                              cosines: UnsafePointer<Float>, sines: UnsafePointer<Float>, velocityWeight: Float,
                              into out: UnsafeMutablePointer<Float>) {
        var total: Float = 0
        for m in 0..<count { total += max(0, energies[m]) }
        guard total > 0 else { return }
        var energyVector = SIMD3<Float>.zero
        var pressureRe: Float = 0, pressureIm: Float = 0, amplitudes: Float = 0
        for m in 0..<count {
            let w = max(0, energies[m]) / total
            energyVector += directions[m] * w
            let amplitude = w.squareRoot()
            pressureRe += amplitude * cosines[m]
            pressureIm += amplitude * sines[m]
            amplitudes += amplitude
        }
        let pressure = pressureRe * pressureRe + pressureIm * pressureIm
        let stability = amplitudes > 0 ? min(1, pressure / (amplitudes * amplitudes)) : 0
        var velocity = SIMD3<Float>.zero
        var xx: Float = 0, xy: Float = 0, xz: Float = 0, yy: Float = 0, yz: Float = 0, zz: Float = 0
        for m in 0..<count {
            let w = max(0, energies[m]) / total
            let d = directions[m] - energyVector
            xx += w * d.x * d.x; xy += w * d.x * d.y; xz += w * d.x * d.z
            yy += w * d.y * d.y; yz += w * d.y * d.z; zz += w * d.z * d.z
            if pressure > 1e-12 {
                velocity += directions[m] * (w.squareRoot() * (cosines[m] * pressureRe + sines[m] * pressureIm) / pressure)
            }
        }
        var position = energyVector
        if velocityWeight > 0 && pressure > 1e-12 {
            let speed = (velocity * velocity).sum().squareRoot()
            if speed > 1 { velocity /= speed }
            position += (velocity - energyVector) * (velocityWeight * stability * stability)
        }
        let unstable = 1 - stability, u2 = unstable * unstable
        let focus = min(1, (energyVector * energyVector).sum().squareRoot())
        let inPhase = 0.054 + 0.292 * acosf(focus)
        let scale = inPhase + (max(inPhase, unstableSpread) - inPhase) * u2
        let diffuse = diffuseSpread * u2
        position *= 1 - inHead * u2
        out[Component.x] = position.x
        out[Component.y] = position.y
        out[Component.z] = position.z
        out[Component.xx] = scale * xx + diffuse
        out[Component.xy] = scale * xy
        out[Component.xz] = scale * xz
        out[Component.yy] = scale * yy + diffuse
        out[Component.yz] = scale * yz
        out[Component.zz] = scale * zz + diffuse
        out[Component.stability] = stability
    }

    /// The predicted perceived width (degrees, at half maximum) of a component as `image` wrote it: its widest axis
    /// with one loudspeaker's spread added, seen from the listener.
    package static func width(position: SIMD3<Float>, spread largest: Float) -> Float {
        let sigma = (speakerSpread * speakerSpread + max(0, largest)).squareRoot()
        let distance = (position * position).sum().squareRoot()
        return 2 * atan2f(1.1774 * sigma, max(1e-3, distance)) * 180 / .pi
    }
}

/// The newest Spatial transform's own bins, placed as a spatial analyser places each frequency: at the centre of gravity
/// of the full-range speakers, weighted by the bin's amplitude in each, Σ|Xᵢ|uᵢ / Σ|Xᵢ| (uᵢ a speaker's unit
/// direction). A source panned between two speakers lands on the line between them where its gains put it, two sources
/// sharing a band keep their own places, and sound the speakers carry independently scatters bin by bin. Published
/// beside the field (`SnapshotSlots.spatialPoints`) and in RESULT tag 54; the LFE, which has no direction, takes no
/// part.
///
/// A band keeps at most `perBand` points, each with its energy (mean square over the full-range speakers, so a band's
/// points add up to its feed energy). A band with more bins than that draws them in proportion to their energy
/// (systematic resampling, one random offset per band and transform) and merges a bin drawn more than once, so a strong
/// partial is never missed and the points still add up to the band's energy.
///
/// Layout: status (1 while the points describe the newest audio), then per band its number of points and `perBand`
/// slots of x y z energy (x right, y front, z up; the speakers on the unit sphere).
package enum SpatialPoints {
    package static let perBand = 32
    package static let pointFloats = 4
    package static let bandFloats = 1 + perBand * pointFloats
    package static let floats = 1 + SpatialField.bandCount * bandFloats
    package static let status = 0
    /// Offset of a band's number of points.
    package static func count(band: Int) -> Int { 1 + band * bandFloats }
    /// Offset of a band's point `index` (x, y, z, energy).
    package static func point(band: Int, index: Int) -> Int { 1 + band * bandFloats + 1 + index * pointFloats }
}

/// Builds the spatial field (`SpatialField`) from the spectrum's own transforms: each role's complex spectrum, the
/// cross-spectral matrix of the speakers per band, smoothed to estimate coherence, and a decomposition of each band's
/// energy into independent and coherent parts. Owned by the analysis thread with its `SpectrumAnalyzer`; allocates
/// only when created.
///
/// Per band and per transform (60 per second):
/// 1. The cross-spectral matrix C = Σ_k w_k X_k X_kᴴ over the band's bins (fractional weights where a band edge
///    falls inside a bin, so every bin's energy is counted once), in mean-square units. Its diagonal is each
///    speaker's band energy now.
/// 2. A smoothed copy estimates coherence, γ_ij = C̄_ij / √(C̄_ii C̄_jj). Its smoothing time grows toward the bass
///    (60 ms to 1 s) so that every band averages about 32 independent estimates (bins × time, fewer in the
///    lowest bands), and |γ|² is corrected for the chance coherence of the averages actually behind it and of the
///    number of speaker pairs compared: uncorrelated speakers read 0, and a band that has only just started
///    sounding is not called coherent before the evidence is there.
/// 3. Speakers whose coherence exceeds the threshold θ share energy, by s = (|γ| − θ)/(1 − θ), rising continuously
///    from 0. Every set of mutually coherent speakers (a maximal clique of that graph) is one coherent component, so
///    two phantom pairs sharing a centre speaker stay two images while a source panned over three speakers is one. A
///    speaker's coherent fraction ρ = max s is divided among its components by its mean share with their other
///    members; the rest of its energy stays independent at the speaker.
/// 4. A component images where `SpatialField.image` puts it, from its speakers' coherent energies and the coherence
///    phases: in the direction of Gerzon's velocity vector in the bass and of his energy vector in the treble, as wide
///    as Frank's model of perceived source width predicts from the energy vector, with a stability
///    |Σ g_i|² / (Σ |g_i|)² (1 in phase, 0 for energy that cancels at the listener); energy that cancels spreads wide
///    and is drawn toward the listener.
package final class SpatialFieldAnalyzer {
    package let sampleRate: Double
    package let transformLength: Int
    /// Analysed roles in slot order: the full-range roles first, then the LFE when routed.
    package let roles: [Int]
    /// Transforms per field: the field is built from every second transform (30 per second). Successive transforms
    /// share 90 % of their 170 ms window, so the skipped ones add almost nothing it could show.
    package static let interval = 2
    /// The multi-resolution observations (`SpatialGeometry.Window.multiResolution`): zone 1 a quarter of the spectrum's
    /// transform (about 43 ms at every rate) for bands centred from 1 kHz, zone 2 an eighth (about 21 ms) from 4 kHz; each
    /// window ends at the newest sample, so its centre, the observation's time, is later the shorter it is. A band takes
    /// all its energy from one zone (nothing is counted twice); the coherence statistics keep the full transform.
    package static let zoneDivisors = [4, 8]
    package static let zoneEdges = [1_000.0, 4_000.0]
    private let fullRange: Int
    private let slotCount: Int
    private let slotOfRole: [Int]
    /// Where every speaker sits and how observations are mapped (`SpatialGeometry`): the standard layout of the roles
    /// until a display sets its own. Set between transforms (the analysis thread's, or before the first).
    package var geometry: SpatialGeometry { didSet { if geometry != oldValue { placeSpeakers() } } }
    /// Places the bins as Build 87–97 did (`SpatialPoints`, the standard layout's directions) instead of observing: for a
    /// display that reads RESULT tag 54 and not the observations (a Bridge plugin serving an app before build 98, which
    /// would never receive them). Its frames have no observations (status 0).
    package var legacyPoints = false
    /// Coherence below which speakers share no image, within `SpatialField.thresholdRange`.
    package var coherenceThreshold = SpatialField.defaultThreshold {
        didSet {
            let range = SpatialField.thresholdRange
            if !range.contains(coherenceThreshold) {
                coherenceThreshold = coherenceThreshold.isFinite ? min(range.upperBound, max(range.lowerBound, coherenceThreshold))
                    : SpatialField.defaultThreshold
            }
        }
    }

    /// The transform's bins the field reads: `firstBin` … `firstBin + binCount − 1`.
    private let firstBin: Int
    private let binCount: Int
    /// A band's bins (relative to `firstBin`), the weights of its partial edge bins, and the step between the inner
    /// bins its cross-spectra read (`maxInner`).
    private struct Span { var first = 0, last = -1; var firstWeight: Float = 0, lastWeight: Float = 0; var step = 1 }
    /// Inner bins a band's cross-spectra read at most: a wide treble band (up to ~340 bins) has far more independent
    /// estimates than coherence needs, so it reads every second or third bin there. Its energies stay exact.
    private static let maxInner = 40
    private let spans: [Span]
    /// The multi-resolution zones: per zone its complex spectra (bin-major, every slot), first bin and bins, bin width,
    /// mean-square scale, and per band its span; each band's zone.
    private struct ZoneGrid {
        let length: Int
        let firstBin: Int
        let binCount: Int
        let binWidth: Double
        let scale: Float
        let spans: [Span]
        let spectra: UnsafeMutablePointer<Float>
    }
    private let zoneGrids: [ZoneGrid]
    private let zoneOfBand: [Int]
    /// Per band: the coherence smoothing time, the effective bins (Hann's 1.5-bin noise bandwidth) and how much of an
    /// image's direction comes from the velocity vector (`SpatialField.velocityWeight`).
    private let smoothing: [Double]
    private let effectiveBins: [Double]
    private let velocityWeights: [Float]
    /// Seconds over which successive (overlapping) transforms are correlated.
    private let correlationTime: Double
    private var phase = 0

    // Storage, allocated once: flat buffers, so the per-band loops run without exclusivity or bounds checks.
    /// Complex spectra, bin-major: for each bin every slot's (re, im), full window.
    private let spectra: UnsafeMutablePointer<Float>
    /// Per band, slotCount² complex values (column-major, upper triangle): this field's matrix and the smoothed one.
    private let frame: UnsafeMutablePointer<Float>
    private let slow: UnsafeMutablePointer<Float>
    /// Per band: seconds sounding and seconds silent, and the sums of the smoothing's weights and squared weights
    /// over the fields averaged (Σw, Σw²), whose ratio (Σw)²/Σw² is how many fields the average really rests on.
    private let activeTime: UnsafeMutablePointer<Double>
    private let silentTime: UnsafeMutablePointer<Double>
    private let weightSum: UnsafeMutablePointer<Double>
    private let weightSquares: UnsafeMutablePointer<Double>
    /// Seconds between fields (`interval` transforms).
    private let fieldSeconds = Double(SpatialFieldAnalyzer.interval) / MeterPipeline.tickRate
    /// Coherent slots carried over: per band and slot, the image's position and whether it is alive.
    private let slotPosition: UnsafeMutablePointer<SIMD3<Float>>
    private let slotAlive: UnsafeMutablePointer<Bool>
    /// The newest field (`SpatialField` layout) and its bins (`SpatialPoints` layout); each bin's energy in the band
    /// being placed, and how many fields have placed points (their random offsets are hashed from it).
    private let values: UnsafeMutablePointer<Float>
    private let points: UnsafeMutablePointer<Float>
    private let binEnergy: UnsafeMutablePointer<Float>
    private var pointSerial: UInt32 = 0
    /// Directions of the full-range slots (x right, y front, z up): unit vectors, which the coherence model uses; their
    /// positions in the geometry's mapping, which the observations use; whether each takes part in the picture (the
    /// LFE and a speaker left out do not); and the largest distance among them (1 for directions).
    private let directions: UnsafeMutablePointer<SIMD3<Float>>
    private let positions: UnsafeMutablePointer<SIMD3<Float>>
    private let directional: UnsafeMutablePointer<Bool>
    private var extent: Float = 1
    /// The newest observations (`SpatialObservations` layout), the one reduction that makes them, and how many frames
    /// were observed (their serial).
    private let observations: UnsafeMutablePointer<Float>
    private let builder: SpatialObservationBuilder
    private var observationSerial: UInt32 = 0
    // Scratch for one band (at most 15 full-range speakers).
    private static let maxCliques = 16
    private let energy: UnsafeMutablePointer<Float>
    /// Each slot's exact band energy now, Σ w_k |X_k|² over every bin of the band.
    private let exact: UnsafeMutablePointer<Float>
    private let share: UnsafeMutablePointer<Float>
    private let rho: UnsafeMutablePointer<Float>
    private let adjacency: UnsafeMutablePointer<UInt16>
    private let cliques: UnsafeMutablePointer<UInt16>
    /// Per clique and speaker: first its affinity, then the fraction of its energy the clique carries.
    private let fraction: UnsafeMutablePointer<Float>
    private let components: UnsafeMutablePointer<Float>
    /// One component's members for `SpatialField.image`: directions, coherent energies and phases.
    private let memberDirections: UnsafeMutablePointer<SIMD3<Float>>
    private let memberEnergies: UnsafeMutablePointer<Float>
    private let memberCosines: UnsafeMutablePointer<Float>
    private let memberSines: UnsafeMutablePointer<Float>

    /// `roles`: the roles the spectrum transforms (L and R first); `transformLength`: its FFT length.
    package init(sampleRate: Double, transformLength n: Int, roles routed: [Int]) {
        self.sampleRate = sampleRate
        transformLength = n
        let full = routed.filter { $0 != Role.lfe && (0..<Role.count).contains($0) }
        roles = full + (routed.contains(Role.lfe) ? [Role.lfe] : [])
        fullRange = full.count
        slotCount = max(1, roles.count)
        var map = [Int](repeating: -1, count: Role.count)
        for (slot, role) in roles.enumerated() { map[role] = slot }
        slotOfRole = map
        geometry = SpatialGeometry.standard(roles: routed)
        let binWidth = sampleRate / Double(n)
        let top = min(SpatialField.highestFrequency, sampleRate / 2 * 0.999)
        let first = max(1, Int((SpatialField.lowestFrequency / binWidth + 0.5).rounded(.down)))
        let last = max(first, min(n / 2 - 1, Int((top / binWidth + 0.5).rounded(.down))))
        firstBin = first
        binCount = last - first + 1
        correlationTime = 0.6 * Double(n) / sampleRate
        var spans = [Span](repeating: Span(), count: SpatialField.bandCount)
        var effective = [Double](repeating: 1, count: SpatialField.bandCount)
        var times = [Double](repeating: 0.06, count: SpatialField.bandCount)
        for band in 0..<SpatialField.bandCount {
            let low = SpatialField.edge(band), high = min(SpatialField.edge(band + 1), top)
            guard high > low else { continue }
            // Continuous bin coordinates of the band; bin k covers k − ½ … k + ½.
            let x0 = low / binWidth, x1 = high / binWidth
            let k0 = max(first, Int((x0 + 0.5).rounded(.down))), k1 = min(last, Int((x1 + 0.5).rounded(.down)))
            guard k1 >= k0 else { continue }
            func overlap(_ k: Int) -> Float { Float(max(0, min(x1, Double(k) + 0.5) - max(x0, Double(k) - 0.5))) }
            let inner = k1 - k0 - 1
            let step = inner > Self.maxInner ? (inner + Self.maxInner - 1) / Self.maxInner : 1
            spans[band] = Span(first: k0 - first, last: k1 - first, firstWeight: overlap(k0), lastWeight: overlap(k1), step: step)
            // Bins closer than Hann's 1.5-bin noise bandwidth are correlated; bins `step` ≥ 2 apart barely are.
            effective[band] = step == 1 ? max(1, (x1 - x0) / 1.5) : Double(2 + (inner + step - 1) / step)
            // About 32 independent averages: bins × (1 + 2τ / correlation time).
            times[band] = min(1.0, max(0.06, (32 / effective[band] - 1) * correlationTime / 2))
        }
        self.spans = spans
        // The zones' grids: the same bands on each shorter transform's bins.
        func grid(length m: Int) -> (first: Int, count: Int, spans: [Span]) {
            let width = sampleRate / Double(m)
            let first = max(1, Int((SpatialField.lowestFrequency / width + 0.5).rounded(.down)))
            let last = max(first, min(m / 2 - 1, Int((top / width + 0.5).rounded(.down))))
            var list = [Span](repeating: Span(), count: SpatialField.bandCount)
            for band in 0..<SpatialField.bandCount {
                let low = SpatialField.edge(band), high = min(SpatialField.edge(band + 1), top)
                guard high > low else { continue }
                let x0 = low / width, x1 = high / width
                let k0 = max(first, Int((x0 + 0.5).rounded(.down))), k1 = min(last, Int((x1 + 0.5).rounded(.down)))
                guard k1 >= k0 else { continue }
                func overlap(_ k: Int) -> Float { Float(max(0, min(x1, Double(k) + 0.5) - max(x0, Double(k) - 0.5))) }
                list[band] = Span(first: k0 - first, last: k1 - first, firstWeight: overlap(k0), lastWeight: overlap(k1), step: 1)
            }
            return (first, last - first + 1, list)
        }
        var grids: [ZoneGrid] = []
        for divisor in Self.zoneDivisors {
            let m = n / divisor
            let g = grid(length: m)
            // Mean square per unit of one-sided |X|² for this window (Parseval): 2 / (m · Σw²), w the Hann window.
            var window = [Float](repeating: 0, count: m)
            vDSP_hann_window(&window, vDSP_Length(m), Int32(vDSP_HANN_DENORM))
            var squares: Float = 0
            vDSP_svesq(window, 1, &squares, vDSP_Length(m))
            let spectra = UnsafeMutablePointer<Float>.allocate(capacity: max(1, g.count * max(1, roles.count) * 2))
            spectra.initialize(repeating: 0, count: max(1, g.count * max(1, roles.count) * 2))
            grids.append(ZoneGrid(length: m, firstBin: g.first, binCount: g.count, binWidth: sampleRate / Double(m),
                                  scale: Float(2 / (Double(m) * Double(squares))), spans: g.spans, spectra: spectra))
        }
        zoneGrids = grids
        zoneOfBand = (0..<SpatialField.bandCount).map { band in
            let hz = SpatialField.centre(band)
            return hz >= Self.zoneEdges[1] ? 2 : (hz >= Self.zoneEdges[0] ? 1 : 0)
        }
        effectiveBins = effective
        smoothing = times
        velocityWeights = (0..<SpatialField.bandCount).map { SpatialField.velocityWeight(hz: SpatialField.centre($0)) }
        func zeroed<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
            let p = UnsafeMutablePointer<T>.allocate(capacity: max(1, count))
            p.initialize(repeating: value, count: max(1, count))
            return p
        }
        let bands = SpatialField.bandCount, matrix = slotCount * slotCount * 2
        spectra = zeroed(binCount * slotCount * 2, Float(0))
        frame = zeroed(bands * matrix, Float(0))
        slow = zeroed(bands * matrix, Float(0))
        activeTime = zeroed(bands, 0.0)
        silentTime = zeroed(bands, 0.0)
        weightSum = zeroed(bands, 0.0)
        weightSquares = zeroed(bands, 0.0)
        slotPosition = zeroed(bands * SpatialField.coherentSlots, SIMD3<Float>.zero)
        slotAlive = zeroed(bands * SpatialField.coherentSlots, false)
        values = zeroed(SpatialField.floats, Float(0))
        points = zeroed(SpatialPoints.floats, Float(0))
        binEnergy = zeroed(binCount, Float(0))
        directions = zeroed(Role.count, SIMD3<Float>.zero)
        positions = zeroed(Role.count, SIMD3<Float>.zero)
        directional = zeroed(Role.count, false)
        observations = zeroed(SpatialObservations.floats, Float(0))
        builder = SpatialObservationBuilder(bins: binCount)
        energy = zeroed(Role.count, Float(0))
        exact = zeroed(Role.count, Float(0))
        share = zeroed(Role.count * Role.count, Float(0))
        rho = zeroed(Role.count, Float(0))
        adjacency = zeroed(Role.count, UInt16(0))
        cliques = zeroed(Self.maxCliques, UInt16(0))
        fraction = zeroed(Self.maxCliques * Role.count, Float(0))
        components = zeroed(SpatialField.coherentSlots * SpatialField.componentFloats, Float(0))
        memberDirections = zeroed(Role.count, SIMD3<Float>.zero)
        memberEnergies = zeroed(Role.count, Float(0))
        memberCosines = zeroed(Role.count, Float(0))
        memberSines = zeroed(Role.count, Float(0))
        placeSpeakers()
    }

    deinit {
        for pointer in [spectra, frame, slow, values, points, binEnergy, energy, exact, share, rho, fraction, components,
                        memberEnergies, memberCosines, memberSines, observations] { pointer.deallocate() }
        memberDirections.deallocate()
        activeTime.deallocate(); silentTime.deallocate(); weightSum.deallocate(); weightSquares.deallocate()
        slotPosition.deallocate(); slotAlive.deallocate(); directions.deallocate(); positions.deallocate(); directional.deallocate()
        adjacency.deallocate(); cliques.deallocate()
        for grid in zoneGrids { grid.spectra.deallocate() }
    }

    private func placeSpeakers() {
        var largest: Float = 0
        for (slot, role) in roles.prefix(fullRange).enumerated() {
            let u = geometry.direction(role: role)
            directional[slot] = u != nil
            let d = u ?? .zero
            directions[slot] = SIMD3(Float(d.x), Float(d.y), Float(d.z))
            let p = geometry.position(role: role) ?? .zero
            positions[slot] = SIMD3(Float(p.x), Float(p.y), Float(p.z))
            largest = max(largest, (positions[slot] * positions[slot]).sum().squareRoot())
        }
        extent = geometry.mapping == .positions ? max(0.1, largest) : 1
    }

    /// The newest field (`SpatialField` layout), `SpatialField.floats` values.
    package var fieldValues: UnsafePointer<Float> { UnsafePointer(values) }
    package var field: [Float] { Array(UnsafeBufferPointer(start: values, count: SpatialField.floats)) }
    /// The newest field's bins (`SpatialPoints` layout), `SpatialPoints.floats` values; status 0 unless `legacyPoints`.
    package var pointValues: UnsafePointer<Float> { UnsafePointer(points) }
    /// The newest observations (`SpatialObservations` layout), `SpatialObservations.floats` values.
    package var observationValues: UnsafePointer<Float> { UnsafePointer(observations) }

    /// Whether this Spatial transform builds the field (every `interval`-th; the first after any other at once).
    package func due(continuing: Bool) -> Bool {
        phase = continuing ? (phase + 1) % Self.interval : 0
        return phase == 0
    }

    /// A break in the audio, or a new stream: nothing measured before it shapes the field after it.
    package func reset() {
        let bands = SpatialField.bandCount, matrix = slotCount * slotCount * 2
        frame.update(repeating: 0, count: bands * matrix)
        slow.update(repeating: 0, count: bands * matrix)
        activeTime.update(repeating: 0, count: bands)
        silentTime.update(repeating: 0, count: bands)
        weightSum.update(repeating: 0, count: bands)
        weightSquares.update(repeating: 0, count: bands)
        slotAlive.update(repeating: false, count: bands * SpatialField.coherentSlots)
        values.update(repeating: 0, count: SpatialField.floats)
        points.update(repeating: 0, count: SpatialPoints.floats)
        observations.update(repeating: 0, count: SpatialObservations.first)
        phase = 0
    }

    /// Takes one role pair's transform: `real`/`imaginary` hold Z = DFT(a + i·b) made with the half-amplitude window,
    /// so A[k] = (Zr[k] + Zr[N−k]) + i(Zi[k] − Zi[N−k]) and B[k] = (Zi[k] + Zi[N−k]) + i(Zr[N−k] − Zr[k]) are the
    /// full-window spectra of `a` and `b`.
    package func capture(_ a: Int, _ b: Int?, real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>) {
        let n = transformLength
        let sa = (0..<Role.count).contains(a) ? slotOfRole[a] : -1
        let sb = b.map { (0..<Role.count).contains($0) ? slotOfRole[$0] : -1 } ?? -1
        guard sa >= 0 || sb >= 0 else { return }
        let stride = slotCount * 2, first = firstBin, o = spectra
        for j in 0..<binCount {
            let k = first + j
            let zr = real[k], zi = imaginary[k], wr = real[n - k], wi = imaginary[n - k]
            if sa >= 0 {
                o[j * stride + sa * 2] = zr + wr
                o[j * stride + sa * 2 + 1] = zi - wi
            }
            if sb >= 0 {
                o[j * stride + sb * 2] = zi + wi
                o[j * stride + sb * 2 + 1] = wr - zr
            }
        }
    }

    /// One role pair's transform over zone `zone`'s (1…) shorter window, as `capture` takes the full one.
    package func captureZone(_ zone: Int, _ a: Int, _ b: Int?, real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>) {
        guard (1...zoneGrids.count).contains(zone) else { return }
        let grid = zoneGrids[zone - 1]
        let n = grid.length
        let sa = (0..<Role.count).contains(a) ? slotOfRole[a] : -1
        let sb = b.map { (0..<Role.count).contains($0) ? slotOfRole[$0] : -1 } ?? -1
        guard sa >= 0 || sb >= 0 else { return }
        let stride = slotCount * 2, first = grid.firstBin, o = grid.spectra
        for j in 0..<grid.binCount {
            let k = first + j
            let zr = real[k], zi = imaginary[k], wr = real[n - k], wi = imaginary[n - k]
            if sa >= 0 {
                o[j * stride + sa * 2] = zr + wr
                o[j * stride + sa * 2 + 1] = zi - wi
            }
            if sb >= 0 {
                o[j * stride + sb * 2] = zi + wi
                o[j * stride + sb * 2 + 1] = wr - zr
            }
        }
    }

    /// A role the transform skipped because its window held only zeros.
    package func silence(_ role: Int) {
        guard (0..<Role.count).contains(role) else { return }
        let slot = slotOfRole[role]
        guard slot >= 0 else { return }
        let stride = slotCount * 2
        for j in 0..<binCount { spectra[j * stride + slot * 2] = 0; spectra[j * stride + slot * 2 + 1] = 0 }
        for grid in zoneGrids {
            for j in 0..<grid.binCount { grid.spectra[j * stride + slot * 2] = 0; grid.spectra[j * stride + slot * 2 + 1] = 0 }
        }
    }

    /// Every role silent (digital silence): the field falls to nothing, and the frame's observations are none.
    package func silenceAll(seconds: Double, windowEnd: UInt64 = 0) {
        spectra.update(repeating: 0, count: binCount * slotCount * 2)
        for grid in zoneGrids { grid.spectra.update(repeating: 0, count: grid.binCount * slotCount * 2) }
        analyse(seconds: seconds, scale: 0, windowEnd: windowEnd)
    }

    /// Builds the field and the observations (with `legacyPoints`, the bins) from the captured spectra. `seconds` since
    /// the previous field; `scale` converts Σ|X|² to the band's mean square (`SpectrumAnalyzer.bandPowerScale`);
    /// `windowEnd` is how many frames the analysis had taken when the transform's window ended (the observations' time).
    package func analyse(seconds: Double, scale: Double, windowEnd: UInt64 = 0) {
        let s = slotCount, matrix = s * s * 2
        let alphaScale = Float(scale)
        let ld = Int32(s)
        let x = UnsafePointer(spectra)
        if !legacyPoints { builder.begin() }
        for band in 0..<SpatialField.bandCount {
            let c = frame + band * matrix
            c.update(repeating: 0, count: matrix)
            let span = spans[band]
            for i in 0..<s { exact[i] = 0 }
            if span.last >= span.first, alphaScale > 0 {
                // Every bin's energy, exactly.
                for k in span.first...span.last {
                    let w = alphaScale * (k == span.first ? span.firstWeight : (k == span.last ? span.lastWeight : 1))
                    let column = x + k * s * 2
                    for i in 0..<s { exact[i] += w * (column[2 * i] * column[2 * i] + column[2 * i + 1] * column[2 * i + 1]) }
                }
                if span.last - span.first >= 6 {
                    // Wide bands: one Hermitian rank-k update for the inner bins (every `step`-th, weighted to stand for
                    // the rest), rank-1 updates for the partial edges.
                    let inner = span.last - span.first - 1
                    let used = (inner + span.step - 1) / span.step
                    cblas_cherk(CblasColMajor, CblasUpper, CblasNoTrans, ld, Int32(used), alphaScale * Float(inner) / Float(used),
                                x + (span.first + 1) * s * 2, Int32(s * span.step), 0, c, ld)
                    cblas_cher(CblasColMajor, CblasUpper, ld, alphaScale * span.firstWeight, x + span.first * s * 2, 1, c, ld)
                    cblas_cher(CblasColMajor, CblasUpper, ld, alphaScale * span.lastWeight, x + span.last * s * 2, 1, c, ld)
                } else {
                    // A few bins: the products directly, cheaper than the library calls.
                    for k in span.first...span.last {
                        let w = alphaScale * (k == span.first ? span.firstWeight : (k == span.last ? span.lastWeight : 1))
                        guard w > 0 else { continue }
                        let column = x + k * s * 2
                        for j in 0..<s {
                            let jr = column[2 * j] * w, ji = column[2 * j + 1] * w
                            let out = c + j * s * 2
                            for i in 0...j {
                                let ir = column[2 * i], ii = column[2 * i + 1]
                                out[2 * i] += ir * jr + ii * ji
                                out[2 * i + 1] += ii * jr - ir * ji
                            }
                        }
                    }
                }
            }
            // While the band's speakers sound, the coherence estimate carries on; after 0.3 s of silence it starts
            // afresh with the next sound. The average starts from nothing rather than from its first field, so no
            // field outweighs the others while it fills, and Σw, Σw² say how many fields it rests on.
            var total: Float = 0
            for i in 0..<fullRange { total += exact[i] }
            let smooth = slow + band * matrix
            if total > 1e-14 {
                if activeTime[band] == 0 {
                    smooth.update(repeating: 0, count: matrix)
                    weightSum[band] = 0
                    weightSquares[band] = 0
                }
                let decay = exp(-seconds / smoothing[band])
                var keep = Float(decay)
                var take = 1 - keep
                vDSP_vsmul(smooth, 1, &keep, smooth, 1, vDSP_Length(matrix))
                vDSP_vsma(c, 1, &take, smooth, 1, smooth, 1, vDSP_Length(matrix))
                weightSum[band] = decay * weightSum[band] + 1
                weightSquares[band] = decay * decay * weightSquares[band] + 1
                activeTime[band] += seconds
                silentTime[band] = 0
            } else {
                silentTime[band] += seconds
                if silentTime[band] > 0.3 { activeTime[band] = 0 }
            }
            decompose(band: band, smooth: smooth)
            if legacyPoints { placePoints(band: band, span: span, scale: alphaScale) } else { observe(band: band, span: span, scale: alphaScale) }
        }
        pointSerial &+= 1
        points[SpatialPoints.status] = legacyPoints ? 1 : 0
        if legacyPoints {
            observations.update(repeating: 0, count: SpatialObservations.first)
        } else {
            finishObservations(windowEnd: windowEnd)
        }
        values[SpatialField.status] = 1
        values[SpatialField.threshold] = coherenceThreshold
        values[SpatialField.speakers] = Float(fullRange)
    }

    /// One band's bins as `SpatialPoints` (`scale` converts Σ|X|² to mean square; 0 for silence): every bin of the band,
    /// or, past `SpatialPoints.perBand` of them, that many drawn in proportion to their energy.
    private func placePoints(band: Int, span: Span, scale: Float) {
        let out = points + SpatialPoints.count(band: band)
        out[0] = 0
        guard span.last >= span.first, scale > 0, fullRange > 0 else { return }
        let s = slotCount, f = fullRange, x = UnsafePointer(spectra), directions = self.directions
        let bins = span.last - span.first + 1
        var total: Float = 0
        for j in 0..<bins {
            let k = span.first + j
            let w = scale * (k == span.first ? span.firstWeight : (k == span.last ? span.lastWeight : 1))
            let column = x + k * s * 2
            var e: Float = 0
            for i in 0..<f { e += column[2 * i] * column[2 * i] + column[2 * i + 1] * column[2 * i + 1] }
            binEnergy[j] = w * e
            total += w * e
        }
        guard total > 1e-20 else { return }
        var made = 0
        func place(_ j: Int, _ energy: Float) {
            let column = x + (span.first + j) * s * 2
            var sum = SIMD3<Float>.zero, amplitudes: Float = 0
            for i in 0..<f {
                let a = (column[2 * i] * column[2 * i] + column[2 * i + 1] * column[2 * i + 1]).squareRoot()
                sum += directions[i] * a
                amplitudes += a
            }
            guard amplitudes > 0, made < SpatialPoints.perBand else { return }
            let p = sum / amplitudes
            let o = out + 1 + made * SpatialPoints.pointFloats
            o[0] = p.x; o[1] = p.y; o[2] = p.z; o[3] = energy
            made += 1
        }
        if bins <= SpatialPoints.perBand {
            for j in 0..<bins where binEnergy[j] > 0 { place(j, binEnergy[j]) }
        } else {
            // Systematic resampling: draws `step` of energy apart from one random offset.
            var hash = pointSerial &* 0x9E37_79B9 ^ UInt32(band) &* 0x85EB_CA6B
            hash ^= hash >> 15; hash = hash &* 0x2C1B_3C6D; hash ^= hash >> 12
            let step = total / Float(SpatialPoints.perBand)
            var next = (Float(hash >> 8) + 0.5) / 16_777_216 * step
            var cumulative: Float = 0, drawn = 0
            for j in 0..<bins where drawn < SpatialPoints.perBand {
                cumulative += binEnergy[j]
                var taken = 0
                while next < cumulative && drawn + taken < SpatialPoints.perBand { taken += 1; next += step }
                if taken > 0 { place(j, Float(taken) * step); drawn += taken }
            }
            // A draw rounding left past the band's last bin belongs to the last bin drawn.
            if drawn < SpatialPoints.perBand && made > 0 {
                out[1 + (made - 1) * SpatialPoints.pointFloats + 3] += Float(SpatialPoints.perBand - drawn) * step
            }
        }
        out[0] = Float(made)
    }

    /// One band's bins into the observation builder: each bin with energy at the amplitude-weighted centre of gravity
    /// of the included full-range speakers' positions in the geometry's mapping, Σ|Xᵢ|sᵢ / Σ|Xᵢ|, its energy their
    /// mean square (a partial edge bin by its share of the band), at its own frequency.
    private func observe(band: Int, span fullSpan: Span, scale fullScale: Float) {
        builder.startBand(band, extent: extent)
        // The band's zone: the full transform, or (multi-resolution) a shorter window above 1 and 4 kHz.
        let zone = geometry.window == .multiResolution ? zoneOfBand[band] : 0
        let span = zone == 0 ? fullSpan : zoneGrids[zone - 1].spans[band]
        let scale = zone == 0 ? fullScale : (fullScale > 0 ? zoneGrids[zone - 1].scale : 0)
        guard span.last >= span.first, scale > 0, fullRange > 0 else { return }
        let s = slotCount, f = fullRange, positions = self.positions, directional = self.directional
        let x = zone == 0 ? UnsafePointer(spectra) : UnsafePointer(zoneGrids[zone - 1].spectra)
        let binWidth = Float(zone == 0 ? sampleRate / Double(transformLength) : zoneGrids[zone - 1].binWidth)
        let firstBin = zone == 0 ? self.firstBin : zoneGrids[zone - 1].firstBin
        for k in span.first...span.last {
            let w = scale * (k == span.first ? span.firstWeight : (k == span.last ? span.lastWeight : 1))
            guard w > 0 else { continue }
            let column = x + k * s * 2
            var sum = SIMD3<Float>.zero, amplitudes: Float = 0, power: Float = 0
            for i in 0..<f where directional[i] {
                let p = column[2 * i] * column[2 * i] + column[2 * i + 1] * column[2 * i + 1]
                let a = p.squareRoot()
                sum += positions[i] * a
                amplitudes += a
                power += p
            }
            guard amplitudes > 0 else { continue }
            let c = sum / amplitudes
            builder.add(x: c.x, y: c.y, z: c.z, energy: w * power, frequency: Float(firstBin + k) * binWidth, zone: Int32(zone))
        }
    }

    /// The frame's observations: the builder's reduction, and the header that says what they are.
    private func finishObservations(windowEnd: UInt64) {
        typealias H = SpatialObservations.Header
        observations.update(repeating: 0, count: SpatialObservations.first)
        builder.finish(detail: geometry.detail, extent: extent, into: observations)
        observationSerial &+= 1
        observations[H.status] = 1
        observations[H.version] = SpatialObservations.version
        observations[H.mapping] = Float(geometry.mapping.rawValue)
        observations[H.source] = SpatialObservations.Source.measured.rawValue
        SpatialObservations.store(UInt64(geometry.revision), parts: 2, at: observations + H.revision)
        SpatialObservations.store(geometry.hash, parts: 4, at: observations + H.hash)
        SpatialObservations.store(windowEnd, parts: 3, at: observations + H.windowEnd, bits: 24)
        observations[H.sampleRate] = Float(sampleRate)
        observations[H.windowLength] = Float(transformLength)
        observations[H.serial] = Float(observationSerial % (1 << 24))
        let multi = geometry.window == .multiResolution
        observations[H.zones] = multi ? Float(1 + zoneGrids.count) : 1
        if multi { for (i, grid) in zoneGrids.enumerated() { observations[H.zoneWindow + i] = Float(grid.length) } }
    }

    /// Independent averages behind a band's coherence estimate right now: its effective bins × the fields its
    /// average rests on, (Σw)²/Σw², counted as independent only as far as fields `correlationTime` apart are.
    private func averages(_ band: Int) -> Double {
        guard weightSquares[band] > 0 else { return 0 }
        let fields = weightSum[band] * weightSum[band] / weightSquares[band]
        return effectiveBins[band] * (1 + (fields - 1) * min(1, fieldSeconds / correlationTime))
    }

    /// One band: every speaker's independent energy and up to `coherentSlots` coherent components.
    ///
    /// Coherence is significance-tested before it counts: with m independent averages an uncorrelated pair's |γ|²
    /// is spread like an exponential of mean 1/m, so (4 + ln P)/m (P the band's speaker pairs, whose largest
    /// chance value grows like ln P) is taken off before the threshold: with the default threshold a chance image
    /// appears in about 1 band in 1,000 per field whatever the number of speakers, while a coherent pair still reads 1. Which speakers share an image, where it sits and how wide it is
    /// come from the smoothed statistics, so a phantom does not wander with every transform's energy; how much energy
    /// it carries follows this transform.
    private func decompose(band: Int, smooth: UnsafePointer<Float>) {
        let s = slotCount, f = fullRange, n = Role.count
        let theta = coherenceThreshold
        let m = averages(band)
        let v = values + SpatialField.headerFloats + band * SpatialField.bandFloats
        let energy = self.energy, exact = self.exact, share = self.share, rho = self.rho, adjacency = self.adjacency
        let cliques = self.cliques, fraction = self.fraction, found = self.components, directions = self.directions
        // arg C̄_ij: the phase of slot i relative to slot j (the matrix holds its upper triangle).
        func phase(_ i: Int, _ j: Int) -> Float {
            i < j ? atan2f(smooth[(j * s + i) * 2 + 1], smooth[(j * s + i) * 2])
                  : -atan2f(smooth[(i * s + j) * 2 + 1], smooth[(i * s + j) * 2])
        }
        func slowEnergy(_ i: Int) -> Float { max(0, smooth[(i * s + i) * 2]) }
        for role in 0..<n { v[role] = 0 }
        // The LFE has no direction: its band energy stays its own.
        if f < roles.count { v[Role.lfe] = max(0, exact[f]) }
        var loudest: Float = 0
        for i in 0..<f {
            // A speaker left out of the picture carries nothing here (its feed still counts in every level reading).
            energy[i] = directional[i] ? max(0, exact[i]) : 0
            loudest = max(loudest, energy[i])
            rho[i] = 0
            adjacency[i] = 0
        }
        var active: UInt16 = 0
        let floor = max(1e-15, loudest * 1e-7)
        for i in 0..<f where energy[i] > floor && slowEnergy(i) > 0 { active |= 1 << UInt16(i) }
        let speakers = active.nonzeroBitCount
        let pairs = Double(max(1, speakers * (speakers - 1) / 2))
        let bias = m > 1.05 ? Float(min(0.9, (4 + log(pairs)) / m)) : 1
        // Pairwise coherence, significance-corrected, as a share above the threshold. A pair at or below the
        // threshold (most of them) is told apart with one product and comparison.
        if bias < 1 && speakers > 1 {
            let below = bias + theta * theta * (1 - bias)
            for i in 0..<f where active & (1 << UInt16(i)) != 0 {
                let ei = slowEnergy(i)
                var j = i + 1
                while j < f {
                    defer { j += 1 }
                    guard active & (1 << UInt16(j)) != 0 else { continue }
                    let ej = slowEnergy(j)
                    let re = smooth[(j * s + i) * 2], im = smooth[(j * s + i) * 2 + 1]
                    let cross = re * re + im * im
                    guard cross > below * ei * ej else {
                        share[i * n + j] = 0
                        share[j * n + i] = 0
                        continue
                    }
                    let magnitude = min(1, cross / max(1e-30, ei * ej))
                    let g = max(0, (magnitude - bias) / (1 - bias)).squareRoot()
                    let excess = max(0, min(1, (g - theta) / (1 - theta)))
                    share[i * n + j] = excess
                    share[j * n + i] = excess
                    guard excess > 0 else { continue }
                    adjacency[i] |= 1 << UInt16(j)
                    adjacency[j] |= 1 << UInt16(i)
                    rho[i] = max(rho[i], excess)
                    rho[j] = max(rho[j], excess)
                }
            }
        }
        var coherent: UInt16 = 0
        for i in 0..<f where adjacency[i] != 0 { coherent |= 1 << UInt16(i) }
        var total = 0
        if coherent != 0 {
            var overflow = false
            Self.enumerate(r: 0, p: coherent, x: 0, adjacency: adjacency, cliques: cliques, count: &total, overflow: &overflow)
            if overflow { total = Self.connectedComponents(coherent, adjacency: adjacency, cliques: cliques) }
        }
        // The fraction of each speaker's energy that goes to each of its cliques: its coherent fraction ρ, divided by
        // its mean share with the clique's other members.
        for k in 0..<total { for i in 0..<f { fraction[k * n + i] = 0 } }
        var bits = coherent
        while bits != 0 {
            let i = bits.trailingZeroBitCount
            bits &= bits - 1
            let bit = UInt16(1) << UInt16(i)
            var affinities: Float = 0
            for k in 0..<total where cliques[k] & bit != 0 {
                var others = cliques[k] & ~bit
                var sum: Float = 0, count: Float = 0
                while others != 0 {
                    let j = others.trailingZeroBitCount
                    others &= others - 1
                    sum += share[i * n + j]
                    count += 1
                }
                let affinity = count > 0 ? sum / count : 0
                fraction[k * n + i] = affinity
                affinities += affinity
            }
            guard affinities > 0 else { continue }
            for k in 0..<total where cliques[k] & bit != 0 {
                fraction[k * n + i] = rho[i] * fraction[k * n + i] / affinities
            }
        }
        // The cliques carrying the most (smoothed) energy keep their images; a dropped one's energy stays at its
        // speakers.
        var kept = (-1, -1, -1)
        var strength: (Float, Float, Float) = (0, 0, 0)
        for k in 0..<total {
            var sum: Float = 0
            for i in 0..<f { sum += fraction[k * n + i] * slowEnergy(i) }
            if sum > strength.0 { kept = (k, kept.0, kept.1); strength = (sum, strength.0, strength.1) }
            else if sum > strength.1 { kept = (kept.0, k, kept.1); strength = (strength.0, sum, strength.1) }
            else if sum > strength.2 { kept = (kept.0, kept.1, k); strength = (strength.0, strength.1, sum) }
        }
        for i in 0..<f {
            var shared: Float = 0
            if kept.0 >= 0 { shared += fraction[kept.0 * n + i] }
            if kept.1 >= 0 { shared += fraction[kept.1 * n + i] }
            if kept.2 >= 0 { shared += fraction[kept.2 * n + i] }
            v[roles[i]] = energy[i] * max(0, 1 - shared)
        }
        // Each kept clique as a component: its energy now, and where it images, how wide and how stable from the
        // smoothed statistics (`SpatialField.image`).
        var count = 0
        for index in 0..<SpatialField.coherentSlots {
            let k = index == 0 ? kept.0 : (index == 1 ? kept.1 : kept.2)
            guard k >= 0 else { continue }
            let members = cliques[k]
            var now: Float = 0, reference = -1, strongest: Float = 0
            var each = members
            while each != 0 {
                let i = each.trailingZeroBitCount
                each &= each - 1
                let part = fraction[k * n + i]
                now += part * energy[i]
                let w = part * slowEnergy(i)
                if w > strongest { strongest = w; reference = i }
            }
            guard now > 0, strongest > 0, reference >= 0 else { continue }
            var m = 0
            var coherence: Float = 0, pairCount: Float = 0
            each = members
            while each != 0 {
                let i = each.trailingZeroBitCount
                each &= each - 1
                memberDirections[m] = directions[i]
                memberEnergies[m] = fraction[k * n + i] * slowEnergy(i)
                let angle = i == reference ? 0 : phase(i, reference)
                memberCosines[m] = cosf(angle)
                memberSines[m] = sinf(angle)
                m += 1
                var later = members & ~((UInt16(1) << UInt16(i + 1)) &- 1)
                while later != 0 {
                    let j = later.trailingZeroBitCount
                    later &= later - 1
                    coherence += theta + share[i * n + j] * (1 - theta)
                    pairCount += 1
                }
            }
            let o = found + count * SpatialField.componentFloats
            o[SpatialField.Component.energy] = now
            SpatialField.image(count: m, directions: memberDirections, energies: memberEnergies, cosines: memberCosines,
                               sines: memberSines, velocityWeight: velocityWeights[band], into: o)
            o[SpatialField.Component.coherence] = pairCount > 0 ? coherence / pairCount : 0
            count += 1
        }
        place(band: band, count: count, found: found, into: v + n)
    }

    /// Puts this field's components into the band's slots so that each image keeps the slot it had: the assignment
    /// with the least total movement, where taking a free slot costs as much as moving half a radius.
    private func place(band: Int, count: Int, found: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let stride = SpatialField.componentFloats
        let alive = slotAlive + band * SpatialField.coherentSlots
        let positions = slotPosition + band * SpatialField.coherentSlots
        func position(_ i: Int) -> SIMD3<Float> {
            SIMD3(found[i * stride + SpatialField.Component.x], found[i * stride + SpatialField.Component.y],
                  found[i * stride + SpatialField.Component.z])
        }
        func cost(_ i: Int, _ slot: Int) -> Float {
            guard i < count else { return 0 }
            guard alive[slot] else { return 0.25 }
            let d = position(i) - positions[slot]
            return (d * d).sum()
        }
        var best = (0, 1, 2), bestCost = Float.infinity
        for a in 0..<3 {
            for b in 0..<3 where b != a {
                let c = 3 - a - b
                let total = cost(0, a) + cost(1, b) + cost(2, c)
                if total < bestCost { bestCost = total; best = (a, b, c) }
            }
        }
        for slot in 0..<SpatialField.coherentSlots {
            let o = out + slot * stride
            for k in 0..<stride { o[k] = 0 }
            // A slot without a component keeps its last position, so a fading image stays where it was.
            o[SpatialField.Component.x] = positions[slot].x
            o[SpatialField.Component.y] = positions[slot].y
            o[SpatialField.Component.z] = positions[slot].z
            alive[slot] = false
        }
        for i in 0..<count {
            let slot = i == 0 ? best.0 : (i == 1 ? best.1 : best.2)
            let o = out + slot * stride
            for k in 0..<stride { o[k] = found[i * stride + k] }
            positions[slot] = position(i)
            alive[slot] = true
        }
    }

    /// Bron–Kerbosch with pivoting over the coherent speakers; cliques of two or more are recorded.
    private static func enumerate(r: UInt16, p: UInt16, x: UInt16, adjacency: UnsafePointer<UInt16>,
                                  cliques: UnsafeMutablePointer<UInt16>, count: inout Int, overflow: inout Bool) {
        if overflow { return }
        if p == 0 && x == 0 {
            guard r.nonzeroBitCount >= 2 else { return }
            if count == maxCliques { overflow = true; return }
            cliques[count] = r
            count += 1
            return
        }
        var pivot = 0, pivotCount = -1
        var candidates = p | x
        while candidates != 0 {
            let u = candidates.trailingZeroBitCount
            candidates &= candidates - 1
            let reach = (p & adjacency[u]).nonzeroBitCount
            if reach > pivotCount { pivotCount = reach; pivot = u }
        }
        var p = p, x = x
        var remaining = p & ~adjacency[pivot]
        while remaining != 0 {
            let v = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            let bit = UInt16(1) << UInt16(v)
            enumerate(r: r | bit, p: p & adjacency[v], x: x & adjacency[v], adjacency: adjacency, cliques: cliques,
                      count: &count, overflow: &overflow)
            if overflow { return }
            p &= ~bit
            x |= bit
        }
    }

    /// Too many overlapping cliques (dense partial coherence): each connected group of coherent speakers becomes one
    /// component instead. Returns the number of groups.
    private static func connectedComponents(_ coherent: UInt16, adjacency: UnsafePointer<UInt16>,
                                            cliques: UnsafeMutablePointer<UInt16>) -> Int {
        var count = 0
        var left = coherent
        while left != 0, count < maxCliques {
            var group = UInt16(1) << UInt16(left.trailingZeroBitCount)
            var grown = true
            while grown {
                var next = group
                var bits = group
                while bits != 0 {
                    let i = bits.trailingZeroBitCount
                    bits &= bits - 1
                    next |= adjacency[i]
                }
                next &= coherent
                grown = next != group
                group = next
            }
            left &= ~group
            if group.nonzeroBitCount >= 2 {
                cliques[count] = group
                count += 1
            }
        }
        return count
    }
}


/// RESULT tag 53 (Bridge/PROTOCOL.md): the spatial field, compactly, for the insert's channels. Little-endian bytes:
///
///   header (12): version 1 · status (1 field, 0 none) · bands (96) · slots (3) · channels · speakers analysed ·
///                coherence threshold u16 (‰) · components u16 · 0 u16
///   then, with status 1: bands × channels independent energies (band-major, the bus's channel order), one byte each:
///                0 none, else −127 + code/2 dB (0.5 dB steps up to +0.5 dBFS);
///   then components × 20: band · slot · energy (as above) · stability (/255) · x y z (i8, /127) · coherence (/255)
///                · xx xy xz yy yz zz (i16, /32767)
///
/// Only coherent slots holding energy are sent; a slot not sent is empty and keeps its last position.
package enum SpatialFieldWire {
    package static let version: UInt8 = 1
    package static let headerBytes = 12
    package static let componentBytes = 20
    /// Snapshot status for a source that analyses every channel but sends no field (a plugin before build 80).
    package static let unsupported: Float = -1

    package static func energyCode(_ e: Float) -> UInt8 {
        guard e.isFinite, e > 0 else { return 0 }
        let code = (2 * (10 * log10(e) + 127)).rounded()
        return code < 1 ? 0 : UInt8(min(255, code))
    }
    package static func energy(_ code: UInt8) -> Float { code == 0 ? 0 : pow(10, (Float(code) / 2 - 127) / 10) }
    private static func unit(_ x: Float) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
    private static func signed8(_ x: Float) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }
    private static func signed16(_ x: Float) -> Int16 { Int16(max(-32767, min(32767, (x * 32767).rounded()))) }

    /// Coherent components of `field` worth sending.
    private static func components(_ field: UnsafePointer<Float>) -> Int {
        var count = 0
        for band in 0..<SpatialField.bandCount {
            for slot in 0..<SpatialField.coherentSlots where energyCode(field[SpatialField.component(band: band, slot: slot)]) > 0 {
                count += 1
            }
        }
        return count
    }

    /// Bytes `encode` writes for `field` and `channels` channels.
    package static func size(_ field: UnsafePointer<Float>, channels: Int) -> Int {
        field[SpatialField.status] == 1
            ? headerBytes + SpatialField.bandCount * channels + components(field) * componentBytes : headerBytes
    }

    /// Writes `field` (`SpatialField` layout) for an insert whose channel c carries role `roles[c]`; returns the bytes
    /// written (`size`).
    @discardableResult
    package static func encode(_ field: UnsafePointer<Float>, roles: [Int], into out: UnsafeMutableRawPointer) -> Int {
        let valid = field[SpatialField.status] == 1
        let count = valid ? components(field) : 0
        out.storeBytes(of: version, toByteOffset: 0, as: UInt8.self)
        out.storeBytes(of: UInt8(valid ? 1 : 0), toByteOffset: 1, as: UInt8.self)
        out.storeBytes(of: UInt8(SpatialField.bandCount), toByteOffset: 2, as: UInt8.self)
        out.storeBytes(of: UInt8(SpatialField.coherentSlots), toByteOffset: 3, as: UInt8.self)
        out.storeBytes(of: UInt8(roles.count), toByteOffset: 4, as: UInt8.self)
        out.storeBytes(of: UInt8(max(0, min(255, field[SpatialField.speakers]))), toByteOffset: 5, as: UInt8.self)
        out.storeBytes(of: UInt16((field[SpatialField.threshold] * 1000).rounded()).littleEndian, toByteOffset: 6, as: UInt16.self)
        out.storeBytes(of: UInt16(count).littleEndian, toByteOffset: 8, as: UInt16.self)
        out.storeBytes(of: UInt16(0), toByteOffset: 10, as: UInt16.self)
        guard valid else { return headerBytes }
        var at = headerBytes
        for band in 0..<SpatialField.bandCount {
            for role in roles {
                out.storeBytes(of: energyCode(field[SpatialField.independent(band: band, role: role)]), toByteOffset: at, as: UInt8.self)
                at += 1
            }
        }
        for band in 0..<SpatialField.bandCount {
            for slot in 0..<SpatialField.coherentSlots {
                let c = field + SpatialField.component(band: band, slot: slot)
                let code = energyCode(c[SpatialField.Component.energy])
                guard code > 0 else { continue }
                out.storeBytes(of: UInt8(band), toByteOffset: at, as: UInt8.self)
                out.storeBytes(of: UInt8(slot), toByteOffset: at + 1, as: UInt8.self)
                out.storeBytes(of: code, toByteOffset: at + 2, as: UInt8.self)
                out.storeBytes(of: unit(c[SpatialField.Component.stability]), toByteOffset: at + 3, as: UInt8.self)
                out.storeBytes(of: signed8(c[SpatialField.Component.x]), toByteOffset: at + 4, as: Int8.self)
                out.storeBytes(of: signed8(c[SpatialField.Component.y]), toByteOffset: at + 5, as: Int8.self)
                out.storeBytes(of: signed8(c[SpatialField.Component.z]), toByteOffset: at + 6, as: Int8.self)
                out.storeBytes(of: unit(c[SpatialField.Component.coherence]), toByteOffset: at + 7, as: UInt8.self)
                for k in 0..<6 {
                    out.storeBytes(of: signed16(c[SpatialField.Component.xx + k]).littleEndian, toByteOffset: at + 8 + 2 * k, as: Int16.self)
                }
                at += componentBytes
            }
        }
        return at
    }

    /// Expands a received field into `field` (`SpatialField` layout) for channels on `roles`. Every energy is
    /// rewritten; an empty slot keeps the position already in `field`. Returns false, leaving status 0, when the
    /// bytes do not describe this insert's channels.
    @discardableResult
    package static func decode(_ bytes: UnsafeRawBufferPointer, roles: [Int], into field: UnsafeMutablePointer<Float>) -> Bool {
        func clear() {
            field[SpatialField.status] = 0
            for band in 0..<SpatialField.bandCount {
                for role in 0..<Role.count { field[SpatialField.independent(band: band, role: role)] = 0 }
                for slot in 0..<SpatialField.coherentSlots { field[SpatialField.component(band: band, slot: slot)] = 0 }
            }
        }
        guard bytes.count >= headerBytes, bytes[0] == version, Int(bytes[2]) == SpatialField.bandCount,
              Int(bytes[3]) == SpatialField.coherentSlots, Int(bytes[4]) == roles.count else { clear(); return false }
        let valid = bytes[1] == 1
        let count = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt16.self)))
        let expected = valid ? headerBytes + SpatialField.bandCount * roles.count + count * componentBytes : headerBytes
        guard bytes.count == expected else { clear(); return false }
        clear()
        guard valid else { return true }
        field[SpatialField.status] = 1
        field[SpatialField.threshold] = Float(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 6, as: UInt16.self))) / 1000
        field[SpatialField.speakers] = Float(bytes[5])
        var at = headerBytes
        for band in 0..<SpatialField.bandCount {
            for role in roles {
                if (0..<Role.count).contains(role) { field[SpatialField.independent(band: band, role: role)] = energy(bytes[at]) }
                at += 1
            }
        }
        for _ in 0..<count {
            let band = Int(bytes[at]), slot = Int(bytes[at + 1])
            guard band < SpatialField.bandCount, slot < SpatialField.coherentSlots else { clear(); return false }
            let c = field + SpatialField.component(band: band, slot: slot)
            c[SpatialField.Component.energy] = energy(bytes[at + 2])
            c[SpatialField.Component.stability] = Float(bytes[at + 3]) / 255
            c[SpatialField.Component.x] = Float(Int8(bitPattern: bytes[at + 4])) / 127
            c[SpatialField.Component.y] = Float(Int8(bitPattern: bytes[at + 5])) / 127
            c[SpatialField.Component.z] = Float(Int8(bitPattern: bytes[at + 6])) / 127
            c[SpatialField.Component.coherence] = Float(bytes[at + 7]) / 255
            for k in 0..<6 {
                c[SpatialField.Component.xx + k] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: at + 8 + 2 * k, as: Int16.self))) / 32767
            }
            at += componentBytes
        }
        return true
    }
}

/// RESULT tag 54 (Bridge/PROTOCOL.md): the newest Spatial transform's bins (`SpatialPoints`). Little-endian bytes:
///
///   header (6): version 1 · status (1 points, 0 none) · bands (96) · points per band at most (32) · points u16
///   then, with status 1: bands bytes, each band's number of points; then points × 7, band by band: x y z (i16,
///                /32767) · energy (as tag 53's: −127 + code/2 dB). Points below −127 dB are left out.
package enum SpatialPointsWire {
    package static let version: UInt8 = 1
    package static let headerBytes = 6
    package static let pointBytes = 7
    package static let largest = headerBytes + SpatialField.bandCount * (1 + SpatialPoints.perBand * pointBytes)

    private static func signed16(_ x: Float) -> Int16 { Int16(max(-32767, min(32767, (x * 32767).rounded()))) }
    /// A band's points as stored, and those `encode` sends (energy above the code's floor).
    private static func stored(_ points: UnsafePointer<Float>, band: Int) -> Int {
        max(0, min(SpatialPoints.perBand, Int(points[SpatialPoints.count(band: band)])))
    }
    private static func count(_ points: UnsafePointer<Float>, band: Int) -> Int {
        var n = 0
        for index in 0..<stored(points, band: band) where SpatialFieldWire.energyCode(points[SpatialPoints.point(band: band, index: index) + 3]) > 0 {
            n += 1
        }
        return n
    }

    /// Bytes `encode` writes for `points`.
    package static func size(_ points: UnsafePointer<Float>) -> Int {
        guard points[SpatialPoints.status] == 1 else { return headerBytes }
        var total = 0
        for band in 0..<SpatialField.bandCount { total += count(points, band: band) }
        return headerBytes + SpatialField.bandCount + total * pointBytes
    }

    /// Writes `points` (`SpatialPoints` layout); returns the bytes written (`size`).
    @discardableResult
    package static func encode(_ points: UnsafePointer<Float>, into out: UnsafeMutableRawPointer) -> Int {
        let valid = points[SpatialPoints.status] == 1
        var total = 0
        if valid { for band in 0..<SpatialField.bandCount { total += count(points, band: band) } }
        out.storeBytes(of: version, toByteOffset: 0, as: UInt8.self)
        out.storeBytes(of: UInt8(valid ? 1 : 0), toByteOffset: 1, as: UInt8.self)
        out.storeBytes(of: UInt8(SpatialField.bandCount), toByteOffset: 2, as: UInt8.self)
        out.storeBytes(of: UInt8(SpatialPoints.perBand), toByteOffset: 3, as: UInt8.self)
        out.storeBytes(of: UInt16(total).littleEndian, toByteOffset: 4, as: UInt16.self)
        guard valid else { return headerBytes }
        var at = headerBytes
        for band in 0..<SpatialField.bandCount {
            out.storeBytes(of: UInt8(count(points, band: band)), toByteOffset: at, as: UInt8.self)
            at += 1
        }
        for band in 0..<SpatialField.bandCount {
            for index in 0..<stored(points, band: band) {
                let p = points + SpatialPoints.point(band: band, index: index)
                guard SpatialFieldWire.energyCode(p[3]) > 0 else { continue }
                out.storeBytes(of: signed16(p[0]).littleEndian, toByteOffset: at, as: Int16.self)
                out.storeBytes(of: signed16(p[1]).littleEndian, toByteOffset: at + 2, as: Int16.self)
                out.storeBytes(of: signed16(p[2]).littleEndian, toByteOffset: at + 4, as: Int16.self)
                out.storeBytes(of: SpatialFieldWire.energyCode(p[3]), toByteOffset: at + 6, as: UInt8.self)
                at += pointBytes
            }
        }
        return at
    }

    /// Expands received points into `points` (`SpatialPoints` layout). Returns false, leaving status 0, when the bytes
    /// are not a valid set.
    @discardableResult
    package static func decode(_ bytes: UnsafeRawBufferPointer, into points: UnsafeMutablePointer<Float>) -> Bool {
        points[SpatialPoints.status] = 0
        for band in 0..<SpatialField.bandCount { points[SpatialPoints.count(band: band)] = 0 }
        guard bytes.count >= headerBytes, bytes[0] == version, Int(bytes[2]) == SpatialField.bandCount,
              Int(bytes[3]) == SpatialPoints.perBand else { return false }
        guard bytes[1] == 1 else { return bytes.count == headerBytes }
        let total = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt16.self)))
        guard bytes.count == headerBytes + SpatialField.bandCount + total * pointBytes else { return false }
        var sum = 0
        for band in 0..<SpatialField.bandCount {
            let n = Int(bytes[headerBytes + band])
            guard n <= SpatialPoints.perBand else { return false }
            sum += n
        }
        guard sum == total else { return false }
        var at = headerBytes + SpatialField.bandCount
        func unit(_ offset: Int) -> Float { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32767 }
        for band in 0..<SpatialField.bandCount {
            let n = Int(bytes[headerBytes + band])
            points[SpatialPoints.count(band: band)] = Float(n)
            for index in 0..<n {
                let p = points + SpatialPoints.point(band: band, index: index)
                p[0] = unit(at); p[1] = unit(at + 2); p[2] = unit(at + 4)
                p[3] = SpatialFieldWire.energy(bytes[at + 6])
                at += pointBytes
            }
        }
        points[SpatialPoints.status] = 1
        return true
    }
}
