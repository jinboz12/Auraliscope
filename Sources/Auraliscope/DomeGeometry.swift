import AnalysisCore
import Foundation

/// Where the Immersive dome is seen from (`DomeGeometry`): its turn about the vertical in degrees, kept continuous so a
/// glide always takes the short way round, the camera's height above the floor in degrees, and the zoom.
struct DomePose: Equatable {
    var turn: Double
    var elevation: Double
    var zoom: Double

    init(turn: Double, elevation: Double, zoom: Double) {
        self.turn = turn.isFinite ? turn : 0
        self.elevation = elevation.isFinite ? min(90, max(0, elevation)) : DomeGeometry.defaultPitch
        self.zoom = zoom.isFinite ? min(DomeGeometry.zoomRange.upperBound, max(DomeGeometry.zoomRange.lowerBound, zoom)) : 1
    }

    /// The pose a view stands for: the Dome view's own camera (`yaw`, `pitch`), the Top view turned by `yaw`, the other
    /// views' fixed cameras.
    init(view: DomeView, yaw: Double, pitch: Double, zoom: Double) {
        let camera = view.camera
        let height = camera?.pitch ?? (pitch.isFinite ? min(DomeGeometry.pitchRange.upperBound, max(DomeGeometry.pitchRange.lowerBound, pitch))
                                                      : DomeGeometry.defaultPitch)
        self.init(turn: view == .perspective || view == .top ? yaw : (camera?.yaw ?? 0), elevation: height, zoom: zoom)
    }

    /// The same pose, its turn moved by whole turns to lie within half a turn of `reference`.
    func near(_ reference: Double) -> DomePose {
        var pose = self
        pose.turn += 360 * ((reference - turn) / 360).rounded()
        return pose
    }
}

/// How the Immersive soundstage is looked at. The Dome view is free: dragged around and up or down. The other views
/// are fixed cameras: from behind the listener at ear height (Front), from above (Top), from the right (Side) and
/// isometric; dragging in Front, Top or Isometric continues in the Dome view from that camera.
enum DomeView: String, CaseIterable {
    case perspective, front, top, side, iso
    static let key = "soundstage.domeView"
    var title: String {
        switch self {
        case .perspective: return L("Dome")
        case .front: return L("Front view")
        case .top: return L("Top view")
        case .side: return L("Side view")
        case .iso: return L("Isometric view")
        }
    }
    /// For a row of segments.
    var short: String {
        switch self {
        case .perspective: return L("Dome")
        case .front: return L("Front")
        case .top: return L("Top")
        case .side: return L("Side")
        case .iso: return L("Iso")
        }
    }
    /// The camera a fixed view stands for, as the Dome view's yaw and height (degrees); nil for the Dome view itself.
    var camera: (yaw: Double, pitch: Double)? {
        switch self {
        case .perspective: return nil
        case .front: return (0, 0)
        case .top: return (0, 90)
        case .side: return (90, 0)
        case .iso: return (-45, 35.264)
        }
    }
}

/// The orthographic camera of the Immersive soundstage, shared by the Metal scene (grid, markers, the body) and the
/// SwiftUI labels. Model coordinates: x to the right, y up, z to the front, the speakers on the unit sphere around the
/// listener at the origin (the spatial field's frame, x right · y front · z up, with y and z swapped; `model`).
struct DomeGeometry {
    typealias Point = SIMD3<Double>
    /// The Dome view's camera height above the floor, in degrees; dragged vertically within `pitchRange`.
    static let defaultPitch = 24.0
    static let pitchRange = 8.0...78.0
    /// Zoom on the listener: the scroll wheel, a pinch or the panel's settings.
    static let zoomRange = 0.6...2.5
    /// Below this panel height the one-line key under the dome gives its room to the dome.
    static let footerMinimumHeight: CGFloat = 230
    static let footerHeight: CGFloat = 16
    /// The room the key's readings need beside the dome, in each lower corner of a wide panel.
    static let cornerKeyWidth: CGFloat = 116

    let size: CGSize
    let view: DomeView
    let yaw: Double
    let pitch: Double
    let zoom: Double
    let scale: Double
    let origin: CGPoint
    /// Where the key goes: in the lower corners beside the dome when the panel is wide enough, else on one line under
    /// it when the panel is tall enough, else nowhere.
    let keyInCorners: Bool
    let showsFooter: Bool
    let elevation: Double
    let sinElevation: Double
    let cosElevation: Double
    private let sinYaw: Double
    private let cosYaw: Double
    /// The yaw the camera actually turns by (degrees): the user's in the Dome and Top views, the view's own otherwise.
    let turn: Double
    /// The whole sphere is fitted (a speaker of the layout sits below the ear plane), not only the dome over the floor.
    let lower: Bool

