import AnalysisCore
import Foundation
import Metal
import simd

/// Radiant's particles (`NebulaStyle.radiant`): every band of the spatial field shown as a handful of particles at the
/// centres of gravity of its frequencies, kept for the persistence time and drawn by `radiantParticleVertex`.
///
/// A spatial analyser places each FFT bin at the centre of gravity of the speakers, weighted by the bin's amplitude in
/// each. The analysis does exactly that for the newest transform (`SpatialPoints`: up to 32 bins per band, drawn in
/// proportion to their energy where a band has more), and each frame this draws `count` particles per band from those
/// bins, again in proportion to their energy, so every particle carries an equal share of the band's light and a
/// strong bin gathers several into one bright bead. A source panned between two speakers sits on the line between them
/// where its gains put it, two sources sharing a band keep their own places, sound the speakers carry independently
/// scatters along the line bin by bin and frame by frame, a hard-panned source sits at its speaker. Each particle
/// carries its band's share of coherent energy that cancels at the listener (`SpatialField`'s stability) for the ochre
/// tint.
///
/// A source without the bins (a Bridge plugin before build 87) still sends the field's statistics, per band each
/// speaker's independent energy and the coherent components (their energy vector, `SpatialField.image`); from those
/// this draws `count` bins as such a source's bins would fall: every independent part, and every coherent part as one
/// virtual speaker at its image, gets an amplitude |CN(0, E)| (the magnitude of a complex Gaussian of its energy, as a
/// noise-like signal's bins have), and the particle sits at their amplitude-weighted centre. Energy out of phase, which
/// has no stable direction there, is also scattered over its predicted spread (`spread` of it).
///
/// A particle's light is its band's level within the glow range below the loudest band (`Radiant.intensity`),
/// shared among the band's particles. The GPU fades and blurs it as it ages (`radiantParticleVertex`), so new
/// particles are crisp beads and older ones smoke into glow, in model space, so the camera can turn at any time.
/// Random draws are hashed from the frame, band, particle and component, so a frozen picture holds still.
final class RadiantParticles {
    /// One particle as the shader reads it (`RadiantParticle`): model position and birth (seconds of the scene's
    /// clock); colour and light at birth; instability, size factor, band and level (dBFS).
    struct Particle {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
        var extra: SIMD4<Float>
    }

    /// What the pointer reads of a particle.
    struct Reading {
        var position: SIMD3<Float>      // field frame
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
    }

    static let capacity = 320_000
    let buffer: MTLBuffer?
    private var particles: UnsafeMutablePointer<Particle>
    private var cursor = 0
    /// The frames drawn: where their particles are in the ring, how many, and when they were born.
    private(set) var frames: [(start: Int, count: Int, birth: Float)] = []
    /// The newest frames' particles as the pointer reads them.
    private(set) var recent: [[Reading]] = []
    static let recentFrames = 6
    /// Counts every change to what the ring holds, so an unchanged picture is not drawn again.
    private(set) var version = 0
    /// The loudest band of the newest frame (dBFS).
    private(set) var loudest: Float = -200

