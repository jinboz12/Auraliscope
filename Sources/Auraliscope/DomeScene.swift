import AnalysisCore
import Metal
import SwiftUI
import simd

/// Render-only geometry around the Immersive nebula. Consumes the same snapshots for local capture and the result-only
/// Bridge path; no raw audio, transport changes, or work on the audio callback.
///
/// The body itself is `NebulaScene` (the spatial field's level per direction, ray-marched by the GPU), drawn first;
/// this scene draws what frames it, over it, as shapes: the hemisphere's grid with the level rings on the floor, the
/// body's footprint on the floor, the speakers, the LFE's level, the listener, the axes and the energy centroid. The
/// grid is built once per camera and scale.
final class DomeScene {
    private struct Key: Equatable {
        var size: CGSize
        var view: DomeView
        var yaw: Double
        var pitch: Double
        var zoom: Double
        var grid: Bool
        var floor: Double
        var ink: Theme.RGB
        var dark: Bool
        /// The lower hemisphere's grid too (a speaker below the ear plane); the meter rings' scale (the layout's
        /// largest distance, 0 without the positions mapping).
        var lower: Bool
        var metric: Double
        var rings: [Int]
    }
    private var key: Key?
    private var grid: [ShapeVertex] = []
    /// The camera as drawn: gliding with the labels after a view is picked or reset, following the hand otherwise.
    private var poseSpring = DomePoseSpring()
    private var drawTime: CFTimeInterval = 0
    private var drawCount = 0
    let nebula: NebulaScene
    /// Whether the nebula was updated this frame (it is encoded only then).
    private(set) var active = false
    /// The floor's unit directions at the body's azimuth steps, once round (model coordinates), for its footprint.
    /// The listener's head, in radii of the speakers' sphere (schematic: a real head is about 0.05 of a 2 m layout).
    static let headRadius = 0.075
    private static let floorDirections = (0...SpatialBody.azimuthSteps).map {
        DomeGeometry.direction(azimuth: Double($0) * SpatialBody.step, elevation: 0)
    }

    init(device: MTLDevice?) {
        nebula = NebulaScene(device: device)
    }

    private func buildGrid(_ g: DomeGeometry, key: Key, nebula n: NebulaSettings) {
        var b = ShapeBuilder(reserving: 4096)
        let ink = key.ink
        // The far side of the shell recedes: lines fade with depth, so the dome reads as a glass bell around the body.
        func segment(_ a: DomeGeometry.Point, _ c: DomeGeometry.Point, width: CGFloat, alpha: Float) {
            let near = Float((g.depth((a + c) / 2) + 1) / 2)
            b.line(g.project(a), g.project(c), width: width, ink.simd(alpha * (0.35 + 0.65 * near)))
        }
        func circle(radius: Double, elevation: Double = 0, width: CGFloat, alpha: Float) {
            for step in 0..<72 {
                segment(DomeGeometry.direction(azimuth: Double(step) * 5, elevation: elevation) * radius,
                        DomeGeometry.direction(azimuth: Double(step + 1) * 5, elevation: elevation) * radius, width: width, alpha: alpha)
            }
        }
        // The floor's rim always; the rest of the grid when asked for.
        circle(radius: 1, width: 1.1, alpha: 0.34)
        if key.grid {
            for elevation in [30.0, 60] { circle(radius: 1, elevation: elevation, width: 0.7, alpha: 0.15) }
            for azimuth in stride(from: 0.0, to: 360, by: 45) {
                for step in 0..<18 {
                    segment(DomeGeometry.direction(azimuth: azimuth, elevation: Double(step) * 5),
                            DomeGeometry.direction(azimuth: azimuth, elevation: Double(step + 1) * 5), width: 0.7, alpha: 0.15)
                }
            }
            // Below the ear plane, fainter, while a speaker of the layout is there: the picture reaches it too.
            if key.lower {
                for elevation in [-30.0, -60] { circle(radius: 1, elevation: elevation, width: 0.6, alpha: 0.09) }
                for azimuth in stride(from: 0.0, to: 360, by: 45) {
                    for step in 0..<18 {
                        segment(DomeGeometry.direction(azimuth: azimuth, elevation: -Double(step) * 5),
                                DomeGeometry.direction(azimuth: azimuth, elevation: -Double(step + 1) * 5), width: 0.6, alpha: 0.09)
                    }
                }
            }
            // In meters (Radiant, the positions mapping): a ring on the floor at every meter (every half meter for a
            // small layout), at the layout's fixed scale; labelled by `DomeLabels`.
            for meters in Self.meterRings(key.metric) {
                circle(radius: meters / key.metric, width: 0.6, alpha: 0.16)
            }
            // The level rings (every 20 dB, labelled in place by `DomeLabels`): concentric hairlines like the
            // stereometer's, brightest nearest the listener.
            for (index, decibels) in key.rings.reversed().enumerated() {
                circle(radius: Double(n.radius(decibels: Float(decibels))), width: 0.6, alpha: max(0.11, 0.2 - 0.04 * Float(index)))
            }
            segment(.zero, DomeGeometry.direction(azimuth: 0, elevation: 0), width: 0.7, alpha: 0.2)
        }
        // A chevron just inside the rim, pointing ahead.
        let tip = DomeGeometry.direction(azimuth: 0, elevation: 0) * 0.97
        for side in [-5.0, 5.0] {
            segment(DomeGeometry.direction(azimuth: side, elevation: 0) * 0.89, tip, width: 1.2, alpha: 0.45)
        }
        grid = b.shapes
    }