    static func elevation(_ view: DomeView, pitch: Double = defaultPitch) -> Double {
        if let camera = view.camera { return camera.pitch * .pi / 180 }
        let p = pitch.isFinite ? min(pitchRange.upperBound, max(pitchRange.lowerBound, pitch)) : defaultPitch
        return p * .pi / 180
    }

    init(size: CGSize, view: DomeView = .perspective, yaw: Double = 0, pitch: Double = DomeGeometry.defaultPitch, zoom: Double = 1,
         lower: Bool = false) {
        // The top view keeps the yaw it is turned to; the other fixed views have their own.
        self.init(size: size, view: view, pose: DomePose(view: view, yaw: yaw, pitch: pitch, zoom: zoom), lower: lower)
    }

    /// The camera at `pose` (a glide passes through poses between views); `view` decides only the layout's choices
    /// (labels, the footprint, the key).
    init(size: CGSize, view: DomeView, pose: DomePose, lower: Bool = false) {
        self.size = size
        self.view = view
        self.lower = lower
        yaw = pose.turn
        pitch = pose.elevation
        zoom = pose.zoom
        elevation = pose.elevation * .pi / 180
        sinElevation = sin(elevation)
        cosElevation = cos(elevation)
        turn = pose.turn
        let a = turn * .pi / 180
        sinYaw = sin(a)
        cosYaw = cos(a)
        // Speaker labels sit just outside the shell (×1.12) and need half a label beyond that on every side; the
        // key, under the dome, takes one line below. The dome's projected span is 1 + sin(elevation) radii tall (a
        // side-on camera sees the whole sphere's height once heights rise above the floor).
        let w = Double(size.width), h = Double(size.height)
        let cramped = h < 160
        let top = cramped ? 6.0 : 12.0
        // With the lower hemisphere the whole sphere: one radius above the listener and one below, whatever the camera.
        let span = lower ? 2 : 1 + sinElevation
        func budget(footer: Bool) -> Double {
            max(1, h - top - (cramped ? 14.0 : 22.0) - (footer ? Double(Self.footerHeight) : 0))
        }
        func fit(footer: Bool) -> Double { max(1, min((w / 2 - 15) / 1.12, budget(footer: footer) / (span * 1.1))) }
        keyInCorners = !cramped && w / 2 - fit(footer: false) * 1.12 - 15 >= Double(Self.cornerKeyWidth)
        showsFooter = !keyInCorners && size.height >= Self.footerMinimumHeight
        let fitted = fit(footer: showsFooter)
        scale = fitted * self.zoom
        origin = CGPoint(x: size.width / 2, y: top + (budget(footer: showsFooter) - fitted * span) / 2 + fitted)
    }

    /// A direction in model coordinates (azimuth clockwise from the front, elevation up from the floor, degrees).
    static func direction(azimuth: Double, elevation: Double) -> Point {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        return Point(sin(a) * cos(e), sin(e), cos(a) * cos(e))
    }
    /// A speaker's position (`SpeakerGeometry`, the analysis' own table); nil for the LFE.
    static func direction(_ speaker: Speaker) -> Point? {
        guard let a = speaker.azimuth else { return nil }
        return direction(azimuth: a, elevation: SpeakerGeometry.elevation(role: speaker.role))
    }
    /// Where `role`'s speaker is drawn in model coordinates with `geometry`: its unit direction, or with `positions`
    /// (Radiant in the positions mapping) its position at the layout's scale, meters × `toModel`, the transform the
    /// observations get. Nil for the LFE and a speaker left out.
    static func speaker(_ role: Int, geometry: SpatialGeometry, positions: Bool, toModel: Double) -> Point? {
        if positions, let p = geometry.position(role: role) { return Point(p.x, p.z, p.y) * toModel }
        guard let d = geometry.direction(role: role) else { return nil }
        return Point(d.x, d.z, d.y)
    }
    /// The spatial field's frame (x right, y front, z up) in model coordinates.
    static func model(_ p: SIMD3<Float>) -> Point { Point(Double(p.x), Double(p.z), Double(p.y)) }

