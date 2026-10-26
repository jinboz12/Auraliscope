import AnalysisCore
import MetalKit

// MARK: - Soundstage: the top-down room, and the Channel Levels panel (vertical meters and correlation)

/// One class for both wells of the right-hand column, so they share the presence springs, peak holds and over
/// latches' logic; `part` picks what it draws.
final class SoundstageScene: CanvasScene {
    let part: SoundstageLayout.Part
    init(part: SoundstageLayout.Part, device: MTLDevice? = nil) {
        self.part = part
        dome = DomeScene(device: part == .room ? device : nil)
    }

    private let dome: DomeScene
    private var holds = [Float](repeating: -120, count: Role.count)
    private var holdTimers = [Float](repeating: 0, count: Role.count)
    private var clipped = [Bool](repeating: false, count: Role.count)
    /// Highest true peak per role since the last reset, linear: above 1 it is an over, drawn in the over zone.
    private var overPeaks = [Float](repeating: 0, count: Role.count)
    private var peakDb = [Float](repeating: -120, count: Role.count)
    private var rmsDb = [Float](repeating: -120, count: Role.count)
    private var epoch = -1
    private var truePeakEpoch = 0
    /// Frames left in which the snapshot's held true peaks may still predate a true-peak reset.
    private var truePeakGrace = 0
    private var peakSequence: Float = -1
    private var peakStream: Float = -1
    /// The DSP's held sample peaks when the overs were last cleared: a held peak re-lights a clip light only
    /// once it rises past this, so clearing the lights (a click on one, or on TRUE PEAK) sticks until a new over.
    private var heldBaseline = [Float](repeating: 0, count: Role.count)
    private var spring = PresenceSpring()
    private var presence: Float { spring.value }
    private var monoSpring = PresenceSpring()
    /// The band switch of this well: the Soundstage's resolution for the room, the correlation bar's for levels.
    private var bands = BandTransition()
    private var mono: Float { monoSpring.value }
    /// Bed and height speakers of the current layout, clockwise from centre front, for the image polygons.
    private var cachedLayout: SpeakerLayout?
    private var bed: [Speaker] = []
    private var heights: [Speaker] = []
    /// Lowest recent correlation (nil in silence): held 2 s, then it follows the reading back up.
    private var correlationLow: Float?
    private var correlationLowTimer: Float = 0
    /// The stereometer's newest clouds (`MeterSnapshot.bandPoints`) with the time each arrived, newest first, and
    /// the snapshot the newest came from.
    private var clouds: [(points: [Float], time: CFTimeInterval)] = []
    private var cloudSequence: Float = -1
    /// The time the clouds age against: the last live frame's.
    private var cloudClock: CFTimeInterval = 0
    /// A dot's opacity halves about every 50 ms, so a sample glows briefly and trails off like phosphor.
    private static let cloudDecay: CFTimeInterval = 0.07
    private static let cloudLife: CFTimeInterval = 0.16
    /// At most this many clouds are drawn, whatever the snapshot rate: each is a glow per sample and band group, and
    /// six keep a band switch's two groupings (up to eight groups) well inside the vertex buffer.
    private static let cloudGenerations = 6
    /// Outline and Filled styles: per published band group (`StereoBands.groups`), how far its samples reach at
    /// each of `envelopeBins` directions across the half disc, as a scope fraction. Rises at once, falls over
    /// about a quarter second, so the shape holds still enough to read.
    private static let envelopeBins = 48
    private var envelopes = [[Float]](repeating: [Float](repeating: 0, count: 48), count: StereoBands.groups.count)
    private var envelopeStyle = StageStyle.dots

    // No underlay: the Immersive nebula's body is the room's overlay (`NebulaScene`), drawn under the dome's grid and
    // speakers; the Channel Levels well draws shapes only.
    var underlayKind: UnderlayKind { .waterfall }
    var underlayTexture: MTLTexture? { nil }
    var underlayState: UnderlayState { UnderlayState() }
    /// Whether the dome (and so the nebula) was drawn this frame.
    private var domeDrawn = false
    /// What the pointer finds in the Immersive nebula (`DomeScene.probe`).
    func domeProbe(at point: CGPoint, layout: SpeakerLayout) -> DomeProbe? {
        part == .room ? dome.probe(at: point, layout: layout) : nil
    }
    func encodeOverlay(_ encoder: MTLRenderCommandEncoder, gpu: MeterGPU) {
        guard part == .room, domeDrawn else { return }
        dome.nebula.encode(encoder, gpu: gpu)
    }
    func encodeOffscreen(_ command: MTLCommandBuffer, gpu: MeterGPU, pixels: CGSize) {
        guard part == .room, domeDrawn else { return }
        dome.nebula.encodeOffscreen(command, gpu: gpu, pixels: pixels)
    }