    /// Adds the dome's shapes to `b`, leaving the body's place under them (`ShapeBuilder.overlayStart`); `opacity` is
    /// the Immersive presence. `dt` moves the signal (0 while frozen), `displayDt` the camera, which glides even then.
    /// Draws the dome at `opacity`, its camera's zoom times `zoom` (Immersive arriving or leaving, `FormatMix.relay`).
    func draw(_ b: inout ShapeBuilder, frame: CanvasFrame, size: CGSize, dt: Float, displayDt: Float, opacity: Float, zoom: Double = 1) {
        let started = Diagnostics.enabled ? CACurrentMediaTime() : 0
        defer {
            if Diagnostics.enabled {
                drawTime += CACurrentMediaTime() - started; drawCount += 1
                if drawCount == 240 {
                    let times = nebula.takeTimes(), per = 1e6 / Double(drawCount)
                    Diagnostics.log(String(format: "[nebula] CPU per frame: %.1f µs (field %.1f, easing %.1f, upload %.1f), %d lobes in %d layers",
                                           drawTime * per, times.field * per, times.ease * per, times.upload * per,
                                           nebula.lobeCount, nebula.layerCount))
                    drawTime = 0; drawCount = 0
                }
            }
        }
        let options = frame.options
        let n = options.nebula
        var pose = poseSpring.step(target: options.cameraPose, glides: options.domeGlides, dt: Double(displayDt))
        pose.zoom *= zoom
        // The speakers and the observations share one transform: unit directions, or (Radiant, the positions mapping)
        // positions in meters at the layout's scale.
        let geometry = frame.geometry
        let positions = n.style == .radiant && geometry.mapping == .positions
        let extent = geometry.extent(roles: frame.layout.roles)
        let toModel = positions ? 1 / extent : 1
        let lower = geometry.reachesBelow(roles: frame.layout.roles)
        let g = DomeGeometry(size: size, view: options.domeView, pose: pose, lower: lower)
        let next = Key(size: size, view: g.view, yaw: g.yaw, pitch: g.pitch, zoom: g.zoom, grid: n.grid, floor: n.floor,
                       ink: Theme.inkRGB, dark: Theme.dark, lower: lower, metric: positions ? extent : 0, rings: n.rings)
        if key != next { key = next; buildGrid(g, key: next, nebula: n) }
        nebula.update(frame: frame, geometry: g, dt: dt, displayDt: displayDt, options: options, presence: opacity)
        active = true
        // The body goes first: the grid, its rings and every marker read over it, as lines through glass.
        let start = b.shapes.count
        b.overlayStart = start
        b.shapes.append(contentsOf: grid)
        let ink = Theme.inkRGB
        let origin = g.project(.zero)
        // The level body's footprint: how far it reaches over the floor in each direction at any height. In the Top view
        // it is the body's outline; in the Dome view it ties lobes in the air to their bearing. Radiant has none: its
        // particles sit where they are heard.
        if nebula.style == .level && g.view != .side && g.view != .front {
            let steps = SpatialBody.azimuthSteps, reach = nebula.footprint, tints = nebula.footprintTint
            let floor = Self.floorDirections
            let alpha: Float = nebula.layerCount == 1 ? 0.55 : 0.3
            for layer in 0..<nebula.layerCount {
                let base = layer * steps
                // Each stretch in the colour where the body reaches furthest above it (by frequency), or the layer's.
                for a in 0..<steps where max(reach[base + a], reach[base + (a + 1) % steps]) > 0.004 {
                    var color = nebula.colors[layer]
                    if nebula.spectral { color = Self.footprintColor(tints[base + a], tints[base + (a + 1) % steps]) }
                    color.w = alpha
                    b.line(g.project(floor[a] * Double(reach[base + a])), g.project(floor[a + 1] * Double(reach[base + (a + 1) % steps])),
                           width: 1, color)
                }
            }
        }
        if n.axes {
            // x right, y front, z up (the spatial field's frame), each 0.4 of the way to the speakers.
            for end in [DomeGeometry.Point(1, 0, 0), DomeGeometry.Point(0, 0, 1), DomeGeometry.Point(0, 1, 0)] {
                b.line(origin, g.project(end * 0.4), width: 1, ink.simd(0.55))
            }
        }
        if n.speakers {
            for speaker in frame.layout.speakers where speaker.group != .lfe {
                guard let d = DomeGeometry.speaker(speaker.role, geometry: geometry, positions: positions, toModel: toModel) else { continue }
                let near = Float((g.depth(d) + 1) / 2)
                let lit = frame.activeRoles.indices.contains(speaker.role) && frame.activeRoles[speaker.role]
                b.disk(g.project(d), radius: 2.2, Theme.displayRGB.simd(0.7 * (0.5 + 0.5 * near)))
                b.ring(g.project(d), radius: 2.6, width: 1, ink.simd((lit ? 0.62 : 0.2) * (0.5 + 0.5 * near)))
            }
        }
        // The listener: a head facing the front (its nose toward 0°, ears at ±90°), so the dome's front, sides and back
        // read at a glance from any view. Schematic size, the same in every mapping.
        let head = Self.headRadius * g.scale
        if n.listener {
            let r = Self.headRadius
            b.disk(origin, radius: head, Theme.displayRGB.simd(0.92))
            // Its equator on the ear plane: an ellipse that turns with the camera.
            for step in 0..<36 {
                let a = DomeGeometry.direction(azimuth: Double(step) * 10, elevation: 0) * r
                let c = DomeGeometry.direction(azimuth: Double(step + 1) * 10, elevation: 0) * r
                let near = Float((g.depth((a + c) / 2) / r + 1) / 2)
                b.line(g.project(a), g.project(c), width: 1, ink.simd(0.18 + 0.32 * near))
            }
            b.ring(origin, radius: head, width: 1.2, ink.simd(0.55))
            // Ears, dimmer when turned away from the camera.
            for side in [-1.0, 1.0] {
                let ear = DomeGeometry.Point(side * r * 1.04, 0, 0)
                let near = Float((g.depth(ear) / r + 1) / 2)
                b.disk(g.project(ear), radius: max(2, head * 0.2), ink.simd(0.25 + 0.45 * near))
            }
            // The nose: a wedge pointing to the front, seen through the head when it faces away from the camera.
            let tip = DomeGeometry.Point(0, 0, r * 1.45), left = DomeGeometry.Point(-r * 0.32, 0, r * 0.92)
            let right = DomeGeometry.Point(r * 0.32, 0, r * 0.92)
            let facing = Float((g.depth(tip) / (r * 1.45) + 1) / 2)
            let nose = ink.simd(0.35 + 0.55 * facing)
            b.line(g.project(left), g.project(tip), width: 1.6, nose)
            b.line(g.project(right), g.project(tip), width: 1.6, nose)
            b.line(g.project(left), g.project(right), width: 1, nose)
        }
        // The LFE has no direction: a ring around the listener whose sweep is its level on the body's scale.
        if n.lfe && frame.layout.hasLFE {
            let around = n.listener ? max(9, head * 1.6 + 4) : 9
            b.ring(origin, radius: around, width: 1, ink.simd(0.15))
            if nebula.lfeRadius > 0.001 { b.ring(origin, radius: around, width: 2, Theme.clayRGB.simd(0.85), sweep: nebula.lfeRadius) }
        }
        if !n.listener { b.disk(origin, radius: 2.1, ink.simd(0.8)) }
        if options.domeCentroid, let center = centroid(frame: frame, positions: positions, toModel: toModel) {
            // The stereometer's focal dot: one point where the energy centres, on a faint stem from the listener.
            let at = g.project(center)
            let lit = Theme.dark ? Theme.creamRGB : Theme.inkRGB
            b.line(origin, at, width: 0.75, ink.simd(0.3))
            b.disk(at, radius: 4.2, Theme.displayRGB.simd(0.85))
            b.disk(at, radius: 3, lit.simd(1))
        }
        b.fade(from: start, by: opacity)
    }

