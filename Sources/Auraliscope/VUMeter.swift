import AnalysisCore
import AppKit
import QuartzCore
import SwiftUI

/// The analogue-style VU meter at the right end of the loudness summary: an ink scale on a card of its own,
/// ember zone above 0 VU, and a needle driven at the display rate from the latest snapshot.
///
/// The dial (arcs, ticks, labels) is a SwiftUI Canvas that only redraws when its size changes. The needle is
/// a Core Animation layer rotated once per display frame under a fixed hub, so moving it costs no SwiftUI update, no
/// text layout and no rasterisation. (Beta 3 redrew the whole dial every frame, about 40 % of the main thread.)
/// 0 VU follows the loudness standard of the current monitoring mode.
struct VUMeterPanel: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    /// 0 VU in dBFS; 0 follows the loudness target (`VUScale.referenceKey`).
    @AppStorage(VUScale.referenceKey) private var fixedReference = 0.0

    var body: some View {
        let running = model.running
        let reference = fixedReference < 0 ? Float(fixedReference) : Float(model.loudnessTarget)
        VUDial()
            .overlay {
                VUNeedle(model: model, running: running, frozen: model.frozen, roles: model.routedRoles, reference: reference)
            }
            .overlay(alignment: .bottomTrailing) {
                let level = running || model.frozen ? readouts.values.programmeLevel : -120
                let vu = VUScale.vu(fromDecibels: level, reference: reference)
                StableNumber(text: level > -100 ? MeterScale.tenths(vu, floor: -99) + " VU" : "— VU", template: "−88.8 VU",
                             font: .system(size: 10, weight: .semibold),
                             color: vu >= 0 && level > -100 ? Theme.ember : (level > -100 ? Theme.ink : Theme.tertiary))
                    .padding(.trailing, PanelPlate.inset + 10).padding(.bottom, PanelPlate.inset + 6)
            }
            .overlay(alignment: .top) { CardTitle(title: "VU · " + L("ALL CHANNELS"), model: model, panel: .vu, settings: .vu, short: "VU") }
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: "0 VU = \(MeterScale.signedInteger(reference)) dBFS")
                    .font(.axis).foregroundStyle(Theme.tertiary)
                    .padding(.leading, PanelPlate.inset + 10).padding(.bottom, PanelPlate.inset + 6)
            }
            .background { PanelPlate() }
            .background { CardSurface() }
            .help(L("VU: the whole programme on one needle, the power sum of every routed channel except LFE, with standard 300 ms VU ballistics. 0 VU sits at the loudness target of the current mode (%@ dBFS).",
                    MeterScale.signedInteger(reference)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("VU meter, all channels"))
    }
}

/// Where the dial's arc sits in a view of `size`; the static Canvas and the needle layers share it.
struct VUGeometry {
    let pivot: CGPoint
    let radius: CGFloat

    init(size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 0)
        // Leave the title row and the plate's top margin: labels sit 15 pt outside the arc.
        radius = max(20, min(rect.width / 2 / sin(VUScale.halfSweep) - 6, size.height - 104))
        pivot = CGPoint(x: rect.midX, y: size.height - 34)
    }

    /// Needle angle from vertical, clockwise positive; `fraction` 0 is the rest stop, 1 is +3 VU.
    static func angle(_ fraction: Double) -> Double { -VUScale.halfSweep + 2 * VUScale.halfSweep * min(1.04, fraction) }

    /// Top-left-origin point on the dial at `fraction` and distance `r` from the pivot.
    func point(_ fraction: Double, _ r: CGFloat) -> CGPoint {
        let a = Self.angle(fraction)
        return CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a))
    }
}

/// The face as a line drawing in one weight and one grey, like a tape machine sketched in outline: the scale is a
/// single arc with short ticks (the marks a little longer), and two lines run from the hub out to the ends of the
/// arc, so the face is one connected shape around the needle's sweep. The zone above 0 VU is the only colour, in
/// the same weight. The hub (a ring with a pin) and the needle are layers above (`VUNeedleView`). It has no inputs
/// besides its size, so SwiftUI draws it once.
private struct VUDial: View {
    /// The one line weight of the face, the needle and the hub.
    static let stroke: CGFloat = 1.1
    /// The hub ring's radius for a dial of `radius`.
    static func hub(_ radius: CGFloat) -> CGFloat { max(4.5, min(7, radius * 0.09)) }