    func prepare(frame: CanvasFrame) {
        if frame.epoch != epoch {
            epoch = frame.epoch
            holds = Array(repeating: -120, count: Role.count)
            clipped = Array(repeating: false, count: Role.count)
            overPeaks = Array(repeating: 0, count: Role.count)
            heldBaseline = Array(repeating: 0, count: Role.count)
            correlationLow = nil
            peakSequence = -1
            peakStream = -1
        }
        if frame.truePeakEpoch != truePeakEpoch {
            truePeakEpoch = frame.truePeakEpoch
            overPeaks = Array(repeating: 0, count: Role.count)
            clipped = Array(repeating: false, count: Role.count)
            heldBaseline = frame.snapshot.heldPeaks
            truePeakGrace = 12
            peakSequence = frame.snapshot.sequence
            peakStream = frame.snapshot.streamID
        }
        // The DSP-held peaks catch an over even in a snapshot this canvas never drew. A true peak above 0 dBTP is
        // an over, like a sample at full scale. Right after a true-peak reset the held values in flight are skipped.
        let snapshot = frame.snapshot
        // A reset while paused clears the frozen frame too. Only new audio may light the warning again;
        // drawing the same snapshot repeatedly is not a new peak or progress through the grace period.
        guard frame.running, snapshot.sequence != peakSequence || snapshot.streamID != peakStream else { return }
        peakSequence = snapshot.sequence
        peakStream = snapshot.streamID
        let held = truePeakGrace == 0
        if truePeakGrace > 0 { truePeakGrace -= 1 }
        for role in 0..<Role.count {
            overPeaks[role] = max(overPeaks[role], snapshot.channelTruePeaks[role], held ? snapshot.heldTruePeaks[role] : 0)
            let heldPeak = snapshot.heldPeaks[role] > heldBaseline[role] ? snapshot.heldPeaks[role] : 0
            if max(snapshot.channelPeaks[role], heldPeak, overPeaks[role]) >= 1 { clipped[role] = true }
        }
    }

    private static func clockwise(_ speakers: [Speaker]) -> [Speaker] {
        speakers.sorted { (($0.azimuth ?? 0) + 360).truncatingRemainder(dividingBy: 360) < (($1.azimuth ?? 0) + 360).truncatingRemainder(dividingBy: 360) }
    }

    func build(_ b: inout ShapeBuilder, frame: CanvasFrame, display: MeterSnapshot, size: CGSize, dt: Float) {
        if cachedLayout != frame.layout {
            cachedLayout = frame.layout
            bed = Self.clockwise(frame.layout.speakers.filter { $0.group == .front || $0.group == .surround })
            heights = Self.clockwise(frame.layout.speakers.filter { $0.group == .height })
        }
        spring.step(target: frame.spatial ? 1 : 0, dt: dt)
        monoSpring.step(target: frame.mono ? 1 : 0, dt: dt)
        bands.step(target: part == .room ? frame.stageBands : frame.levelsBands, dt: dt)
        let layout = SoundstageLayout(size: size, presence: CGFloat(presence), mono: CGFloat(mono), layout: frame.layout, part: part,
                                      lanes: part == .levels ? bands.lanes : CGFloat(StereoBands.count))

        // The springs above move the layout even while frozen; holds, trails and envelopes below do not.
        let signalDt = frame.signal(dt)
        for role in 0..<Role.count {
            peakDb[role] = MeterScale.decibels(display.channelPeaks[role])
            rmsDb[role] = MeterScale.decibels(display.channelRMS[role])
            if peakDb[role] >= holds[role] {
                holds[role] = peakDb[role]
                holdTimers[role] = frame.options.levelsHold.seconds ?? .infinity
            } else if holdTimers[role] > 0 {
                holdTimers[role] -= signalDt
            } else {
                holds[role] = max(-120, holds[role] - frame.options.levelsRelease.decibelsPerSecond * signalDt)
            }
        }
        domeDrawn = false
        switch part {
        case .room:
            // Stereo and Mono show the stereometer, Immersive the dome: one hands over to the other (`FormatMix.relay`),
            // the stereometer swelling a little as it leaves, the dome settling in from a little farther away.
            let relay = FormatMix.relay(CGFloat(presence))
            if relay.dome > 0.001 {
                dome.draw(&b, frame: frame, size: size, dt: signalDt, displayDt: dt, opacity: Float(relay.dome), zoom: relay.domeZoom)
                domeDrawn = true
            }
            updateCloud(frame)
            if relay.stereo > 0.001 {
                let start = b.shapes.count
                drawStereometer(&b, layout: layout, display: display, running: frame.shown, style: frame.stageStyle, dt: signalDt,
                                layers: shownLayers(frame), focus: focusGroup(frame))
                b.fade(from: start, by: Float(relay.stereo))
                b.scale(from: start, by: relay.stereoScale, around: layout.scopeCenter)
            }
        case .levels:
            drawMeters(&b, layout: layout, frame: frame)
            drawCorrelation(&b, layout: layout, display: display, running: frame.shown, dt: signalDt, layers: bands.layers)
        }
    }

    /// L always reads at full strength, R recedes in Mono, every other role follows the Spatial presence.
    private func visibility(_ role: Int) -> Float {
        role == Role.left ? 1 : (role == Role.right ? presence + (1 - presence) * (1 - mono) : presence)
    }