    // Per band, the components of the frame being built.
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
    /// Per band, the newest transform's bins (`SpatialPoints`) when the source sends them: position and energy.
    private var bins: [(position: SIMD3<Float>, energy: Float)] = []
    /// Each field band's hue on the spectral scale and centre (Hz).
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
        bins.reserveCapacity(SpatialPoints.perBand)
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
        recent.removeAll { $0.first.map { clock - $0.birth > lifetime } ?? true }
        if frames.count != before { version &+= 1 }
    }

    /// What one frame is built from.
    struct Input {
        var field: UnsafeBufferPointer<Float>
        /// The same transform's bins (`SpatialPoints` layout), or nothing from a source that does not send them.
        var points = UnsafeBufferPointer<Float>(start: nil, count: 0)
        var roleBandPower: [Float]
        var speakers: [(role: Int, name: String, direction: SIMD3<Float>)]
        var shown: [Bool]
        var layers: [SpatialBody.Layer]
        /// Coloured by frequency, or each layer in its colour.
        var spectral: Bool
        var layerColors: [SIMD3<Float>]
        var perBand: Int
        var size: Float
        var spread: Float
        var floor: Float
        var range: Float
    }

    /// The loudest band (dBFS) `input` holds, before any particle is made: the glow's range hangs from it.
    func loudestBand(_ input: Input) -> Float {
        var top: Float = -200
        forEachBand(input) { _, _, _, energy, _ in top = max(top, 10 * SpatialBody.log10(max(energy, 1e-30))) }
        return top
    }

    /// Adds one frame of particles born at `birth` (scene clock, seconds), hashed from `serial`, with the glow's range
    /// hanging from `peak` (dBFS).
    func add(_ input: Input, birth: Float, serial: UInt32, peak: Float) {
        let floorEnergy = Float(pow(10, Double(input.floor) / 10))
        let perBand = max(1, input.perBand)
        let toRange = 1 / max(1, input.range)
        // The light is the band's brightness shared among its particles, each by its own draw's energy, compressed as
        // the brightness is (exp(contrast·x) is energy^γ).
        let gamma = Radiant.contrast * 10 / (max(1, input.range) * Float(M_LN10))
        let worst = perBand * (SpatialField.bandCount + StereoBands.count)
        if cursor + worst > Self.capacity { cursor = 0 }
        let start = cursor
        var made: [Reading] = []
        made.reserveCapacity(min(worst, 4096))
        loudest = -200
        forEachBand(input) { layer, band, hue, total, five in
            guard total > floorEnergy else { return }
            let level = 10 * SpatialBody.log10(total)
            loudest = max(loudest, level)
            let brightness = Radiant.intensity((level - peak) * toRange)
            guard brightness > 0 else { return }
            if !bins.isEmpty {
                addBins(layer: layer, band: band, hue: hue, total: total, level: level, brightness: brightness,
                        draws: perBand, serial: serial, birth: birth, size: input.size, into: &made)
                return
            }
            let draws = five ? perBand * 4 : perBand
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
                var p = sum / sumA
                p.z = max(0, p.z)
                let length = simd_length(p)
                if length > 1.05 { p *= 1.05 / length }
                // Shared by the square root of their number: a band whose particles scatter still shows, one whose
                // particles fall on one point burns brighter.
                let light = brightness * powf(max(1e-6, sumE / total), gamma) / Float(draws).squareRoot()
                let instability = unsteady / sumA
                // Model coordinates: x right, y up, z ahead.
                particles[cursor] = Particle(position: SIMD4(p.x, p.z, p.y, birth), color: SIMD4(hue, light),
                                             extra: SIMD4(instability, input.size, Float(band), level))
                cursor += 1
                let source = parts[strongest.index]
                made.append(Reading(position: p, light: light, birth: birth, band: five ? -1 - band : band, layer: layer,
                                    level: level, hue: hue, kind: source.kind, width: source.width,
                                    stability: source.stability, coherence: source.coherence))
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

    /// One band's particles from its bins (`bins`): `draws` of them in proportion to the bins' energy (systematic
    /// resampling from one random offset), each with an equal share of the band's light. Draws that fall on the same bin
    /// would be the same particle drawn over itself, so they are one particle with their light added: the light adds
    /// up alike, and a tone or a phantom costs one particle per band, not `draws`.
    private func addBins(layer: Int, band: Int, hue: SIMD3<Float>, total: Float, level: Float, brightness: Float,
                         draws: Int, serial: UInt32, birth: Float, size: Float, into made: inout [Reading]) {
        var binTotal: Float = 0
        for bin in bins { binTotal += bin.energy }
        guard binTotal > 0 else { return }
        // The band's coherent energy, how much of it cancels at the listener, and its strongest image.
        var coherent: Float = 0, cancelling: Float = 0
        var strongest: Part?
        for part in parts {
            if case .speaker = part.kind { continue }
            coherent += part.energy
            cancelling += part.energy * part.instability
            if part.energy > (strongest?.energy ?? 0) { strongest = part }
        }
        let instability = total > 0 ? min(1, cancelling / total) : 0
        let share = brightness / Float(draws).squareRoot()
        func emit(_ index: Int, _ taken: Int) {
            guard cursor < Self.capacity else { return }
            var p = bins[index].position
            p.z = max(0, p.z)
            let length = simd_length(p)
            if length > 1.05 { p *= 1.05 / length }
            let light = share * Float(taken)
            particles[cursor] = Particle(position: SIMD4(p.x, p.z, p.y, birth), color: SIMD4(hue, light),
                                         extra: SIMD4(instability, size, Float(band), level))
            cursor += 1
            // What the pointer reads: the speaker the particle sits on, or the band's strongest coherent image while
            // most of the band is coherent.
            var kind = DomeProbe.Kind.none
            var source: Part?
            for part in parts {
                if case .speaker = part.kind, simd_distance(part.position, p) < 0.02 { kind = part.kind; break }
            }
            if kind == .none, let strongest, coherent > 0.5 * total {
                kind = strongest.kind
                source = strongest
            }
            made.append(Reading(position: p, light: light, birth: birth, band: band, layer: layer, level: level, hue: hue,
                                kind: kind, width: source?.width, stability: source?.stability, coherence: source?.coherence))
        }
        var random = Hash(serial: serial, band: band + layer * 4_096, particle: 0)
        let step = binTotal / Float(draws)
        var next = random.uniform() * step
        var index = 0, below: Float = 0, taken = 0
        for _ in 0..<draws {
            while index < bins.count - 1 && below + bins[index].energy < next {
                if taken > 0 { emit(index, taken); taken = 0 }
                below += bins[index].energy
                index += 1
            }
            taken += 1
            next += step
        }
        if taken > 0 { emit(index, taken) }
    }

    /// Calls `body` with each band of every layer that holds energy: its layer, band (a field band, or an analysis
    /// band for a source without a field), hue and energy, with `parts` filled with its components and `bins` with
    /// its bins when the source sends them.
    private func forEachBand(_ input: Input, _ body: (_ layer: Int, _ band: Int, _ hue: SIMD3<Float>, _ energy: Float, _ five: Bool) -> Void) {
        let field = input.field
        let status = field.count == SpatialField.floats ? field[SpatialField.status] : 0
        let points = input.points
        let pointed = status == 1 && points.count == SpatialPoints.floats && points[SpatialPoints.status] == 1
        func isShown(_ role: Int) -> Bool { input.shown.indices.contains(role) && input.shown[role] }
        for (layer, spec) in input.layers.enumerated() {
            let layerHue = input.layerColors.indices.contains(layer) ? input.layerColors[layer] : SIMD3(repeating: 0.9)
            if status == 1, let bands = spec.bands {
                for band in bands {
                    parts.removeAll(keepingCapacity: true)
                    bins.removeAll(keepingCapacity: true)
                    if pointed {
                        let storedCount = points[SpatialPoints.count(band: band)]
                        let count = storedCount.isFinite ? Int(max(0, min(Float(SpatialPoints.perBand), storedCount))) : 0
                        for index in 0..<count {
                            let o = SpatialPoints.point(band: band, index: index)
                            let p = SIMD3(points[o], points[o + 1], points[o + 2]), e = points[o + 3]
                            guard e.isFinite, e > 0, p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                            // Equal positions have the same Gaussian, age, colour and phase tint. Combine their
                            // energy before sampling: mono and hard pans need only one bead per band.
                            if let existing = bins.firstIndex(where: { $0.position == p }) {
                                bins[existing].energy += e
                            } else {
                                bins.append((p, e))
                            }
                        }
                    }
                    // A valid measured frame with no bins means silence here, not permission to invent bins.
                    if pointed && bins.isEmpty { continue }
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
                        let scatter = !pointed && scale > 0.02
                        let spread = max(field[o + s], field[o + s + 3], field[o + s + 5])
                        parts.append(Part(position: p, energy: e, instability: instability,
                                          cholesky: scatter ? Self.cholesky(covariance) * scale.squareRoot() : simd_float3x3(0),
                                          scatter: scatter, kind: instability > 0.5 ? .unstable : .image,
                                          width: SpatialField.width(position: p, spread: spread), stability: stability,
                                          coherence: max(0, min(1, field[o + SpatialField.Component.coherence]))))
                    }
                    guard total > 0, !parts.isEmpty else { continue }
                    body(layer, band, input.spectral ? bandHue[band] : layerHue, total, false)
                }
            } else if status == SpatialFieldWire.unsupported {
                // Each channel's band energy at its speaker only.
                for five in spec.fiveBands {
                    parts.removeAll(keepingCapacity: true)
                    bins.removeAll(keepingCapacity: true)
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

    /// The particles of the frames drawn, as the vertex shader places them: one draw per frame.
    func encode(_ encoder: MTLRenderCommandEncoder, clock: Float, lifetime: Float) {
        guard let buffer else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        // Adjacent frames occupy one contiguous part of the ring. Birth times live in each particle, so the GPU
        // can age them in one draw. Flush only across a gap or the ring wrap (usually one or two draws per pass).
        var start = 0, count = 0
        func flush() {
            guard count > 0 else { return }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count,
                                   baseInstance: start)
        }
        for frame in frames where clock - frame.birth <= lifetime && frame.count > 0 {
            if count > 0 && start + count != frame.start { flush(); count = 0 }
            if count == 0 { start = frame.start }
            count += frame.count
        }
        flush()
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
    /// Where particles fall for controlled fields (7.1.4 speakers, one band): a centred phantom is a tight point between
    /// L and R, a hard-panned source sits at its speaker, uncorrelated L and R spread along the line between them, and
    /// energy out of phase scatters, tinted. Returns the failures.
    static func checkGeometry() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL particles: \(message)"); failures += 1 }
        }
        let layout = SpeakerLayout.s714
        let speakers: [(role: Int, name: String, direction: SIMD3<Float>)] = layout.speakers.compactMap { speaker in
            guard speaker.group != .lfe, let d = SpeakerGeometry.direction(role: speaker.role, sidesAtNinety: layout.sidesAtNinety) else { return nil }
            return (speaker.role, speaker.name, SIMD3(Float(d.x), Float(d.y), Float(d.z)))
        }
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
                                  layerColors: [SIMD3(repeating: 1)], perBand: 32, size: 1, spread: 1, floor: -60, range: 24)
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

        // The analysis' bins: particles where the bins are, as many at each as its share of the band's energy.
        func runBins(_ bins: [(SIMD3<Float>, Float)], _ build: (inout [Float]) -> Void) -> [Reading] {
            var field = [Float](repeating: 0, count: SpatialField.floats)
            field[SpatialField.status] = 1
            build(&field)
            var points = [Float](repeating: 0, count: SpatialPoints.floats)
            points[SpatialPoints.status] = 1
            points[SpatialPoints.count(band: band)] = Float(bins.count)
            for (index, bin) in bins.enumerated() {
                let o = SpatialPoints.point(band: band, index: index)
                points[o] = bin.0.x; points[o + 1] = bin.0.y; points[o + 2] = bin.0.z; points[o + 3] = bin.1
            }
            let particles = RadiantParticles(device: nil)
            field.withUnsafeBufferPointer { f in
                points.withUnsafeBufferPointer { p in
                    let input = Input(field: f, points: p, roleBandPower: [], speakers: speakers, shown: [Bool](repeating: true, count: Role.count),
                                      layers: [SpatialBody.Layer(bands: band...band, fiveBands: [2])], spectral: true,
                                      layerColors: [SIMD3(repeating: 1)], perBand: 30, size: 1, spread: 1, floor: -60, range: 24)
                    particles.add(input, birth: 0, serial: 7, peak: particles.loudestBand(input))
                }
            }
            return particles.recent.last ?? []
        }
        let gains = (2 * left + right) / 3
        let pannedBins = runBins([(gains, 0.01)]) {
            $0[SpatialField.independent(band: band, role: Role.left)] = 0.002
            coherent(&$0, at: centre, energy: 0.008, stability: 1, spread: 0.2)
        }
        let unit = pannedBins.first?.light ?? 0
        check(pannedBins.count == 1 && simd_distance(pannedBins[0].position, gains) < 1e-6,
              "a bin panned by its gains: its particles (one, carrying all their light) exactly where the gains put it, not at the field's image")
        let two = runBins([(left, 0.01), (centre, 0.02)]) {
            $0[SpatialField.independent(band: band, role: Role.left)] = 0.01
            coherent(&$0, at: centre, energy: 0.02, stability: 1)
        }
        let atLeft = two.filter { simd_distance($0.position, left) < 1e-6 }.reduce(0) { $0 + $1.light } / unit * 30
        let atCentre = two.filter { simd_distance($0.position, centre) < 1e-6 }.reduce(0) { $0 + $1.light } / unit * 30
        check(two.count == 2 && abs(atLeft - 10) < 1e-3 && abs(atCentre - 20) < 1e-3,
              "two sources in one band: each at its own place, light in proportion to energy (\(atLeft) draws at L, \(atCentre) at the centre)")
        check(two.filter { simd_distance($0.position, left) < 1e-6 }.allSatisfy { $0.kind == .speaker("L") },
              "a particle on a speaker reads as that speaker's")
        let cancelling = runBins([(centre, 0.01)]) { coherent(&$0, at: centre * 0.5, energy: 0.01, stability: 0) }
        check(cancelling.allSatisfy { simd_distance($0.position, centre) < 1e-6 && $0.kind == .unstable },
              "energy that cancels sits where its amplitudes put it and reads out of phase")
        let coincident = runBins(Array(repeating: (centre, Float(0.01 / 32)), count: 32)) {
            coherent(&$0, at: centre, energy: 0.01, stability: 1)
        }
        check(coincident.count == 1 && abs((coincident.first?.light ?? 0) - unit) < 1e-5,
              "32 colocated bins become one bead with the same total light")
        let emptyMeasured = runBins([]) { coherent(&$0, at: centre, energy: 0.01, stability: 1) }
        check(emptyMeasured.isEmpty, "an empty measured band never falls back to simulated positions")
        return failures
    }
}