    var body: some View {
        Canvas { context, size in
            let dial = VUGeometry(size: size)
            let radius = dial.radius
            let line = Theme.ink.opacity(0.62), ember = Theme.ember.opacity(0.9)
            let style = StrokeStyle(lineWidth: Self.stroke, lineCap: .round, lineJoin: .round)
            func arc(from: Double, to: Double, steps: Int = 48) -> Path {
                Path { path in
                    for step in 0...steps {
                        let p = dial.point(from + (to - from) * Double(step) / Double(steps), radius)
                        if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
            }
            func spoke(_ f: Double, _ r0: CGFloat, _ r1: CGFloat) -> Path {
                Path { path in path.move(to: dial.point(f, r0)); path.addLine(to: dial.point(f, r1)) }
            }
            let zero = VUScale.fraction(vu: 0)
            // The outline: from the hub out to the rest end, round the scale to +3 VU, and back to the hub.
            let hub = Self.hub(radius) + 3
            context.stroke(spoke(0, hub, radius), with: .color(line), style: style)
            context.stroke(arc(from: 0, to: zero), with: .color(line), style: style)
            context.stroke(arc(from: zero, to: 1, steps: 16), with: .color(ember), style: style)
            context.stroke(spoke(1, hub, radius), with: .color(line), style: style)
            // Ticks outward from the scale; the named marks a little longer.
            let dense = radius > 84
            for mark in VUScale.marks {
                let f = VUScale.fraction(vu: mark)
                let major = [-20, -10, -5, -3, 0, 3].contains(mark)
                context.stroke(spoke(f, radius, radius + (major ? 6 : 3.5)), with: .color(mark > 0 ? ember : line), style: style)
                guard major || dense else { continue }
                let label = mark > 0 ? "+\(Int(mark))" : (mark == 0 ? "0" : "\(Int(-mark))")
                context.draw(Text(label).font(.system(size: 8, weight: .semibold).monospacedDigit())
                                .foregroundColor(mark > 0 ? Theme.ember : Theme.ink.opacity(0.8)),
                             at: dial.point(f, radius + 15))
            }
            context.draw(Text(verbatim: "VU").font(.system(size: 13, weight: .semibold).width(.expanded))
                            .foregroundColor(Theme.ink.opacity(0.24)),
                         at: CGPoint(x: dial.pivot.x, y: dial.pivot.y - radius * 0.46))
        }
    }
}

/// Needle and hub, as layers above the dial.
private struct VUNeedle: NSViewRepresentable {
    let model: MeterModel
    let running: Bool
    let frozen: Bool
    let roles: [Bool]
    let reference: Float

    func makeNSView(context: Context) -> VUNeedleView { VUNeedleView(model: model) }

    func updateNSView(_ view: VUNeedleView, context: Context) {
        view.roles = roles
        view.reference = reference
        view.update(running: running, frozen: frozen)
    }

    static func dismantleNSView(_ view: VUNeedleView, coordinator: ()) { view.shutDown() }
}

/// Owns the IEC 60268-17 ballistics. A display link (a 60 Hz timer before macOS 14) steps them while capture
/// runs and the window is visible; otherwise the needle rests and nothing ticks. Paused, it stays where it was.
final class VUNeedleView: NSView {
    private weak var model: MeterModel?
    var roles = [Bool](repeating: false, count: Role.count)
    var reference: Float = VUScale.defaultReference
    private var running = false
    /// Paused with the picture held (`MeterModel.frozen`).
    private var frozen = false

    private let ballistics = VUBallistics()
    private let shaft = CAShapeLayer()
    private let hub = CAShapeLayer()
    private let pin = CAShapeLayer()
    private var shownFraction = -1.0
    private var ticker: AnyObject?
    private var occlusionObserver: NSObjectProtocol?
    private var rateObserver: NSObjectProtocol?

    init(model: MeterModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Flat line work like the face: no shadow, the dial's one weight (a touch firmer for the needle).
        shaft.lineWidth = VUDial.stroke + 0.2
        shaft.lineCap = .round
        shaft.fillColor = nil
        hub.fillColor = Theme.displayRGB.cgColor()
        hub.strokeColor = Theme.inkRGB.cgColor(0.62)
        hub.lineWidth = VUDial.stroke
        pin.fillColor = Theme.inkRGB.cgColor(0.85)
        pin.strokeColor = nil
        for sublayer in [shaft, hub, pin] {
            sublayer.actions = ["transform": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(sublayer)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let dial = VUGeometry(size: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The needle is drawn pointing straight up from the hub ring and rotated into place; its tip crosses the
        // scale a little, like a playhead across its ruler.
        let ring = VUDial.hub(dial.radius)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -(ring + 2)))
        path.addLine(to: CGPoint(x: 0, y: -(dial.radius + 5)))
        shaft.bounds = .zero
        shaft.path = path
        shaft.position = dial.pivot
        // The hub: a ring with a pin, like a reel's.
        for part in [hub, pin] {
            part.bounds = .zero
            part.position = dial.pivot
        }
        hub.path = CGPath(ellipseIn: CGRect(x: -ring, y: -ring, width: 2 * ring, height: 2 * ring), transform: nil)
        pin.path = CGPath(ellipseIn: CGRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2), transform: nil)
        CATransaction.commit()
        shownFraction = -1
        show(ballistics.position)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [shaft, hub, pin] { sublayer.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTicker() }
            }
        }
        viewDidChangeBackingProperties()
        updateTicker()
    }