    /// The stereometer's band layers, each with the groups it draws: all of them, or the single band chosen on the
    /// BANDS menu. A single band applies to its own split; an outgoing split keeps all its bands while it fades.
    private func shownLayers(_ frame: CanvasFrame) -> [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])] {
        bands.layers.map { layer in
            let all = Array(0..<layer.resolution.count)
            guard let solo = frame.options.stageSolo, layer.resolution == frame.stageBands, solo < layer.resolution.count else {
                return (layer.resolution, layer.weight, all)
            }
            return (layer.resolution, layer.weight, [solo])
        }
    }

    /// The published band group the focal point follows: the band shown alone, or the whole programme.
    private func focusGroup(_ frame: CanvasFrame) -> Int {
        guard let solo = frame.options.stageSolo, solo < frame.stageBands.count else { return StereoBands.Resolution.overall.offset }
        return frame.stageBands.offset + solo
    }

    /// A stereometer sample in Mono: R follows L as the mode folds, so the programme stands on M.
    private func folded(_ left: Float, _ right: Float) -> Float { right + (left - right) * mono }

    /// Keeps the clouds of the last `cloudLife` seconds; each fades with its age, frame by frame. Frozen, the
    /// clouds and their clock stand still, so the trail holds as it was.
    private func updateCloud(_ frame: CanvasFrame) {
        guard frame.shown else {
            clouds.removeAll()
            return
        }
        guard frame.running else { return }
        let now = CanvasDriver.now
        cloudClock = now
        let snapshot = frame.snapshot
        if snapshot.sequence != cloudSequence {
            cloudSequence = snapshot.sequence
            clouds.insert((snapshot.bandPoints, now), at: 0)
        }
        clouds.removeAll { now - $0.time > Self.cloudLife }
        if clouds.count > Self.cloudGenerations { clouds.removeLast(clouds.count - Self.cloudGenerations) }
    }

    /// Stereometer, in Stereo: a polar sample plot in a half disc, like a hardware goniometer turned into polar
    /// form. Every sample of the newest 1/30 s is a dot at its angle between L and R (mid straight up, side
    /// sideways, out of phase along the horizon) and at its level from the centre (−60 dBFS) to the rim (0 dBFS),
    /// coloured by its `StereoBands` band: a narrow, centred bass reads as a warm spike toward M, a wide top end as
    /// a cool fan. Around the rim, one arc per band sums the band up: centred where its energy sits between L and
    /// R, spread by its decorrelation (a point for mono or panned, the L–R span for unrelated sides, on toward the
    /// horizon as it goes out of phase), bright with its level.
    private func drawStereometer(_ b: inout ShapeBuilder, layout: SoundstageLayout, display: MeterSnapshot, running: Bool,
                                 style: StageStyle, dt: Float,
                                 layers: [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])], focus: Int) {
        let ink = Theme.inkRGB
        let c = layout.scopeCenter
        func arc(from: Double, to: Double, fraction: CGFloat, width: CGFloat, _ color: SIMD4<Float>) {
            let steps = max(2, Int(abs(to - from) / 4))
            var previous = layout.scopePoint(angle: from, fraction: fraction)
            for step in 1...steps {
                let point = layout.scopePoint(angle: from + (to - from) * Double(step) / Double(steps), fraction: fraction)
                b.line(previous, point, width: width, color)
                previous = point
            }
        }
        // Field: the plate itself, no toned screen. Level rings every 12 dB as concentric hairlines, brightest
        // nearest the listener and fading outward, the full-scale rim held a touch firmer; L, M and R as faint
        // spokes, so the rings and the signal carry the picture.
        let dark = Theme.dark
        let rings: [Float] = [-48, -36, -24, -12]
        for (index, db) in rings.enumerated() {
            arc(from: -90, to: 90, fraction: SoundstageLayout.scopeFraction(decibels: db), width: 0.75,
                ink.simd((dark ? 0.30 : 0.26) - Float(index) * (dark ? 0.045 : 0.04)))
        }
        arc(from: -90, to: 90, fraction: 1, width: 0.9, ink.simd(dark ? 0.24 : 0.22))
        b.line(layout.scopePoint(angle: -90, fraction: 1), layout.scopePoint(angle: 90, fraction: 1), width: 0.75, ink.simd(0.14))
        for angle in [-45.0, 0, 45] {
            b.line(c, layout.scopePoint(angle: angle, fraction: 1), width: 0.75, ink.simd(angle == 0 ? 0.12 : 0.07))
        }

        // Rims: a hairline track per band group of the chosen resolution, then its arc. During a band switch the
        // outgoing and incoming sets cross-fade.
        for (resolution, weight, shown) in layers {
        let rimStart = b.shapes.count
        for group in shown {
            let fraction = layout.rimRadius(group) / max(1, layout.scopeRadius)
            let hue = Theme.bandRGB(resolution, group)
            let band = resolution.offset + group
            arc(from: -90, to: 90, fraction: fraction, width: 0.75, hue.simd(dark ? 0.12 : 0.14))
            guard running, display.bandLevel[band] > -80 else { continue }
            // Mono has one channel: the band stands on M, as narrow as a mono source.
            let m = Double(mono)
            let r = Double(max(-1, min(1, display.bandCorrelation[band]))) * (1 - m) + m
            let balance = Double(max(-1, min(1, display.bandBalance[band]))) * (1 - m)
            let spread = min(90, r >= 0 ? 45 * (1 - r) : 45 + 45 * -r) * (1 - pow(abs(balance), 3))
            let centre = 45 * balance
            let half = max(2, spread)
            let level = MeterScale.position(decibels: display.bandLevel[band] + 12)
            let alpha = 0.35 + 0.65 * level
            arc(from: max(-90, centre - half), to: min(90, centre + half), fraction: fraction, width: 2.25, hue.simd(alpha))
        }
        b.fade(from: rimStart, by: weight)
        }

        // Shapes only update while shown: start them afresh on a style change instead of flashing old ones.
        if style != envelopeStyle {
            envelopeStyle = style
            for index in envelopes.indices { envelopes[index] = [Float](repeating: 0, count: Self.envelopeBins) }
        }
        switch style {
        case .dots: drawCloud(&b, layout: layout, layers: layers)
        case .outline, .filled: drawEnvelopes(&b, layout: layout, running: running, dt: dt, filled: style == .filled, layers: layers)
        }
        b.disk(c, radius: 1.6, ink.simd(0.35))
        drawFocus(&b, layout: layout, display: display, running: running, dt: dt, group: focus)
    }

    /// Eased position of the stereometer's focal point: its direction (°) and scope fraction.
    private var focusAngle: Double = 0
    private var focusFraction: CGFloat = 0
    private var focusShown: Float = 0

    /// The focal point: one bright dot where the programme (or the band shown alone) sits, from its measured
    /// balance (toward L or R, as a sample on one side alone points at ±45°; on M in Mono) and its level from the
    /// centre (−60 dBFS) to the rim. It eases over about 0.1 s so it reads as a position, not a flicker, and
    /// fades out in silence.
    private func drawFocus(_ b: inout ShapeBuilder, layout: SoundstageLayout, display: MeterSnapshot, running: Bool,
                           dt: Float, group: Int) {
        let level = display.bandLevel[group]
        let live = running && level > -80
        let ease = dt > 0 ? CGFloat(1 - exp(-dt / 0.1)) : 1
        if live {
            let angle = 45 * Double(max(-1, min(1, display.bandBalance[group]))) * Double(1 - mono)
            let fraction = SoundstageLayout.scopeFraction(decibels: level)
            focusAngle += (angle - focusAngle) * Double(ease)
            focusFraction += (fraction - focusFraction) * ease
        }
        focusShown += ((live ? 1 : 0) - focusShown) * Float(ease)
        guard focusShown > 0.01, focusFraction > 0.01 else { return }
        let at = layout.scopePoint(angle: focusAngle, fraction: focusFraction)
        let lit = Theme.dark ? Theme.creamRGB : Theme.inkRGB
        b.glow(at, radius: 12, lit.simd(0.22 * focusShown))
        b.disk(at, radius: 5, Theme.displayRGB.simd(0.85 * focusShown))
        b.disk(at, radius: 3.6, lit.simd(focusShown))
    }

    /// Dots style: every sample of the recent clouds as a point of light, in the Immersive nebula's manner. Each
    /// sample is a soft glow in its band's hue; the newest 1/30 s also carries a small bright spark, and older
    /// samples spread and fade as they age, so the trail diffuses into a haze. On dark the glows add up as light
    /// (`ShapeBuilder.light`): where the programme gathers they burn toward white and the fringes keep their hues;
    /// on light they lay a tinted wash with the sparks crisp on top. Bands are interleaved point by point, so no
    /// band always covers another. During a band switch the dots re-colour by cross-fading the two groupings.
    private func drawCloud(_ b: inout ShapeBuilder, layout: SoundstageLayout,
                           layers: [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])]) {
        let dark = Theme.dark
        let points = StereoBands.scopePoints
        let now = cloudClock
        let center = layout.scopeCenter, radius = layout.scopeRadius
        // Glow and spark sizes follow the scope, so a small panel is not smothered and an enlarged one not sparse.
        let size = max(0.75, min(1.4, radius / 220))
        let lightStart = b.shapes.count
        for (resolution, weight, shown) in layers {
        let cloudStart = b.shapes.count
        let groups = resolution.groups
        let hues = (0..<resolution.count).map { Theme.bandRGB(resolution, $0) }
        let sparks = hues.map { dark ? $0.mixed(with: Theme.RGB(r: 1, g: 1, b: 1), amount: 0.55) : $0 }
        // Fewer groups overlap less: keep the summed light about as bright whatever the band setting.
        let share = Float(1 / Double(max(1, shown.count)).squareRoot())
        for (generation, cloud) in clouds.enumerated().reversed() where cloud.points.count == StereoBands.scopeFloats {
            let newest = generation == 0
            let age = Float((now - cloud.time) / Self.cloudDecay)
            let opacity = newest ? 1 : Float(exp(-Double(age)))
            guard opacity > 0.06 else { continue }
            let glowRadius = size * (8 + 3 * CGFloat(min(age, 3)))
            let glowAlpha = (dark ? 0.3 : 0.17) * share * opacity * (newest ? 1 : 0.8)
            for point in 0..<points {
                for (group, members) in groups.enumerated() where shown.contains(group) {
                    // A group's samples are the sum of its bands' (the crossovers sum back to the programme).
                    var left: Float = 0, right: Float = 0
                    for band in members {
                        left += cloud.points[(band * points + point) * 2]
                        right += cloud.points[(band * points + point) * 2 + 1]
                    }
                    guard let offset = SoundstageLayout.scopeSample(left: left, right: folded(left, right)) else { continue }
                    let position = CGPoint(x: center.x + offset.x * radius, y: center.y + offset.y * radius)
                    b.glow(position, radius: glowRadius, hues[group].simd(glowAlpha))
                    if newest { b.disk(position, radius: 1.15 * size, sparks[group].simd(dark ? 0.75 : 0.9)) }
                }
            }
        }
        b.fade(from: cloudStart, by: weight)
        }
        if dark { b.light = lightStart..<b.shapes.count }
    }

    /// Where a sample of the cloud lands on the half disc: its direction (−90 L … 0 M … 90 R) and scope fraction.
    private static func polar(left: Float, right: Float) -> (angle: Double, fraction: CGFloat)? {
        var mid = (left + right) * 0.70710677, side = (right - left) * 0.70710677
        let amplitude = (left * left + right * right).squareRoot()
        guard amplitude > 0.001, amplitude.isFinite else { return nil }
        if mid < 0 { mid = -mid; side = -side }
        let fraction = SoundstageLayout.scopeFraction(decibels: 20 * log10(amplitude))
        guard fraction > 0 else { return nil }
        return (Double(atan2(side, mid)) * 180 / .pi, fraction)
    }

    /// Outline and Filled styles: each band as the shape its samples fill, the outline of how far they reach in
    /// every direction. A narrow, centred bass is a tall spike toward M; a wide top end a low, broad fan.
    ///
    /// Filled shapes overlap wherever bands share a direction, so they are layered to stay readable: the largest
    /// shape is laid down first and the smaller ones over it, every fill is a light tint (overlaps mix rather than
    /// cover), and all the outlines are drawn after all the fills, each on a backing stroke in the screen colour,
    /// so every band's edge stays whole and crisp on top of any fill.
    private func drawEnvelopes(_ b: inout ShapeBuilder, layout: SoundstageLayout, running: Bool, dt: Float, filled: Bool,
                               layers: [(resolution: StereoBands.Resolution, weight: Float, groups: [Int])]) {
        let bins = Self.envelopeBins
        let points = StereoBands.scopePoints
        let fall = exp(-dt / 0.25)
        let c = layout.scopeCenter
        for (resolution, weight, shown) in layers {
            // Reach per direction of each group, from the clouds in view.
            for (group, members) in resolution.groups.enumerated() {
                var reach = [Float](repeating: 0, count: bins)
                var count = [Float](repeating: 0, count: bins)
                if running {
                    for cloud in clouds where cloud.points.count == StereoBands.scopeFloats {
                        for point in 0..<points {
                            var left: Float = 0, right: Float = 0
                            for band in members {
                                left += cloud.points[(band * points + point) * 2]
                                right += cloud.points[(band * points + point) * 2 + 1]
                            }
                            guard let sample = Self.polar(left: left, right: folded(left, right)) else { continue }
                            let bin = min(bins - 1, max(0, Int((sample.angle + 90) / 180 * Double(bins))))
                            reach[bin] = max(reach[bin], Float(sample.fraction))
                            count[bin] += 1
                        }
                    }
                }
                // A direction only a few stray samples reach is drawn short: the shape follows where the band's
                // samples gather, not the farthest outlier, so a focused band reads narrow and a diffuse one wide.
                let total = count.reduce(0, +)
                if total > 0 {
                    let even = total / Float(bins)
                    for bin in 0..<bins { reach[bin] *= min(1, (count[bin] / (0.6 * even)).squareRoot()) }
                }
                // Close gaps between sparse samples (the reach of a bin carries to its neighbours, tapering), then
                // soften the edge so the outline reads as a shape rather than a comb.
                var spread = reach
                for bin in 0..<bins {
                    for offset in 1...2 {
                        let taper: Float = offset == 1 ? 0.92 : 0.8
                        if bin >= offset { spread[bin] = max(spread[bin], reach[bin - offset] * taper) }
                        if bin + offset < bins { spread[bin] = max(spread[bin], reach[bin + offset] * taper) }
                    }
                }
                let index = resolution.offset + group
                for _ in 0..<2 {
                    let pass = spread
                    for bin in 0..<bins { spread[bin] = 0.25 * pass[max(0, bin - 1)] + 0.5 * pass[bin] + 0.25 * pass[min(bins - 1, bin + 1)] }
                }
                for bin in 0..<bins {
                    let target = spread[bin]
                    let value = envelopes[index][bin]
                    envelopes[index][bin] = target > value ? value + (target - value) * 0.6 : max(target, value * fall)
                }
            }

            // The outline of each group: out along its reach, from the L horizon through M to the R horizon.
            let shapes: [(group: Int, outline: [CGPoint], area: Float)] = shown.compactMap { group in
                let reach = envelopes[resolution.offset + group]
                let area = reach.reduce(0) { $0 + $1 * $1 }
                guard area > 0.0005 else { return nil }
                let outline = (0...bins).map { edge -> CGPoint in
                    // Bin edges; the reach at an edge is its two bins' mean. The ends keep their bin's reach, so a band
                    // that reaches out to the horizon closes along it instead of pinching back to the centre there,
                    // which left dark wedges between the shapes and the horizon (Filled).
                    let before = edge > 0 ? reach[edge - 1] : reach[0], after = edge < bins ? reach[edge] : reach[bins - 1]
                    let fraction = CGFloat((before + after) / 2)
                    return layout.scopePoint(angle: -90 + 180 * Double(edge) / Double(bins), fraction: fraction)
                }
                return (group, outline, area)
            }
            let start = b.shapes.count
            if filled {
                // Filled: each band as a body of light, like the Immersive dome's volume (`bodyFragment`).
                for shape in shapes.sorted(by: { $0.area > $1.area }) {
                    drawBody(&b, center: c, outline: shape.outline, hue: Theme.bandRGB(resolution, shape.group))
                }
            } else {
                // Outlines skip the closing spokes along the horizon, which only close the shape.
                for shape in shapes.sorted(by: { $0.area > $1.area }) {
                    let hue = Theme.bandRGB(resolution, shape.group)
                    let edge = shape.outline.dropFirst().dropLast()
                    for (p, q) in zip(edge, edge.dropFirst()) { b.line(p, q, width: 3.5, Theme.displayRGB.simd(0.7)) }
                    for (p, q) in zip(edge, edge.dropFirst()) { b.line(p, q, width: 1.6, hue.simd(0.95)) }
                }
            }
            b.fade(from: start, by: weight)
        }
    }

    /// One band of the Filled stereometer drawn as the Immersive dome draws its volume, flattened: a haze that
    /// thickens toward the listener and turns toward cream (ink on a light well) at the core, a soft skin where the
    /// band's reach ends, lit from the upper left like the dome's, and a faint glow beyond it. No hard outline:
    /// overlapping bands show through one another as the dome's lobes do.
    private func drawBody(_ b: inout ShapeBuilder, center c: CGPoint, outline: [CGPoint], hue: Theme.RGB) {
        guard outline.count >= 2 else { return }
        let dark = Theme.dark
        let core = dark ? Theme.creamRGB : Theme.inkRGB
        // Fractions of the reach, denser toward the skin, then out into the glow.
        let rings: [CGFloat] = [0, 0.25, 0.45, 0.62, 0.76, 0.86, 0.93, 0.97, 1, 1.04, 1.1, 1.17]
        let light = SIMD2<Float>(-0.47, -0.88) // screen space: up and to the left
        let haze: Float = dark ? 0.62 : 0.42, skinStrength: Float = dark ? 0.5 : 0.42
        func color(_ f: CGFloat, lit: Float) -> SIMD4<Float> {
            let x = Float(f)
            let inside = max(0, 1 - x)
            let body = inside * inside * 0.8 + inside * 0.35
            let skin = exp(-(x - 1) * (x - 1) / (0.085 * 0.085))
            let tint = min(1, inside * inside * 0.75)
            let deep = SIMD3<Float>(hue.r * 0.85 + (core.r - hue.r * 0.85) * tint, hue.g * 0.85 + (core.g - hue.g * 0.85) * tint,
                                    hue.b * 0.85 + (core.b - hue.b * 0.85) * tint)
            let shine = SIMD3<Float>(hue.r, hue.g, hue.b) * (0.7 + 0.65 * lit)
            let s = min(1, skin * 1.5)
            let rgb = deep + (shine - deep) * s
            let alpha = min(0.94, body * haze + skin * skinStrength * (0.65 + 0.35 * lit))
            return SIMD4<Float>(min(1, rgb.x), min(1, rgb.y), min(1, rgb.z), alpha)
        }
        // How lit each point of the outline is: its direction from the listener against the light.
        let lit: [Float] = outline.map { point in
            let dx = Float(point.x - c.x), dy = Float(point.y - c.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0.5 else { return 0.55 }
            return 0.55 + 0.45 * max(0, (dx * light.x + dy * light.y) / length)
        }
        func at(_ index: Int, _ f: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (outline[index].x - c.x) * f, y: c.y + (outline[index].y - c.y) * f)
        }
        // Each ring's colour at each outline point, once: neighbouring quads share their corners.
        let count = outline.count
        var colors = [SIMD4<Float>](repeating: .zero, count: rings.count * count)
        for (ring, f) in rings.enumerated() {
            for index in 0..<count { colors[ring * count + index] = color(f, lit: lit[index]) }
        }
        for ring in 0..<(rings.count - 1) {
            let inner = rings[ring], outer = rings[ring + 1]
            let innerRow = ring * count, outerRow = innerRow + count
            for index in 0..<(count - 1) {
                let next = index + 1
                let a = at(index, inner), d = at(next, inner), p = at(index, outer), q = at(next, outer)
                let ca = colors[innerRow + index], cd = colors[innerRow + next]
                let cp = colors[outerRow + index], cq = colors[outerRow + next]
                if inner == 0 {
                    b.triangle(a, p, q, ca, cp, cq)
                } else {
                    b.triangle(a, p, q, ca, cp, cq)
                    b.triangle(a, q, d, ca, cq, cd)
                }
            }
        }
    }

    /// A closed polygon with each edge bent toward a Catmull-Rom curve through the vertices by `amount` (0 keeps
    /// the straight edges, 1 is the full curve), so the field can morph between the two.
    private static func smoothed(_ points: [CGPoint], amount: CGFloat, steps: Int = 6) -> [CGPoint] {
        guard points.count >= 3, amount > 0.001 else { return points }
        let n = points.count
        var result: [CGPoint] = []
        result.reserveCapacity(n * steps)
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func curve(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                let straight = CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
                let bent = CGPoint(x: curve(p0.x, p1.x, p2.x, p3.x), y: curve(p0.y, p1.y, p2.y, p3.y))
                result.append(CGPoint(x: straight.x + (bent.x - straight.x) * amount, y: straight.y + (bent.y - straight.y) * amount))
            }
        }
        return result
    }

    /// Channel meters: each bar runs in a recessed slot its full width, so the scale reads down the whole height even
    /// when the channel is quiet. One fill whose colour follows the current level only (the accent, ochre while the
    /// channel peaks within 3 dB of full scale), the peak as the same colour translucent behind it, and the peak hold as
    /// a 2 pt mark across the slot, ink (ochre within 3 dB of full scale). An over never recolours the bar: above 0 dB
    /// the slot is tinted ember and fills to the highest true-peak over, and a dot over the bar stays lit until the
    /// next reset.
    private func drawMeters(_ b: inout ShapeBuilder, layout: SoundstageLayout, frame: CanvasFrame) {
        guard layout.scale.height > 8 else { return }
        let ink = Theme.inkRGB
        let ember = Theme.emberRGB
        if let first = layout.columns.first(where: { $0.width > 0.5 }), let last = layout.columns.last(where: { $0.width > 0.5 }) {
            let zero = layout.y(decibels: 0).rounded()
            b.rect(CGRect(x: first.minX, y: zero - 0.25, width: last.maxX - first.minX, height: 0.5), ink.simd(Float(ChartInk.reference)))
        }
        // Group rules under each header, in the group's colour.
        for header in layout.headers {
            let weight = Float(layout.headerWeight(header.group))
            guard header.rect.width > 1 else { continue }
            b.roundedRect(CGRect(x: header.rect.minX + 2, y: (header.rect.maxY - 3).rounded(), width: header.rect.width - 4, height: 1.5),
                          radius: 0.75, Theme.groupRGB(header.group).simd(0.5 * weight * weight))
        }
        for (index, speaker) in layout.speakers.enumerated() {
            let role = speaker.role
            let v = visibility(role)
            guard v > 0.002 else { continue }
            let bar = layout.bar(index)
            guard bar.width > 1 else { continue }
            let active = frame.activeRoles[role]
            let radius = bar.width / 2
            // Track: a recessed slot the bar's full width, so its scale runs the whole height even when quiet, tinted
            // ember above 0 dB.
            b.roundedRect(bar, radius: radius, ink.simd((active ? 0.075 : 0.04) * v))
            let overTrack = layout.overTrack(index)
            b.roundedRect(overTrack, radius: min(radius, overTrack.height / 2), ember.simd(0.10 * v))
            if active {
                let over = MeterScale.decibels(overPeaks[role])
                let status = peakDb[role] >= -3 ? Theme.ochreRGB : Theme.sageRGB
                if peakDb[role] > -70 {
                    let top = layout.y(decibels: min(0, peakDb[role]))
                    b.roundedRect(CGRect(x: bar.minX, y: top, width: bar.width, height: max(bar.width, bar.maxY - top)),
                                  radius: radius, status.simd(0.35 * v))
                }
                if rmsDb[role] > -70 {
                    let top = layout.y(decibels: min(0, rmsDb[role]))
                    b.roundedRect(CGRect(x: bar.minX, y: top, width: bar.width, height: max(bar.width, bar.maxY - top)),
                                  radius: radius, status.simd(v))
                }
                if over > 0 && overTrack.height > 1 {
                    let top = max(overTrack.minY, min(overTrack.maxY - 2, layout.y(decibels: over)))
                    let fill = CGRect(x: overTrack.minX, y: top, width: overTrack.width, height: overTrack.maxY - top)
                    b.roundedRect(fill, radius: min(radius, fill.height / 2), ember.simd(v))
                }
                if holds[role] > -60 {
                    // Peak hold: the gauge's target mark, a thin ink bar across the track.
                    let y = layout.y(decibels: min(0, holds[role]))
                    b.roundedRect(CGRect(x: bar.minX - 2, y: y - 1, width: bar.width + 4, height: 2), radius: 1,
                                  (holds[role] >= -3 ? Theme.ochreRGB : ink).simd(v))
                }
            }
            // Clip light, like the LIVE dot: faint while clear, ember once an over or a full-scale sample has
            // latched it, until the next reset.
            let cap = layout.cap(index)
            b.disk(CGPoint(x: cap.midX, y: cap.midY), radius: cap.width / 2,
                   clipped[role] ? ember.simd(v) : ink.simd((active ? 0.16 : 0.07) * v))
        }
    }

    /// Correlation on the conventional scale, −1 at the left, 0 at the centre, +1 at the right, over coloured
    /// zones that say what each range means for the listener: out of phase (cancels in mono), wide, healthy
    /// stereo, mono. The bar is split into one lane per `StereoBands` band (the top band on top), so a bass that
    /// is mono-safe and a top end that cancels read apart: each lane fills from 0 to its band's reading and marks
    /// it with a short needle in its zone colour. The full-band needle crosses every lane, and a hold tick marks
    /// the lowest recent full-band reading, so a brief dip toward cancellation stays visible after it moved on.
    private func drawCorrelation(_ b: inout ShapeBuilder, layout: SoundstageLayout, display: MeterSnapshot, running: Bool, dt: Float,
                                 layers: [(resolution: StereoBands.Resolution, weight: Float)]) {
        let value = display.correlation
        let live = running && value != MeterSnapshot.noCorrelation
        updateCorrelationHold(live ? value : nil, dt: dt)
        // Shown in Stereo only: the section dissolves as it folds away toward Mono or Multi Channel.
        let fade = Float(layout.correlationWeight * layout.correlationWeight)
        guard fade > 0.002 else { return }
        let track = layout.correlationTrack
        let ink = Theme.inkRGB
        let edges: [Float] = [-1] + CorrelationZone.edges + [1]
        // Zone tints behind every lane, the lit zone stronger.
        for (from, to) in zip(edges, edges.dropFirst()) {
            let x0 = layout.correlationX(from), x1 = layout.correlationX(to)
            var tint = Theme.correlation((from + to) / 2)
            tint.w = (live && CorrelationZone(value) == CorrelationZone((from + to) / 2) ? 0.16 : 0.08) * fade
            b.rect(CGRect(x: x0, y: track.minY, width: x1 - x0, height: track.height), tint)
        }
        // Lane tracks of each resolution showing; during a band switch the two sets cross-fade in the gliding bar.
        for (resolution, weight) in layers {
            for lane in 0..<resolution.count {
                let rect = layout.correlationLane(lane, of: resolution.count)
                b.roundedRect(rect, radius: rect.height / 2, ink.simd(0.06 * fade * weight))
            }
        }
        for edge in CorrelationZone.edges + [0] {
            let x = (layout.correlationX(edge) * 2).rounded() / 2
            let center = edge == 0
            b.rect(CGRect(x: x, y: track.minY - (center ? 3 : 1), width: 0.5, height: track.height + (center ? 6 : 2)),
                   ink.simd((center ? 0.35 : 0.18) * fade))
        }
        guard running else { return }
        // Each lane: a fill from 0 to its reading, split at the colour stops so its colour follows the scale, and
        // a short needle. Quiet bands fade back, so the lanes that carry the mix lead. Overall is the single
        // classic bar: the full-band reading, marked by the full-band needle alone.
        for (resolution, weight) in layers {
        let laneStart = b.shapes.count
        let overall = resolution == .overall
        for group in 0..<resolution.count {
            let band = resolution.offset + group
            let reading = overall ? display.correlation : display.bandCorrelation[band]
            guard reading != MeterSnapshot.noCorrelation else { continue }
            let lane = layout.correlationLane(group, of: resolution.count).insetBy(dx: 0, dy: 1)
            let presence = 0.45 + 0.55 * MeterScale.position(decibels: display.bandLevel[band] + 12)
            let lower = min(0, reading), upper = max(0, reading)
            var from = lower
            for stop in Theme.correlationStops where stop.value > from && from < upper {
                let to = min(stop.value, upper)
                let x0 = layout.correlationX(from), x1 = layout.correlationX(to)
                if x1 - x0 > 0.01 {
                    var left = Theme.correlation(from), right = Theme.correlation(to)
                    left.w = 0.7 * presence * fade
                    right.w = 0.7 * presence * fade
                    b.quad(CGRect(x: x0, y: lane.minY, width: x1 - x0, height: lane.height), left: left, right: right)
                }
                from = to
            }
            guard !overall else { continue }
            let x = layout.correlationX(reading)
            var needle = Theme.correlation(reading)
            needle.w = presence * fade
            b.roundedRect(CGRect(x: x - 1.5, y: lane.minY - 1, width: 3, height: lane.height + 2), radius: 1.5, needle)
        }
        b.fade(from: laneStart, by: weight)
        }
        guard live else { return }
        if let low = correlationLow, low < value - 0.02 {
            var hold = Theme.correlation(low) * 0.6 + ink.simd() * 0.4
            hold.w = fade
            b.rect(CGRect(x: layout.correlationX(low) - 1, y: track.minY - 3, width: 2, height: track.height + 6), hold)
        }
        let x = layout.correlationX(value)
        let needle = value < CorrelationZone.edges[0] ? Theme.emberRGB : ink
        b.glow(CGPoint(x: x, y: track.minY - 4), radius: 8, Theme.correlation(value) * SIMD4(1, 1, 1, 0) + SIMD4(0, 0, 0, 0.30 * fade))
        b.roundedRect(CGRect(x: x - 1, y: track.minY - 5, width: 2, height: track.height + 10), radius: 1, needle.simd(0.85 * fade))
        b.triangle(CGPoint(x: x - 4, y: track.minY - 8), CGPoint(x: x + 4, y: track.minY - 8), CGPoint(x: x, y: track.minY - 3),
                   needle.simd(0.95 * fade), needle.simd(0.95 * fade), needle.simd(0.95 * fade))
    }

    private func updateCorrelationHold(_ value: Float?, dt: Float) {
        guard let value else {
            correlationLow = nil
            return
        }
        if let low = correlationLow, low < value {
            if correlationLowTimer > 0 {
                correlationLowTimer -= dt
            } else {
                correlationLow = min(value, low + 0.5 * dt)
            }
        } else {
            correlationLow = value
            correlationLowTimer = 2
        }
    }
}

