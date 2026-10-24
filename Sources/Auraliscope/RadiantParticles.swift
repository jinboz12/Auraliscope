import AnalysisCore
import Foundation
import Metal
import simd

/// Radiant's particles (`NebulaStyle.radiant`): every band of the spatial analysis shown as particles where its
/// frequencies are heard, kept for the persistence time and drawn by `radiantParticleVertex`.
///
/// From build 98 each particle is one observation of the analysis (`SpatialObservations`): a frequency, or a group of
/// neighbouring frequencies at one place, at the centre of gravity of the speakers weighted by its amplitude in each,
/// in the geometry's mapping (unit directions, or meters). Nothing is sampled again here: the analysis' one reduction
/// already decided which frequencies share a particle. A particle sits exactly where its observation is (no clamping to
/// the speakers' sphere or above the floor: a layout with speakers below the ear plane is drawn below it), at the
/// particle size whatever its frequencies' spread around it (drawn as wide as that, diffuse treble became one broad
/// splat), and the model's scale is the layout's (`toModel`: 1 / its largest distance in meters, or 1 for directions),
/// the same transform the speakers are drawn with.
///
/// Light: a band's level within the glow range below the loudest band sets its light once (`Radiant.intensity`, the
/// display's compression); its particles share that light in proportion to their energy (Σ shares = 1), so the band's
/// total light does not depend on how many particles it has, and no energy is weighted twice. Each particle carries its
/// band's share of coherent energy that cancels at the listener (`SpatialField`'s stability) for the ochre tint.
///
/// A source without observations (a Bridge plugin before build 87, the demo) still sends the field's statistics, per
/// band each speaker's independent energy and the coherent components (their energy vector, `SpatialField.image`);
/// from those this draws `count` particles as such a source's bins would fall: every independent part, and every
/// coherent part as one virtual speaker at its image, gets an amplitude |CN(0, E)| (as a noise-like signal's bins
/// have), and the particle sits at their amplitude-weighted centre. Its particles then share the band's light likewise.
/// Energy out of phase, which has no stable direction there, is also scattered over its predicted spread.
///
/// The GPU fades and blurs particles as they age (`radiantParticleVertex`), so new particles are crisp beads and older
/// ones smoke into glow, in model space, so the camera can turn at any time. Random draws (the statistics only) are
/// hashed from the frame, band, particle and component, so a frozen picture holds still.
final class RadiantParticles {
    /// One particle as the shader reads it (`RadiantParticle`): model position and birth (seconds of the scene's
    /// clock); colour and light at birth; instability, spread (model units), band and level (dBFS).
    struct Particle {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
        var extra: SIMD4<Float>
    }

    /// What the pointer reads of a particle.
    struct Reading {
        /// The field frame, in the mapping's units (unit directions, or meters).
        var position: SIMD3<Float>
        var light: Float
        var birth: Float
        var band: Int
        var layer: Int
        var level: Float                // the band's level, dBFS
        var hue: SIMD3<Float>
        var kind: DomeProbe.Kind
        var width: Float?
        var stability: Float?
        var coherence: Float?
        /// The observation's energy-weighted frequency (Hz); nil for a particle drawn from statistics.
        var frequency: Float?
    }

    static let capacity = 320_000
    let buffer: MTLBuffer?
    private var particles: UnsafeMutablePointer<Particle>
    private var cursor = 0
    /// The frames drawn: where their particles are in the ring, how many, and when the newest of them was born.
    private(set) var frames: [(start: Int, count: Int, birth: Float)] = []
    /// The newest frames' particles as the pointer reads them.
    private(set) var recent: [[Reading]] = []
    static let recentFrames = 6
    /// Counts every change to what the ring holds, so an unchanged picture is not drawn again.
    private(set) var version = 0
    /// The loudest band of the newest frame (dBFS).
    private(set) var loudest: Float = -200
    /// The light the newest frame emitted before exposure: in total and per band (checks: the light is conserved).
    private(set) var emitted: Float = 0
    private(set) var emittedPerBand = [Float](repeating: 0, count: SpatialField.bandCount)

