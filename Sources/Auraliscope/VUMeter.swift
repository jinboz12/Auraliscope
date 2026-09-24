import AppKit
import QuartzCore
import SwiftUI

/// The analogue-style VU meter at the right end of the loudness summary: an ink scale on a display well,
/// ember zone above 0 VU, and a needle driven at the display rate from the latest snapshot.
///
/// The dial (arcs, ticks, labels) is a SwiftUI Canvas that only redraws when its size changes. The needle is
/// a pair of Core Animation layers rotated once per display frame, so moving it costs no SwiftUI update, no
/// text layout and no rasterisation. (Beta 3 redrew the whole dial every frame, about 40 % of the main thread.)
/// 0 VU follows the loudness standard of the current monitoring mode.
struct VUMeterPanel: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let running = model.running
        let reference = Float(model.loudnessTarget)
        VUDial()
            .overlay {
                VUNeedle(model: model, running: running, roles: model.routedRoles, reference: reference)
            }
            .overlay(alignment: .bottomTrailing) {
                let level = running ? readouts.values.programmeLevel : -120
                let vu = VUScale.vu(fromDecibels: level, reference: reference)
                StableNumber(text: level > -100 ? MeterScale.tenths(vu, floor: -99) + " VU" : "— VU", template: "−88.8 VU",
                             font: .system(size: 10, weight: .semibold),
                             color: vu >= 0 && level > -100 ? Theme.ember : (level > -100 ? Theme.ink : Theme.tertiary))
                    .padding(.trailing, 10).padding(.bottom, 7)
            }
            .overlay(alignment: .topLeading) {
                Eyebrow("VU · ALL CHANNELS", color: Theme.tertiary).padding(.top, 7).padding(.leading, 9)
            }
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: "0 VU = \(MeterScale.signedInteger(reference)) dBFS")
                    .font(.axis).foregroundStyle(Theme.tertiary)
                    .padding(.leading, 9).padding(.bottom, 7)
            }
            .background { WellSurface() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
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
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 0)
        // Leave the top 26 pt to the title: labels sit 15 pt outside the arc.
        radius = max(20, min(rect.width / 2 / sin(VUScale.halfSweep) - 6, size.height - 66))
        pivot = CGPoint(x: rect.midX, y: size.height - 20)
    }

    /// Needle angle from vertical, clockwise positive; `fraction` 0 is the rest stop, 1 is +3 VU.
    static func angle(_ fraction: Double) -> Double { -VUScale.halfSweep + 2 * VUScale.halfSweep * min(1.04, fraction) }

    /// Top-left-origin point on the dial at `fraction` and distance `r` from the pivot.
    func point(_ fraction: Double, _ r: CGFloat) -> CGPoint {
        let a = Self.angle(fraction)
        return CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a))
    }
}