extension SoundstageScene {
    /// Regression for a latched over, paused reset, stale snapshots, and a new genuine over.
    static func checkPeakReset() -> Bool {
        let scene = SoundstageScene(part: .levels)
        var frame = CanvasFrame(running: true)
        frame.snapshot.sequence = 1
        frame.snapshot.channelTruePeaks[Role.left] = 1.1
        frame.snapshot.heldTruePeaks[Role.left] = 1.2
        scene.prepare(frame: frame)
        guard scene.clipped[Role.left] else { return false }
        frame.running = false
        frame.truePeakEpoch += 1
        for _ in 0..<180 { scene.prepare(frame: frame) }
        guard !scene.clipped[Role.left], scene.overPeaks[Role.left] == 0 else { return false }
        frame.running = true
        scene.prepare(frame: frame)
        guard !scene.clipped[Role.left] else { return false }
        frame.snapshot.sequence = 2
        frame.snapshot.channelTruePeaks[Role.left] = 0.5
        for _ in 0..<180 { scene.prepare(frame: frame) }
        guard !scene.clipped[Role.left] else { return false }
        frame.snapshot.sequence = 3
        frame.snapshot.channelTruePeaks[Role.left] = 1.1
        scene.prepare(frame: frame)
        guard scene.clipped[Role.left] else { return false }
        frame.running = false
        frame.epoch += 1
        scene.prepare(frame: frame)
        guard !scene.clipped[Role.left] else { return false }
        print("PASS: peak warnings clear while paused, ignore stale frames and relight for new overs")
        return true
    }
}
