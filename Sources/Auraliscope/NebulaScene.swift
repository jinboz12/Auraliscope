import Accelerate
import AnalysisCore
import Metal
import SwiftUI
import simd

/// The Immersive soundstage's nebula, in either style (`NebulaStyle`). Radiant draws the spatial field as particles
/// (`RadiantParticles`): each band where its frequencies' centres of gravity fall, faded and smeared as they age. The
/// level body, described below, draws it as one glowing volume whose radius in each direction is the level heard
/// from there.
///
/// On each changed input the CPU builds the body's level in each of `SpatialBody.count` directions per layer (the full
/// band, or each band of the BANDS menu's split), and for the full band how loud each of the five analysis bands is
/// heard from each direction. Every display frame it glides toward that target (the targets arrive at the analysis
/// rate, about 30 per second, and are run straight from one to the next so the motion has no steps), eases it in dB
/// (attack, release and a fading afterglow, so fades look even), maps it to a radius on a fixed dBFS scale (the floor
/// at the listener, 0 dBFS at the speakers' shell, so a level always has the same radius and the floor rings read it)
/// and uploads one slice per layer of a small texture: the radius with afterglow, the share out of phase, its weight
/// and the live radius; and, coloured by frequency, two slices with each band's radius on the same scale. A layer that
/// has come to rest is neither eased nor uploaded again until its target changes.
///
/// The GPU marches the occupied volume (`bodyFragment`): emissive light that burns toward white where the body is deep
/// and loud, a fainter afterglow, energy out of phase tinted ochre. Coloured by frequency, a point of the body wears the
/// hues of the bands that reach at least that far in its direction, weighted by how far they reach: toward the
/// listener every audible band mixes (toward white for broadband sound), toward the edge only the loudest bands remain,
/// so the fringe shows what dominates each direction. It marches at half the canvas' resolution into a texture of its
/// own, kept while nothing it shows changes, and is laid under the dome's grid and speakers. A band change draws the new
/// choice into a second set of textures and cross-fades the old body out over it.
final class NebulaScene {
    let body = SpatialBody()
    /// Two sets of the body's textures: a band change draws the new choice into the other set and cross-fades.
    private let textures: [MTLTexture]
    private let bandTextures: [MTLTexture]
    private var active = 0
    private var texture: MTLTexture? { textures.indices.contains(active) ? textures[active] : nil }
    private var bandTexture: MTLTexture? { bandTextures.indices.contains(active) ? bandTextures[active] : nil }
    /// The body a band change leaves, fading out over the new one (its set, camera, quad and colours as last drawn),
    /// and the change's progress on the 0.55 s spring every band switch follows (`BandTransition`).
    private var leaving: (set: Int, uniforms: BodyUniforms, colors: [SIMD4<Float>])?
    private var crossfade = PresenceSpring()
    /// The half-resolution body (`encodeOffscreen`), the quad it covers this frame (nil: nothing to lay in), what it
    /// last showed, and a count of the textures' uploads, so an unchanged body is not drawn again.
    private var offscreen: MTLTexture?
    /// Radiant's glow, near (a quarter of the half-resolution texture) and wide (an eighth), each with its blur's other
    /// half; its sparks, at the canvas' full resolution.
    private var glowTextures: [MTLTexture] = []
    private var wideTextures: [MTLTexture] = []
    private var sparkTexture: MTLTexture?
    /// The Radiant body's volumes (`radiantSplatKernel`): both grids' fixed-point sums in one buffer, and per grid the
    /// blurred volume (first) and the blur's scratch; what the splat and the ray-march were last given.
    private var volumeSums: MTLBuffer?
    private var fineVolume: [MTLTexture] = []
    private var coarseVolume: [MTLTexture] = []
    private(set) var bodySplat = VolumeSplat()
    private(set) var bodyLook = RadiantBodyLook()
    /// The Radiant body's point lights (Radiant's particles over the body): how they are laid in, their half-resolution
    /// haze, and the quad they were last laid in with (nil: none this frame).
    private(set) var pointUniforms = BodyUniforms()
    private var pointLook = RadiantLook()
    private var pointsTexture: MTLTexture?
    private(set) var pointsComposite: BodyUniforms?
    /// Radiant's exposure meter (`radiantMeterKernel`): the wide glow's brightest point, and that held; the scene's
    /// clock when it was last read.
    private let meter: MTLBuffer?
    private var meterClock: Float = 0
    private var composite: BodyUniforms?
    /// How far the dome has arrived (`DomeScene.draw`'s opacity): the composites are laid in at this.
    private var entrance: Float = 1
    private var compositeLook = RadiantLook()
    // Cache the outgoing composite once on a style/Radiant-band change. No second particle simulation or ray march
    // runs during the transition; rapid switches capture the currently blended image instead of flashing back.
    private var transitionTexture: MTLTexture?
    private var transitionQuad = BodyUniforms()
    private var transition = PresenceSpring()
    private var pendingTransition = false
    private var renderedKey: RenderKey?
    private var version = 0
    /// A small tile of static 3D noise: the body's fine grain, like the backdrop's film grain (`Grain`).
    private let grainTexture: MTLTexture?
    private static let size = SpatialBody.count * SpatialBody.maxLayers
    private static let bandCount = StereoBands.count

    /// Every per-direction plane in one allocation, so the per-frame loop runs on plain pointers. Per layer and
    /// direction (`size` each): the level shown (dB, eased), its afterglow (dB), the share out of phase (held while the
    /// direction is silent) and how lit it has been lately, the weight that share carries between directions; each
    /// band's radius shown (five planes, eased, held while silent); the target the level glides from and to; the newest
    /// target's share out of phase and band radii; the radius drawn (0…1). Then one layer's planes before they are
    /// interleaved for the textures (radius, share × weight, weight, live radius, the five band radii and the largest of
    /// them, scaled to 16 bits) and its footprint.
    private let store: UnsafeMutablePointer<Float>
    private static let planeCount = 4 + bandCount + 3 + bandCount + 1
    private var level: UnsafeMutablePointer<Float> { store }
    private var glow: UnsafeMutablePointer<Float> { store + Self.size }
    private var phase: UnsafeMutablePointer<Float> { store + 2 * Self.size }
    private var weight: UnsafeMutablePointer<Float> { store + 3 * Self.size }
    private var bands: UnsafeMutablePointer<Float> { store + 4 * Self.size }
    private var from: UnsafeMutablePointer<Float> { store + (4 + Self.bandCount) * Self.size }
    private var to: UnsafeMutablePointer<Float> { store + (5 + Self.bandCount) * Self.size }
    private var targetShare: UnsafeMutablePointer<Float> { store + (6 + Self.bandCount) * Self.size }
    private var targetBands: UnsafeMutablePointer<Float> { store + (7 + Self.bandCount) * Self.size }
    private var radii: UnsafeMutablePointer<Float> { store + (7 + 2 * Self.bandCount) * Self.size }
    private var planes: UnsafeMutablePointer<Float> { store + Self.planeCount * Self.size }
    private static let uploadPlanes = 4 + bandCount + 1
    private var reachScratch: UnsafeMutablePointer<Float> { planes + Self.uploadPlanes * SpatialBody.count }
    /// The radius drawn (0…1) per layer and direction, as uploaded; the pointer's reading samples it as the GPU does.
    var radius: [Float] { Array(UnsafeBufferPointer(start: radii, count: Self.size)) }
    private var upload = [UInt16](repeating: 0, count: SpatialBody.count * 4)
    /// Per azimuth step of the layer being eased: the direction where the body reaches furthest over the floor.
    private var reachIndex = [Int](repeating: -1, count: SpatialBody.azimuthSteps)
    private var bandUpload = [UInt16](repeating: 0, count: SpatialBody.count * 8)
    /// Per layer and azimuth step: how far the body reaches over the floor at any height (radius × cos elevation), and
    /// the colour at its edge there.
    private(set) var footprint = [Float](repeating: 0, count: SpatialBody.azimuthSteps * SpatialBody.maxLayers)
    private(set) var footprintTint = [SIMD3<Float>](repeating: SIMD3(repeating: 0.8),
                                                    count: SpatialBody.azimuthSteps * SpatialBody.maxLayers)
    /// The LFE's level (dB, eased like the body's) and the radius it reaches on the same scale.
    private var lfeLevel: Float = -200
    private var lfeGlow: Float = -200
    private(set) var lfeRadius: Float = 0

    /// What the last frame drew: its band choice and groups, the camera and quad, and each layer's colour, then the
    /// core's tint, the out-of-phase tint, the panel's ground and the five band hues.
    private(set) var choice = BandChoice(.overall)
    private(set) var groups: [Int] = [0]
    private(set) var uniforms = BodyUniforms()
    private(set) var colors = [SIMD4<Float>](repeating: .zero, count: SpatialBody.maxLayers + 3 + StereoBands.count)
    private(set) var floor: Float = -60
    /// Whether the body is coloured by frequency: the full band with Frequency colours (a split wears its bands' hues).
    private(set) var spectral = true
    /// How the field is drawn: Radiant's particles, or the level body.
    private(set) var style = NebulaStyle.radiant
    /// Radiant: its particles; the scene's own clock (seconds of signal, still while frozen) and frame count; the loudest
    /// band (dBFS) the glow's range hangs from, risen at once and fallen back slowly, and the newest frame's; the
    /// speakers' directions for the layout drawn; what the particles were last made with; the camera and look they are
    /// drawn with.
    let particles: RadiantParticles
    private(set) var clock: Float = 0
    private var serial: UInt32 = 0
    private(set) var peak: Float = -200
    private var newest: Float = -200
    private var particleLayout: (layout: SpeakerLayout, hash: UInt64)?
    private var particleSpeakers: [(role: Int, name: String, direction: SIMD3<Float>)] = []
    private var particlePositions: [(role: Int, name: String, position: SIMD3<Float>)] = []
    private var particleKey: ParticleKey?
    /// The scene clock minus the audio time (seconds) of the newest observations, so a frame is born when its audio
    /// was analysed, not when it arrived; set again after a jump (a pause, a break, a new stream).
    private var audioAnchor: Double?
    private var lastAudioTime: Double?
    /// The newest observation frame taken (its serial and window end): the same frame shown again (a display frame
    /// between analyses, a held result) is never added twice.
    private var lastObserved: (serial: Float, end: UInt64)?
    /// Observations computed with another geometry than the one drawn (a layout change on its way to the analysis, or
    /// a plugin that computes with the standard layout): how many frames were refused, and whether the newest was.
    private(set) var refusedFrames = 0
    private(set) var waitingForGeometry = false
    /// Draws the observations as they are (`NebulaSettings.rawPoints`).
    private(set) var raw = false
    /// Model units per unit of the observations (1 / the layout's largest distance in meters, or 1), and whether they are
    /// in meters: the readout projects them as the particles are drawn.
    private var observationScale: Float = 1
    private var observationsInMeters = false
    private var lastGeometry: UInt64?
    /// The frames heard lately with their bins (newest last, within the persistence time): a change to how the
    /// particles are drawn remakes the picture from them, so it shows what was heard rather than the newest frame
    /// repeated.
    private struct Heard {
        var birth: Float
        var serial: UInt32
        var field: [Float]
        var observations: [Float]
        var power: [Float]
    }
    private var heard: [Heard] = []
    private(set) var camera = RadiantCamera()
    private(set) var look = RadiantLook()
    private struct ParticleKey: Equatable {
        var perBand: Int
        var raw: Bool
        var spread: Float
        var spectral: Bool
        var layers: [SpatialBody.Layer]
        var colors: [SIMD3<Float>]
        var floor: Float
        var range: Float
    }
    /// The field the newest frame read: 1 the plugin's or the local analysis', −1 a source without one (each channel's
    /// band energy at its speaker), 0 none.
    private(set) var status: Float = 0
    // Reuse the measured target between snapshots; easing still runs at the display rate.
    // Content equality also catches frozen-band changes and sources whose serial restarts.
    private var cachedAnalysisSerial: Float = -1
    private var cachedField: [Float] = []
    private var cachedObservations: [Float] = []
    private var cachedPower: [Float] = []
    private var cachedShown: [Bool] = []
    private var cachedLayers: [SpatialBody.Layer] = []
    private var cachedSettings: SpatialBody.Settings?
    private var cachedFloor: Float = 0
    private(set) var evaluations = 0
    /// Frames each layer was eased and uploaded (diagnostics: a layer at rest is skipped).
    private(set) var easedFrames = 0
    private var bound: Float = 0
    private var layerBound = [Float](repeating: 0, count: SpatialBody.maxLayers)
    /// The first grid direction the easing covers (`SpatialBody.firstRow`'s).
    private var easedFrom = SpatialBody.floorRow * SpatialBody.azimuthSteps
    /// Per layer: whether it has come to rest on its target (nothing to ease or upload until the target changes).
    private var settled = [Bool](repeating: false, count: SpatialBody.maxLayers)
    /// Seconds since the newest target and the interval the targets have been arriving at: the glide's progress.
    private var sinceTarget: Float = 0
    private var targetInterval: Float = 1.0 / 30
    private var epoch = -1
    private var stream: Float = -1
    private var lastLayout: SpeakerLayout?
    private var lastChoice: BandChoice?
    private var lastSpectral: Bool?
    private var lastStyle: NebulaStyle?
    /// Each field band's centre (Hz) and the analysis band (`StereoBands`) it lies in, computed once.
    private let centres = (0..<SpatialField.bandCount).map { SpatialField.centre($0) }
    private let fiveBands = (0..<SpatialField.bandCount).map { band in
        StereoBands.edges.lastIndex { SpatialField.centre(band) >= $0 } ?? 0
    }