    // Per band, the components of the frame being built (the field's: for the readings and the statistics).
    private struct Part {
        var position: SIMD3<Float>
        var energy: Float
        var instability: Float
        var cholesky: simd_float3x3
        var scatter: Bool
        var kind: DomeProbe.Kind
        var width: Float?
        var stability: Float?
        var coherence: Float?
    }
    private var parts: [Part] = []
    /// Where each band's observations start in the frame's list.
    private var bandStart = [Int](repeating: 0, count: SpatialField.bandCount + 1)
    /// Each field band's hue on the spectral scale.
    private let bandHue = (0..<SpatialField.bandCount).map { SpectralHue.at(hz: SpatialField.centre($0)) }

    init(device: MTLDevice?) {
        if let device, let buffer = device.makeBuffer(length: Self.capacity * MemoryLayout<Particle>.stride, options: .storageModeShared) {
            self.buffer = buffer
            particles = buffer.contents().bindMemory(to: Particle.self, capacity: Self.capacity)
        } else {
            buffer = nil
            // Without a device (checks), particles still go somewhere: a ring of the same size in memory.
            particles = .allocate(capacity: Self.capacity)
        }
        parts.reserveCapacity(Role.count + SpatialField.coherentSlots)
    }

    deinit { if buffer == nil { particles.deallocate() } }

    func clear() {
        frames.removeAll(keepingCapacity: true)
        recent.removeAll(keepingCapacity: true)
        cursor = 0
        version &+= 1
    }

    /// Forgets frames older than `lifetime` seconds at `clock`.
    func prune(clock: Float, lifetime: Float) {
        let before = frames.count
        frames.removeAll { clock - $0.birth > lifetime }
        recent.removeAll { frame in frame.map { clock - $0.birth > lifetime }.allSatisfy { $0 } }
        if frames.count != before { version &+= 1 }
    }

    /// What one frame is built from.
    struct Input {
        var field: UnsafeBufferPointer<Float>
        /// The same transform's observations (`SpatialObservations` layout, ending after its last observation), or
        /// nothing: then the field's statistics are drawn.
        var observations = UnsafeBufferPointer<Float>(start: nil, count: 0)
        var roleBandPower: [Float]
        /// The speakers' unit directions (the statistics' and the readings' frame).
        var speakers: [(role: Int, name: String, direction: SIMD3<Float>)]
        /// The speakers where the observations put them (the mapping's units), for the readings.
        var positions: [(role: Int, name: String, position: SIMD3<Float>)] = []
        /// Model units per unit of the observations' mapping: 1 / the layout's largest distance, or 1 for directions.
        var toModel: Float = 1
        /// Seconds each analysis zone's window centre lies before the newest zone's (`SpatialObservations` zones).
        var zoneDelays: [Float] = [0]
        /// The bare observations (`NebulaSettings.rawPoints`): no spread drawn.
        var raw = false
        /// The geometry reaches below the ear plane: draws from statistics may go there too.
        var lower = false
        var shown: [Bool]
        var layers: [SpatialBody.Layer]
        /// Coloured by frequency, or each layer in its colour.
        var spectral: Bool
        var layerColors: [SIMD3<Float>]
        /// Particles per band drawn from the statistics (a source without observations).
        var perBand: Int
        var spread: Float
        var floor: Float
        var range: Float
    }

    /// Whether `input` carries a valid frame of observations.
    private static func observed(_ input: Input) -> Bool {
        let o = input.observations
        guard o.count >= SpatialObservations.first, o[SpatialObservations.Header.status] == 1 else { return false }
        let count = Int(o[SpatialObservations.Header.count])
        return count >= 0 && o.count >= SpatialObservations.first + count * SpatialObservations.fields
    }

    /// The loudest band (dBFS) `input` holds, before any particle is made: the glow's range hangs from it.
    func loudestBand(_ input: Input) -> Float {
        var top: Float = -200
        forEachBand(input) { _, _, _, energy, _ in top = max(top, 10 * SpatialBody.log10(max(energy, 1e-30))) }
        return top
    }