    /// A footprint stretch's colour by frequency: its two ends' colours at full brightness with the body's extra chroma
    /// (`bodyFragment`), deepened on the light well.
    private static func footprintColor(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD4<Float> {
        var c = (a + b) * 0.5
        c /= max(0.05, max(c.x, max(c.y, c.z)))
        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        c = simd_clamp(SIMD3(repeating: luma) + (c - SIMD3(repeating: luma)) * 1.45, .zero, SIMD3(repeating: 1))
        let rgb = Theme.RGB(r: c.x, g: c.y, b: c.z)
        return (Theme.dark ? rgb : rgb.legible(on: Theme.displayRGB, ratio: 3)).simd(1)
    }

    /// The meter rings of a layout `extent` meters across (none for 0): every meter, every half meter under 2 m.
    static func meterRings(_ extent: Double) -> [Double] {
        guard extent > 0 else { return [] }
        let step = extent < 2 ? 0.5 : 1.0
        return stride(from: step, through: extent + 1e-9, by: step).map { $0 }
    }

    /// The power-weighted balance point of the speakers for the bands shown (full band: each channel's RMS).
    private func centroid(frame: CanvasFrame, positions: Bool, toModel: Double) -> DomeGeometry.Point? {
        let choice = frame.options.domeBands
        var powers = [Float](repeating: 0, count: Role.count)
        for role in 0..<Role.count where frame.shown && frame.activeRoles[role] {
            if let solo = choice.solo, choice.resolution != .overall {
                powers[role] = choice.members(solo).reduce(0) { $0 + DomeGeometry.power(role: role, band: $1, snapshot: frame.snapshot) }
            } else {
                powers[role] = DomeGeometry.power(role: role, band: DomeBand.full, snapshot: frame.snapshot)
            }
        }
        return DomeGeometry.centroid(layout: frame.layout, active: frame.activeRoles, powers: powers, geometry: frame.geometry,
                                     positions: positions, toModel: toModel)
    }
}

/// What the pointer finds in the dome: the first point of the body along its line of sight.
struct DomeProbe: Equatable {
    /// What forms the body there most: a speaker's own energy, a coherent image, energy out of phase, or (fading)
    /// nothing measured now.
    enum Kind: Equatable { case speaker(String), image, unstable, none }
    var kind: Kind
    /// The layer's band range when the dome shows more than one band.
    var band: String?
    var hue: Theme.RGB
    /// The level the body shows in this direction (dBFS).
    var decibels: Double
    var azimuth: Double
    var elevation: Double
    /// Coherent images: their predicted perceived width (degrees), the share of their energy that arrives in phase,
    /// and their speakers' coherence (0–1).
    var width: Double?
    var stability: Double?
    var coherence: Double?
    /// The energy-weighted centre frequency (Hz) of what forms the body there most.
    var centroid: Double?
    /// With the positions mapping: how far from the listener the feeds' distribution puts it (meters), not a measured
    /// distance of a source.
    var meters: Double? = nil
    /// The centre of gravity is at the listener (opposite speakers in balance): it has no direction, and the angles mean
    /// nothing.
    var directionless = false
}

extension DomeScene {
    /// The body's reading at `point` (canvas points), for the last frame drawn.
    func probe(at point: CGPoint, layout: SpeakerLayout) -> DomeProbe? { nebula.probe(at: point, layout: layout) }
}

/// The pointer's reading over the body: with several bands, which band's body it is; the level the body shows in that
/// direction; what forms it there (a speaker's own energy, a coherent phantom image, or energy out of phase); the
/// bearing and height; and for an image how wide it is predicted to be heard, how much of it arrives in phase and how
/// coherent its speakers are. An estimate from the loudspeaker feeds, not a measured source position.
struct DomeProbeTag: View {
    let probe: DomeProbe
    @ObservedObject private var l10n = Localizer.shared
    var body: some View {
        let font = Font.caption2.weight(.medium).monospacedDigit()
        HStack(spacing: 5) {
            Circle().fill(probe.hue.color).frame(width: 6, height: 6)
            if let band = probe.band {
                Text(verbatim: band).font(font).foregroundStyle(Theme.ink)
            }
            Text(verbatim: MeterScale.tenths(Float(probe.decibels), floor: -120) + " dBFS").font(font).foregroundStyle(Theme.ink)
            switch probe.kind {
            case .speaker(let name):
                Text(verbatim: name).font(font.weight(.semibold)).foregroundStyle(Theme.sage)
            case .image:
                Text(L("Phantom")).font(font.weight(.semibold)).foregroundStyle(Theme.sage)
            case .unstable:
                Text(L("Out of phase")).font(font.weight(.semibold)).foregroundStyle(Theme.ochre)
            case .none:
                EmptyView()
            }
            if probe.directionless {
                Text(L("no direction")).font(font).foregroundStyle(Theme.secondary)
            } else {
                Text(verbatim: String(format: "↻ %@°", MeterScale.signedInteger(Float(probe.azimuth.rounded()))))
                    .font(font).foregroundStyle(Theme.secondary)
                Text(verbatim: String(format: "↑ %d°", Int(probe.elevation.rounded()))).font(font).foregroundStyle(Theme.secondary)
            }
            if let width = probe.width {
                // Frank's regression, from frontal pairs: an estimate elsewhere.
                Text(L("width %d° (frontal model)", Int(width.rounded()))).font(font).foregroundStyle(Theme.secondary)
            }
            if let stability = probe.stability, let coherence = probe.coherence {
                Text(L("in phase %d%%", Int((stability * 100).rounded()))).font(font).foregroundStyle(Theme.secondary)
                Text(L("coherence %.2f", coherence)).font(font).foregroundStyle(Theme.secondary)
            }
            if let meters = probe.meters, meters.isFinite {
                Text(L("%@ m, distribution", String(format: "%.2f", meters))).font(font).foregroundStyle(Theme.secondary)
            }
            if let centroid = probe.centroid, centroid.isFinite {
                Text(L("centre %@", centroid >= 1_000 ? String(format: "%.1f kHz", centroid / 1_000) : "\(Int(centroid.rounded())) Hz"))
                    .font(font).foregroundStyle(Theme.secondary)
            }
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background { BadgeSurface() }
    }
}

/// The dome's labels for the window's camera (`DomeCamera`). Only this observes the camera, so a drag, a pinch or a
/// glide re-renders the labels and nothing else of the panel.
struct DomeLabelsHost: View {
    let size: CGSize
    let layout: SpeakerLayout
    let options: DisplayOptions
    /// The geometry the dome is drawn with (`MeterModel.displayGeometry`).
    var geometry: SpatialGeometry? = nil
    /// The camera's zoom times this: the dome settling in as Immersive arrives (`FormatMix.relay`), as `DomeScene` draws it.
    var zoom: Double = 1
    @ObservedObject private var camera = DomeCamera.shared