    init(device: MTLDevice?) {
        particles = RadiantParticles(device: device)
        let floats = Self.planeCount * Self.size + Self.uploadPlanes * SpatialBody.count + SpatialBody.azimuthSteps
        store = .allocate(capacity: floats)
        store.initialize(repeating: 0, count: floats)
        // Levels, afterglows and the glide's ends start in silence.
        for plane in [0, 1, 4 + Self.bandCount, 5 + Self.bandCount] { (store + plane * Self.size).update(repeating: -200, count: Self.size) }
        meter = device?.makeBuffer(length: 2 * MemoryLayout<Float>.stride, options: .storageModeShared)
        meter?.contents().initializeMemory(as: Float.self, repeating: 0, count: 2)
        guard let device else { textures = []; bandTextures = []; grainTexture = nil; return }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba16Unorm
        descriptor.width = SpatialBody.azimuthSteps
        descriptor.height = SpatialBody.rows
        descriptor.arrayLength = SpatialBody.maxLayers
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        // Two slices per layer: bands 0–3, then band 4 and the largest band radius.
        descriptor.arrayLength = 2 * SpatialBody.maxLayers
        bandTextures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        grainTexture = Self.makeGrain(device: device)
    }

    deinit { store.deallocate() }

    /// 32³ texels of smoothed value noise (0…1, mean ½), tiling, made once.
    private static func makeGrain(device: MTLDevice) -> MTLTexture? {
        let n = 32
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // White noise, then one pass of a 3×3×3 box over the tile so the grain is soft, not texel-sharp.
        var state: UInt32 = 0x9E37_79B9
        var raw = [Float](repeating: 0, count: n * n * n)
        for i in raw.indices {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            raw[i] = Float(state & 0xFFFF) / 65_535
        }
        var smooth = [Float](repeating: 0, count: n * n * n)
        var low: Float = 1, high: Float = 0
        for z in 0..<n { for y in 0..<n { for x in 0..<n {
            var sum: Float = 0
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                sum += raw[((z + dz + n) % n) * n * n + ((y + dy + n) % n) * n + (x + dx + n) % n]
            }}}
            let v = sum / 27
            smooth[z * n * n + y * n + x] = v
            low = min(low, v); high = max(high, v)
        }}}
        let bytes = smooth.map { UInt8(max(0, min(255, ($0 - low) / max(1e-6, high - low) * 255))) }
        texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: bytes,
                        bytesPerRow: n, bytesPerImage: n * n)
        return texture
    }

    var layerCount: Int { body.layerCount }
    var lobeCount: Int { body.lobes.prefix(body.layerCount).reduce(0) { $0 + $1.count } }
    /// With diagnostics on: seconds spent since last read building the body from the field (`SpatialBody.evaluate`),
    /// easing it and uploading it.
    private var times: (field: CFTimeInterval, ease: CFTimeInterval, upload: CFTimeInterval) = (0, 0, 0)
    func takeTimes() -> (field: CFTimeInterval, ease: CFTimeInterval, upload: CFTimeInterval) {
        defer { times = (0, 0, 0) }
        return times
    }

    /// The layers of a band choice: per group, the run of field bands inside the panel's frequency range and, for a
    /// source without a field, the analysis bands that reach into it.
    private func layers(_ choice: BandChoice, _ n: NebulaSettings) -> [SpatialBody.Layer] {
        choice.groups.map { group in
            let members = choice.resolution.groups[max(0, min(choice.resolution.count - 1, group))]
            var first = -1, last = -1
            for band in 0..<SpatialField.bandCount where members.contains(fiveBands[band])
                && centres[band] >= n.lowest * 0.999 && centres[band] <= n.highest * 1.001 {
                if first < 0 { first = band }
                last = band
            }
            let reaching = members.filter { five in
                let low = StereoBands.edges[five], high = five + 1 < StereoBands.count ? StereoBands.edges[five + 1] : 20_000
                return high > n.lowest && low < n.highest
            }
            return SpatialBody.Layer(bands: first >= 0 ? first...last : nil, fiveBands: reaching)
        }
    }

    /// Builds the frame's body from its field, eases it by `dt` (0 while frozen), and uploads it for `geometry`'s camera.
    /// A band change cross-fades over `displayDt`, frozen or not.
    func update(frame: CanvasFrame, geometry g: DomeGeometry, dt: Float, displayDt: Float, options: DisplayOptions, presence: Float) {
        let n = options.nebula
        let field = frame.snapshot.spatialField
        status = field.count == SpatialField.floats ? field[SpatialField.status] : 0
        let layout = frame.layout
        let choice = options.domeBands
        spectral = n.spectral(choice)
        // A band change starts the new choice from its measured shape in the other set of textures and cross-fades the
        // old body out over it (the textures it was drawn from stay as they were).
        let switched = lastChoice != nil && lastChoice != choice
        if switched, n.style == .level, lastStyle == .level, textures.count == 2, uniforms.layers > 0 {
            leaving = (active, uniforms, colors)
            active ^= 1
            version &+= 1
            crossfade.restart()
        }
        if leaving != nil {
            crossfade.step(target: 1, dt: displayDt)
            if crossfade.value >= 0.999 { leaving = nil }
        }
        // A new geometry (the user's layout changed, or the source computes with another) starts afresh: its
        // observations are another coordinate frame, never one statistical sample with the old ones.
        let regeometry = lastGeometry != nil && lastGeometry != frame.geometry.hash
        lastGeometry = frame.geometry.hash
        // A new measurement, stream, layout or band starts from the measured shape.
        let reset = epoch != frame.epoch || stream != frame.snapshot.streamID || lastLayout != layout || lastChoice == nil || switched
            || regeometry
        style = n.style
        // A new colouring, or a return to the level body, redraws the body at rest.
        let recolored = lastSpectral != spectral || lastStyle != style
        // Radiant starts afresh when it is chosen again: its particles from before belong to another moment.
        let restyled = lastStyle != nil && lastStyle != style
        let sourceReset = epoch != frame.epoch || stream != frame.snapshot.streamID || lastLayout != layout
        if sourceReset {
            leaving = nil
            transitionTexture = nil
            pendingTransition = false
        } else if restyled || (switched && style == .radiant) || regeometry {
            // The old picture fades out over the new one: only its image is held, none of its particles.
            pendingTransition = composite != nil
        }
        if !pendingTransition, transitionTexture != nil {
            transition.step(target: 1, dt: displayDt)
            if transition.value >= 0.999 { transitionTexture = nil }
        }
        if restyled { leaving = nil }
        epoch = frame.epoch
        stream = frame.snapshot.streamID
        lastLayout = layout
        lastChoice = choice
        lastSpectral = spectral
        lastStyle = style
        self.choice = choice
        groups = choice.groups
        floor = Float(n.floor)
        var shown = [Bool](repeating: false, count: Role.count)
        for speaker in layout.speakers where frame.shown && frame.activeRoles.indices.contains(speaker.role) {
            shown[speaker.role] = frame.activeRoles[speaker.role]
        }
        if !n.lfe { shown[Role.lfe] = false }
        let settings = SpatialBody.Settings(smoothing: n.smoothing, spread: n.spread)
        let layers = layers(choice, n)
        let started = Diagnostics.enabled ? CACurrentMediaTime() : 0
        // New audio: a new field, its observations, or (from a source without a field) new band energies.
        let contentChanged = cachedField != field || cachedObservations != frame.snapshot.spatialObservations
            || cachedPower != frame.snapshot.roleBandPower
        // The analysis clock advances even for bit-identical steady signals. Redrawing a display frame does not.
        let fresh = contentChanged || cachedAnalysisSerial != frame.snapshot.spectrogramSerial
        cachedAnalysisSerial = frame.snapshot.spectrogramSerial
        cachedObservations = frame.snapshot.spatialObservations
        let changed = reset || restyled || contentChanged || cachedShown != shown || cachedLayers != layers || cachedSettings != settings
            || cachedFloor != floor
        if changed {
            // The level body reads the field only when it was computed with the geometry drawn (its observations,
            // from the same transform, carry the geometry's hash): directions only, its radius stays the level.
            let accepted = Self.accepts(frame.snapshot.spatialObservations, geometry: frame.geometry, layout: layout)
            let usable = accepted || frame.snapshot.spatialObservations.first != 1
            (usable ? field : []).withUnsafeBufferPointer { field in
                body.evaluate(field: field, roleBandPower: frame.snapshot.roleBandPower, layout: layout, geometry: frame.geometry,
                              shown: shown, layers: layers, settings: settings, floor: floor, metadataOnly: style == .radiant)
            }
            cachedField = field; cachedPower = frame.snapshot.roleBandPower; cachedShown = shown
            cachedLayers = layers; cachedSettings = settings; cachedFloor = floor
            evaluations += 1
        }
        if Diagnostics.enabled { times.field += CACurrentMediaTime() - started }
        let snapToTarget = reset || (changed && dt == 0)
        // Levels ease toward 6 dB under the floor, not toward silence, so the release reads in the range shown.
        let bottom = floor - 6
        let audible = Float(pow(10, Double(bottom) / 10))
        // The glide between targets: a new target starts from wherever the level was heading, and is reached when the
        // next one is due.
        sinceTarget += dt
        let progress: Float
        if changed {
            let reached = min(1, sinceTarget / targetInterval)
            if !snapToTarget { targetInterval = max(1.0 / 120, min(0.1, sinceTarget)) }
            if style == .level { prepareTargets(bottom: bottom, glide: snapToTarget ? 1 : reached, snap: snapToTarget) }
            sinceTarget = 0
            for layer in 0..<SpatialBody.maxLayers { settled[layer] = false }
            progress = snapToTarget ? 1 : 0
        } else {
            progress = min(1, sinceTarget / targetInterval)
        }
        if recolored {
            // A change to Frequency colours while the field holds still needs the band targets it never computed.
            if style == .level && spectral && !changed { prepareBandTargets() }
            for layer in 0..<SpatialBody.maxLayers { settled[layer] = false }
        }
        // Only the level body is eased and uploaded; Radiant's particles are made from the field itself.
        if style == .level && (changed || dt > 0 || recolored) {
            ease(dt: dt, n: n, bottom: bottom, progress: progress, snap: snapToTarget)
        }
        // The LFE, on the same scale and with the same motion.
        let attack = 1 - exp(-dt / Float(max(0.001, n.attack / 1000)))
        let release = 1 - exp(-dt / Float(max(0.001, n.release / 1000)))
        let fade: Float = n.persistence > 0 ? 30 * dt / Float(n.persistence / 1000) : 1_000
        let lfeTarget = body.lfe > audible ? max(bottom, 10 * SpatialBody.log10(body.lfe)) : bottom
        if snapToTarget {
            lfeLevel = lfeTarget; lfeGlow = lfeTarget
        } else {
            lfeLevel += (lfeTarget - lfeLevel) * (lfeTarget > lfeLevel ? attack : release)
            lfeGlow = max(lfeLevel, lfeGlow - fade)
        }
        lfeRadius = max(0, min(1, (max(lfeLevel, lfeGlow - 6) - floor) / -floor))
        for (layer, group) in groups.enumerated() where layer < SpatialBody.maxLayers {
            // The theme's colours: the bands' hues, or the accent for the full band.
            colors[layer] = Theme.bandRGB(choice.resolution, group).simd(1)
        }
        // The core's tint: toward cream on the dark well, toward ink on the light one; energy out of phase in ochre;
        // the well's own ground; the five band hues as they glow on dark (the light wash deepens them itself).
        let base = SpatialBody.maxLayers
        colors[base] = (Theme.dark ? Theme.creamRGB : Theme.inkRGB).simd(1)
        colors[base + 1] = (Theme.dark ? Theme.ochreRGB : Theme.ochreRGB.legible(on: Theme.displayRGB, ratio: 3)).simd(1)
        colors[base + 2] = Theme.displayRGB.simd(1)
        for (band, hue) in SpectralHue.bands.enumerated() { colors[base + 3 + band] = SIMD4(hue, 1) }
        // The body is drawn at its own opacity and laid in at the presence (`encode`), so it fades in and out with the dome
        // like any other picture; inside, the tone mapping would keep a faint body nearly as bright as a full one.
        entrance = presence
        uniforms = g.bodyUniforms(opacity: Float(n.opacity), layers: body.layerCount, dark: Theme.dark)
        uniforms.lower = body.firstRow < SpatialBody.floorRow ? 1 : 0
        uniforms.spectral = spectral ? 1 : 0
        uniforms.grain = n.grain ? 1 : 0
        if style == .radiant {
            updateRadiant(frame: frame, dt: dt, n: n, layers: layers, shown: shown, changed: changed, fresh: fresh,
                          reset: sourceReset || restyled || regeometry || particleKey == nil)
            return
        }
        // The shader's afterglow feather reaches at most 0.096 radii past its edge; cover it, including quantization.
        uniforms.bound = bound > 0.004 ? min(1, bound + 0.1) : 0
        let reach = uniforms.bound * uniforms.scale + 2
        uniforms.minX = max(uniforms.minX, uniforms.originX - reach)
        uniforms.maxX = min(uniforms.maxX, uniforms.originX + reach)
        uniforms.minY = max(uniforms.minY, uniforms.originY - reach)
        uniforms.maxY = min(uniforms.maxY, uniforms.originY + reach)
    }

    /// Whether `observations` (`SpatialObservations`) were computed with `geometry`: the analysis' own (its hash), or a
    /// Bridge plugin before build 98's bins of the standard layout while the standard layout is drawn. A frame without
    /// observations (status 0) is neither.
    static func accepts(_ observations: [Float], geometry: SpatialGeometry, layout: SpeakerLayout) -> Bool {
        guard observations.count >= SpatialObservations.first, observations[SpatialObservations.Header.status] == 1 else { return false }
        switch SpatialObservations.Source(rawValue: observations[SpatialObservations.Header.source]) {
        case .measured?:
            let hash = observations.withUnsafeBufferPointer { SpatialObservations.hash($0.baseAddress!) }
            return hash == geometry.hash && observations[SpatialObservations.Header.mapping] == Float(geometry.mapping.rawValue)
        case .legacy?:
            return geometry.isStandard(roles: layout.roles)
        default:
            return false
        }
    }

    /// Radiant: a new frame of particles from each new set of observations, the loudest band followed, old frames
    /// forgotten, and the camera and composite for this frame. Each frame is born at its audio's time (the newest
    /// window's end, its zones by their windows' centres), so a burst of results is spread as the audio was, not as it
    /// arrived. A change to how they are drawn remakes the picture from the frames heard; a source without
    /// observations (or with nothing heard yet while frozen) shows, after a reset or a change while frozen, the
    /// picture a steady field leaves after the persistence time. Observations of another geometry are never drawn.
    private func updateRadiant(frame: CanvasFrame, dt: Float, n: NebulaSettings, layers: [SpatialBody.Layer], shown: [Bool],
                               changed: Bool, fresh: Bool, reset: Bool) {
        raw = n.rawPoints
        // The bare observations: the newest frame only (one analysis interval), held while frozen.
        let lifetime = raw ? 1.5 / 30 : max(0.06, Float(n.persistence / 1000))
        clock += dt
        if reset {
            particles.clear()
            peak = -200
            audioAnchor = nil
            lastAudioTime = nil
            lastObserved = nil
            // The exposure meter starts again from what it next measures.
            meter?.contents().initializeMemory(as: Float.self, repeating: 0, count: 2)
            meterClock = clock
        }
        let geometry = frame.geometry
        if particleLayout?.layout != frame.layout || particleLayout?.hash != geometry.hash {
            particleLayout = (frame.layout, geometry.hash)
            particleSpeakers = frame.layout.speakers.compactMap { speaker in
                guard speaker.group != .lfe, let d = geometry.direction(role: speaker.role) else { return nil }
                return (speaker.role, speaker.name, SIMD3(Float(d.x), Float(d.y), Float(d.z)))
            }
            particlePositions = frame.layout.speakers.compactMap { speaker in
                guard speaker.group != .lfe, let p = geometry.position(role: speaker.role) else { return nil }
                return (speaker.role, speaker.name, SIMD3(Float(p.x), Float(p.y), Float(p.z)))
            }
        }
        let toModel = Float(1 / geometry.extent(roles: frame.layout.roles))
        observationScale = toModel
        observationsInMeters = geometry.mapping == .positions
        let layerColors = (0..<layers.count).map { SIMD3(colors[$0].x, colors[$0].y, colors[$0].z) }
        let key = ParticleKey(perBand: Int(n.particles), raw: raw, spread: Float(n.spread), spectral: spectral, layers: layers,
                              colors: layerColors, floor: floor, range: Float(n.range))
        let selectionChanged = particleKey?.layers != key.layers
        let remade = particleKey != key
        particleKey = key
        let snapshot = frame.snapshot
        let observations = snapshot.spatialObservations
        // Each zone's delay before the newest: its window's centre against the shortest zone's.
        var delays: [Float] = [0]
        if observations.count >= SpatialObservations.first, observations[SpatialObservations.Header.status] == 1 {
            let zones = max(1, min(4, Int(observations[SpatialObservations.Header.zones])))
            let rate = max(1, observations[SpatialObservations.Header.sampleRate])
            let windows = observations.withUnsafeBufferPointer { v in (0..<zones).map { SpatialObservations.window(v.baseAddress!, zone: $0) } }
            let shortest = windows.min() ?? 0
            delays = windows.map { max(0, ($0 - shortest) / 2 / rate) }
        }
        func input(_ field: UnsafeBufferPointer<Float>, _ observations: UnsafeBufferPointer<Float>, _ power: [Float]) -> RadiantParticles.Input {
            RadiantParticles.Input(field: field, observations: observations, roleBandPower: power, speakers: particleSpeakers,
                                   positions: particlePositions, toModel: toModel, zoneDelays: delays, raw: raw,
                                   lower: geometry.reachesBelow(roles: frame.layout.roles), shown: shown,
                                   layers: layers, spectral: spectral, layerColors: layerColors, perBand: Int(n.particles),
                                   spread: Float(n.spread), floor: floor, range: Float(n.range))
        }
        let hasObservations = snapshot.spatialField.first == 1 && observations.first == 1
        let accepted = hasObservations && Self.accepts(observations, geometry: geometry, layout: frame.layout)
        // A new frame of observations: another serial or window end than the newest taken (the analysis' own clock).
        let identity = hasObservations ? observations.withUnsafeBufferPointer {
            (serial: $0[SpatialObservations.Header.serial], end: SpatialObservations.windowEnd($0.baseAddress!)) } : nil
        var newFrame = false
        if let identity {
            newFrame = lastObserved.map { last in last.serial != identity.serial || last.end != identity.end } ?? true
        }
        let freshFrame = hasObservations ? newFrame : fresh
        waitingForGeometry = hasObservations && !accepted
        if waitingForGeometry && freshFrame && dt > 0 {
            refusedFrames += 1
            lastObserved = identity
        }
        if reset || !hasObservations { heard.removeAll(keepingCapacity: true) }
        if hasObservations {
            // The audio time of the newest window's end, and the scene time it maps to.
            let audioTime = observations.withUnsafeBufferPointer { v -> Double? in
                let rate = Double(v[SpatialObservations.Header.sampleRate])
                return rate > 0 ? Double(SpatialObservations.windowEnd(v.baseAddress!)) / rate : nil
            }
            func birth() -> Float {
                guard let audioTime else { return clock }
                // Anchored to the first frame heard; again after a jump of more than a quarter second either way.
                if let anchor = audioAnchor, let last = lastAudioTime, audioTime >= last, abs(audioTime + anchor - Double(clock)) < 0.25 {
                    lastAudioTime = audioTime
                    return min(clock, Float(audioTime + anchor))
                }
                audioAnchor = Double(clock) - audioTime
                lastAudioTime = audioTime
                return clock
            }
            if accepted {
                // The observations: each new frame added as it is heard; the picture remade from the frames heard
                // when how they are drawn changes.
                if freshFrame || reset || remade || changed {
                    snapshot.spatialField.withUnsafeBufferPointer { field in
                        observations.withUnsafeBufferPointer { points in
                            newest = particles.loudestBand(input(field, points, snapshot.roleBandPower))
                        }
                    }
                    if selectionChanged || newest > peak { peak = newest }
                }
                let rebuild = reset || remade || (changed && !freshFrame)
                // After a reset the newest frame is the first heard of what comes next.
                if (freshFrame || reset) && dt > 0 {
                    serial &+= 1
                    lastObserved = identity
                    let born = birth()
                    heard.append(Heard(birth: born, serial: serial, field: snapshot.spatialField, observations: observations,
                                       power: snapshot.roleBandPower))
                    if !rebuild {
                        snapshot.spatialField.withUnsafeBufferPointer { field in
                            observations.withUnsafeBufferPointer { points in
                                particles.add(input(field, points, snapshot.roleBandPower), birth: born, serial: serial, peak: peak)
                            }
                        }
                    }
                }
                heard.removeAll { clock - $0.birth > lifetime }
                if rebuild || (particles.frames.isEmpty && dt == 0 && changed) {
                    particles.clear()
                    if heard.isEmpty {
                        // Frozen with nothing heard since the reset: show only the available measurement.
                        snapshot.spatialField.withUnsafeBufferPointer { field in
                            observations.withUnsafeBufferPointer { points in
                                serial &+= 1
                                particles.add(input(field, points, snapshot.roleBandPower), birth: clock, serial: serial, peak: peak)
                            }
                        }
                    } else {
                        for h in heard {
                            h.field.withUnsafeBufferPointer { field in
                                h.observations.withUnsafeBufferPointer { points in
                                    particles.add(input(field, points, h.power), birth: h.birth, serial: h.serial, peak: peak)
                                }
                            }
                        }
                    }
                }
            } else if freshFrame || reset {
                // Computed with another geometry: nothing of it is drawn (the old particles have been cleared by the
                // geometry's change; the analysis' next frames will carry the new hash).
                heard.removeAll(keepingCapacity: true)
            }
        } else if fresh || changed || remade || particles.frames.isEmpty {
            frame.snapshot.spatialField.withUnsafeBufferPointer { field in
                let input = input(field, UnsafeBufferPointer(start: nil, count: 0), frame.snapshot.roleBandPower)
                newest = particles.loudestBand(input)
                if newest > peak { peak = newest }
                if dt > 0 && !reset && !particles.frames.isEmpty {
                    serial &+= 1
                    particles.add(input, birth: clock, serial: serial, peak: peak)
                } else {
                    particles.clear()
                    let count = max(1, min(30, Int((lifetime * 30).rounded())))
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        serial &+= 1
                        particles.add(input, birth: clock - Float(i) / 30, serial: serial, peak: peak)
                    }
                }
            }
        }
        // The range falls back slowly toward the newest frame's loudest band, so the glow does not pump.
        if dt > 0, newest < peak { peak += (max(newest, floor) - peak) * (1 - exp(-dt / Radiant.peakRelease)) }
        particles.prune(clock: clock, lifetime: lifetime)
        let ochre = colors[SpatialBody.maxLayers + 1]
        // The bare observations: every particle the same small size, no smear, glint, depth shading or glow.
        let size = raw ? Radiant.size : Radiant.size * Float(n.particleSize)
        camera = RadiantCamera(originX: uniforms.originX, originY: uniforms.originY, scale: uniforms.scale,
                               sinElevation: uniforms.sinElevation, cosElevation: uniforms.cosElevation,
                               sinYaw: uniforms.sinYaw, cosYaw: uniforms.cosYaw, viewportX: uniforms.viewportX,
                               viewportY: uniforms.viewportY, pixels: camera.pixels, clock: clock, fade: raw ? 1_000 : lifetime / 3,
                               lifetime: lifetime, size: size, blur: raw ? 0 : Radiant.blur * Float(n.blur),
                               minimum: Radiant.minimumPixels, depthFade: raw ? 0 : Radiant.depthFade, ochreR: ochre.x, ochreG: ochre.y,
                               ochreB: ochre.z, pass: 0, sparkSize: Radiant.sparkSize * Float(n.particleSize),
                               sparkFade: Radiant.sparkFade, sparkGain: raw ? 0 : Radiant.sparkGain * Float(n.sparkle))
        let core = colors[SpatialBody.maxLayers]
        look = raw ? RadiantLook(sparkle: 0, glowNear: 0, glowFar: 0, chroma: 1, hotFrom: 1_000, hotTo: 2_000, limit: 1e9, ease: 0,
                                 palette: 0)
            : RadiantLook(sparkle: n.sparkle > 0 ? 1 : 0, glowNear: Radiant.glowNear, glowFar: Radiant.glowFar,
                          chroma: Radiant.paletteChroma, hotFrom: Radiant.hotFrom, hotTo: Radiant.hotTo,
                          limit: Radiant.denseLimit, ease: Radiant.denseEase, blend: Radiant.blend,
                          grain: n.grain ? Radiant.grain : 0, coreR: core.x, coreG: core.y, coreB: core.z, palette: 1)
        if !raw {
            // Its point lights: the particles as Radiant draws them, over the whole canvas (they smear wherever they
            // have been), with less glow than Radiant's own.
            pointUniforms = uniforms
            pointUniforms.style = 1
            pointUniforms.gain = uniforms.opacity * Radiant.exposure * Radiant.presence(peak: peak, floor: floor) * Radiant.burn
                * RadiantBody.pointExposure * Float(n.points)
            pointUniforms.spare = Radiant.bloom
            pointUniforms.bound = particles.liveCount > 0 && n.points > 0 ? 1 : 0
            pointUniforms.minX = 0; pointUniforms.minY = 0
            pointUniforms.maxX = uniforms.viewportX; pointUniforms.maxY = uniforms.viewportY
            pointLook = look
            pointLook.glowNear = RadiantBody.pointGlowNear
            pointLook.glowFar = RadiantBody.pointGlowFar
            // The Radiant body: the particles gathered into the volumes and marched as the level body's gas, in the
            // body's quad around the dome. How loud the loudest band is sets how dense the whole body is.
            let born = RadiantBody.size * Float(n.particleSize)
            let rate = RadiantBody.blur * Float(n.blur)
            bodySplat = VolumeSplat(clock: clock, lifetime: lifetime, fade: lifetime / 3, bornVariance: born * born, blurRate: rate,
                                    coarseVariance: born * born + max(rate * lifetime, 1e-4), ochreR: ochre.x, ochreG: ochre.y,
                                    ochreB: ochre.z, reach: RadiantBody.reach, fixedScale: RadiantBody.fixedScale,
                                    least: RadiantBody.least, fineSize: UInt32(RadiantBody.fineSize),
                                    coarseSize: UInt32(RadiantBody.coarseSize))
            bodyLook = RadiantBodyLook(reach: RadiantBody.reach,
                                       density: RadiantBody.density * Radiant.presence(peak: peak, floor: floor),
                                       edgeFrom: RadiantBody.edgeFrom, edgeTo: RadiantBody.edgeTo, base: RadiantBody.base,
                                       absorb: RadiantBody.absorb, chroma: RadiantBody.chroma, shellFrom: RadiantBody.shellFrom,
                                       wash: RadiantBody.wash,
                                       glow: 1 + (RadiantBody.underPoints - 1) * Float(min(1, max(0, n.points))))
            uniforms.style = 2
            uniforms.lower = geometry.reachesBelow(roles: frame.layout.roles) ? 1 : 0
            uniforms.bound = particles.liveCount > 0 && bodyLook.density > 0 ? RadiantBody.shell : 0
            let reach = uniforms.bound * uniforms.scale + 2
            uniforms.minX = max(0, uniforms.originX - reach); uniforms.maxX = min(uniforms.viewportX, uniforms.originX + reach)
            uniforms.minY = max(0, uniforms.originY - reach); uniforms.maxY = min(uniforms.viewportY, uniforms.originY + reach)
            return
        }
        // The composite covers the canvas: particles smear wherever they have been.
        uniforms.style = 1
        uniforms.gain = uniforms.opacity * Radiant.exposure * Radiant.presence(peak: peak, floor: floor) * (raw ? 1 : Radiant.burn)
        uniforms.spare = raw ? 0 : Radiant.bloom
        uniforms.bound = particles.liveCount > 0 ? 1 : 0
        uniforms.minX = 0; uniforms.minY = 0
        uniforms.maxX = uniforms.viewportX; uniforms.maxY = uniforms.viewportY
    }

    /// A new target from `body`: each direction's level (dB, at least `bottom`), share out of phase and band radii;
    /// the glide restarts from where it had got to (`glide` of the way from the old start to the old target).
    private func prepareTargets(bottom: Float, glide: Float, snap: Bool) {
        let count = SpatialBody.count, samples = vDSP_Length(count)
        let layers = body.layerCount
        let from = self.from, to = self.to, share = targetShare
        var tiny: Float = 1e-30, ten: Float = 10, low = bottom, zero: Float = 0, one: Float = 1
        var length = Int32(count)
        body.energy.withUnsafeBufferPointer { energy in
        body.unstable.withUnsafeBufferPointer { unstable in
            for layer in 0..<layers {
                let base = layer * count
                let e = energy.baseAddress! + base, f = from + base, t = to + base, s = share + base
                // The glide's new start: where the level was heading (from + (to − from)·glide).
                if !snap {
                    var amount = glide
                    vDSP_vsub(f, 1, t, 1, s, 1, samples)           // s = to − from (scratch)
                    vDSP_vsma(s, 1, &amount, f, 1, f, 1, samples)  // from += (to − from)·glide
                }
                // Every direction's target, max(bottom, 10 log₁₀ e), and its share out of phase, all at once.
                vDSP_vthr(e, 1, &tiny, t, 1, samples)
                vDSP_vdiv(t, 1, unstable.baseAddress! + base, 1, s, 1, samples)
                vDSP_vclip(s, 1, &zero, &one, s, 1, samples)
                vvlog10f(t, t, &length)
                vDSP_vsmul(t, 1, &ten, t, 1, samples)
                vDSP_vthr(t, 1, &low, t, 1, samples)
                if snap { f.update(from: t, count: count) }
            }
        }}
        if spectral { prepareBandTargets() }
    }

    /// Coloured by frequency: each direction's band radii on the body's scale, (10 log₁₀ e_b − floor) / −floor.
    private func prepareBandTargets() {
        let count = SpatialBody.count, samples = vDSP_Length(count), stride = SpatialBody.planeStride
        let bandTargets = targetBands
        var tiny: Float = 1e-30, ten: Float = 10, zero: Float = 0, one: Float = 1
        var length = Int32(count)
        var offset = -floor, toRadius = 1 / -floor
        body.bands.withUnsafeBufferPointer { bands in
            for layer in 0..<body.layerCount {
                let base = layer * count
                for band in 0..<Self.bandCount {
                    let out = bandTargets + band * stride + base
                    vDSP_vthr(bands.baseAddress! + band * stride + base, 1, &tiny, out, 1, samples)
                    vvlog10f(out, out, &length)
                    vDSP_vsmul(out, 1, &ten, out, 1, samples)
                    vDSP_vsadd(out, 1, &offset, out, 1, samples)
                    vDSP_vsmul(out, 1, &toRadius, out, 1, samples)
                    vDSP_vclip(out, 1, &zero, &one, out, 1, samples)
                }
            }
        }
    }

    /// Eases every layer that is not at rest by `dt` toward its gliding target (`progress` of the way from its start),
    /// and uploads it. Eight directions at a time.
    private func ease(dt: Float, n: NebulaSettings, bottom: Float, progress: Float, snap: Bool) {
        let attack = SIMD8<Float>(repeating: 1 - exp(-dt / Float(max(0.001, n.attack / 1000))))
        let release = SIMD8<Float>(repeating: 1 - exp(-dt / Float(max(0.001, n.release / 1000))))
        // The afterglow falls 30 dB per persistence time, linearly in dB, after the level has released.
        let fade = SIMD8<Float>(repeating: n.persistence > 0 ? 30 * dt / Float(n.persistence / 1000) : 1_000)
        let follow = SIMD8<Float>(repeating: 1 - exp(-dt / 0.08)), dim = SIMD8<Float>(repeating: 1 - exp(-dt / 1.0))
        let floorV = SIMD8<Float>(repeating: bottom), lowest = SIMD8<Float>(repeating: floor)
        let toRadius = SIMD8<Float>(repeating: 1 / -floor), six = SIMD8<Float>(repeating: 6)
        let zero = SIMD8<Float>(repeating: 0), one = SIMD8<Float>(repeating: 1), scale = SIMD8<Float>(repeating: 65_535)
        let glide = SIMD8<Float>(repeating: progress), hundred = SIMD8<Float>(repeating: 100)
        let count = SpatialBody.count, columns = SpatialBody.azimuthSteps, stride = SpatialBody.planeStride
        let samples = vDSP_Length(count), spectral = self.spectral, bandCount = Self.bandCount
        @inline(__always) func load(_ p: UnsafeMutablePointer<Float>, _ i: Int) -> SIMD8<Float> {
            UnsafeRawPointer(p + i).loadUnaligned(as: SIMD8<Float>.self)
        }
        @inline(__always) func store(_ v: SIMD8<Float>, _ p: UnsafeMutablePointer<Float>, _ i: Int) {
            UnsafeMutableRawPointer(p + i).storeBytes(of: v, as: SIMD8<Float>.self)
        }
        // The simd module's functions, not the standard library's generic SIMD ones, which run lane by lane.
        @inline(__always) func peak(_ v: SIMD8<Float>) -> SIMD8<Float> { simd_abs(v) }
        let floorShare = SpatialBody.floorShare
        // Rows below the body's first (the lower hemisphere, while no speaker of the layout is there) hold nothing:
        // cleared once when they leave use, then never eased or written again.
        let firstIndex = body.firstRow * columns
        if firstIndex != easedFrom {
            if firstIndex > easedFrom {
                let all = self.store
                for plane in 0..<Self.planeCount { (all + plane * Self.size).update(repeating: 0, count: Self.size) }
                for plane in [0, 1, 4 + Self.bandCount, 5 + Self.bandCount] { (all + plane * Self.size).update(repeating: -200, count: Self.size) }
                planes.update(repeating: 0, count: Self.uploadPlanes * count)
            }
            easedFrom = firstIndex
        }
        for layer in 0..<body.layerCount where !settled[layer] {
            let base = layer * count
            let easing = Diagnostics.enabled ? CACurrentMediaTime() : 0
            var moved: Float = 0
            var top: Float = 0
            let levels = level + base, glows = glow + base, phases = phase + base, weights = weight + base
            let starts = from + base, goals = to + base, shares = targetShare + base, radii = self.radii + base
            let shown = bands + base, targets = targetBands + base
            let r16 = planes, phase16 = r16 + count, weight16 = phase16 + count, live16 = weight16 + count
            let band16 = live16 + count, widest16 = band16 + bandCount * count
            let reach = reachScratch
            for a in 0..<columns { reachIndex[a] = -1 }
            reach.update(repeating: 0, count: columns)
            var i = firstIndex
            while i < count {
                let start = load(starts, i)
                let goal = start + (load(goals, i) - start) * glide
                let lit = goal .> floorV
                var now = load(levels, i), afterglow = load(glows, i)
                var held = load(phases, i), lately = load(weights, i)
                let before = now, beforeGlow = afterglow, beforeLately = lately
                if snap {
                    now = goal
                    afterglow = goal
                    held = zero.replacing(with: load(shares, i), where: lit)
                    lately = zero.replacing(with: one, where: lit)
                } else {
                    let difference = goal - now
                    now += difference * release.replacing(with: attack, where: difference .> zero)
                    afterglow = simd_max(now, afterglow - fade)
                    held = held.replacing(with: held + (load(shares, i) - held) * follow, where: lit)
                    lately = (lately - lately * dim).replacing(with: lately + (one - lately) * follow, where: lit)
                }
                store(now, levels, i); store(afterglow, glows, i)
                store(held, phases, i); store(lately, weights, i)
                var drift = simd_max(peak(now - before), peak(afterglow - beforeGlow))
                drift = simd_max(drift, peak(lately - beforeLately) * hundred)
                let r = simd_clamp((simd_max(now, afterglow - six) - lowest) * toRadius, zero, one)
                store(r, radii, i)
                top = max(top, simd_reduce_max(r))
                let w = simd_clamp(lately, zero, one)
                store(r * scale, r16, i)
                store(simd_clamp(held, zero, one) * w * scale, phase16, i)
                store(w * scale, weight16, i)
                store(simd_clamp((now - lowest) * toRadius, zero, one) * scale, live16, i)
                if spectral {
                    // Each band's radius follows its target while the direction is heard and holds while it is not.
                    var widest = zero
                    for band in 0..<bandCount {
                        let plane = shown + band * stride, target = targets + band * stride
                        var value = load(plane, i)
                        let goal = load(target, i)
                        let updated = snap ? goal : value.replacing(with: value + (goal - value) * follow, where: lit)
                        drift = simd_max(drift, peak(updated - value) * hundred)
                        value = updated
                        store(value, plane, i)
                        store(value * scale, band16 + band * count, i)
                        widest = simd_max(widest, value)
                    }
                    store(widest * scale, widest16, i)
                }
                moved = max(moved, simd_reduce_max(drift))
                // The footprint: the furthest reach over the floor in each of these eight azimuths, any height.
                let row = i / columns, column = i - row * columns
                let over = r * SIMD8<Float>(repeating: floorShare[row])
                let ahead = UnsafeMutableRawPointer(reach + column).loadUnaligned(as: SIMD8<Float>.self)
                let further = over .> ahead
                if any(further) {
                    UnsafeMutableRawPointer(reach + column).storeBytes(of: simd_max(over, ahead), as: SIMD8<Float>.self)
                    for k in 0..<8 where further[k] { reachIndex[column + k] = i + k }
                }
                i += 8
            }
            for a in 0..<columns {
                footprint[layer * columns + a] = reach[a]
                if spectral, reachIndex[a] >= 0 { footprintTint[layer * columns + a] = edgeColor(layer: layer, index: reachIndex[a]) }
            }
            // Interleaved for the textures: radius, weighted phase, phase weight and live radius; bands 0–3, then band 4
            // and the largest band radius.
            upload.withUnsafeMutableBufferPointer { texels in
                let t = texels.baseAddress!
                vDSP_vfixu16(r16, 1, t, 4, samples)
                vDSP_vfixu16(phase16, 1, t + 1, 4, samples)
                vDSP_vfixu16(weight16, 1, t + 2, 4, samples)
                vDSP_vfixu16(live16, 1, t + 3, 4, samples)
            }
            if spectral {
                bandUpload.withUnsafeMutableBufferPointer { texels in
                    let t = texels.baseAddress!, second = t + 4 * count
                    for band in 0..<4 { vDSP_vfixu16(band16 + band * count, 1, t + band, 4, samples) }
                    vDSP_vfixu16(band16 + 4 * count, 1, second, 4, samples)
                    vDSP_vfixu16(widest16, 1, second + 1, 4, samples)
                }
            }
            layerBound[layer] = top
            // At rest once nothing moves by a thousandth of a dB (or the weights by a hundred-thousandth) and the glide
            // has arrived: the textures already hold this picture.
            if progress >= 1 && moved < 0.001 { settled[layer] = true }
            easedFrames += 1
            let uploading = Diagnostics.enabled ? CACurrentMediaTime() : 0
            let region = MTLRegionMake2D(0, 0, SpatialBody.azimuthSteps, SpatialBody.rows)
            let row = SpatialBody.azimuthSteps * 4 * MemoryLayout<UInt16>.stride, image = count * 4 * MemoryLayout<UInt16>.stride
            version &+= 1
            texture?.replace(region: region, mipmapLevel: 0, slice: layer, withBytes: upload, bytesPerRow: row, bytesPerImage: image)
            if spectral {
                bandUpload.withUnsafeBytes { bytes in
                    let start = bytes.baseAddress!
                    bandTexture?.replace(region: region, mipmapLevel: 0, slice: 2 * layer, withBytes: start, bytesPerRow: row,
                                         bytesPerImage: image)
                    bandTexture?.replace(region: region, mipmapLevel: 0, slice: 2 * layer + 1, withBytes: start + image,
                                         bytesPerRow: row, bytesPerImage: image)
                }
            }
            if Diagnostics.enabled {
                let now = CACurrentMediaTime()
                times.ease += uploading - easing
                times.upload += now - uploading
            }
        }
        bound = layerBound.prefix(body.layerCount).max() ?? 0
    }

    /// The colour by frequency at `share` (0 at the listener, 1 at the live edge) of grid direction `index` of `layer`,
    /// as `bodyFragment` mixes it: the hues of the bands that reach at least that far, weighted by how far they reach.
    private func spectralColor(layer: Int, index: Int, share: Float) -> SIMD3<Float> {
        let stride = SpatialBody.planeStride, i = layer * SpatialBody.count + index
        var widest: Float = 0
        for band in 0..<Self.bandCount { widest = max(widest, bands[band * stride + i]) }
        guard widest > 0.002 else { return SIMD3(repeating: 0.85) }
        var sum = SIMD3<Float>.zero, total: Float = 0
        for band in 0..<Self.bandCount {
            let r = bands[band * stride + i]
            let x = (r / widest - (share - 0.2)) / 0.24
            let reach = max(0, min(1, x * x * (3 - 2 * x)))
            let w = reach * (0.1 + r) * (x > 0 ? 1 : 0)
            sum += SpectralHue.bands[band] * w
            total += w
        }
        return total > 0 ? sum / total : SIMD3(repeating: 0.85)
    }

    /// The colour near the body's edge in a direction: the loudest bands' hues.
    private func edgeColor(layer: Int, index: Int) -> SIMD3<Float> { spectralColor(layer: layer, index: index, share: 0.95) }

    /// The body at half the canvas' resolution, in a texture of its own: a soft volume loses nothing to it, and the
    /// ray-march costs a quarter. During a band change, the old body fading out first and the new one fading in. When
    /// nothing it shows has changed (paused, or come to rest) the texture is kept and not drawn again.
    func encodeOffscreen(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {
        if transitionTexture != nil && (transitionQuad.viewportX != uniforms.viewportX || transitionQuad.viewportY != uniforms.viewportY) {
            transitionTexture = nil
        }
        if pendingTransition {
            pendingTransition = false
            captureTransition(command, gpu: gpu, pixels: pixels)
        }
        if style == .radiant { encodeRadiant(command, gpu: gpu, pixels: pixels); return }
        guard let grainTexture, textures.count == 2, bandTextures.count == 2 else { composite = nil; return }
        let p = max(0, crossfade.value)
        var passes: [(state: BodyUniforms, colors: [SIMD4<Float>], set: Int)] = []
        if let leaving {
            var old = leaving.uniforms
            // The leaving body follows the camera: only its picture, not where it is seen from, is held.
            old.viewportX = uniforms.viewportX; old.viewportY = uniforms.viewportY
            old.originX = uniforms.originX; old.originY = uniforms.originY; old.scale = uniforms.scale
            old.sinElevation = uniforms.sinElevation; old.cosElevation = uniforms.cosElevation
            old.sinYaw = uniforms.sinYaw; old.cosYaw = uniforms.cosYaw
            let reach = old.bound * uniforms.scale + 2
            old.minX = max(0, uniforms.originX - reach); old.maxX = min(uniforms.viewportX, uniforms.originX + reach)
            old.minY = max(0, uniforms.originY - reach); old.maxY = min(uniforms.viewportY, uniforms.originY + reach)
            old.opacity *= (1 - p) * (1 - p)
            passes.append((old, leaving.colors, leaving.set))
        }
        var state = uniforms
        if leaving != nil { state.opacity *= p * p }
        passes.append((state, colors, active))
        passes = passes.filter { $0.state.style < 0.5 && $0.state.bound > 0 && $0.state.layers > 0 && $0.state.opacity > 0.002
            && $0.state.maxX > $0.state.minX && $0.state.maxY > $0.state.minY }
        guard !passes.isEmpty else { composite = nil; return }
        var quad = passes[0].state
        for pass in passes.dropFirst() {
            quad.minX = min(quad.minX, pass.state.minX); quad.maxX = max(quad.maxX, pass.state.maxX)
            quad.minY = min(quad.minY, pass.state.minY); quad.maxY = max(quad.maxY, pass.state.maxY)
        }
        guard let offscreen = target(gpu: gpu, pixels: pixels) else { composite = nil; return }
        composite = quad
        let key = RenderKey(passes: passes.map { RenderKey.Pass(state: $0.state, colors: $0.colors, set: $0.set) }, version: version)
        guard key != renderedKey else { return }
        renderedKey = key
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = offscreen
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { composite = nil; return }
        for body in passes {
            encoder.setRenderPipelineState(gpu.bodyOffscreen)
            var state = body.state
            encoder.setVertexBytes(&state, length: MemoryLayout<BodyUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&state, length: MemoryLayout<BodyUniforms>.stride, index: 0)
            encoder.setFragmentBytes(body.colors, length: body.colors.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentTexture(textures[body.set], index: 0)
            encoder.setFragmentTexture(bandTextures[body.set], index: 1)
            encoder.setFragmentTexture(grainTexture, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
    }

    /// The half-resolution texture both styles draw into, made again when the canvas' size changes.
    private func target(gpu: MeterGPU, pixels: CGSize) -> MTLTexture? {
        let width = max(1, Int((pixels.width / 2).rounded(.up))), height = max(1, Int((pixels.height / 2).rounded(.up)))
        if offscreen?.width != width || offscreen?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            offscreen = gpu.device.makeTexture(descriptor: descriptor)
            renderedKey = nil
        }
        return offscreen
    }

    /// Radiant's particles added into the half-resolution texture (their haze) and a full-resolution one (their sparks),
    /// every frame they age (kept while frozen and the camera holds still), and the haze's glow.
    private func encodeRadiant(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {
        if uniforms.style > 1.5 { encodeRadiantBody(command, gpu: gpu, pixels: pixels); return }
        guard uniforms.bound > 0, uniforms.gain > 0.0001, let offscreen = target(gpu: gpu, pixels: pixels),
              let sparks = sparkTarget(gpu: gpu, pixels: pixels) else {
            composite = nil
            return
        }
        var camera = self.camera
        camera.pixels = Float(offscreen.width) / max(1, camera.viewportX)
        self.camera.pixels = camera.pixels
        composite = uniforms
        compositeLook = look
        let key = RenderKey(passes: [RenderKey.Pass(state: uniforms, colors: [], set: -1)], version: particles.version, camera: camera)
        guard key != renderedKey else { return }
        renderedKey = key
        if !encodeParticles(command, gpu: gpu, haze: offscreen, sparks: sparks, camera: camera) { composite = nil }
    }

    /// Radiant's particles: their haze added into `haze` (half resolution), their sparks into `sparks` (the canvas'
    /// resolution), the haze's glow near and wide, and the exposure meter. False when a pass could not be made.
    private func encodeParticles(_ command: MTLCommandBuffer, gpu: MeterGPU, haze offscreen: MTLTexture, sparks: MTLTexture,
                                 camera: RadiantCamera) -> Bool {
        func draw(into texture: MTLTexture, _ camera: RadiantCamera, lifetime: Float) -> Bool {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            var camera = camera
            encoder.setRenderPipelineState(gpu.radiantParticles)
            encoder.setVertexBytes(&camera, length: MemoryLayout<RadiantCamera>.stride, index: 1)
            particles.encode(encoder, clock: camera.clock, lifetime: lifetime)
            encoder.endEncoding()
            return true
        }
        guard draw(into: offscreen, camera, lifetime: camera.lifetime) else { return false }
        // The sparks: only the newest frames, at the canvas' own resolution, so they stay sharp. Drawn (cleared) even at
        // Sparkle 0, so the composite never reads what the texture held before.
        var spark = camera
        spark.pass = 1
        spark.pixels = Float(sparks.width) / max(1, camera.viewportX)
        spark.minimum = Radiant.sparkMinimumPixels
        guard draw(into: sparks, spark, lifetime: camera.sparkGain > 0 ? min(camera.lifetime, 4 * camera.sparkFade) : -1) else {
            return false
        }
        // The glow: averaged down to a quarter, then blurred across and down, twice; that averaged down to half again
        // and blurred the same way for the wide glow.
        let width = max(1, offscreen.width / 4), height = max(1, offscreen.height / 4)
        let wideWidth = max(1, width / 2), wideHeight = max(1, height / 2)
        func textures(_ existing: [MTLTexture], _ width: Int, _ height: Int) -> [MTLTexture] {
            if existing.count == 2 && existing[0].width == width && existing[0].height == height { return existing }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return (0..<2).compactMap { _ in gpu.device.makeTexture(descriptor: descriptor) }
        }
        glowTextures = textures(glowTextures, width, height)
        wideTextures = textures(wideTextures, wideWidth, wideHeight)
        guard glowTextures.count == 2, wideTextures.count == 2 else { return false }
        func run(_ state: MTLRenderPipelineState, from source: MTLTexture, into destination: MTLTexture, step: SIMD2<Float>?) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(state)
            encoder.setFragmentTexture(source, index: 0)
            if var step { encoder.setFragmentBytes(&step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        func blur(_ pair: [MTLTexture]) {
            for _ in 0..<2 {
                run(gpu.bloomBlur, from: pair[0], into: pair[1], step: SIMD2(1 / Float(pair[0].width), 0))
                run(gpu.bloomBlur, from: pair[1], into: pair[0], step: SIMD2(0, 1 / Float(pair[0].height)))
            }
        }
        run(gpu.bloomDown, from: offscreen, into: glowTextures[0], step: nil)
        blur(glowTextures)
        run(gpu.bloomDown, from: glowTextures[0], into: wideTextures[0], step: nil)
        blur(wideTextures)
        // How dense the light is over a broad patch, held: the composite eases its exposure past `Radiant.denseLimit`.
        if let meter, let encoder = command.makeComputeCommandEncoder() {
            var rate = 1 - Foundation.exp(-max(0, camera.clock - meterClock) / Radiant.meterRelease)
            meterClock = camera.clock
            encoder.setComputePipelineState(gpu.radiantMeter)
            encoder.setTexture(wideTextures[0], index: 0)
            encoder.setBuffer(meter, offset: 0, index: 0)
            encoder.setBytes(&rate, length: MemoryLayout<Float>.stride, index: 1)
            encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
        }
        return true
    }

    /// The Radiant body: the live particles added into the volumes, each volume resolved and blurred, then ray-marched
    /// into the half-resolution texture as the level body is, every frame they age (kept while frozen and the camera
    /// holds still).
    private func encodeRadiantBody(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {
        guard uniforms.bound > 0, let offscreen = target(gpu: gpu, pixels: pixels), let particleBuffer = particles.buffer,
              let grainTexture, prepareVolumes(device: gpu.device), let sums = volumeSums else {
            composite = nil
            return
        }
        composite = uniforms
        // The point lights share the body's camera and clock; their haze has a half-resolution texture of its own.
        var camera = self.camera
        camera.pixels = Float(offscreen.width) / max(1, camera.viewportX)
        self.camera.pixels = camera.pixels
        let points = pointUniforms.bound > 0 && pointUniforms.gain > 0.0001 ? pointUniforms : nil
        let pointTargets = points == nil ? nil : pointsTarget(gpu: gpu, like: offscreen).flatMap { haze in
            sparkTarget(gpu: gpu, pixels: pixels).map { (haze: haze, sparks: $0) }
        }
        pointsComposite = pointTargets == nil ? nil : points
        compositeLook = pointLook
        let key = RenderKey(passes: [RenderKey.Pass(state: uniforms, colors: [colors[SpatialBody.maxLayers]], set: -2),
                                     RenderKey.Pass(state: pointsComposite ?? BodyUniforms(), colors: [], set: -3)],
                            version: particles.version, camera: pointsComposite == nil ? nil : camera, splat: bodySplat,
                            look: bodyLook, pointLook: pointsComposite == nil ? nil : pointLook)
        guard key != renderedKey else { return }
        renderedKey = key
        guard let blit = command.makeBlitCommandEncoder() else { composite = nil; return }
        blit.fill(buffer: sums, range: 0..<sums.length, value: 0)
        blit.endEncoding()
        guard let compute = command.makeComputeCommandEncoder() else { composite = nil; return }
        let fineCount = RadiantBody.fineSize * RadiantBody.fineSize * RadiantBody.fineSize
        compute.setComputePipelineState(gpu.radiantSplat)
        compute.setBuffer(particleBuffer, offset: 0, index: 0)
        compute.setBuffer(sums, offset: 0, index: 2)
        compute.setBuffer(sums, offset: fineCount * 4 * MemoryLayout<UInt32>.stride, index: 3)
        let width = min(256, gpu.radiantSplat.maxTotalThreadsPerThreadgroup)
        for segment in particles.segments(clock: bodySplat.clock, lifetime: bodySplat.lifetime) {
            var splat = bodySplat
            splat.first = UInt32(segment.start)
            splat.count = UInt32(segment.count)
            compute.setBytes(&splat, length: MemoryLayout<VolumeSplat>.stride, index: 1)
            compute.dispatchThreads(MTLSize(width: segment.count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        // Each grid: resolved and blurred along x into its volume, along y into the scratch, along z back into the volume.
        let grids: [(textures: [MTLTexture], size: Int, offset: Int, sigma: Float)] = [
            (fineVolume, RadiantBody.fineSize, 0, bodySplat.bornVariance.squareRoot()),
            (coarseVolume, RadiantBody.coarseSize, fineCount * 4 * MemoryLayout<UInt32>.stride, bodySplat.coarseVariance.squareRoot())
        ]
        for grid in grids {
            let voxel = 2 * RadiantBody.reach / Float(grid.size)
            // The trilinear splat and the trilinear sampling each widen a particle by about a voxel's ⅓ in variance.
            let sigma = max(0.5, (max(0, grid.sigma * grid.sigma - voxel * voxel / 3)).squareRoot() / voxel)
            // Without speakers below the ear plane only the rows from just under the floor up are worked on.
            let floorRow = Int(((RadiantBody.reach - 0.2) / voxel).rounded(.down))
            let firstRow = uniforms.lower > 0.5 ? 0 : max(0, min(grid.size - 1, floorRow))
            var pass = VolumeBlur(size: UInt32(grid.size), firstRow: UInt32(firstRow), radius: Int32(min(16, (2.5 * sigma).rounded(.up))),
                                  sigma: sigma, unit: RadiantBody.unit / (RadiantBody.fixedScale * voxel * voxel * voxel), axis: 0)
            let threads = MTLSize(width: grid.size, height: grid.size - firstRow, depth: grid.size)
            let group = MTLSize(width: 8, height: 8, depth: 4)
            compute.setComputePipelineState(gpu.radiantResolve)
            compute.setBuffer(sums, offset: grid.offset, index: 0)
            compute.setBytes(&pass, length: MemoryLayout<VolumeBlur>.stride, index: 1)
            compute.setTexture(grid.textures[0], index: 0)
            compute.dispatchThreads(threads, threadsPerThreadgroup: group)
            compute.setComputePipelineState(gpu.radiantBlur)
            for (axis, from, to) in [(UInt32(1), 0, 1), (UInt32(2), 1, 0)] {
                pass.axis = axis
                compute.setTexture(grid.textures[from], index: 0)
                compute.setTexture(grid.textures[to], index: 1)
                compute.setBytes(&pass, length: MemoryLayout<VolumeBlur>.stride, index: 0)
                compute.dispatchThreads(threads, threadsPerThreadgroup: group)
            }
        }
        compute.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = offscreen
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { composite = nil; return }
        var state = uniforms
        var look = bodyLook
        encoder.setRenderPipelineState(gpu.radiantBody)
        encoder.setVertexBytes(&state, length: MemoryLayout<BodyUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&state, length: MemoryLayout<BodyUniforms>.stride, index: 0)
        encoder.setFragmentBytes(colors, length: colors.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&look, length: MemoryLayout<RadiantBodyLook>.stride, index: 2)
        encoder.setFragmentTexture(fineVolume[0], index: 0)
        encoder.setFragmentTexture(coarseVolume[0], index: 1)
        encoder.setFragmentTexture(grainTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        if let pointTargets, !encodeParticles(command, gpu: gpu, haze: pointTargets.haze, sparks: pointTargets.sparks, camera: camera) {
            pointsComposite = nil
        }
    }

    /// The half-resolution texture the Radiant body's point lights are drawn into, the size of the body's own.
    private func pointsTarget(gpu: MeterGPU, like body: MTLTexture) -> MTLTexture? {
        if pointsTexture?.width != body.width || pointsTexture?.height != body.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: body.width, height: body.height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            pointsTexture = gpu.device.makeTexture(descriptor: descriptor)
            renderedKey = nil
        }
        return pointsTexture
    }

    /// The Radiant body's sums and volumes, made once (about 6 MB).
    private func prepareVolumes(device: MTLDevice) -> Bool {
        if volumeSums != nil && fineVolume.count == 2 && coarseVolume.count == 2 { return true }
        let fine = RadiantBody.fineSize, coarse = RadiantBody.coarseSize
        let bytes = (fine * fine * fine + coarse * coarse * coarse) * 4 * MemoryLayout<UInt32>.stride
        volumeSums = device.makeBuffer(length: bytes, options: .storageModePrivate)
        func volumes(_ size: Int) -> [MTLTexture] {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba16Float
            descriptor.width = size
            descriptor.height = size
            descriptor.depth = size
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            return (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        }
        fineVolume = volumes(fine)
        coarseVolume = volumes(coarse)
        return volumeSums != nil && fineVolume.count == 2 && coarseVolume.count == 2
    }

    /// The full-resolution texture Radiant's sparks are drawn into, made again when the canvas' size changes.
    private func sparkTarget(gpu: MeterGPU, pixels: CGSize) -> MTLTexture? {
        let width = max(1, Int(pixels.width.rounded(.up))), height = max(1, Int(pixels.height.rounded(.up)))
        if sparkTexture?.width != width || sparkTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            sparkTexture = gpu.device.makeTexture(descriptor: descriptor)
            renderedKey = nil
        }
        return sparkTexture
    }

    /// The half-resolution texture laid into the canvas' pass, where the dome's shapes leave room for it
    /// (`ShapeBuilder.overlayStart`): the level body as it is, Radiant's light tone-mapped.
    private func captureTransition(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {
        guard let quad = composite, quad.viewportX == uniforms.viewportX, quad.viewportY == uniforms.viewportY else {
            transitionTexture = nil
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: max(1, Int(pixels.width)), height: max(1, Int(pixels.height)), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(encoder, gpu: gpu)
        encoder.endEncoding()
        transitionTexture = texture
        transitionQuad = quad
        transitionQuad.minX = 0; transitionQuad.minY = 0
        transitionQuad.maxX = quad.viewportX; transitionQuad.maxY = quad.viewportY
        transition.restart()
    }

    func encode(_ encoder: MTLRenderCommandEncoder, gpu: MeterGPU) {
        let progress = transitionTexture == nil ? Float(1) : max(0, transition.value)
        if let texture = transitionTexture {
            var quad = transitionQuad
            var alpha = (1 - progress) * entrance
            encoder.setRenderPipelineState(gpu.bodyComposite)
            encoder.setVertexBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 3)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        guard var quad = composite, let offscreen else { return }
        var alpha = progress * entrance
        // Radiant's light is tone-mapped on its way in; the level body and the Radiant body are laid in as drawn.
        let light = quad.style > 0.5 && quad.style < 1.5
        encoder.setRenderPipelineState(light ? gpu.radiantComposite : gpu.bodyComposite)
        encoder.setVertexBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 3)
        encoder.setFragmentTexture(offscreen, index: 0)
        if light {
            var look = compositeLook
            encoder.setFragmentTexture(glowTextures.first ?? offscreen, index: 1)
            encoder.setFragmentTexture(wideTextures.first ?? offscreen, index: 2)
            encoder.setFragmentTexture(sparkTexture ?? offscreen, index: 3)
            encoder.setFragmentTexture(grainTexture, index: 4)
            encoder.setFragmentBytes(&look, length: MemoryLayout<RadiantLook>.stride, index: 1)
            setMeter(encoder)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        // The Radiant body's point lights: on dark their light adds to the body's, on light they are laid over it.
        if quad.style > 1.5, var points = pointsComposite, let pointsTexture {
            var look = compositeLook
            encoder.setRenderPipelineState(points.dark > 0.5 ? gpu.radiantPoints : gpu.radiantComposite)
            encoder.setVertexBytes(&points, length: MemoryLayout<BodyUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&points, length: MemoryLayout<BodyUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 3)
            encoder.setFragmentTexture(pointsTexture, index: 0)
            encoder.setFragmentTexture(glowTextures.first ?? pointsTexture, index: 1)
            encoder.setFragmentTexture(wideTextures.first ?? pointsTexture, index: 2)
            encoder.setFragmentTexture(sparkTexture ?? pointsTexture, index: 3)
            encoder.setFragmentTexture(grainTexture, index: 4)
            encoder.setFragmentBytes(&look, length: MemoryLayout<RadiantLook>.stride, index: 1)
            setMeter(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func setMeter(_ encoder: MTLRenderCommandEncoder) {
        if let meter {
            encoder.setFragmentBuffer(meter, offset: 0, index: 2)
        } else {
            var unmetered: [Float] = [0, 0]
            encoder.setFragmentBytes(&unmetered, length: 2 * MemoryLayout<Float>.stride, index: 2)
        }
    }

    /// What the offscreen texture last showed: each body drawn (its camera, quad, opacity and colours, and the set it
    /// was drawn from) and the textures' version; for Radiant, the particles' version and their camera and clock.
    private struct RenderKey: Equatable {
        struct Pass: Equatable {
            var state: BodyUniforms
            var colors: [SIMD4<Float>]
            var set: Int
        }
        var passes: [Pass]
        var version: Int
        var camera: RadiantCamera?
        var splat: VolumeSplat?
        var look: RadiantBodyLook?
        var pointLook: RadiantLook?
    }

    // MARK: Pointer

    /// The displayed radius of `layer` toward (`azimuth`, `elevation`), degrees, interpolated as the shader's sampler
    /// interpolates the texture.
    func radius(layer: Int, azimuth: Double, elevation: Double) -> Float {
        let columns = SpatialBody.azimuthSteps, rows = SpatialBody.rows - 1
        var a = (azimuth / SpatialBody.step).truncatingRemainder(dividingBy: Double(columns))
        if a < 0 { a += Double(columns) }
        let e = max(0, min(Double(rows), elevation / SpatialBody.step + Double(SpatialBody.lowerSteps)))
        let a0 = Int(a) % columns, a1 = (a0 + 1) % columns, e0 = min(rows, Int(e)), e1 = min(rows, e0 + 1)
        let ta = Float(a - Double(Int(a))), te = Float(e - Double(e0))
        let base = layer * SpatialBody.count
        let radii = self.radii
        func v(_ x: Int, _ y: Int) -> Float { radii[base + y * columns + x] }
        let low = v(a0, e0) + (v(a1, e0) - v(a0, e0)) * ta, high = v(a0, e1) + (v(a1, e1) - v(a0, e1)) * ta
        return low + (high - low) * te
    }

    /// The colour shown at `rho` (radii from the listener) toward (`azimuth`, `elevation`) in `layer`: by frequency,
    /// or the layer's own colour.
    func tint(layer: Int, azimuth: Double, elevation: Double, rho: Float) -> Theme.RGB {
        let d = SpeakerGeometry.direction(azimuth: azimuth, elevation: elevation)
        let index = SpatialBody.nearest(SIMD3(Float(d.x), Float(d.y), Float(d.z)))
        let i = layer * SpatialBody.count + index
        guard spectral, weight[i] > 0.01 else {
            let c = colors[min(colors.count - 1, layer)]
            return Theme.RGB(r: c.x, g: c.y, b: c.z)
        }
        let live = max(0.004, min(1, (level[i] - floor) / -floor))
        let c = spectralColor(layer: layer, index: index, share: min(1, rho / live))
        let rgb = Theme.RGB(r: c.x, g: c.y, b: c.z)
        return Theme.dark ? rgb : rgb.legible(on: Theme.displayRGB, ratio: 3)
    }

    /// Marches the pointer's line of sight front to back, as `bodyFragment` does, to the first point inside the body,
    /// and reads it: the direction, the level the body shows there, and what forms it there most. Nil over empty space.
    func probe(at point: CGPoint, layout: SpeakerLayout) -> DomeProbe? {
        let s = uniforms
        if style == .radiant { return s.scale > 0 ? radiantProbe(at: point) : nil }
        guard body.layerCount > 0, s.layers > 0, s.scale > 0 else { return nil }
        let x = (Float(point.x) - s.originX) / s.scale, y = (s.originY - Float(point.y)) / s.scale
        let rr = x * x + y * y
        guard rr < 1 else { return nil }
        let half = (1 - rr).squareRoot()
        var far = -half
        // Above the floor only, unless the layout reaches below the ear plane (the shader's `lower`).
        if s.lower < 0.5 {
            if s.sinElevation > 0.001 { far = max(far, -y * s.cosElevation / s.sinElevation) } else if y < 0 { return nil }
        }
        var t = half
        while t > far {
            defer { t -= 0.01 }
            let q = SIMD3(x, y * s.cosElevation + t * s.sinElevation, y * s.sinElevation - t * s.cosElevation)
            // Model coordinates (x right, y up, z front), then the field's frame (x right, y front, z up).
            let p = SIMD3(q.x * s.cosYaw - q.z * s.sinYaw, q.y, q.x * s.sinYaw + q.z * s.cosYaw)
            let rho = simd_length(p)
            guard rho > 0.01 else { continue }
            let d = SIMD3(p.x, p.z, p.y) / rho
            let azimuth = Double(atan2(d.x, d.y)) * 180 / .pi
            let elevation = Double(asin(max(s.lower > 0.5 ? -1 : 0, min(1, d.z)))) * 180 / .pi
            var best: (layer: Int, radius: Float)?
            for layer in 0..<body.layerCount {
                let r = radius(layer: layer, azimuth: azimuth, elevation: elevation)
                if r > 0.004, rho <= r, r > (best?.radius ?? 0) { best = (layer, r) }
            }
            guard let best else { continue }
            return reading(layer: best.layer, value: best.radius, toward: d, rho: rho, layout: layout)
        }
        return nil
    }

    /// The pointer's reading of `layer` at `rho` toward unit direction `d` (field frame), where the body shows `value`
    /// on its floor…0 dBFS scale.
    private func reading(layer: Int, value: Float, toward d: SIMD3<Float>, rho: Float, layout: SpeakerLayout) -> DomeProbe {
        let azimuth = Double(atan2(d.x, d.y)) * 180 / .pi, elevation = Double(asin(max(-1, min(1, d.z)))) * 180 / .pi
        let group = groups[min(groups.count - 1, layer)]
        var kind = DomeProbe.Kind.none
        var width: Double?, stability: Double?, coherence: Double?, centroid: Double?
        let up = SIMD3(d.x, d.y, abs(d.z))
        if let strongest = body.strongest(layer: layer, toward: up), 10 * log10(max(1e-30, strongest.energy)) > floor {
            centroid = Double(strongest.lobe.centroid)
            switch strongest.lobe.kind {
            case .speaker(let role): kind = .speaker(layout.name(of: role))
            case .image:
                kind = strongest.lobe.instability > 0.5 ? .unstable : .image
                width = Double(strongest.lobe.width)
                stability = Double(1 - strongest.lobe.instability)
                coherence = Double(strongest.lobe.coherence)
            }
        }
        return DomeProbe(kind: kind, band: groups.count > 1 ? BandChoice.range(choice.resolution, group) : nil,
                         hue: tint(layer: layer, azimuth: azimuth, elevation: elevation, rho: rho),
                         decibels: Double(floor + value * -floor), azimuth: azimuth, elevation: elevation,
                         width: width, stability: stability, coherence: coherence, centroid: centroid)
    }

    /// Radiant: the particle the pointer is over, among the newest, and what it stands for: its band's centre frequency
    /// and level, where it sits, and the part of the field that pulls it there most (a speaker's own energy, a phantom
    /// image or energy out of phase).
    private func radiantProbe(at point: CGPoint) -> DomeProbe? {
        let s = uniforms
        let toModel = observationScale
        func project(_ p: SIMD3<Float>) -> CGPoint {
            // The field's frame (x right, y front, z up) to model coordinates at the layout's scale, then the camera.
            let m = SIMD3(p.x, p.z, p.y) * toModel
            let q = SIMD3(m.x * s.cosYaw + m.z * s.sinYaw, m.y, m.z * s.cosYaw - m.x * s.sinYaw)
            return CGPoint(x: CGFloat(s.originX + q.x * s.scale), y: CGFloat(s.originY - (q.z * s.sinElevation + q.y * s.cosElevation) * s.scale))
        }
        guard let r = particles.reading(at: point, clock: clock, fade: camera.fade, reach: 10, project: project) else { return nil }
        let length = simd_length(r.position)
        let d = length > 1e-4 ? r.position / length : SIMD3<Float>(0, 1, 0)
        let azimuth = Double(atan2(d.x, d.y)) * 180 / .pi, elevation = Double(asin(max(-1, min(1, d.z)))) * 180 / .pi
        let hz = r.band >= 0 ? SpatialField.centre(r.band) : exp2(SpectralHue.centres[min(StereoBands.count - 1, -1 - r.band)])
        let group = groups[min(groups.count - 1, max(0, r.layer))]
        let rgb = Theme.RGB(r: r.hue.x, g: r.hue.y, b: r.hue.z)
        return DomeProbe(kind: r.kind, band: groups.count > 1 ? BandChoice.range(choice.resolution, group) : nil,
                         hue: Theme.dark ? rgb : rgb.legible(on: Theme.displayRGB, ratio: 3), decibels: Double(r.level),
                         azimuth: azimuth, elevation: elevation, width: r.width.map(Double.init),
                         stability: r.stability.map(Double.init), coherence: r.coherence.map(Double.init),
                         centroid: r.frequency.map(Double.init) ?? hz, meters: observationsInMeters ? Double(length) : nil,
                         directionless: length < 0.02 / max(observationScale, 1e-6))
    }
}

extension NebulaScene {
    /// Exercises display caching with a real analysis snapshot, including held settings and stream transitions: the
    /// level body's easing and caching, then Radiant's particles.
    static func checkLifecycle() -> Bool {
        let scene = NebulaScene(device: nil)
        var frame = CanvasFrame(running: true)
        frame.snapshot = DemoSignal.snapshot(at: 4.5, sequence: 135)
        let geometry = DomeGeometry(size: CGSize(width: 520, height: 440))
        var options = DisplayOptions()
        options.nebula.style = .level
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL nebula: \(message)"); failures += 1 }
        }
        func update(_ dt: Float = 1.0 / 60) {
            scene.update(frame: frame, geometry: geometry, dt: dt, displayDt: dt, options: options, presence: 1)
        }
        update()
        check(scene.evaluations == 1, "initial target")
        update()
        check(scene.evaluations == 1, "same input reused while easing")
        let held = scene.radius
        update(0)
        check(scene.radius == held, "frozen radius unchanged")
        options.nebula.opacity = 0.6
        update(0)
        check(scene.evaluations == 1 && scene.radius == held, "appearance does not rebuild field")
        // A steady target comes to rest: no more easing or uploads until it changes.
        for _ in 0..<600 { update() }
        let eased = scene.easedFrames
        for _ in 0..<30 { update() }
        check(scene.easedFrames == eased, "a body at rest is not eased again")
        options.nebula.colors = .theme
        update()
        check(scene.easedFrames > eased && !scene.spectral, "a colour change redraws the body at rest")
        options.nebula.colors = .frequency
        check(!options.nebula.rings.isEmpty && scene.uniforms.style == 0, "the level body has its rings")
        // The glide: a new target is approached without a jump, and the body moves toward it.
        frame.snapshot = DemoSignal.snapshot(at: 7.3, sequence: 219)
        update(1.0 / 60)
        let first = scene.radius
        update(1.0 / 60)
        check(scene.radius != first, "the body glides toward a new target")
        var expected = scene.evaluations
        options.nebula.smoothing = 50
        update(0)
        expected += 1
        check(scene.evaluations == expected, "frozen smoothing invalidates target")
        options.domeBands = BandChoice(.five)
        update(0)
        expected += 1
        check(scene.evaluations == expected && scene.layerCount == 5 && !scene.spectral, "held band split updates layers")
        frame.epoch += 1
        update(0)
        expected += 1
        check(scene.evaluations == expected, "epoch reset")
        frame.snapshot.streamID += 1
        update(0)
        expected += 1
        check(scene.evaluations == expected, "stream reset")
        frame.activeRoles[Role.lfe] = false
        update(0)
        expected += 1
        check(scene.evaluations == expected, "active roles invalidate")
        options.nebula.floor = -80
        update(0)
        expected += 1
        check(scene.evaluations == expected, "floor invalidates")
        // Reused serial but changed field: content is authoritative.
        frame.snapshot.spatialField[SpatialField.status] = 0
        update(0)
        expected += 1
        check(scene.evaluations == expected, "changed field with same sequence")
        for _ in 0..<600 { update() }
        check(scene.evaluations == expected, "silence target reused through release")
        check(scene.uniforms.bound == 0, "silence eventually skips GPU volume")
        check(scene.radius.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "finite bounded radii")
        check(UnsafeBufferPointer(start: scene.bands, count: bandCount * size).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
              "finite bounded band radii")

        // Radiant: particles from the field, a frozen picture that holds, new frames as the field changes, a reading
        // under the pointer, and nothing once the sound has gone.
        let radiant = NebulaScene(device: nil)
        var live = CanvasFrame(running: true)
        live.snapshot = DemoSignal.snapshot(at: 4.5, sequence: 135)
        var look = DisplayOptions()
        look.nebula.style = .radiant
        func step(_ dt: Float = 1.0 / 60) {
            radiant.update(frame: live, geometry: geometry, dt: dt, displayDt: dt, options: look, presence: 1)
        }
        step()
        check(radiant.particles.liveCount > 0 && radiant.uniforms.style == 2 && radiant.bodyLook.density > 0
              && radiant.uniforms.bound == RadiantBody.shell, "Radiant body gathers particles from the field into its volume")
        check(radiant.peak > -200 && radiant.peak <= 0, "Radiant's range hangs from the loudest band")
        check(look.nebula.rings.isEmpty, "Radiant has no level rings")
        let splat = radiant.bodySplat
        check(splat.bornVariance > 0 && splat.blurRate > 0 && splat.coarseVariance > splat.bornVariance
              && splat.lifetime > 0 && splat.fade > 0, "new light is compact, older light swells into haze")
        check(radiant.uniforms.minX > 0 && radiant.uniforms.maxX < radiant.uniforms.viewportX,
              "the body is marched in the dome's quad, not the whole canvas")
        check(radiant.pointUniforms.bound == 1 && radiant.pointUniforms.gain > 0 && radiant.pointUniforms.style == 1
              && radiant.bodyLook.glow < 1, "point lights over the body, the body dimmed under them")
        look.nebula.points = 0
        step(0)
        check(radiant.pointUniforms.bound == 0 && radiant.bodyLook.glow == 1 && radiant.uniforms.style == 2,
              "Points 0 shows the body alone")
        look.nebula.points = 1
        look.nebula.blur = 0
        step(0)
        check(radiant.bodySplat.blurRate == 0 && radiant.particles.liveCount > 0, "Blur 0 keeps light as compact as when heard")
        look.nebula.blur = 1
        look.nebula.rawPoints = true
        step(0)
        check(radiant.uniforms.style == 1 && radiant.raw, "raw observations draw the particles themselves")
        look.nebula.rawPoints = false
        step(0)
        check(radiant.uniforms.style == 2, "and back to the body")
        let frozen = radiant.particles.version
        for _ in 0..<10 { step(0) }
        check(radiant.particles.version == frozen, "a frozen picture holds still")
        let frames = radiant.particles.frames.count
        live.snapshot = DemoSignal.snapshot(at: 4.6, sequence: 138)
        step()
        check(radiant.particles.frames.count == frames + 1, "a new field adds a frame")
        let fallbackVersion = radiant.particles.version
        live.snapshot.spectrogramSerial += 1
        step()
        check(radiant.particles.version > fallbackVersion && radiant.particles.frames.last?.birth == radiant.clock,
              "steady legacy/statistical input also follows the analysis clock")
        let everyPosition = radiant.particles.recent.joined().map(\.position)
        check(!everyPosition.isEmpty && everyPosition.allSatisfy { $0.x.isFinite && simd_length($0) <= 1.0501 && $0.z >= 0 },
              "particles stay inside the speakers' sphere, above the floor")
        if let brightest = radiant.particles.recent.last?.max(by: { $0.light < $1.light }) {
            let p = brightest.position
            let point = geometry.project(DomeGeometry.Point(Double(p.x), Double(p.z), Double(p.y)))
            let reading = radiant.probe(at: point, layout: live.layout)
            check(reading != nil && (reading?.centroid ?? 0) > 0, "the pointer reads the particle under it")
        }
        look.nebula.style = .level
        step()
        check(radiant.uniforms.style == 0 && radiant.easedFrames > 0, "switching to the level body draws it")
        look.nebula.style = .radiant
        step()
        check(radiant.uniforms.style == 2, "and back to Radiant body")
        live.snapshot.spatialField[SpatialField.status] = 0
        for i in 0..<120 {
            live.snapshot.spatialField[SpatialField.threshold] = Float(i)
            step()
        }
        check(radiant.particles.liveCount == 0 && radiant.uniforms.bound == 0, "silence leaves no particles")

        // Radiant from the analysis' observations: each new frame added as heard, born at its audio's time; a change
        // to how they are drawn remakes the picture from the frames heard (not the newest repeated); frozen, it holds;
        // the same frame shown twice is added once; a reset starts afresh; observations of another geometry are never
        // drawn, and a geometry change leaves no particles of the old one.
        var frameSerial: Float = 0
        var windowEnd: UInt64 = 48_000 * 4
        func observed(_ snapshot: MeterSnapshot, _ shift: Float, hash: UInt64, source: SpatialObservations.Source = .measured,
                      next: Bool = true) -> MeterSnapshot {
            var s = snapshot
            if next { frameSerial += 1; windowEnd += 1_600 }
            var list: [Float] = []
            var counts = [Float](repeating: 0, count: SpatialField.bandCount)
            for band in 0..<SpatialField.bandCount {
                var total: Float = 0
                for role in 0..<Role.count where role != Role.lfe { total += s.spatialField[SpatialField.independent(band: band, role: role)] }
                for slot in 0..<SpatialField.coherentSlots { total += s.spatialField[SpatialField.component(band: band, slot: slot)] }
                guard total > 0 else { continue }
                counts[band] = 2
                for index in 0..<2 {
                    list += [(index == 0 ? -0.3 : 0.3) + shift, 0.8, 0, total / 2, Float(SpatialField.centre(band)),
                             Float(SpatialField.edge(band)), Float(SpatialField.edge(band + 1)), 0, 0]
                }
            }
            var v = [Float](repeating: 0, count: SpatialObservations.first)
            typealias H = SpatialObservations.Header
            v[H.status] = 1; v[H.version] = SpatialObservations.version; v[H.source] = source.rawValue
            v[H.sampleRate] = 48_000; v[H.windowLength] = 8_192; v[H.zones] = 1; v[H.serial] = frameSerial
            v[H.count] = Float(list.count / SpatialObservations.fields)
            v.withUnsafeMutableBufferPointer { p in
                SpatialObservations.store(hash, parts: 4, at: p.baseAddress! + H.hash)
                SpatialObservations.store(windowEnd, parts: 3, at: p.baseAddress! + H.windowEnd, bits: 24)
            }
            for band in 0..<SpatialField.bandCount { v[SpatialObservations.counts + band] = counts[band] }
            s.spatialObservations = v + list
            return s
        }
        let bins = NebulaScene(device: nil)
        var heard = CanvasFrame(running: true)
        let drawn = heard.geometry.hash
        heard.snapshot = observed(DemoSignal.snapshot(at: 4.5, sequence: 135), 0, hash: drawn)
        func hear(_ dt: Float = 1.0 / 60) {
            bins.update(frame: heard, geometry: geometry, dt: dt, displayDt: dt, options: look, presence: 1)
        }
        hear()
        check(bins.particles.frames.count == 1 && bins.particles.recent.last?.allSatisfy { abs(abs($0.position.x) - 0.3) < 1e-5 } == true,
              "the observations make one frame of particles where they are")
        for i in 1...5 {
            heard.snapshot = observed(DemoSignal.snapshot(at: 4.5 + Double(i) / 30, sequence: 135 + i), Float(i) * 0.01, hash: drawn)
            hear()
            hear()
        }
        check(bins.particles.frames.count == 6, "each new frame of observations adds one frame, shown twice or not (\(bins.particles.frames.count))")
        let xs = Set(bins.particles.recent.joined().map { ($0.position.x * 1000).rounded() })
        look.nebula.particleSize = 1.5
        hear()
        check(bins.particles.frames.count == 6 && Set(bins.particles.recent.joined().map { ($0.position.x * 1000).rounded() }) == xs,
              "a change of how they are drawn remakes the frames heard")
        let still = bins.particles.version
        for _ in 0..<10 { hear(0) }
        check(bins.particles.version == still, "a frozen picture of observations holds still")
        // A burst: after a gap, two frames arriving in one display frame are born 1/30 s apart, as their audio was
        // (the older in the past, never one in the future).
        heard.snapshot = observed(heard.snapshot, 0.05, hash: drawn)
        hear(1.0 / 30)
        hear(1.0 / 30)
        hear(1.0 / 30)
        heard.snapshot = observed(heard.snapshot, 0.06, hash: drawn)
        hear(0.001)
        let earlier = bins.particles.frames.last?.birth ?? 0
        heard.snapshot = observed(heard.snapshot, 0.07, hash: drawn)
        hear(0.001)
        let later = bins.particles.frames.last?.birth ?? 0
        check(abs((later - earlier) - 1.0 / 30) < 0.002 && later <= bins.clock,
              "a burst is spread as its audio was (\(later - earlier) s apart)")
        heard.snapshot.streamID += 1
        hear()
        check(bins.particles.frames.count == 1, "a new stream starts afresh from what it hears")
        // Bit-identical steady audio still arrives at the analysis rate (each frame its own serial and time);
        // display-only redraws add nothing.
        for _ in 0..<90 {
            heard.snapshot = observed(heard.snapshot, 0.06, hash: drawn)
            hear(1.0 / 30)
        }
        check(bins.particles.frames.count >= 14 && bins.particles.liveCount > 0,
              "steady measured audio remains visible beyond its persistence time")
        let steadyFrames = bins.particles.frames.count
        hear(0)
        check(bins.particles.frames.count == steadyFrames, "a held measurement is not emitted twice")
        let ages = bins.heard.map(\.birth)
        look.domeBands = BandChoice(.five)
        hear(0)
        check(bins.heard.map(\.birth) == ages && bins.particles.frames.count == steadyFrames,
              "band switches preserve the measured history and its ages")
        let bodyEvaluations = bins.easedFrames
        heard.snapshot = observed(heard.snapshot, 0.06, hash: drawn)
        hear()
        check(bins.easedFrames == bodyEvaluations, "Radiant never uploads the unused level grid")
        // The same frame on the next display frames (the analysis is slower than the display) is not added again.
        let newest = bins.particles.frames.last?.birth
        hear()
        hear()
        check(bins.particles.frames.last?.birth == newest, "a frame shown on several display frames is added once")
        // Another geometry drawn (the user changed the layout): no particle of the old one stays, and observations
        // still computed with the old one are never drawn; those with the new one are.
        var moved = heard.geometry.placements
        moved[Role.left].azimuth = -40
        heard.geometry = SpatialGeometry(placements: moved, roles: heard.layout.roles)
        heard.snapshot = observed(heard.snapshot, 0.06, hash: drawn)
        hear()
        check(bins.particles.liveCount == 0 && bins.waitingForGeometry && bins.refusedFrames >= 1,
              "observations of the old geometry are not drawn after a layout change, and none of its particles stay")
        heard.snapshot = observed(heard.snapshot, 0.06, hash: heard.geometry.hash)
        hear()
        check(bins.particles.liveCount > 0 && !bins.waitingForGeometry, "observations of the new geometry are drawn")
        // A plugin before build 98: its bins (the standard layout's) are drawn only while the standard layout is.
        let lastDrawn = bins.particles.frames.last?.birth
        heard.snapshot = observed(heard.snapshot, 0.06, hash: 0, source: .legacy)
        hear()
        check(bins.waitingForGeometry && bins.particles.frames.last?.birth == lastDrawn,
              "a plugin's standard-layout bins are not drawn beside a custom layout")
        heard.geometry = SpatialGeometry.standard(roles: heard.layout.roles)
        heard.snapshot = observed(heard.snapshot, 0.06, hash: 0, source: .legacy)
        hear()
        check(!bins.waitingForGeometry && bins.particles.liveCount > 0, "…and drawn with the standard layout")
        // A held measured frame starts with the one observation available, not a fabricated trail.
        let heldScene = NebulaScene(device: nil)
        heldScene.update(frame: heard, geometry: geometry, dt: 0, displayDt: 0, options: look, presence: 1)
        check(heldScene.particles.frames.count == 1, "first frozen measurement has no invented past")
        // The bare observations: the newest frame only, no spread, glint, glow or depth shading.
        look.nebula.rawPoints = true
        heard.snapshot = observed(heard.snapshot, 0.06, hash: 0, source: .legacy)
        hear()
        for _ in 0..<6 {
            heard.snapshot = observed(heard.snapshot, 0.06, hash: 0, source: .legacy)
            hear(1.0 / 30)
        }
        check(bins.raw && bins.camera.blur == 0 && bins.camera.sparkGain == 0 && bins.camera.depthFade == 0
                  && bins.look.glowNear == 0 && bins.uniforms.spare == 0 && bins.particles.frames.count <= 2,
              "raw points: only the newest frame, nothing smeared, glinting or glowing (\(bins.particles.frames.count) frames)")
        look.nebula.rawPoints = false
        // Hover data must expire with the particles, even if no replacement frame arrives.
        bins.particles.prune(clock: bins.clock + 10, lifetime: 0.5)
        check(bins.particles.liveCount == 0 && bins.particles.recent.isEmpty,
              "expired particles leave no invisible hover readings")
        look.nebula.particles = 20
        failures += RadiantParticles.checkGeometry()
        print("Nebula lifecycle: \(failures) failures")
        return failures == 0
    }
}


extension NebulaScene {
    /// Real Metal regression: a frozen style switch and an interrupted switch both begin at the last visible image.
    /// Exercises the actual composite shaders, texture capture and release without touching saved preferences.
    static func checkGPUTransitions() -> Bool {
        do {
            let gpu = try MeterGPU.shared.get()
            let scene = NebulaScene(device: gpu.device)
            var frame = CanvasFrame(running: true)
            frame.snapshot = DemoSignal.snapshot(at: 4.5, sequence: 135)
            let geometry = DomeGeometry(size: CGSize(width: 520, height: 440))
            var options = DisplayOptions()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 520, height: 440, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            guard let target = gpu.device.makeTexture(descriptor: descriptor) else { throw MetalError.allocation }
            func render() throws -> [UInt8] {
                scene.update(frame: frame, geometry: geometry, dt: 0, displayDt: 1.0 / 60, options: options, presence: 1)
                guard let command = gpu.queue.makeCommandBuffer() else { throw MetalError.allocation }
                scene.encodeOffscreen(command, gpu: gpu, pixels: CGSize(width: 520, height: 440))
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MetalError.allocation }
                scene.encode(encoder, gpu: gpu)
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                if let error = command.error { throw error }
                var bytes = [UInt8](repeating: 0, count: 520 * 440 * 4)
                target.getBytes(&bytes, bytesPerRow: 520 * 4, from: MTLRegionMake2D(0, 0, 520, 440), mipmapLevel: 0)
                return bytes
            }
            func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
                zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
            }
            var failures = 0
            func check(_ ok: Bool, _ label: String) {
                if !ok { failures += 1; print("FAIL GPU transition: \(label)") }
            }
            let initial = try render()
            check(initial.contains { $0 > 0 }, "initial frame is visible")
            options.nebula.style = .level
            let first = try render()
            check(difference(initial, first) <= 2 && scene.transitionTexture != nil,
                  "style switch starts at the outgoing image")
            var middle = first
            for _ in 0..<12 { middle = try render() }
            check(middle != first, "transition advances with the signal frozen")
            options.nebula.style = .radiant
            let interrupted = try render()
            check(difference(middle, interrupted) <= 2, "interrupted switch captures the current blend")
            for _ in 0..<90 { _ = try render() }
            check(scene.transitionTexture == nil, "completed transition releases its texture")
            options.domeBands = BandChoice(.five)
            _ = try render()
            check(scene.transitionTexture != nil, "Radiant band switch crossfades")
            frame.snapshot.streamID += 1
            _ = try render()
            check(scene.transitionTexture == nil, "source change cannot crossfade stale measurements")
            print("Nebula GPU transitions: \(failures) failures")
            return failures == 0
        } catch {
            print("FAIL GPU transitions: \(error)")
            return false
        }
    }
}

extension NebulaScene {
    /// The three coordinate frames kept apart and checked against each other (`--test-spatial-projection`): the
    /// observations' mathematical positions, their projection by the CPU (`DomeGeometry.project`, which the labels,
    /// markers and hover readout use), and where the GPU actually draws them (each particle's brightness centroid in the
    /// rendered image, raw points: no smear, glint, glow or depth shading). Several cameras, the directions and the
    /// meters mapping, points below the ear plane. Also the hover readout at each projected point. Returns whether every
    /// centroid is within 0.5 logical points of the CPU's projection and every readout names the right direction.
    static func checkProjection() -> Bool {
        do {
            let gpu = try MeterGPU.shared.get()
            let size = CGSize(width: 520, height: 440), scale = 2
            let width = Int(size.width) * scale, height = Int(size.height) * scale
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            guard let target = gpu.device.makeTexture(descriptor: descriptor) else { throw MetalError.allocation }
            var failures = 0, worst = 0.0, worstReading = 0.0, checked = 0
            let layout = SpeakerLayout.s714
            var below = SpatialGeometry.standardPlacements(sidesAtNinety: true)
            below[Role.leftTopRear] = SpeakerPlacement(azimuth: -135, elevation: -25)
            below[Role.rightTopRear] = SpeakerPlacement(azimuth: 135, elevation: -25)
            var meters = below
            for role in 0..<Role.count { meters[role].distance = 2.5 }
            meters[Role.left].distance = 1.5
            meters[Role.rightTopRear].distance = 3
            let geometries = [SpatialGeometry.standard(roles: layout.roles),
                              SpatialGeometry(placements: below, roles: layout.roles),
                              SpatialGeometry(placements: meters, mapping: .positions, roles: layout.roles)]
            let poses = [DomePose(view: .perspective, yaw: 0, pitch: DomeGeometry.defaultPitch, zoom: 1),
                         DomePose(view: .perspective, yaw: 37, pitch: 50, zoom: 1.4),
                         DomePose(view: .top, yaw: -20, pitch: 90, zoom: 1),
                         DomePose(view: .side, yaw: 90, pitch: 0, zoom: 1)]
            for geometry in geometries {
                // Points where the observations would put sound: on speakers, between them, and below the ear plane.
                let roles = [Role.left, Role.right, Role.center, Role.leftSurround, Role.leftTopFront, Role.rightTopRear]
                var points = roles.compactMap { geometry.position(role: $0) }.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
                let l = points[0], r = points[1]
                points.append((2 * l + r) / 3)
                points.append((points[5] + l) / 2)
                for pose in poses {
                    let scene = NebulaScene(device: gpu.device)
                    var frame = CanvasFrame(running: true)
                    frame.layout = layout
                    frame.geometry = geometry
                    var options = DisplayOptions()
                    options.nebula.style = .radiant
                    options.nebula.rawPoints = true
                    options.domeView = pose.elevation == 90 ? .top : (pose.elevation == 0 ? .side : .perspective)
                    frame.snapshot.spatialField[SpatialField.status] = 1
                    // One observation per band, each band equally loud, so every particle has the same light.
                    var v = [Float](repeating: 0, count: SpatialObservations.first)
                    typealias H = SpatialObservations.Header
                    v[H.status] = 1; v[H.version] = SpatialObservations.version; v[H.source] = SpatialObservations.Source.measured.rawValue
                    v[H.mapping] = Float(geometry.mapping.rawValue); v[H.sampleRate] = 48_000; v[H.windowLength] = 8_192; v[H.zones] = 1
                    v[H.serial] = 1; v[H.count] = Float(points.count)
                    v.withUnsafeMutableBufferPointer { p in
                        SpatialObservations.store(geometry.hash, parts: 4, at: p.baseAddress! + H.hash)
                        SpatialObservations.store(48_000, parts: 3, at: p.baseAddress! + H.windowEnd, bits: 24)
                    }
                    var list: [Float] = []
                    for (i, p) in points.enumerated() {
                        let band = 10 + 8 * i
                        v[SpatialObservations.counts + band] = 1
                        let hz = Float(SpatialField.centre(band))
                        list += [p.x, p.y, p.z, 1e-3, hz, hz, hz, 0, 0]
                    }
                    frame.snapshot.spatialObservations = v + list
                    let g = DomeGeometry(size: size, view: options.domeView, pose: pose, lower: geometry.reachesBelow(roles: layout.roles))
                    scene.update(frame: frame, geometry: g, dt: 1.0 / 60, displayDt: 1.0 / 60, options: options, presence: 1)
                    guard let command = gpu.queue.makeCommandBuffer() else { throw MetalError.allocation }
                    scene.encodeOffscreen(command, gpu: gpu, pixels: CGSize(width: width, height: height))
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MetalError.allocation }
                    scene.encode(encoder, gpu: gpu)
                    encoder.endEncoding()
                    command.commit()
                    command.waitUntilCompleted()
                    if let error = command.error { throw error }
                    var pixels = [UInt8](repeating: 0, count: width * height * 4)
                    target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    let toModel = 1 / geometry.extent(roles: layout.roles)
                    let projected = points.map { p in
                        g.project(DomeGeometry.Point(Double(p.x), Double(p.z), Double(p.y)) * (geometry.mapping == .positions ? toModel : 1))
                    }
                    for (i, point) in projected.enumerated() {
                        // Skip points another one would overlap on screen in this camera.
                        let clear = projected.enumerated().allSatisfy { j, q in j == i || hypot(q.x - point.x, q.y - point.y) > 12 }
                        guard clear, point.x > 10, point.y > 10, point.x < size.width - 10, point.y < size.height - 10 else { continue }
                        // The brightness centroid within 8 points of the CPU's projection, in pixels of the target.
                        var sum = 0.0, sx = 0.0, sy = 0.0
                        let cx = Int(point.x * CGFloat(scale)), cy = Int(point.y * CGFloat(scale))
                        for y in max(0, cy - 16)..<min(height, cy + 17) {
                            for x in max(0, cx - 16)..<min(width, cx + 17) {
                                let o = (y * width + x) * 4
                                let luma = 0.0722 * Double(pixels[o]) + 0.7152 * Double(pixels[o + 1]) + 0.2126 * Double(pixels[o + 2])
                                guard luma > 2 else { continue }
                                sum += luma; sx += luma * (Double(x) + 0.5); sy += luma * (Double(y) + 0.5)
                            }
                        }
                        checked += 1
                        guard sum > 0 else { failures += 1; print("FAIL projection: nothing drawn at \(point)"); continue }
                        let gx = sx / sum / Double(scale), gy = sy / sum / Double(scale)
                        let error = hypot(gx - Double(point.x), gy - Double(point.y))
                        worst = max(worst, error)
                        if error > 0.5 {
                            failures += 1
                            print(String(format: "FAIL projection: GPU centroid %.2f pt from the CPU's (point %d, %@ mapping, camera %.0f/%.0f°)",
                                         error, i, geometry.mapping == .positions ? "meters" : "directions", pose.turn, pose.elevation))
                        }
                        // The hover readout at the projected point names the observation's own direction.
                        if let probe = scene.probe(at: point, layout: layout) {
                            let p = points[i]
                            let d = p / max(1e-6, simd_length(p))
                            let azimuth = Double(atan2(d.x, d.y)) * 180 / .pi, elevation = Double(asin(d.z)) * 180 / .pi
                            var da = abs(probe.azimuth - azimuth).truncatingRemainder(dividingBy: 360)
                            if da > 180 { da = 360 - da }
                            let off = max(da * cos(elevation * .pi / 180), abs(probe.elevation - elevation))
                            worstReading = max(worstReading, off)
                            if off > 0.5 {
                                failures += 1
                                print(String(format: "FAIL readout: %.2f° off (point %d)", off, i))
                            }
                        } else {
                            failures += 1
                            print("FAIL readout: nothing read at point \(i)")
                        }
                    }
                }
            }
            print(String(format: "Spatial projection: %d points, GPU centroid within %.3f pt of the CPU projection, readouts within %.3f°, %d failures",
                         checked, worst, worstReading, failures))
            return failures == 0 && checked > 40
        } catch {
            print("FAIL projection: \(error)")
            return false
        }
    }
}