    /// Adds one frame of particles born at `birth` (scene clock, seconds; zones of a multi-resolution analysis earlier
    /// by their delays), hashed from `serial`, with the glow's range hanging from `peak` (dBFS).
    func add(_ input: Input, birth: Float, serial: UInt32, peak: Float) {
        let floorEnergy = Float(pow(10, Double(input.floor) / 10))
        let perBand = max(1, input.perBand)
        let toRange = 1 / max(1, input.range)
        let observed = Self.observed(input)
        let worst = observed ? SpatialObservations.capacity : perBand * (SpatialField.bandCount + StereoBands.count)
        if cursor + worst > Self.capacity { cursor = 0 }
        let start = cursor
        var made: [Reading] = []
        made.reserveCapacity(min(worst, 4096))
        loudest = -200
        emitted = 0
        for band in 0..<SpatialField.bandCount { emittedPerBand[band] = 0 }
        forEachBand(input) { layer, band, hue, total, five in
            guard total > floorEnergy else { return }
            let level = 10 * SpatialBody.log10(total)
            loudest = max(loudest, level)
            // The band's light, compressed once (`Radiant.intensity`); its particles share it by energy.
            let brightness = Radiant.intensity((level - peak) * toRange)
            guard brightness > 0 else { return }
            if observed {
                addObservations(input, layer: layer, band: band, hue: hue, total: total, level: level, brightness: brightness,
                                birth: birth, into: &made)
            } else {
                addStatistics(input, layer: layer, band: band, five: five, hue: hue, total: total, level: level,
                              brightness: brightness, serial: serial, birth: birth, into: &made)
            }
        }
        let count = cursor - start
        // A frame overwrites the oldest particles where the ring wraps.
        frames.removeAll { $0.start < start + count && start < $0.start + $0.count }
        if count > 0 { frames.append((start, count, birth)) }
        recent.append(made)
        if recent.count > Self.recentFrames { recent.removeFirst(recent.count - Self.recentFrames) }
        version &+= 1
    }

    /// One band's observations as particles: each exactly where it is (model = the mapping × `toModel`), its light the
    /// band's times its share of the band's energy.
    private func addObservations(_ input: Input, layer: Int, band: Int, hue: SIMD3<Float>, total: Float, level: Float,
                                 brightness: Float, birth: Float, into made: inout [Reading]) {
        let o = input.observations
        // The band's coherent energy, how much of it cancels at the listener, and its strongest image (the field's).
        var coherent: Float = 0, cancelling: Float = 0
        var strongest: Part?
        for part in parts {
            if case .speaker = part.kind { continue }
            coherent += part.energy
            cancelling += part.energy * part.instability
            if part.energy > (strongest?.energy ?? 0) { strongest = part }
        }
        let fieldTotal = parts.reduce(0) { $0 + $1.energy }
        let instability = fieldTotal > 0 ? min(1, cancelling / fieldTotal) : 0
        let scale = input.toModel
        let near = 0.02 / max(scale, 1e-6)
        for i in bandStart[band]..<bandStart[band + 1] where cursor < Self.capacity {
            let base = SpatialObservations.observation(i)
            let e = o[base + 3]
            guard e > 0 else { continue }
            let p = SIMD3(o[base], o[base + 1], o[base + 2])
            let light = brightness * e / total
            let zone = max(0, min(input.zoneDelays.count - 1, Int(o[base + 8])))
            let born = birth - input.zoneDelays[zone]
            let frequency = o[base + 4]
            let color = input.spectral && frequency > 0 ? SpectralHue.at(hz: Double(frequency)) : hue
            let spread = input.raw ? 0 : o[base + 7] * scale
            // Model coordinates: x right, y up, z ahead.
            particles[cursor] = Particle(position: SIMD4(p.x * scale, p.z * scale, p.y * scale, born), color: SIMD4(color, light),
                                         extra: SIMD4(instability, spread, Float(band), level))
            cursor += 1
            emitted += light
            emittedPerBand[band] += light
            // What the pointer reads: the speaker the particle sits on, or the band's strongest coherent image while
            // most of the band is coherent.
            var kind = DomeProbe.Kind.none
            var source: Part?
            for speaker in input.positions where simd_distance(speaker.position, p) < near {
                kind = .speaker(speaker.name)
                break
            }
            if kind == .none, let strongest, coherent > 0.5 * fieldTotal {
                kind = strongest.kind
                source = strongest
            }
            made.append(Reading(position: p, light: light, birth: born, band: band, layer: layer, level: level, hue: color,
                                kind: kind, width: source?.width, stability: source?.stability, coherence: source?.coherence,
                                frequency: frequency > 0 ? frequency : nil))
        }
    }