    var body: some View {
        var pose = camera.state.pose
        pose.zoom *= zoom
        return DomeLabels(size: size, layout: layout, options: options, view: camera.state.settings.view, pose: pose,
                          geometry: geometry ?? SpatialGeometry.standard(roles: layout.roles))
    }
}

/// The dome's speaker names, ring levels, front and axes, placed by the Metal scene's own projection. SwiftUI animates
/// the pose (a glide between views turns the labels with the dome, along the same spring as `DomeScene`), and the
/// labels are drawn into one canvas, so moving them is a redraw rather than a new layout of many views.
struct DomeLabels: View, Animatable {
    let size: CGSize
    let layout: SpeakerLayout
    let options: DisplayOptions
    let view: DomeView
    var pose: DomePose
    var geometry: SpatialGeometry
    @ObservedObject private var l10n = Localizer.shared

    /// The speakers' transform, as `DomeScene` draws them.
    private var positions: Bool { options.nebula.style == .radiant && geometry.mapping == .positions }
    private var extent: Double { geometry.extent(roles: layout.roles) }
    private func point(_ speaker: Speaker) -> DomeGeometry.Point? {
        DomeGeometry.speaker(speaker.role, geometry: geometry, positions: positions, toModel: positions ? 1 / extent : 1)
    }

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { pose.animatableData }
        set { pose.animatableData = newValue }
    }