    func rotated(_ p: Point) -> Point {
        Point(p.x * cosYaw + p.z * sinYaw, p.y, p.z * cosYaw - p.x * sinYaw)
    }
    func project(_ p: Point) -> CGPoint {
        let q = rotated(p)
        return CGPoint(x: origin.x + q.x * scale, y: origin.y - (q.z * sinElevation + q.y * cosElevation) * scale)
    }
    /// Larger depth is nearer the camera. Do not confuse screen height with depth when sorting transparent shapes.
    func depth(_ p: Point) -> Double {
        let q = rotated(p)
        return q.y * sinElevation - q.z * cosElevation
    }
    /// The azimuth (degrees, model space) that points to the right of the screen on the floor, whatever the yaw.
    var screenRightAzimuth: Double { 90 - turn }

    /// The body shader's camera (`BodyUniforms` in Metal): the same projection as `project`, and the quad it covers,
    /// the dome's outline (the sphere above the floor's near edge) within the canvas.
    func bodyUniforms(opacity: Float, layers: Int, dark: Bool) -> BodyUniforms {
        let reach = CGFloat(scale) + 2
        let below = CGFloat(lower ? scale : scale * max(0, sinElevation)) + 2
        return BodyUniforms(minX: Float(max(0, origin.x - reach)), minY: Float(max(0, origin.y - reach)),
                            maxX: Float(min(size.width, origin.x + reach)), maxY: Float(min(size.height, origin.y + below)),
                            viewportX: Float(max(1, size.width)), viewportY: Float(max(1, size.height)),
                            originX: Float(origin.x), originY: Float(origin.y), scale: Float(scale),
                            sinElevation: Float(sinElevation), cosElevation: Float(cosElevation),
                            sinYaw: Float(sinYaw), cosYaw: Float(cosYaw), opacity: opacity, dark: dark ? 1 : 0,
                            layers: UInt32(max(0, layers)))
    }

    /// The mean square of a role in one of the five analysis bands, or (`band` −1) its full-band mean square.
    static func power(role: Int, band: Int, snapshot: MeterSnapshot) -> Float {
        guard (0..<Role.count).contains(role) else { return 0 }
        if (0..<StereoBands.count).contains(band) {
            let i = role * StereoBands.count + band
            guard i < snapshot.roleBandPower.count else { return 0 }
            let p = snapshot.roleBandPower[i]
            return p.isFinite ? max(0, p) : 0
        }
        let rms = snapshot.channelRMS[role]
        return rms.isFinite ? max(0, rms) * max(0, rms) : 0
    }
    /// The power-weighted balance point of the speakers: a summary, not a source position.
    static func centroid(layout: SpeakerLayout, active: [Bool], powers: [Float], geometry: SpatialGeometry? = nil,
                         positions: Bool = false, toModel: Double = 1) -> Point? {
        var sum = Point.zero, total = 0.0
        for speaker in layout.speakers {
            let place = geometry.map { DomeGeometry.speaker(speaker.role, geometry: $0, positions: positions, toModel: toModel) } ?? direction(speaker)
            guard let direction = place, active.indices.contains(speaker.role), active[speaker.role],
                  powers.indices.contains(speaker.role), powers[speaker.role].isFinite, powers[speaker.role] > 0 else { continue }
            let p = Double(powers[speaker.role])
            sum += direction * p
            total += p
        }
        return total > 1e-6 ? sum / total : nil
    }
}

/// The body shader's camera and quad, in canvas points (see `bodyVertex`): scalars only, so Swift and Metal agree on
/// the layout, 92 bytes.
struct BodyUniforms: Equatable {
    var minX: Float = 0
    var minY: Float = 0
    var maxX: Float = 0
    var maxY: Float = 0
    var viewportX: Float = 1
    var viewportY: Float = 1
    var originX: Float = 0
    var originY: Float = 0
    var scale: Float = 1
    var sinElevation: Float = 0
    var cosElevation: Float = 1
    var sinYaw: Float = 0
    var cosYaw: Float = 1
    var opacity: Float = 0
    var dark: Float = 1
    var layers: UInt32 = 0
    var bound: Float = 1
    /// 1 colours the full band by frequency (the band radii's texture), 0 each layer by its own colour.
    var spectral: Float = 0
    /// 1 lays the static grain over the glow, 0 leaves it smooth.
    var grain: Float = 0
    /// 1 draws Radiant (its particles, `radiantCompositeFragment`), 0 the level body (`bodyFragment`).
    var style: Float = 0
    /// Radiant: the light's gain in the composite.
    var gain: Float = 0
    var spare: Float = 0
    /// 1 marches the whole sphere (a speaker of the layout sits below the ear plane), 0 only above the floor.
    var lower: Float = 0
}