    /// One band drawn from the field's statistics (a source without observations): `perBand` draws (four times as
    /// many for a source without a field), each at the amplitude-weighted centre of |CN(0, E)| amplitudes of the
    /// band's parts, sharing the band's light in proportion to their drawn energy.
    private func addStatistics(_ input: Input, layer: Int, band: Int, five: Bool, hue: SIMD3<Float>, total: Float, level: Float,
                               brightness: Float, serial: UInt32, birth: Float, into made: inout [Reading]) {
        let draws = five ? input.perBand * 4 : input.perBand
        let first = cursor, firstReading = made.count
        var drawn: Float = 0
        for k in 0..<draws {
            var random = Hash(serial: serial, band: band + (five ? 1_000 : 0) + layer * 4_096, particle: k)
            var sumA: Float = 0, sumE: Float = 0, unsteady: Float = 0
            var sum = SIMD3<Float>.zero
            var strongest = (amplitude: Float(0), index: 0)
            for (index, part) in parts.enumerated() {
                // |CN(0, E)|² is E times an exponential draw.
                let power = part.energy * random.exponential()
                let amplitude = power.squareRoot()
                var position = part.position
                if part.scatter {
                    position += part.cholesky * SIMD3(random.normal(), random.normal(), random.normal())
                }
                sum += position * amplitude
                sumA += amplitude
                sumE += power
                unsteady += part.instability * amplitude
                if amplitude > strongest.amplitude { strongest = (amplitude, index) }
            }
            guard sumA > 0, cursor < Self.capacity else { continue }
            // Simulated draws (not measurements) stay within the speakers' sphere and, unless the layout reaches below
            // it, above the ear plane, where the field's own parts are.
            var p = sum / sumA
            if !input.lower { p.z = max(0, p.z) }
            let length = simd_length(p)
            if length > 1.05 { p *= 1.05 / length }
            // Each draw's share is set below, once the band's draws are known; held here as its drawn energy.
            particles[cursor] = Particle(position: SIMD4(p.x, p.z, p.y, birth), color: SIMD4(hue, sumE),
                                         extra: SIMD4(unsteady / sumA, 0, Float(band), level))
            cursor += 1
            drawn += sumE
            let source = parts[strongest.index]
            made.append(Reading(position: p, light: sumE, birth: birth, band: five ? -1 - band : band, layer: layer,
                                level: level, hue: hue, kind: source.kind, width: source.width,
                                stability: source.stability, coherence: source.coherence, frequency: nil))
        }
        guard drawn > 0 else { return }
        // Σ shares = 1: the band's light is the same however many draws it has.
        let unit = brightness / drawn
        for i in first..<cursor { particles[i].color.w *= unit }
        for i in firstReading..<made.count { made[i].light *= unit }
        emitted += brightness
        if !five { emittedPerBand[band] += brightness }
    }