    private struct Label { var text: String; var point: CGPoint; var quiet = false }
    private func labels(_ g: DomeGeometry) -> [Label] {
        var result: [Label] = []
        var occupied: [CGRect] = []
        func place(_ text: String, _ point: CGPoint, width: CGFloat, quiet: Bool = false) {
            let rect = CGRect(x: point.x - width / 2, y: point.y - 6, width: width, height: 12)
            guard rect.minX >= 2 && rect.maxX < size.width - 2 && rect.minY > 2 && rect.maxY < size.height - 2
                    && !occupied.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) }) else { return }
            result.append(Label(text: text, point: point, quiet: quiet)); occupied.append(rect)
        }
        let n = options.nebula
        // The level rings carry their dBFS values where they cross the floor at the right of the screen, outermost
        // first; in a cramped well the inner ones keep their lines and give up their labels.
        if n.grid && g.view != .side && g.view != .front {
            let right = g.screenRightAzimuth
            for decibels in n.rings {
                let radius = Double(n.radius(decibels: Float(decibels)))
                guard g.scale >= 48 || radius > 0.5 else { continue }
                var point = g.project(DomeGeometry.direction(azimuth: right, elevation: 0) * radius)
                point.y += g.view == .top ? 0 : 7
                point.x += g.view == .top ? 0 : 2
                place(MeterScale.signedInteger(Float(decibels)), point, width: 22, quiet: true)
            }
        }
        // The meter rings (Radiant, the positions mapping), where they cross the floor at the right of the screen.
        if n.grid && positions && g.view != .side && g.view != .front {
            let right = g.screenRightAzimuth
            for meters in DomeScene.meterRings(extent) {
                var point = g.project(DomeGeometry.direction(azimuth: right, elevation: 0) * (meters / extent))
                point.y += g.view == .top ? 0 : 7
                point.x += g.view == .top ? 0 : 2
                place(meters.rounded() == meters ? "\(Int(meters)) m" : String(format: "%.1f m", meters), point, width: 30, quiet: true)
            }
        }
        // The front: a chevron on the floor marks it (`DomeScene`); the word is added only when no centre speaker
        // names that direction already, or when the view looks along the front.
        if g.view == .side || g.view == .front || !n.speakers || !layout.speakers.contains(where: { $0.azimuth == 0 && $0.group != .height }) {
            var front = g.project(DomeGeometry.direction(azimuth: 0, elevation: 0) * 1.13)
            front.y += g.view == .side ? 9 : -6
            place(L("FRONT"), front, width: 40)
        }
        if n.axes {
            for end in [DomeGeometry.Point(1, 0, 0), DomeGeometry.Point(0, 0, 1), DomeGeometry.Point(0, 1, 0)] {
                var point = g.project(end * 0.46)
                point.y -= 1
                place(end.x > 0 ? "x" : (end.z > 0 ? "y" : "z"), point, width: 10, quiet: true)
            }
        }
        guard n.speakers else { return result }
        // Nearer speakers first: when labels collide at small sizes, the ones in front of the dome win.
        let speakers = layout.speakers.compactMap { speaker in point(speaker).map { (speaker, $0) } }
            .sorted { g.depth($0.1) > g.depth($1.1) }
        for (speaker, d) in speakers {
            let anchor = g.project(d)
            var point = g.project(d * 1.12)
            // Push the label away from the dome's centre on screen, so it never sits on the shell line.
            let dx = point.x - g.origin.x, dy = point.y - (g.origin.y - g.scale * 0.35)
            let length = max(1, sqrt(dx * dx + dy * dy))
            point.x += dx / length * 6
            point.y += dy / length * 6 + (anchor.y <= g.origin.y ? -2 : 3)
            place(speaker.name, point, width: CGFloat(speaker.name.count) * 6.5 + 6)
        }
        return result
    }

    var body: some View {
        let g = DomeGeometry(size: size, view: view, pose: pose, lower: geometry.reachesBelow(roles: layout.roles))
        let lfe = layout.hasLFE && options.nebula.lfe
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for label in labels(g) {
                    context.draw(Text(verbatim: label.text).font(.axis).foregroundColor(label.quiet ? Theme.tertiary : Theme.secondary),
                                 at: label.point)
                }
                if lfe {
                    context.draw(Text(verbatim: "LFE").font(.axis).foregroundColor(Theme.tertiary),
                                 at: CGPoint(x: g.origin.x - 24, y: g.origin.y + (g.view == .side || g.view == .front ? -8 : 6)))
                }
            }
            if g.showsFooter {
                NebulaKey(choice: options.domeBands, nebula: options.nebula)
                    .frame(width: size.width - 16).position(x: size.width / 2, y: size.height - 11)
            } else if g.keyInCorners {
                NebulaCornerKey(choice: options.domeBands, nebula: options.nebula)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(width: size.width, height: size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

extension DomeLabels {
    private var accessibility: String {
        let n = options.nebula
        if n.style == .radiant {
            return L("A glowing body of the speaker feeds' frequency bands, each where its band is heard: at the centre of gravity of the speakers that carry it, weighted by its level in each. A centred phantom gathers between two speakers, a wide stereo programme stretches along the line between them, sound all round gathers toward the listener. The loudest band burns white and quieter ones fade out %d dB below it; older light swells into haze. Point lights mark exactly where each band's frequencies sit. Energy out of phase is tinted ochre. Speakers stand where the speaker layout puts them (the standard one puts every height at 45 degrees).", Int(n.range.rounded()))
                + (n.spectral(options.domeBands) ? " " + L("The body wears the colors of the frequencies at each place, warm for bass and cool for treble; where many bands meet, their light adds up toward white.") : "")
        }
        return L("Spatial energy body of the speaker feeds. Its radius in each direction is the level heard from there, from %@ dBFS at the listener to 0 dBFS at the speakers, not a distance. Energy several speakers carry coherently points between them; energy out of phase is tinted ochre. Speakers stand where the speaker layout puts them (the standard one puts every height at 45 degrees).", MeterScale.signedInteger(Float(n.floor)))
            + (n.spectral(options.domeBands) ? " " + L("Its color shows the frequencies heard from each direction: near the listener every band mixes toward white, near the edge only the loudest bands remain, warm for bass and cool for treble.") : "")
    }
}

/// The nebula's key beside the dome in a wide panel: in the lower corners, name-over-value readings like the
/// stereometer's (the bands' hues on the left when the dome shows several, the radius' or glow's scale on the right).
/// What direction and tint mean is left to the accessibility description, so the corners above stay clear.
struct NebulaCornerKey: View {
    let choice: BandChoice
    let nebula: NebulaSettings
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                if choice.groups.count > 1 || nebula.spectral(choice) {
                    reading(L("FREQUENCY"), alignment: .leading) { NebulaKey(choice: choice, nebula: nebula, part: .bands) }
                }
                Spacer(minLength: 0)
                reading(nebula.style == .radiant ? L("GLOW = LEVEL") : L("RADIUS = LEVEL"), alignment: .trailing) {
                    NebulaKey(choice: choice, nebula: nebula, part: .scale)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func reading<Content: View>(_ name: String, alignment: HorizontalAlignment, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(name).font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(l10n.tracking(Tracking.eyebrow))
                .foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
            content()
        }
    }
}

/// The nebula's key, one line under it: the bands' hues (when the dome shows several) and the radius' scale in dBFS,
/// the hues left out when the panel is too narrow.
struct NebulaKey: View {
    let choice: BandChoice
    let nebula: NebulaSettings
    /// One part alone (the corner key's), or the whole line.
    enum Part { case line, bands, scale }
    var part = Part.line
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        switch part {
        case .bands: bands
        case .scale:
            if nebula.style == .radiant {
                glowScale
            } else {
                Text(L("%@ to 0 dBFS", floorText)).font(.axis).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
            }
        case .line:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { bands; scaleLine }
                scaleLine
            }
        }
    }

    private var floorText: String { MeterScale.signedInteger(Float(nebula.floor)) }

    /// Low to high, the hue of each band drawn; coloured by frequency, the spectral scale itself.
    @ViewBuilder private var bands: some View {
        if nebula.spectral(choice) {
            HStack(spacing: 4) {
                Text(verbatim: "20 Hz").font(.axis).foregroundStyle(Theme.tertiary)
                SpectralScaleBar().frame(width: 46, height: 5)
                Text(verbatim: "20 kHz").font(.axis).foregroundStyle(Theme.tertiary)
            }
            .fixedSize()
        } else if choice.groups.count > 1 {
            HStack(spacing: 3) {
                Text(verbatim: "20 Hz").font(.axis).foregroundStyle(Theme.tertiary)
                ForEach(choice.groups, id: \.self) { group in
                    Circle().fill(Theme.bandColor(choice.resolution, group)).frame(width: 5, height: 5)
                }
                Text(verbatim: "20 kHz").font(.axis).foregroundStyle(Theme.tertiary)
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var scaleLine: some View {
        if nebula.style == .radiant {
            HStack(spacing: 4) {
                Text(L("Glow = level")).font(.axis).foregroundStyle(Theme.tertiary)
                glowScale
            }
            .fixedSize()
        } else {
            Text(L("Radius = level, %@ to 0 dBFS", floorText)).font(.axis).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
        }
    }

    /// Radiant's brightness over its range: from the range's foot to the loudest direction, as the glow looks seen
    /// straight through it.
    private var glowScale: some View {
        HStack(spacing: 4) {
            Text(verbatim: "−\(Int(nebula.range.rounded())) dB").font(.axis).foregroundStyle(Theme.tertiary)
            GlowScaleBar().frame(width: 40, height: 5)
            Text(L("loudest")).font(.axis).foregroundStyle(Theme.tertiary)
        }
        .lineLimit(1).fixedSize()
    }

}

/// Radiant's brightness over its glow range as a small capsule, from the range's foot to the loudest direction: on
/// the dark well light rising out of it, on the light one a wash deepening toward ink.
struct GlowScaleBar: View {
    var body: some View {
        let ink = Theme.dark ? Theme.creamRGB : Theme.inkRGB
        let stops = stride(from: 0.0, through: 1.0, by: 0.125).map { at in
            Gradient.Stop(color: ink.color.opacity(Double(Radiant.seen(Float(at - 1)))), location: at)
        }
        Capsule().fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            .overlay { Capsule().strokeBorder(Theme.hairline.opacity(0.5), lineWidth: 0.5) }
    }
}

/// The spectral scale as a small capsule: the five band hues at their bands' centres along log frequency, 20 Hz to
/// 20 kHz, as the Immersive nebula mixes them.
struct SpectralScaleBar: View {
    var body: some View {
        let low = log2(20.0), span = log2(20_000.0) - low
        let stops = SpectralHue.centres.enumerated().map { band, centre in
            Gradient.Stop(color: Theme.bandColor(band), location: (centre - low) / span)
        }
        Capsule().fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
    }
}