/// Radiant's camera and particle look (`RadiantCamera` in Metal): scalars only, 96 bytes.
struct RadiantCamera: Equatable {
    var originX: Float = 0
    var originY: Float = 0
    var scale: Float = 1
    var sinElevation: Float = 0
    var cosElevation: Float = 1
    var sinYaw: Float = 0
    var cosYaw: Float = 1
    var viewportX: Float = 1
    var viewportY: Float = 1
    /// Pixels of the target per canvas point.
    var pixels: Float = 1
    var clock: Float = 0
    /// Seconds per e-fold of a particle's fading, and how long it lasts.
    var fade: Float = 0.2
    var lifetime: Float = 0.5
    /// The haze: σ when born (radii, times each particle's own factor), the σ its smear adds over one second (radii;
    /// the variance grows with age), smallest σ (pixels).
    var size: Float = 0.011
    var blur: Float = 0.06
    var minimum: Float = 0.7
    var depthFade: Float = 0.25
    var ochreR: Float = 0.8
    var ochreG: Float = 0.6
    var ochreB: Float = 0.3
    /// 0 draws the haze, 1 the sparks: σ (radii, times each particle's own factor), seconds per e-fold of their fading,
    /// and their peak as a share of the particle's light.
    var pass: Float = 0
    var sparkSize: Float = 0.002
    var sparkFade: Float = 0.04
    var sparkGain: Float = 1
}

/// How Radiant's light is laid into the canvas (`RadiantLook` in Metal, `radiantCompositeFragment`): the sparks' share,
/// the near and wide glow's, the chroma added, the exposure over which the densest light burns toward white, and the
/// broad density (exposed) past which the exposure eases, and how much (0 not at all, 1 down to it). Then the level
/// body's palette (`Radiant.blend`…): how far a point's hue moves toward the hues heard around it, the grain's depth (0
/// none), the core's tint (cream on dark, ink on light), and whether that palette is used (1) or the light keeps its own
/// hues (0, the bare observations). Scalars only, 56 bytes.
struct RadiantLook: Equatable {
    var sparkle: Float = 1
    var glowNear: Float = 1
    var glowFar: Float = 0
    var chroma: Float = 1.35
    var hotFrom: Float = 1.5
    var hotTo: Float = 6
    var limit: Float = 2
    var ease: Float = 0
    var blend: Float = 0
    var grain: Float = 0
    var coreR: Float = 1
    var coreG: Float = 1
    var coreB: Float = 1
    var palette: Float = 1
}

/// The Radiant body's particle splat (`radiantSplatKernel`; Metal's `VolumeSplat`): the clock and how particles age
/// and fade, the variances of the fine and coarse volumes (radii²) and the smear's growth per second, the out-of-phase
/// tint, the cube's reach, the fixed-point scale and the faintest light added; the ring's segment and both grids' sizes.
struct VolumeSplat: Equatable {
    var clock: Float = 0
    var lifetime: Float = 0.5
    var fade: Float = 0.2
    var bornVariance: Float = 0
    var blurRate: Float = 0
    var coarseVariance: Float = 1
    var ochreR: Float = 0.8
    var ochreG: Float = 0.6
    var ochreB: Float = 0.3
    var reach: Float = 1
    var fixedScale: Float = 1
    var least: Float = 0
    var first: UInt32 = 0
    var count: UInt32 = 0
    var fineSize: UInt32 = 0
    var coarseSize: UInt32 = 0
}

/// One pass of a volume's separable blur (`radiantResolveKernel`, `radiantBlurKernel`; Metal's `VolumeBlur`): the
/// grid's side, the first row (y) it covers, the kernel's reach in voxels and σ, the scale from fixed-point sums to the
/// stored density, and the axis (1 y, 2 z; the resolve runs along x).
struct VolumeBlur: Equatable {
    var size: UInt32 = 0
    var firstRow: UInt32 = 0
    var radius: Int32 = 0
    var sigma: Float = 1
    var unit: Float = 1
    var axis: UInt32 = 0
}

/// The Radiant body's look (`radiantBodyFragment`; Metal's `RadiantBodyLook`), see `RadiantBody`.
struct RadiantBodyLook: Equatable {
    var reach: Float = 1
    var density: Float = 1
    var edgeFrom: Float = 0.02
    var edgeTo: Float = 0.2
    var base: Float = 0.3
    var absorb: Float = 0.5
    var chroma: Float = 1.3
    var shellFrom: Float = 0.95
    var wash: Float = 0.7
    var glow: Float = 1
}

/// The full band in `DomeGeometry.power`: the channel's RMS rather than one analysis band.
enum DomeBand {
    static let full = -1
}