    /// Calls `body` with each band of every layer that holds energy: its layer, band (a field band, or an analysis
    /// band for a source without a field), hue and energy, with `parts` filled with its components. With observations,
    /// a band's energy is its observations'.
    private func forEachBand(_ input: Input, _ body: (_ layer: Int, _ band: Int, _ hue: SIMD3<Float>, _ energy: Float, _ five: Bool) -> Void) {
        let field = input.field
        let status = field.count == SpatialField.floats ? field[SpatialField.status] : 0
        let observed = status == 1 && Self.observed(input)
        if observed {
            let o = input.observations
            var at = 0
            for band in 0..<SpatialField.bandCount {
                bandStart[band] = at
                let n = o[SpatialObservations.counts + band]
                at += n.isFinite ? max(0, Int(n)) : 0
            }
            bandStart[SpatialField.bandCount] = min(at, Int(o[SpatialObservations.Header.count]))
            for band in 0..<SpatialField.bandCount { bandStart[band] = min(bandStart[band], bandStart[SpatialField.bandCount]) }
        }
        func isShown(_ role: Int) -> Bool { input.shown.indices.contains(role) && input.shown[role] }
        for (layer, spec) in input.layers.enumerated() {
            let layerHue = input.layerColors.indices.contains(layer) ? input.layerColors[layer] : SIMD3(repeating: 0.9)
            if status == 1, let bands = spec.bands {
                for band in bands {
                    parts.removeAll(keepingCapacity: true)
                    var observedEnergy: Float = 0
                    if observed {
                        for i in bandStart[band]..<bandStart[band + 1] {
                            let e = input.observations[SpatialObservations.observation(i) + 3]
                            if e.isFinite, e > 0 { observedEnergy += e }
                        }
                        // A valid measured frame with nothing in this band means silence here, not permission to
                        // invent particles.
                        if observedEnergy <= 0 { continue }
                    }
                    var total: Float = 0
                    for speaker in input.speakers where isShown(speaker.role) {
                        let e = field[SpatialField.independent(band: band, role: speaker.role)]
                        guard e.isFinite, e > 0 else { continue }
                        total += e
                        parts.append(Part(position: speaker.direction, energy: e, instability: 0, cholesky: simd_float3x3(0),
                                          scatter: false, kind: .speaker(speaker.name)))
                    }
                    for slot in 0..<SpatialField.coherentSlots {
                        let o = SpatialField.component(band: band, slot: slot)
                        let e = field[o + SpatialField.Component.energy]
                        guard e.isFinite, e > 0 else { continue }
                        let p = SIMD3(field[o + SpatialField.Component.x], field[o + SpatialField.Component.y],
                                      field[o + SpatialField.Component.z])
                        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                        let stability = max(0, min(1, field[o + SpatialField.Component.stability]))
                        let instability = 1 - stability
                        total += e
                        // Energy out of phase has no stable direction: scattered over its predicted spread.
                        let s = SpatialField.Component.xx
                        let covariance = simd_float3x3(rows: [
                            SIMD3(field[o + s], field[o + s + 1], field[o + s + 2]),
                            SIMD3(field[o + s + 1], field[o + s + 3], field[o + s + 4]),
                            SIMD3(field[o + s + 2], field[o + s + 4], field[o + s + 5])])
                        let scale = input.spread * instability
                        let scatter = !observed && scale > 0.02
                        let spread = max(field[o + s], field[o + s + 3], field[o + s + 5])
                        parts.append(Part(position: p, energy: e, instability: instability,
                                          cholesky: scatter ? Self.cholesky(covariance) * scale.squareRoot() : simd_float3x3(0),
                                          scatter: scatter, kind: instability > 0.5 ? .unstable : .image,
                                          width: SpatialField.width(position: p, spread: spread), stability: stability,
                                          coherence: max(0, min(1, field[o + SpatialField.Component.coherence]))))
                    }
                    if observed {
                        body(layer, band, input.spectral ? bandHue[band] : layerHue, observedEnergy, false)
                    } else {
                        guard total > 0, !parts.isEmpty else { continue }
                        body(layer, band, input.spectral ? bandHue[band] : layerHue, total, false)
                    }
                }
            } else if status == SpatialFieldWire.unsupported {
                // Each channel's band energy at its speaker only.
                for five in spec.fiveBands {
                    parts.removeAll(keepingCapacity: true)
                    var total: Float = 0
                    for speaker in input.speakers where isShown(speaker.role) {
                        let i = speaker.role * StereoBands.count + five
                        guard input.roleBandPower.indices.contains(i) else { continue }
                        let e = input.roleBandPower[i]
                        guard e.isFinite, e > 0 else { continue }
                        total += e
                        parts.append(Part(position: speaker.direction, energy: e, instability: 0, cholesky: simd_float3x3(0),
                                          scatter: false, kind: .speaker(speaker.name)))
                    }
                    guard total > 0 else { continue }
                    body(layer, five, input.spectral ? SpectralHue.bands[five] : layerHue, total, true)
                }
            }
        }
    }

    /// The lower-triangular L with L Lᵀ = `m` (a covariance; zero where it is not positive).
    private static func cholesky(_ m: simd_float3x3) -> simd_float3x3 {
        let a = m.columns
        let l11 = max(0, a.0.x).squareRoot()
        let l21 = l11 > 1e-9 ? a.0.y / l11 : 0, l31 = l11 > 1e-9 ? a.0.z / l11 : 0
        let l22 = max(0, a.1.y - l21 * l21).squareRoot()
        let l32 = l22 > 1e-9 ? (a.1.z - l31 * l21) / l22 : 0
        let l33 = max(0, a.2.z - l31 * l31 - l32 * l32).squareRoot()
        return simd_float3x3(columns: (SIMD3(l11, l21, l31), SIMD3(0, l22, l32), SIMD3(0, 0, l33)))
    }

