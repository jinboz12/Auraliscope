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
    /// Radiant's exposure meter (`radiantMeterKernel`): the wide glow's brightest point, and that held; the scene's
    /// clock when it was last read.
    private let meter: MTLBuffer?
    private var meterClock: Float = 0
    private var composite: BodyUniforms?
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
    private var particleLayout: SpeakerLayout?
    private var particleSpeakers: [(role: Int, name: String, direction: SIMD3<Float>)] = []
    private var particleKey: ParticleKey?
    /// The frames heard lately with their bins (newest last, within the persistence time): a change to how the
    /// particles are drawn remakes the picture from them, so it shows what was heard rather than the newest frame
    /// repeated.
    private struct Heard {
        var birth: Float
        var serial: UInt32
        var field: [Float]
        var points: [Float]
        var power: [Float]
    }
    private var heard: [Heard] = []
    private(set) var camera = RadiantCamera()
    private(set) var look = RadiantLook()
    private struct ParticleKey: Equatable {
        var perBand: Int
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
    private var cachedPoints: [Float] = []
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
        descriptor.height = SpatialBody.elevationSteps + 1
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
        // A new measurement, stream, layout or band starts from the measured shape.
        let reset = epoch != frame.epoch || stream != frame.snapshot.streamID || lastLayout != layout || lastChoice == nil || switched
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
        } else if restyled || (switched && style == .radiant) {
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
        // New audio: a new field, its bins, or (from a source without a field) new band energies.
        let contentChanged = cachedField != field || cachedPoints != frame.snapshot.spatialPoints || cachedPower != frame.snapshot.roleBandPower
        // The analysis clock advances even for bit-identical steady signals. Redrawing a display frame does not.
        let fresh = contentChanged || cachedAnalysisSerial != frame.snapshot.spectrogramSerial
        cachedAnalysisSerial = frame.snapshot.spectrogramSerial
        cachedPoints = frame.snapshot.spatialPoints
        let changed = reset || restyled || contentChanged || cachedShown != shown || cachedLayers != layers || cachedSettings != settings
            || cachedFloor != floor
        if changed {
            field.withUnsafeBufferPointer { field in
                body.evaluate(field: field, roleBandPower: frame.snapshot.roleBandPower, layout: layout, shown: shown,
                              layers: layers, settings: settings, floor: floor, metadataOnly: style == .radiant)
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
        uniforms = g.bodyUniforms(opacity: presence * Float(n.opacity), layers: body.layerCount, dark: Theme.dark)
        uniforms.spectral = spectral ? 1 : 0
        uniforms.grain = n.grain ? 1 : 0
        if style == .radiant {
            updateRadiant(frame: frame, dt: dt, n: n, layers: layers, shown: shown, changed: changed, fresh: fresh,
                          reset: sourceReset || restyled || particleKey == nil)
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

    /// Radiant: a new frame of particles from each new field, the loudest band followed, old frames forgotten, and the
    /// camera and composite for this frame. With the analysis' bins, a change to how they are drawn remakes the picture
    /// from the frames heard; without them (or with nothing heard yet while frozen), after a reset or a change while
    /// frozen, the picture a steady field leaves after the persistence time, so it shows at once as it would after a
    /// while.
    private func updateRadiant(frame: CanvasFrame, dt: Float, n: NebulaSettings, layers: [SpatialBody.Layer], shown: [Bool],
                               changed: Bool, fresh: Bool, reset: Bool) {
        let lifetime = max(0.06, Float(n.persistence / 1000))
        clock += dt
        if reset {
            particles.clear()
            peak = -200
            // The exposure meter starts again from what it next measures.
            meter?.contents().initializeMemory(as: Float.self, repeating: 0, count: 2)
            meterClock = clock
        }
        if particleLayout != frame.layout {
            particleLayout = frame.layout
            particleSpeakers = frame.layout.speakers.compactMap { speaker in
                guard speaker.group != .lfe,
                      let d = SpeakerGeometry.direction(role: speaker.role, sidesAtNinety: frame.layout.sidesAtNinety) else { return nil }
                return (speaker.role, speaker.name, SIMD3(Float(d.x), Float(d.y), Float(d.z)))
            }
        }
        let layerColors = (0..<layers.count).map { SIMD3(colors[$0].x, colors[$0].y, colors[$0].z) }
        let key = ParticleKey(perBand: Int(n.particles), spread: Float(n.spread), spectral: spectral, layers: layers,
                              colors: layerColors, floor: floor, range: Float(n.range))
        let selectionChanged = particleKey?.layers != key.layers
        let remade = particleKey != key
        particleKey = key
        let snapshot = frame.snapshot
        func input(_ field: UnsafeBufferPointer<Float>, _ points: UnsafeBufferPointer<Float>, _ power: [Float]) -> RadiantParticles.Input {
            RadiantParticles.Input(field: field, points: points, roleBandPower: power, speakers: particleSpeakers, shown: shown,
                                   layers: layers, spectral: spectral, layerColors: layerColors, perBand: Int(n.particles),
                                   size: 1, spread: Float(n.spread), floor: floor, range: Float(n.range))
        }
        let pointed = snapshot.spatialField.first == 1 && snapshot.spatialPoints.first == 1
        if reset || !pointed { heard.removeAll(keepingCapacity: true) }
        if pointed {
            // The bins: each new frame added as it is heard; the picture remade from the frames heard when how they
            // are drawn changes.
            if fresh || reset || remade || changed {
                snapshot.spatialField.withUnsafeBufferPointer { field in
                    snapshot.spatialPoints.withUnsafeBufferPointer { points in
                        newest = particles.loudestBand(input(field, points, snapshot.roleBandPower))
                    }
                }
                if selectionChanged || newest > peak { peak = newest }
            }
            let rebuild = reset || remade || (changed && !fresh)
            // After a reset the newest frame is the first heard of what comes next.
            if (fresh || reset) && dt > 0 {
                serial &+= 1
                heard.append(Heard(birth: clock, serial: serial, field: snapshot.spatialField, points: snapshot.spatialPoints,
                                   power: snapshot.roleBandPower))
                if !rebuild {
                    snapshot.spatialField.withUnsafeBufferPointer { field in
                        snapshot.spatialPoints.withUnsafeBufferPointer { points in
                            particles.add(input(field, points, snapshot.roleBandPower), birth: clock, serial: serial, peak: peak)
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
                        snapshot.spatialPoints.withUnsafeBufferPointer { points in
                            serial &+= 1
                            particles.add(input(field, points, snapshot.roleBandPower), birth: clock, serial: serial, peak: peak)
                        }
                    }
                } else {
                    for h in heard {
                        h.field.withUnsafeBufferPointer { field in
                            h.points.withUnsafeBufferPointer { points in
                                particles.add(input(field, points, h.power), birth: h.birth, serial: h.serial, peak: peak)
                            }
                        }
                    }
                }
            }
        } else if fresh || changed || remade || particles.frames.isEmpty {
            frame.snapshot.spatialField.withUnsafeBufferPointer { field in
                let input = RadiantParticles.Input(field: field, roleBandPower: frame.snapshot.roleBandPower,
                                                   speakers: particleSpeakers, shown: shown, layers: layers, spectral: spectral,
                                                   layerColors: layerColors, perBand: Int(n.particles), size: 1,
                                                   spread: Float(n.spread), floor: floor, range: Float(n.range))
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
        camera = RadiantCamera(originX: uniforms.originX, originY: uniforms.originY, scale: uniforms.scale,
                               sinElevation: uniforms.sinElevation, cosElevation: uniforms.cosElevation,
                               sinYaw: uniforms.sinYaw, cosYaw: uniforms.cosYaw, viewportX: uniforms.viewportX,
                               viewportY: uniforms.viewportY, pixels: camera.pixels, clock: clock, fade: lifetime / 3,
                               lifetime: lifetime, size: Radiant.size * Float(n.particleSize), blur: Radiant.blur * Float(n.blur),
                               minimum: Radiant.minimumPixels, depthFade: Radiant.depthFade, ochreR: ochre.x, ochreG: ochre.y,
                               ochreB: ochre.z, pass: 0, sparkSize: Radiant.sparkSize * Float(n.particleSize),
                               sparkFade: Radiant.sparkFade, sparkGain: Radiant.sparkGain * Float(n.sparkle))
        look = RadiantLook(sparkle: n.sparkle > 0 ? 1 : 0, glowNear: Radiant.glowNear, glowFar: Radiant.glowFar,
                           chroma: Radiant.chroma, hotFrom: Radiant.hotFrom, hotTo: Radiant.hotTo,
                           limit: Radiant.denseLimit, ease: Radiant.denseEase)
        // The composite covers the canvas: particles smear wherever they have been.
        uniforms.style = 1
        uniforms.gain = uniforms.opacity * Radiant.exposure * Radiant.presence(peak: peak, floor: floor)
        uniforms.spare = Radiant.bloom
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
            var i = 0
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
            let region = MTLRegionMake2D(0, 0, SpatialBody.azimuthSteps, SpatialBody.elevationSteps + 1)
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
        guard draw(into: offscreen, camera, lifetime: camera.lifetime) else { composite = nil; return }
        // The sparks: only the newest frames, at the canvas' own resolution, so they stay sharp. Drawn (cleared) even at
        // Sparkle 0, so the composite never reads what the texture held before.
        var spark = camera
        spark.pass = 1
        spark.pixels = Float(sparks.width) / max(1, camera.viewportX)
        spark.minimum = Radiant.sparkMinimumPixels
        guard draw(into: sparks, spark, lifetime: camera.sparkGain > 0 ? min(camera.lifetime, 4 * camera.sparkFade) : -1) else {
            composite = nil
            return
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
        guard glowTextures.count == 2, wideTextures.count == 2 else { return }
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
            var alpha = 1 - progress
            encoder.setRenderPipelineState(gpu.bodyComposite)
            encoder.setVertexBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 3)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        guard var quad = composite, let offscreen else { return }
        var alpha = progress
        encoder.setRenderPipelineState(quad.style > 0.5 ? gpu.radiantComposite : gpu.bodyComposite)
        encoder.setVertexBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<BodyUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 3)
        encoder.setFragmentTexture(offscreen, index: 0)
        if quad.style > 0.5 {
            var look = compositeLook
            encoder.setFragmentTexture(glowTextures.first ?? offscreen, index: 1)
            encoder.setFragmentTexture(wideTextures.first ?? offscreen, index: 2)
            encoder.setFragmentTexture(sparkTexture ?? offscreen, index: 3)
            encoder.setFragmentBytes(&look, length: MemoryLayout<RadiantLook>.stride, index: 1)
            if let meter {
                encoder.setFragmentBuffer(meter, offset: 0, index: 2)
            } else {
                var unmetered: [Float] = [0, 0]
                encoder.setFragmentBytes(&unmetered, length: 2 * MemoryLayout<Float>.stride, index: 2)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
    }

    // MARK: Pointer

    /// The displayed radius of `layer` toward (`azimuth`, `elevation`), degrees, interpolated as the shader's sampler
    /// interpolates the texture.
    func radius(layer: Int, azimuth: Double, elevation: Double) -> Float {
        let columns = SpatialBody.azimuthSteps, rows = SpatialBody.elevationSteps
        var a = (azimuth / SpatialBody.step).truncatingRemainder(dividingBy: Double(columns))
        if a < 0 { a += Double(columns) }
        let e = max(0, min(Double(rows), elevation / SpatialBody.step))
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
        if s.sinElevation > 0.001 { far = max(far, -y * s.cosElevation / s.sinElevation) } else if y < 0 { return nil }
        var t = half
        while t > far {
            defer { t -= 0.01 }
            let q = SIMD3(x, y * s.cosElevation + t * s.sinElevation, y * s.sinElevation - t * s.cosElevation)
            // Model coordinates (x right, y up, z front), then the field's frame (x right, y front, z up).
            let p = SIMD3(q.x * s.cosYaw - q.z * s.sinYaw, q.y, q.x * s.sinYaw + q.z * s.cosYaw)
            let rho = simd_length(p)
            guard rho > 0.01 else { continue }
            let d = SIMD3(p.x, p.z, p.y) / rho
            let azimuth = Double(atan2(d.x, d.y)) * 180 / .pi, elevation = Double(asin(max(0, min(1, d.z)))) * 180 / .pi
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
                         hue: tint(layer: layer, azimuth: azimuth, elevation: max(0, elevation), rho: rho),
                         decibels: Double(floor + value * -floor), azimuth: azimuth, elevation: elevation,
                         width: width, stability: stability, coherence: coherence, centroid: centroid)
    }

    /// Radiant: the particle the pointer is over, among the newest, and what it stands for: its band's centre frequency
    /// and level, where it sits, and the part of the field that pulls it there most (a speaker's own energy, a phantom
    /// image or energy out of phase).
    private func radiantProbe(at point: CGPoint) -> DomeProbe? {
        let s = uniforms
        func project(_ p: SIMD3<Float>) -> CGPoint {
            // The field's frame (x right, y front, z up) to model coordinates, then the camera.
            let m = SIMD3(p.x, p.z, p.y)
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
                         stability: r.stability.map(Double.init), coherence: r.coherence.map(Double.init), centroid: hz)
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
        check(radiant.particles.liveCount > 0 && radiant.uniforms.style == 1 && radiant.uniforms.gain > 0,
              "Radiant makes particles from the field")
        check(radiant.peak > -200 && radiant.peak <= 0, "Radiant's range hangs from the loudest band")
        check(look.nebula.rings.isEmpty, "Radiant has no level rings")
        check(radiant.camera.sparkGain > 0 && radiant.look.sparkle == 1 && radiant.camera.blur > 0,
              "new particles glint, older ones smear")
        look.nebula.sparkle = 0
        step(0)
        check(radiant.camera.sparkGain == 0 && radiant.look.sparkle == 0 && radiant.particles.liveCount > 0,
              "Sparkle 0 leaves only the glow")
        look.nebula.sparkle = 1
        step(0)
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
        check(radiant.uniforms.style == 1, "and back to Radiant")
        live.snapshot.spatialField[SpatialField.status] = 0
        for i in 0..<120 {
            live.snapshot.spatialField[SpatialField.threshold] = Float(i)
            step()
        }
        check(radiant.particles.liveCount == 0 && radiant.uniforms.bound == 0, "silence leaves no particles")

        // Radiant from the analysis' bins: each new frame added as heard; a change to how they are drawn remakes the
        // picture from the frames heard (not the newest repeated); frozen, it holds; a reset starts afresh.
        func withBins(_ snapshot: MeterSnapshot, _ shift: Float) -> MeterSnapshot {
            var s = snapshot
            s.spatialPoints[SpatialPoints.status] = 1
            for band in 0..<SpatialField.bandCount {
                var total: Float = 0
                for role in 0..<Role.count where role != Role.lfe { total += s.spatialField[SpatialField.independent(band: band, role: role)] }
                for slot in 0..<SpatialField.coherentSlots { total += s.spatialField[SpatialField.component(band: band, slot: slot)] }
                guard total > 0 else { continue }
                s.spatialPoints[SpatialPoints.count(band: band)] = 2
                for index in 0..<2 {
                    let o = SpatialPoints.point(band: band, index: index)
                    s.spatialPoints[o] = (index == 0 ? -0.3 : 0.3) + shift
                    s.spatialPoints[o + 1] = 0.8
                    s.spatialPoints[o + 3] = total / 2
                }
            }
            return s
        }
        let bins = NebulaScene(device: nil)
        var heard = CanvasFrame(running: true)
        heard.snapshot = withBins(DemoSignal.snapshot(at: 4.5, sequence: 135), 0)
        func hear(_ dt: Float = 1.0 / 60) {
            bins.update(frame: heard, geometry: geometry, dt: dt, displayDt: dt, options: look, presence: 1)
        }
        hear()
        check(bins.particles.frames.count == 1 && bins.particles.recent.last?.allSatisfy { abs(abs($0.position.x) - 0.3) < 1e-5 } == true,
              "the bins make one frame of particles where the bins are")
        for i in 1...5 {
            heard.snapshot = withBins(DemoSignal.snapshot(at: 4.5 + Double(i) / 30, sequence: 135 + i), Float(i) * 0.01)
            hear()
            hear()
        }
        check(bins.particles.frames.count == 6, "each new frame of bins adds one frame (\(bins.particles.frames.count))")
        let xs = Set(bins.particles.recent.joined().map { ($0.position.x * 1000).rounded() })
        look.nebula.particles = 12
        hear()
        check(bins.particles.frames.count == 6 && Set(bins.particles.recent.joined().map { ($0.position.x * 1000).rounded() }) == xs,
              "a change of how they are drawn remakes the frames heard")
        let still = bins.particles.version
        for _ in 0..<10 { hear(0) }
        check(bins.particles.version == still, "a frozen picture of bins holds still")
        heard.snapshot.streamID += 1
        hear()
        check(bins.particles.frames.count == 1, "a new stream starts afresh from what it hears")
        // Bit-identical steady audio still arrives at the analysis rate; display-only redraws add nothing.
        for _ in 0..<90 {
            heard.snapshot.spectrogramSerial += 1
            hear(1.0 / 30)
        }
        check(bins.particles.frames.count >= 14 && bins.particles.liveCount > 0,
              "steady measured audio remains visible beyond its persistence time")
        let steadyFrames = bins.particles.frames.count
        hear(0)
        check(bins.particles.frames.count == steadyFrames, "held measurement is not emitted twice")
        let ages = bins.heard.map(\.birth)
        look.domeBands = BandChoice(.five)
        hear(0)
        check(bins.heard.map(\.birth) == ages && bins.particles.frames.count == steadyFrames,
              "band switches preserve the measured history and its ages")
        let bodyEvaluations = bins.easedFrames
        heard.snapshot.spectrogramSerial += 1
        hear()
        check(bins.easedFrames == bodyEvaluations, "Radiant never uploads the unused level grid")
        // A held measured frame starts with the one observation available, not a fabricated trail.
        let heldScene = NebulaScene(device: nil)
        heldScene.update(frame: heard, geometry: geometry, dt: 0, displayDt: 0, options: look, presence: 1)
        check(heldScene.particles.frames.count == 1, "first frozen measurement has no invented past")
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