/// Scale and zones, drawn in one Canvas. It has no inputs besides its size, so SwiftUI draws it once.
private struct VUDial: View {
    var body: some View {
        Canvas { context, size in
            let dial = VUGeometry(size: size)
            let radius = dial.radius
            func arc(from: Double, to: Double, radius r: CGFloat) -> Path {
                Path { path in
                    for step in 0...40 {
                        let p = dial.point(from + (to - from) * Double(step) / 40, r)
                        if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
            }
            let zero = VUScale.fraction(vu: 0)
            // Scale arc: ink to 0 VU, a heavier ember band above it.
            context.stroke(arc(from: 0, to: zero, radius: radius), with: .color(Theme.ink.opacity(0.62)), lineWidth: 1)
            context.stroke(arc(from: zero, to: 1, radius: radius - 2), with: .color(Theme.ember.opacity(0.9)), lineWidth: 5)
            let dense = radius > 84
            for mark in VUScale.marks {
                let f = VUScale.fraction(vu: mark)
                let major = [-20, -10, -5, -3, 0, 3].contains(mark)
                var tick = Path()
                tick.move(to: dial.point(f, radius))
                tick.addLine(to: dial.point(f, radius + (major ? 7 : 4)))
                context.stroke(tick, with: .color((mark > 0 ? Theme.ember : Theme.ink).opacity(major ? 0.90 : 0.62)),
                               lineWidth: major ? 1.2 : 0.8)
                guard major || dense else { continue }
                let label = mark > 0 ? "+\(Int(mark))" : (mark == 0 ? "0" : "\(Int(-mark))")
                context.draw(Text(label).font(.system(size: 8, weight: .semibold).monospacedDigit())
                                .foregroundColor(mark > 0 ? Theme.ember : Theme.ink.opacity(0.85)),
                             at: dial.point(f, radius + 15))
            }
            context.draw(Text(verbatim: "VU").font(.system(size: 13, weight: .semibold).width(.expanded))
                            .foregroundColor(Theme.ink.opacity(0.42)),
                         at: CGPoint(x: dial.pivot.x, y: dial.pivot.y - radius * 0.46))
        }
    }
}

/// Needle, its shadow and the hub, as layers above the dial.
private struct VUNeedle: NSViewRepresentable {
    let model: MeterModel
    let running: Bool
    let roles: [Bool]
    let reference: Float

    func makeNSView(context: Context) -> VUNeedleView { VUNeedleView(model: model) }

    func updateNSView(_ view: VUNeedleView, context: Context) {
        view.roles = roles
        view.reference = reference
        view.running = running
    }

    static func dismantleNSView(_ view: VUNeedleView, coordinator: ()) { view.shutDown() }
}

/// Owns the IEC 60268-17 ballistics. A display link (a 60 Hz timer before macOS 14) steps them while capture
/// runs and the window is visible; otherwise the needle rests and nothing ticks.
final class VUNeedleView: NSView {
    private weak var model: MeterModel?
    var roles = [Bool](repeating: false, count: Role.count)
    var reference: Float = VUScale.defaultReference
    var running = false { didSet { if running != oldValue { runningChanged() } } }

    private let ballistics = VUBallistics()
    private let needleShadow = CAShapeLayer()
    private let shaft = CAShapeLayer()
    private let hub = CAShapeLayer()
    private var shownFraction = -1.0
    private var ticker: AnyObject?
    private var occlusionObserver: NSObjectProtocol?

    init(model: MeterModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        needleShadow.strokeColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: Theme.dark ? 0.35 : 0.16)
        needleShadow.lineWidth = 2
        shaft.lineWidth = 1.6
        shaft.lineCap = .round
        hub.fillColor = Theme.cardRGB.cgColor()
        hub.strokeColor = Theme.inkRGB.cgColor(0.55)
        hub.lineWidth = 1
        for sublayer in [needleShadow, shaft, hub] {
            sublayer.fillColor = sublayer === hub ? sublayer.fillColor : nil
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
        // The needle is drawn pointing straight up from the pivot and rotated into place.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -dial.radius * 0.16))
        path.addLine(to: CGPoint(x: 0, y: -(dial.radius + 3)))
        for needle in [needleShadow, shaft] {
            needle.bounds = .zero
            needle.path = path
        }
        shaft.position = dial.pivot
        needleShadow.position = CGPoint(x: dial.pivot.x, y: dial.pivot.y + 1.5)
        hub.bounds = .zero
        hub.position = dial.pivot
        hub.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
        CATransaction.commit()
        shownFraction = -1
        show(ballistics.position)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [needleShadow, shaft, hub] { sublayer.contentsScale = scale }
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
    }

    private func runningChanged() {
        if !running {
            ballistics.rest()
            show(0)
        }
        restyle()
        updateTicker()
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shaft.strokeColor = Theme.inkRGB.cgColor(running ? 1 : 0.5)
        CATransaction.commit()
    }

    private var visible: Bool { window?.occlusionState.contains(.visible) == true }

    private func updateTicker() {
        if running && window != nil && visible { startTicker() } else { stopTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        if #available(macOS 14, *) {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
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
        needleShadow.transform = rotation
        CATransaction.commit()
    }
}