    /// The particles' random draws: a small hash chain seeded by frame, band and particle.
    private struct Hash {
        var state: UInt32
        init(serial: UInt32, band: Int, particle: Int) {
            state = serial &* 0x9E37_79B9 ^ UInt32(truncatingIfNeeded: band) &* 0x85EB_CA6B ^ UInt32(truncatingIfNeeded: particle) &* 0xC2B2_AE35
            state ^= state >> 16
            if state == 0 { state = 0x6D2B_79F5 }
        }
        /// Uniform in (0, 1].
        mutating func uniform() -> Float {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return (Float(state >> 8) + 1) / 16_777_216
        }
        /// Exponential, mean 1.
        mutating func exponential() -> Float { -Foundation.log(uniform()) }
        /// Standard normal (Box–Muller, one of the pair).
        mutating func normal() -> Float {
            let u = uniform(), v = uniform()
            return (-2 * Foundation.log(u)).squareRoot() * cosf(2 * .pi * v)
        }
    }

    /// The particles of the frames drawn, as the vertex shader places them: one draw per segment.
    func encode(_ encoder: MTLRenderCommandEncoder, clock: Float, lifetime: Float) {
        guard let buffer else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        for segment in segments(clock: clock, lifetime: lifetime) {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segment.count,
                                   baseInstance: segment.start)
        }
    }

    /// The ring's runs of particles of the frames still alive at `clock`. Adjacent frames occupy one contiguous part of
    /// the ring and birth times live in each particle, so the GPU can age them in one pass; a run ends only across a
    /// gap or the ring's wrap (usually one or two runs).
    func segments(clock: Float, lifetime: Float) -> [(start: Int, count: Int)] {
        var runs: [(start: Int, count: Int)] = []
        var start = 0, count = 0
        for frame in frames where clock - frame.birth <= lifetime && frame.count > 0 {
            if count > 0 && start + count != frame.start { runs.append((start, count)); count = 0 }
            if count == 0 { start = frame.start }
            count += frame.count
        }
        if count > 0 { runs.append((start, count)) }
        return runs
    }

    var liveCount: Int { frames.reduce(0) { $0 + $1.count } }

    /// The particle the pointer is over at `point` (canvas points) through `project`, the brightest within reach as it
    /// shows now (`fade` seconds per e-fold), among the newest frames.
    func reading(at point: CGPoint, clock: Float, fade: Float, reach: CGFloat,
                 project: (SIMD3<Float>) -> CGPoint) -> Reading? {
        var best: (Reading, Float)?
        for frame in recent {
            for particle in frame {
                let age = clock - particle.birth
                guard age >= 0 else { continue }
                let p = project(particle.position)
                let dx = p.x - point.x, dy = p.y - point.y
                let distance2 = Float(dx * dx + dy * dy), r2 = Float(reach * reach)
                guard distance2 < r2 else { continue }
                let score = particle.light * Foundation.exp(-age / max(0.01, fade)) * Foundation.exp(-2 * distance2 / r2)
                if score > (best?.1 ?? 0) { best = (particle, score) }
            }
        }
        return best?.0
    }
}