    func shutDown() {
        stopTicker()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
        rateObserver = nil
    }

    /// Both at once, so pausing never passes through a stopped state that would drop the needle.
    func update(running: Bool, frozen: Bool) {
        guard running != self.running || frozen != self.frozen else { return }
        self.running = running
        self.frozen = frozen
        if !running {
            if frozen {
                ballistics.hold()
            } else {
                ballistics.rest()
                show(0)
            }
        }
        restyle()
        updateTicker()
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shaft.strokeColor = Theme.inkRGB.cgColor(running || frozen ? 1 : 0.5)
        CATransaction.commit()
    }

    private var visible: Bool { window?.occlusionState.contains(.visible) == true }

    private func updateTicker() {
        if running && window != nil && visible { startTicker() } else { stopTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        if rateObserver == nil {
            // A new display frame rate (Settings ▸ General) restarts the needle at it.
            rateObserver = NotificationCenter.default.addObserver(forName: CanvasDriver.frameRateChanged, object: nil,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stopTicker()
                    self?.updateTicker()
                }
            }
        }
        // The canvases' rate (60 Hz, also on a 120 Hz display, or 30), so the needle moves with them.
        let rate = Float(CanvasDriver.shared.frameRate)
        if #available(macOS 14, *) {
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let timer = Timer(timeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    private func stopTicker() {
        if #available(macOS 14, *), let link = ticker as? CADisplayLink { link.invalidate() }
        (ticker as? Timer)?.invalidate()
        ticker = nil
    }

    @objc private func tick() {
        guard running, let model else { return }
        let level = VUScale.aggregate(rms: model.pollSnapshot().channelRMS, roles: roles)
        let target = VUScale.fraction(vu: VUScale.vu(fromDecibels: level, reference: reference))
        show(ballistics.step(toward: target, at: CACurrentMediaTime()))
    }

    /// Rotates the needle; a needle at rest commits nothing.
    private func show(_ fraction: Double) {
        guard abs(fraction - shownFraction) > 0.00005 else { return }
        shownFraction = fraction
        let rotation = CATransform3DMakeRotation(CGFloat(VUGeometry.angle(fraction)), 0, 0, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shaft.transform = rotation
        CATransaction.commit()
    }
}