extension RadiantParticles {
    /// Where particles fall and how much light they carry, for controlled inputs (7.1.4 speakers, one band). From the
    /// field's statistics: a centred phantom is a tight point between L and R, a hard-panned source sits at its
    /// speaker, uncorrelated L and R spread along the line between them, energy out of phase scatters. From
    /// observations: each exactly where it is, its light its share of the band's, the band's total light the same for
    /// one particle or many, nothing clamped (below the ear plane, beyond 1 m in meters). Returns the failures.
    static func checkGeometry() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL particles: \(message)"); failures += 1 }
        }
        let layout = SpeakerLayout.s714
        let geometry = SpatialGeometry.standard(roles: layout.roles)
        let speakers: [(role: Int, name: String, direction: SIMD3<Float>)] = layout.speakers.compactMap { speaker in
            guard speaker.group != .lfe, let d = geometry.direction(role: speaker.role) else { return nil }
            return (speaker.role, speaker.name, SIMD3(Float(d.x), Float(d.y), Float(d.z)))
        }
        let positions = speakers.map { (role: $0.role, name: $0.name, position: $0.direction) }
        let left = speakers.first { $0.role == Role.left }!.direction, right = speakers.first { $0.role == Role.right }!.direction
        let band = 50
        func run(_ build: (inout [Float]) -> Void) -> [Reading] {
            var field = [Float](repeating: 0, count: SpatialField.floats)
            field[SpatialField.status] = 1
            build(&field)
            let particles = RadiantParticles(device: nil)
            field.withUnsafeBufferPointer { pointer in
                let input = Input(field: pointer, roleBandPower: [], speakers: speakers, shown: [Bool](repeating: true, count: Role.count),
                                  layers: [SpatialBody.Layer(bands: band...band, fiveBands: [2])], spectral: true,
                                  layerColors: [SIMD3(repeating: 1)], perBand: 32, spread: 1, floor: -60, range: 24)
                particles.add(input, birth: 0, serial: 7, peak: particles.loudestBand(input))
            }
            return particles.recent.last ?? []
        }
        func coherent(_ field: inout [Float], at p: SIMD3<Float>, energy: Float, stability: Float, spread: Float = 0) {
            let o = SpatialField.component(band: band, slot: 0)
            field[o + SpatialField.Component.energy] = energy
            field[o + SpatialField.Component.x] = p.x; field[o + SpatialField.Component.y] = p.y; field[o + SpatialField.Component.z] = p.z
            field[o + SpatialField.Component.xx] = spread; field[o + SpatialField.Component.yy] = spread * 0.2
            field[o + SpatialField.Component.stability] = stability
        }
        let centre = (left + right) / 2
        let phantom = run { coherent(&$0, at: centre, energy: 0.01, stability: 1, spread: 0.2) }
        check(phantom.count == 32 && phantom.allSatisfy { simd_distance($0.position, centre) < 1e-4 && $0.kind == .image },
              "a centred phantom is one point between L and R")
        check(abs(phantom.reduce(0) { $0 + $1.light } - Radiant.intensity(0)) < 1e-4,
              "a band drawn from statistics emits the band's light whatever its draws (\(phantom.reduce(0) { $0 + $1.light }))")
        let hard = run { $0[SpatialField.independent(band: band, role: Role.left)] = 0.01 }
        check(!hard.isEmpty && hard.allSatisfy { simd_distance($0.position, left) < 1e-4 && $0.kind == .speaker("L") },
              "a hard-panned source sits at its speaker")
        let wide = run {
            $0[SpatialField.independent(band: band, role: Role.left)] = 0.01
            $0[SpatialField.independent(band: band, role: Role.right)] = 0.01
        }
        let xs = wide.map(\.position.x)
        let mean = xs.reduce(0, +) / Float(max(1, xs.count))
        let deviation = (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(max(1, xs.count))).squareRoot()
        let onLine = wide.allSatisfy { abs($0.position.y - centre.y) < 1e-3 && abs($0.position.z) < 1e-4 }
        check(onLine && abs(mean) < 0.12 && deviation > 0.08 && xs.contains { $0 < -0.1 } && xs.contains { $0 > 0.1 },
              "uncorrelated L and R spread along the line between them (mean \(mean), deviation \(deviation))")
        let opposed = run { coherent(&$0, at: centre * 0.5, energy: 0.01, stability: 0, spread: 0.2) }
        let scatter = opposed.map { simd_distance($0.position, centre * 0.5) }.max() ?? 0
        check(scatter > 0.05 && opposed.allSatisfy { $0.kind == .unstable }, "energy out of phase scatters over its spread")
        let silent = run { _ in }
        check(silent.isEmpty, "silence makes no particles")

        // Observations (build 98): one particle each, where it is, its light its share of the band's.
        typealias O = (position: SIMD3<Float>, energy: Float, frequency: Float, spread: Float)
        func runObserved(_ observations: [O], toModel: Float = 1, positions: [(role: Int, name: String, position: SIMD3<Float>)] = positions,
                         _ build: (inout [Float]) -> Void) -> (readings: [Reading], particles: RadiantParticles) {
            var field = [Float](repeating: 0, count: SpatialField.floats)
            field[SpatialField.status] = 1
            build(&field)
            var v = [Float](repeating: 0, count: SpatialObservations.first + observations.count * SpatialObservations.fields)
            v[SpatialObservations.Header.status] = 1
            v[SpatialObservations.Header.count] = Float(observations.count)
            v[SpatialObservations.counts + band] = Float(observations.count)
            for (i, ob) in observations.enumerated() {
                let o = SpatialObservations.observation(i)
                v[o] = ob.position.x; v[o + 1] = ob.position.y; v[o + 2] = ob.position.z; v[o + 3] = ob.energy
                v[o + 4] = ob.frequency; v[o + 5] = ob.frequency; v[o + 6] = ob.frequency; v[o + 7] = ob.spread
            }
            let particles = RadiantParticles(device: nil)
            field.withUnsafeBufferPointer { f in
                v.withUnsafeBufferPointer { p in
                    let input = Input(field: f, observations: p, roleBandPower: [], speakers: speakers, positions: positions,
                                      toModel: toModel, shown: [Bool](repeating: true, count: Role.count),
                                      layers: [SpatialBody.Layer(bands: band...band, fiveBands: [2])], spectral: true,
                                      layerColors: [SIMD3(repeating: 1)], perBand: 30, spread: 1, floor: -60, range: 24)
                    particles.add(input, birth: 0, serial: 7, peak: particles.loudestBand(input))
                }
            }
            return (particles.recent.last ?? [], particles)
        }
        let gains = (2 * left + right) / 3
        let panned = runObserved([(gains, 0.01, 1_000, 0)]) {
            $0[SpatialField.independent(band: band, role: Role.left)] = 0.002
            coherent(&$0, at: centre, energy: 0.008, stability: 1, spread: 0.2)
        }.readings
        check(panned.count == 1 && simd_distance(panned[0].position, gains) < 1e-6 && panned[0].frequency == 1_000,
              "an observation panned by its gains: one particle exactly where the gains put it, with its own frequency")
        let unit = panned.first?.light ?? 0
        let two = runObserved([(left, 0.01, 900, 0), (centre, 0.02, 1_100, 0)]) {
            $0[SpatialField.independent(band: band, role: Role.left)] = 0.01
            coherent(&$0, at: centre, energy: 0.02, stability: 1)
        }.readings
        let atLeft = two.filter { simd_distance($0.position, left) < 1e-6 }.reduce(0) { $0 + $1.light }
        let atCentre = two.filter { simd_distance($0.position, centre) < 1e-6 }.reduce(0) { $0 + $1.light }
        check(two.count == 2 && abs(atLeft / (atLeft + atCentre) - 1.0 / 3) < 1e-5 && abs(atLeft + atCentre - unit) < 1e-5,
              "two sources in one band: each at its own place, light in proportion to energy, the band's total unchanged")
        check(two.filter { simd_distance($0.position, left) < 1e-6 }.allSatisfy { $0.kind == .speaker("L") },
              "a particle on a speaker reads as that speaker's")
        // The same band's energy as one observation or as 30: the same total light, the same centre of light.
        let many = (0..<30).map { i -> O in
            let t = Float(i) / 29
            return (left + (right - left) * t, 0.01 / 30, 1_000, 0)
        }
        let one = runObserved([(centre, 0.01, 1_000, 0.2)]) { _ in }
        let thirty = runObserved(many) { _ in }
        let centreOfLight = thirty.readings.reduce(SIMD3<Float>.zero) { $0 + $1.position * $1.light } / max(1e-9, thirty.particles.emitted)
        check(abs(one.particles.emitted - thirty.particles.emitted) <= 0.01 * one.particles.emitted
                  && simd_distance(centreOfLight, centre) < 1e-4,
              "a band's light is conserved whatever its number of particles (\(one.particles.emitted) vs \(thirty.particles.emitted))")
        // Nothing clamped: below the ear plane stays below it; in meters, 3 m out stays 3 m out (model × 1/3).
        let below = SIMD3<Float>(0, 0.66, -0.34)
        check(runObserved([(below, 0.01, 1_000, 0)]) { _ in }.readings.first.map { simd_distance($0.position, below) < 1e-6 } == true,
              "an observation below the ear plane is not raised onto it")
        let far = SIMD3<Float>(0.5, 2.9, 0.2)
        let meters = runObserved([(far, 0.01, 1_000, 0.3)], toModel: 1.0 / 3) { _ in }
        check(meters.readings.first.map { simd_distance($0.position, far) < 1e-6 } == true
                  && meters.particles.liveCount == 1,
              "an observation in meters keeps its distance, drawn at the layout's scale")
        let cancelling = runObserved([(centre, 0.01, 1_000, 0)]) { coherent(&$0, at: centre * 0.5, energy: 0.01, stability: 0) }.readings
        check(cancelling.allSatisfy { simd_distance($0.position, centre) < 1e-6 && $0.kind == .unstable },
              "energy that cancels sits where its amplitudes put it and reads out of phase")
        let emptyMeasured = runObserved([]) { coherent(&$0, at: centre, energy: 0.01, stability: 1) }.readings
        check(emptyMeasured.isEmpty, "an empty measured band never falls back to simulated positions")
        return failures
    }
}
