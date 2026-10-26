import AnalysisCore
import SwiftUI

// MARK: - Surfaces

/// A panel: one surface carrying a module's title row, its controls and its plot.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { CardSurface() }
    }
}

/// A panel's frame: frosted glass over the night. The backdrop's colour shows faintly through it; a sheen falls
/// across its upper part, and its one rim is a bevel, lit along the upper-left edge and in shade along the lower
/// right, as a soft-extruded surface is, while a soft shadow lifts it off the window. Modules separate by depth and
/// light rather than by borders. Native material blurs the backdrop; tint and rim stay behind the measurement content.
struct CardSurface: View {
    var radius: CGFloat = Theme.cardRadius
    @ViewBuilder
    var body: some View {
        if Theme.isConsole {
            ConsoleCardSurface(radius: radius)
        } else {
            glassSurface
        }
    }

    @ViewBuilder
    private var glassSurface: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = Theme.dark
        // The goofy theme uses a tinted, unblurred backing so the user's original frog photograph can show
        // faintly through it. Other themes retain their original material and all contents keep full opacity.
        shape.fill(Theme.palette == .milkFrog
                   ? AnyShapeStyle(Theme.cardTint.opacity(dark ? 0.72 : 0.84))
                   : AnyShapeStyle(.ultraThinMaterial))
            .overlay { shape.fill(Theme.panelFill) }
            .overlay {
                // A sheen in the upper part, as light falls on frosted glass from the upper left.
                shape.fill(LinearGradient(colors: [Color.white.opacity(dark ? 0.085 : 0.30), .clear],
                                          startPoint: .topLeading, endPoint: UnitPoint(x: 0.62, y: 0.6)))
            }
            .overlay {
                shape.gradientBorder(LinearGradient(stops: dark
                                                        ? [.init(color: Color.white.opacity(0.30), location: 0),
                                                           .init(color: Color.white.opacity(0.06), location: 0.45),
                                                           .init(color: Color.black.opacity(0.45), location: 1)]
                                                        : [.init(color: Color.white, location: 0),
                                                           .init(color: Color.white.opacity(0.6), location: 0.5),
                                                           .init(color: Theme.hairline.opacity(0.16), location: 1)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: Theme.cardShadow, radius: dark ? 16 : 18, x: dark ? 2 : 3, y: dark ? 8 : 8)
    }
}

extension InsettableShape {
    /// A border filled with `gradient`, drawn as the gradient masked to the border. The same look as
    /// `strokeBorder(gradient)`, which is rasterized on the CPU at every size: while panels moved or resized, redrawing
    /// their rims took most of the main thread and dropped frames.
    func gradientBorder(_ gradient: LinearGradient, lineWidth: CGFloat) -> some View {
        gradient.mask { strokeBorder(lineWidth: lineWidth) }
    }
}

extension Theme {
    /// The light along a round control's or a field's top edge.
    static var controlRim: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(dark ? 0.12 : 0.9), Color.white.opacity(dark ? 0.0 : 0.2)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A quiet recess on the same translucent card, without another rim or shadow.
/// Only its background is tinted; measurement text and Metal geometry keep their full contrast.
struct PlotPlate: View {
    var radius: CGFloat = Theme.wellRadius
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.plotWash)
            .overlay {
                if Theme.isConsole {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .gradientBorder(LinearGradient(colors: [.black.opacity(Theme.dark ? 0.65 : 0.24),
                                                               .white.opacity(Theme.dark ? 0.10 : 0.8)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: 2)
                                .gradientBorder(LinearGradient(colors: [.black.opacity(Theme.dark ? 0.22 : 0.10), .clear],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        }
                }
            }
            .allowsHitTesting(false)
    }
}

/// The title row of the summary's small panels (the 15 s history, the VU meter), at the panel's usual inset. A narrow
/// panel gives up some of the inset before the title is cut.
struct CardTitle: View {
    let title: String
    let model: MeterModel?
    /// The panel this title heads, for its window button at the trailing end.
    var panel: MeterPanel? = nil
    /// Settings this panel shares with another (the VU meter's live with the loudness panel's).
    var settings: PanelKind? = nil
    /// A shorter title for a narrow panel, before the title is cut.
    var short: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                Eyebrow(title, color: Theme.title).fixedSize().padding(.leading, 18)
                Eyebrow(title, color: Theme.title).fixedSize().padding(.leading, 12)
                if let short { Eyebrow(short, color: Theme.title).fixedSize().padding(.leading, 12) }
                Eyebrow(short ?? title, color: Theme.title).padding(.leading, 10)
            }
            Spacer(minLength: 4)
            if let settings { PanelSettingsButton(panel: settings, model: model, window: false) }
            if let panel { PanelWindowButton(panel: panel) }
        }
        .padding(.trailing, panel == nil ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 22)
        .padding(.top, 14)
    }
}

/// The meter's one status reading: LIVE with an accent dot, PAUSED with a pause glyph on an outlined tag, STANDBY
/// with an empty ring. Shape and word carry the state as well as colour.
struct StatusReading: View {
    @ObservedObject var model: MeterModel
    var detail: String? = nil
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let paused = !model.running && model.frozen
        HStack(spacing: 6) {
            if model.running {
                // The live light breathes (`PulseRing`) over its steady glow.
                Circle().fill(Theme.sage).frame(width: 6, height: 6)
                    .background { PulseRing(color: Theme.sageRGB) }
                    .background { Circle().fill(Theme.glow(Theme.sage, 0.5)).frame(width: 12, height: 12).blur(radius: 3) }
            } else if paused {
                Image(systemName: "pause.fill").font(.system(size: 7, weight: .black))
            } else {
                Circle().strokeBorder(Theme.tertiary, lineWidth: 1).frame(width: 7, height: 7)
            }
            Text(model.running ? L("LIVE") : (paused ? L("PAUSED") : L("STANDBY")))
                .font(.system(size: 10, weight: .bold)).tracking(1)
            if let detail {
                Text(verbatim: "·").foregroundStyle(Theme.tertiary)
                Text(verbatim: detail).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .foregroundStyle(model.running ? Theme.ink : (paused ? Theme.ink : Theme.tertiary))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, paused ? 9 : 0)
        .frame(height: 20)
        .background {
            if paused {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.45), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.running)
    }
}

/// Reserves the width of `template` so changing digits never shift neighbouring text.
struct StableNumber: View {
    let text: String
    let template: String
    let font: Font
    var color: Color = Theme.ink
    /// Trailing keeps a column of readings on their decimal point; leading keeps a reading under its title.
    var alignment: Alignment = .trailing

    var body: some View {
        ZStack(alignment: alignment) {
            Text(template).hidden()
            Text(text).foregroundStyle(color)
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// A card's title row, as on a hardware panel: the title alone at the leading edge, and at the trailing edge only
/// what acts on the card (its settings, a band switch) and its status light. Keys and readings live in the card.
struct PanelHeader<Trailing: View>: View {
    let title: String
    /// What the panel shows, after the title in the quieter voice; dropped first when the row is tight.
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Eyebrow(title, color: Theme.title).fixedSize().layoutPriority(1)
            if let detail {
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: detail).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).fixedSize().padding(.leading, 6)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .animation(.formatText, value: detail)
    }
}

// MARK: - Loudness

/// Where the main reading sits against the target, as status text rather than a chip: a dot and the words in the
/// status colour (the accent on target, ochre above, slate below), the way the panel's status lights speak.
struct DeltaBadge: View {
    let value: Float
    let target: Float

    var body: some View {
        let valid = value > -70
        let (text, color) = Self.describe(value - target, valid: valid)
        HStack(spacing: 6) {
            Circle().fill(valid ? color : Theme.tertiary.opacity(0.6)).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .tracking(Localizer.shared.tracking(0.4))
                .monospacedDigit()
                .foregroundStyle(valid ? color : Theme.tertiary)
        }
        .fixedSize()
    }

    private static func describe(_ delta: Float, valid: Bool) -> (String, Color) {
        guard valid else { return ("—", Theme.tertiary) }
        if abs(delta) <= 1 { return (L("ON TARGET"), Theme.sage) }
        return ((delta > 0 ? "+" : "") + MeterScale.tenths(delta) + " LU", delta > 0 ? Theme.ochre : Theme.slate)
    }
}

/// The main reading on a transport-style slider: a hairline track ticked every 3 LU (longer every 12), the reading as
/// a filled run ending in a knob, in the delta's colour, and the target as an upright ink mark.
struct LoudnessGauge: View {
    let value: Float
    let target: Float
    /// Grows the track, knob and target mark with a taller summary (`HeroLayout.contentScale`).
    var scale: CGFloat = 1
    @AppStorage(LoudnessScale.key) private var rangeKey = LoudnessScale.full.rawValue
    @AppStorage(LoudnessUnit.key) private var unitKey = LoudnessUnit.lufs.rawValue

    var body: some View {
        let gaugeScale = LoudnessScale(rawValue: rangeKey) ?? .full
        let unit = LoudnessUnit(rawValue: unitKey) ?? .lufs
        let range = gaugeScale.range(target: target)
        let fraction: (Float) -> CGFloat = { lufs in
            CGFloat(max(0, min(1, (lufs - range.lowerBound) / (range.upperBound - range.lowerBound))))
        }
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let delta = value - target
                let fill = abs(delta) <= 1 ? Theme.sage : (delta > 0 ? Theme.ochre : Theme.slate)
                let lit = value > range.lowerBound
                let x = width * fraction(value)
                let mid = proxy.size.height / 2
                let knob = 9 + 3 * (scale - 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        context.fill(Path(roundedRect: CGRect(x: 0, y: mid - 1, width: size.width, height: 2), cornerRadius: 1),
                                     with: .color(Theme.hairline.opacity(0.14)))
                        let steps = Int(((range.upperBound - range.lowerBound) / gaugeScale.step).rounded())
                        for step in 0...steps {
                            let lu = range.lowerBound + Float(step) * gaugeScale.step
                            let major = (lu - range.lowerBound).truncatingRemainder(dividingBy: gaugeScale.labelStep) == 0
                            let tx = min(size.width - 0.5, max(0, size.width * fraction(lu) - 0.5))
                            context.fill(Path(CGRect(x: tx, y: mid + 5, width: 1, height: major ? 5 : 3)),
                                         with: .color(Theme.hairline.opacity(major ? 0.32 : 0.18)))
                        }
                    }
                    Capsule().fill(fill)
                        .frame(width: max(3, x), height: 3)
                        .offset(y: mid - 1.5)
                        .opacity(lit ? 1 : 0)
                    Circle().fill(fill)
                        .overlay { Circle().strokeBorder(Theme.dark ? Color.black.opacity(0.35) : Color.white.opacity(0.9), lineWidth: 1.5) }
                        .frame(width: knob, height: knob)
                        .offset(x: min(width - knob, max(0, x - knob / 2)), y: mid - knob / 2)
                        .opacity(lit ? 1 : 0)
                    Capsule().fill(Theme.ink)
                        .frame(width: 2, height: 16 + 8 * (scale - 1))
                        .offset(x: width * fraction(target) - 1, y: mid - 8 - 4 * (scale - 1))
                }
            }
            .frame(height: 16 + 8 * (scale - 1))
            let labels = Array(stride(from: range.lowerBound, through: range.upperBound + 0.01, by: gaugeScale.labelStep))
            HStack {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, tick in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(verbatim: unit.label(tick, target: target)).font(.axis).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

/// One statistic on the loudness summary, set like a hardware panel's parameter: the title over the reading, with no
/// tile behind, centred as a group in whatever height it is given, and the unit after the reading. The template
/// reserves the usual width of the reading, so the unit holds still while the digits change.
struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    var color: Color = Theme.ink
    var template = "−88.8"
    /// Grows the reading with a taller summary; the column itself stretches to the height it is offered.
    var scale: CGFloat = 1
    /// A warning chip beside the title (OVER).
    var alert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 6) {
                Eyebrow(title, color: Theme.tertiary)
                if let alert { AlarmTag(text: alert) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                StableNumber(text: value, template: template, font: .system(size: 19 * scale, weight: .medium),
                             color: color, alignment: .leading)
                if !unit.isEmpty {
                    Text(verbatim: unit).font(.system(size: 9 * (1 + (scale - 1) * 0.5), weight: .medium)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Where the plot of the summary's small panels (the 15 s history and the VU meter) lies: under the title row, inset
/// by the panel's margin.
struct PanelPlate: View {
    static let inset: CGFloat = 10
    static let top: CGFloat = 46
    static func rect(in size: CGSize) -> CGRect {
        CGRect(x: inset, y: top, width: max(1, size.width - 2 * inset), height: max(1, size.height - top - inset))
    }
    var body: some View {
        GeometryReader { proxy in
            let rect = Self.rect(in: proxy.size)
            PlotPlate().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
        }
    }
}

/// The chart line scale, shared by every SwiftUI plot: the zero or reference line, major and minor grid lines,
/// and the short ticks the axis labels name. The Metal scenes use the same opacities (`MeterGrid`).
enum ChartInk {
    static var reference: Double { Theme.dark ? 0.28 : 0.28 }
    static var major: Double { Theme.dark ? 0.14 : 0.14 }
    static var minor: Double { Theme.dark ? 0.065 : 0.075 }
    static var tick: Double { Theme.dark ? 0.38 : 0.40 }
}

/// An alarm: the only filled tag in the interface, ember with a warning glyph, so an over reads by shape and word as
/// well as colour.
struct AlarmTag: View {
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7, weight: .bold))
            Text(text).font(.system(size: 8, weight: .heavy)).tracking(Localizer.shared.tracking(0.6))
        }
        .foregroundStyle(Theme.onStatus)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.ember))
    }
}

/// Short-term (accent) over momentary (faint) for the chosen span (the last 15 s by default, up to the whole
/// session), with the ±1 LU target band and time marks, on a card of its own beside the summary.
struct LoudnessHistory: View {
    let short: [Float]
    let momentary: [Float]
    let target: Float
    var model: MeterModel?
    var panel: MeterPanel? = nil
    /// Seconds across the plot, and the share of its width (from the right, "now") the readings cover.
    var seconds: Double = Readouts.historySeconds
    var covered: Double? = nil
    var title: String? = nil
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(HistoryScale.momentaryKey) private var showsMomentary = true
    @AppStorage(HistoryScale.bandKey) private var showsBand = true
    @AppStorage(HistoryScale.key) private var scaleKey = HistoryScale.full.rawValue
    @AppStorage(LoudnessUnit.key) private var unitKey = LoudnessUnit.lufs.rawValue

    /// When the newest reading was taken (the live 15 s plot): between readings the curves glide left at the readings'
    /// pace instead of jumping a step at each, so the plot scrolls as smoothly as the meters around it.
    var newest: Date? = nil

    /// Where everything sits in a canvas of `size`.
    struct Plot {
        let rect: CGRect
        let levels: ClosedRange<Float>
        func y(_ lufs: Float) -> CGFloat {
            rect.maxY - CGFloat(max(0, min(1, (lufs - levels.lowerBound) / (levels.upperBound - levels.lowerBound)))) * rect.height
        }
        init(size: CGSize, scale: HistoryScale, target: Float) {
            let plate = PanelPlate.rect(in: size)
            rect = CGRect(x: plate.minX + 8, y: plate.minY + 10, width: max(1, plate.width - 16), height: max(1, plate.height - 30))
            levels = scale.span(target: target)
        }
    }

    var body: some View {
        let scale = HistoryScale(rawValue: scaleKey) ?? .full
        let unit = LoudnessUnit(rawValue: unitKey) ?? .lufs
        let showsBand = showsBand
        Canvas { context, size in
            let plot = Plot(size: size, scale: scale, target: target)
            let rect = plot.rect, levels = plot.levels
            func y(_ lufs: Float) -> CGFloat { plot.y(lufs) }
            let band = CGRect(x: rect.minX, y: y(target + 1), width: rect.width, height: max(1, y(target - 1) - y(target + 1)))
            if showsBand { context.fill(Path(band), with: .color(Theme.sage.opacity(Theme.dark ? 0.12 : 0.12))) }
            // In LU the grid sits on whole steps from the target, so its labels read −6, −12…
            let grid = unit == .lu && scale == .full
                ? [target - 6, target - 12, target - 18].filter { levels.contains($0) } : scale.grid(target: target)
            for lufs: Float in grid {
                context.fill(Path(CGRect(x: rect.minX, y: y(lufs), width: rect.width, height: 0.5)), with: .color(Theme.hairline.opacity(ChartInk.major)))
            }
            let span = max(1, seconds)
            let marks = HistorySpan.marks(seconds: span)
            for mark in marks {
                let x = rect.maxX - CGFloat(mark / span) * rect.width
                context.fill(Path(CGRect(x: x, y: rect.minY, width: 0.5, height: rect.height)), with: .color(Theme.hairline.opacity(ChartInk.minor)))
                context.fill(Path(CGRect(x: x, y: rect.maxY, width: 0.5, height: 4)), with: .color(Theme.hairline.opacity(ChartInk.tick)))
            }
            // The scale in place: the two grid lines' LUFS at the left, the target at the right of its band, and the
            // 5 s marks under the plot ("now" is the overlay at the right).
            guard rect.height >= 40 else { return }
            for lufs: Float in grid where abs(lufs - target) > 2.5 && rect.height >= 72 {
                context.draw(Text(verbatim: unit.label(lufs, target: target)).font(.axis).foregroundColor(Theme.tertiary),
                             at: CGPoint(x: rect.minX + 2, y: y(lufs) - 7), anchor: .leading)
            }
            context.draw(Text(verbatim: unit == .lu ? "0" : MeterScale.signedInteger(target)).font(.axis).foregroundColor(Theme.sage),
                         at: CGPoint(x: rect.minX + 2, y: y(target + 1) - 7), anchor: .leading)
            if rect.width >= 150 {
                for mark in marks {
                    let x = rect.maxX - CGFloat(mark / span) * rect.width
                    guard x > rect.minX + 24 else { continue }
                    context.draw(Text(verbatim: "−" + HistorySpan.label(mark)).font(.axis).foregroundColor(Theme.tertiary),
                                 at: CGPoint(x: x, y: rect.maxY + 11), anchor: .center)
                }
            }
        }
        .overlay {
            GeometryReader { proxy in
                let plot = Plot(size: proxy.size, scale: scale, target: target)
                let share = CGFloat(covered ?? Double(short.count) / Double(Readouts.historyLength))
                let step = plot.rect.width * min(1, share) / CGFloat(max(1, short.count - 1))
                HistoryCurves(short: short, momentary: momentary, plot: plot, step: step, showsMomentary: showsMomentary,
                              dark: Theme.dark, palette: Theme.palette,
                              glide: newest != nil && (model?.running ?? false) ? newest : nil)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            CardTitle(title: title ?? L("LAST 15 S"), model: model, panel: panel, settings: panel == nil ? nil : .history)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(L("now")).font(.axis).foregroundStyle(Theme.tertiary)
                .padding(.bottom, PanelPlate.inset + 6).padding(.trailing, PanelPlate.inset + 8)
        }
        .background { PanelPlate() }
        .background { CardSurface() }
    }

}

/// The loudness history's short-term and momentary curves, the newest reading at the plot's right edge, as two shape
/// layers clipped to the plot. Live (`glide` is when the newest reading was taken) the window server slides them one
/// step left over the interval to the next reading, so the plot scrolls evenly at the display's rate with no work in
/// the app between readings (a SwiftUI timeline redrawing it every frame cost about 8 % of a core).
private struct HistoryCurves: NSViewRepresentable {
    let short: [Float]
    let momentary: [Float]
    let plot: LoudnessHistory.Plot
    let step: CGFloat
    let showsMomentary: Bool
    let dark: Bool
    let palette: Theme.Palette
    let glide: Date?

    final class View: NSView {
        let clip = CALayer(), slide = CALayer(), shortLayer = CAShapeLayer(), momentaryLayer = CAShapeLayer()
        var shown: (glide: Date?, step: CGFloat, rect: CGRect)?
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            clip.masksToBounds = true
            for shape in [momentaryLayer, shortLayer] {
                shape.fillColor = nil
                shape.lineJoin = .round
                slide.addSublayer(shape)
            }
            clip.addSublayer(slide)
            layer?.addSublayer(clip)
        }
        required init?(coder: NSCoder) { nil }
    }

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        let rect = plot.rect, levels = plot.levels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contentsScale = view.window?.backingScaleFactor ?? 2
        // The clip spans the plot (a little taller, for the stroke at its edges); the curves are laid out in it with the
        // newest reading at its right edge.
        let clipRect = rect.insetBy(dx: 0, dy: -4)
        view.clip.frame = clipRect
        view.slide.frame = CGRect(origin: .zero, size: clipRect.size)
        func path(_ values: [Float]) -> CGPath {
            let path = CGMutablePath()
            let start = rect.width - CGFloat(values.count - 1) * step
            var drawing = false
            for (index, value) in values.enumerated() {
                guard value > min(MeterScale.loudnessFloor, levels.lowerBound) - 12 else { drawing = false; continue }
                let point = CGPoint(x: start + CGFloat(index) * step, y: min(rect.maxY, plot.y(value)) - clipRect.minY)
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            return path
        }
        view.shortLayer.path = path(short)
        view.shortLayer.strokeColor = NSColor(Theme.sage).cgColor
        view.shortLayer.lineWidth = 1.8
        view.momentaryLayer.isHidden = !showsMomentary
        if showsMomentary {
            view.momentaryLayer.path = path(momentary)
            view.momentaryLayer.strokeColor = NSColor(Theme.ink.opacity(dark ? 0.28 : 0.30)).cgColor
            view.momentaryLayer.lineWidth = 1
        }
        for shape in [view.shortLayer, view.momentaryLayer] { shape.contentsScale = view.layer?.contentsScale ?? 2 }
        CATransaction.commit()
        // A new reading (or a new size) starts the slide again from where the new curves sit; paused, they hold.
        let key = (glide: glide, step: step, rect: rect)
        guard view.shown.map({ $0.glide != key.glide || $0.step != key.step || $0.rect != key.rect }) ?? true else { return }
        view.shown = key
        view.slide.removeAnimation(forKey: "glide")
        guard let glide else { return }
        let interval = 1 / Readouts.rate
        // Started part way if this reading was taken a moment ago, so the curves stay where time puts them.
        let elapsed = min(interval, max(0, Date().timeIntervalSince(glide)))
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -step
        animation.duration = interval
        animation.beginTime = view.slide.convertTime(CACurrentMediaTime(), from: nil) - elapsed
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        view.slide.add(animation, forKey: "glide")
    }
}

/// How much time the history plot spans: the last 15 s, 1 or 5 minutes, or the whole measurement since the last reset.
enum HistorySpan: String, CaseIterable {
    case fifteen, minute, five, session

    static let key = "history.span"

    var seconds: Double? {
        switch self {
        case .fifteen: return 15
        case .minute: return 60
        case .five: return 300
        case .session: return nil
        }
    }

    var title: String {
        switch self {
        case .fifteen: return L("15 s")
        case .minute: return L("1 min")
        case .five: return L("5 min")
        case .session: return L("Session")
        }
    }

    /// The panel's title.
    var heading: String {
        switch self {
        case .fifteen: return L("LAST 15 S")
        case .minute: return L("LAST 1 MIN")
        case .five: return L("LAST 5 MIN")
        case .session: return L("SESSION")
        }
    }

    /// Time marks back from now, about three to five across the span.
    static func marks(seconds: Double) -> [Double] {
        let steps: [Double] = [5, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let step = steps.first { seconds / $0 <= 5 } ?? 7200
        return Array(stride(from: step, to: seconds, by: step))
    }

    /// Kept per language: the plot redraws its marks with every reading, and the locale's number formatting is the
    /// slow part of drawing it.
    private static var labels: [LabelKey: String] = [:]
    private struct LabelKey: Hashable {
        let language: AppLanguage
        let seconds: Int
    }

    static func label(_ seconds: Double) -> String {
        let key = LabelKey(language: Localizer.shared.language, seconds: Int(seconds))
        if let label = labels[key] { return label }
        let label = seconds < 60 ? L("%d s", Int(seconds))
            : seconds < 3600 ? L("%d min", Int(seconds / 60)) : L("%d h", Int(seconds / 3600))
        labels[key] = label
        return label
    }
}

/// The LAST 15 S plot's loudness scale: the summary's full −36…0 LUFS, or 18 LU around the target.
enum HistoryScale: String, CaseIterable {
    case full, close

    static let key = "history.scale"
    static let momentaryKey = "history.momentary"
    static let bandKey = "history.targetBand"

    var title: String {
        switch self {
        case .full: return L("Full")
        case .close: return L("Close")
        }
    }

    func span(target: Float) -> ClosedRange<Float> {
        switch self {
        case .full: return MeterScale.loudnessFloor...0
        case .close: return (target - 12)...(target + 6)
        }
    }

    /// Grid lines: −12 and −24 LUFS on the full scale; every 6 LU from the target on the close one.
    func grid(target: Float) -> [Float] {
        switch self {
        case .full: return [-12, -24]
        case .close: return [target + 6, target - 6, target - 12]
        }
    }
}

// MARK: - Waveform and Soundstage

/// Spring shared by every SwiftUI element that follows the monitoring mode; the Metal scene's critically
/// damped presence uses the same 0.55 s response, so text and graphics move as one.
extension Animation {
    static let formatShift = Animation.spring(response: 0.55, dampingFraction: 1)
    /// What a header says about the mode (its detail, its key, its BANDS menu) cross-fades in a quarter second, so
    /// the words change while the panels below are still on their way.
    static var formatText: Animation { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.24) }
}

extension FormatMix {
    /// The Soundstage well's hand-over between Stereo's stereometer and Immersive's dome at presence `p` (0 Stereo,
    /// 1 Immersive): a relay rather than a double exposure. The stereometer leaves over the first 55 % of the way,
    /// swelling 6 % toward the viewer as it goes; the dome arrives over the last 70 %, settling in from 8 % farther
    /// out. Run backwards, the dome recedes first and the stereometer settles back into place. The Metal scene and the
    /// SwiftUI labels both read it, so lines and words move as one.
    static func relay(_ p: CGFloat) -> (stereo: CGFloat, dome: CGFloat, stereoScale: CGFloat, domeZoom: Double) {
        func smooth(_ x: CGFloat) -> CGFloat { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        let leaving = smooth(p / 0.55), arriving = smooth((p - 0.3) / 0.7)
        return (1 - leaving, arriving, 1 + 0.06 * leaving, 0.92 + 0.08 * Double(arriving))
    }
}

/// The stereometer's readings come and go with the stereometer itself (`FormatMix.relay`), not on a spring of their own.
private struct StereoRelay: ViewModifier, Animatable {
    var presence: CGFloat
    var animatableData: CGFloat {
        get { presence }
        set { presence = newValue }
    }
    func body(content: Content) -> some View { content.opacity(FormatMix.relay(presence).stereo) }
}

/// Opacity of a receding element at a given presence: squared, so text clears out before rows finish
/// collapsing and never overlaps its neighbours mid-transition.
private func dissolve(_ weight: CGFloat) -> Double { Double(weight * weight) }

/// The two presences a format sets, animated together by the SwiftUI overlays: `presence` 0 → 1 toward
/// Spatial, `mono` 0 → 1 toward Mono. Stereo is (0, 0). Metal steps the same pair with its own springs.
struct FormatMix: Equatable {
    var presence: CGFloat
    var mono: CGFloat

    init(_ format: ChannelFormat) {
        presence = format == .spatial ? 1 : 0
        mono = format == .mono ? 1 : 0
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(presence, mono) }
        set { presence = newValue.first; mono = newValue.second }
    }
}

/// The Waveform card: header row, then a display well holding its own canvas and labels. In Stereo it shows
/// L over R; in Spatial every channel of the layout gets a lane, and the lanes share the well's height, so
/// the card keeps its size while lanes grow in or recede. Canvas and labels are both placed from
/// `WaveformLayout` of the well's live size and the same presence spring.
struct WaveformPanel: View {
    let model: MeterModel
    let layout: SpeakerLayout
    let format: ChannelFormat
    let activeRoles: [Bool]
    @AppStorage(DisplayOptions.waveSecondsKey) private var waveSeconds = 4
    @AppStorage(WaveScale.key) private var scaleKey = WaveScale.linear.rawValue
    @State private var pointer: CGPoint? = Diagnostics.waveProbePoint

    var body: some View {
        let seconds = DisplayOptions.waveChoices.contains(waveSeconds) ? waveSeconds : 4
        let scale = WaveScale(rawValue: scaleKey) ?? .linear
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                WaveHeader(model: model, format: format, layout: layout)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .waveform, model: model)
                        ZoomResting {
                            WaveformLabels(size: proxy.size, speakers: layout.speakers, mix: FormatMix(format),
                                           activeRoles: activeRoles, scale: scale, seconds: seconds)
                            if let pointer {
                                WaveformCursor(size: proxy.size, point: pointer, speakers: layout.speakers, mix: FormatMix(format),
                                               activeRoles: activeRoles, seconds: seconds)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        // A held diagnostic point is not moved by the real pointer.
                        guard Diagnostics.waveProbePoint == nil else { return }
                        switch phase {
                        case .active(let point): pointer = point
                        case .ended: pointer = nil
                        }
                    }
                    .animation(.formatShift, value: format)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
                .background { PlotPlate() }
            }
        }
    }
}

/// The Soundstage card: the top-down room of the current format, with its own header and well.
struct SoundstagePanel: View {
    @ObservedObject private var l10n = Localizer.shared
    let model: MeterModel
    let activeRoles: [Bool]
    let format: ChannelFormat
    let layout: SpeakerLayout
    /// The stereometer's and the band map's resolution, chosen on the header.
    @AppStorage(DisplayOptions.stageBandsKey) private var bands = StereoBands.Resolution.five.rawValue
    /// The room's band markers in Immersive; hidden with the BANDS menu's Off.
    @AppStorage(DisplayOptions.bandMarkersKey) private var markers = true

    @AppStorage(DisplayOptions.domeBandsKey) private var domeBands = DisplayOptions.storedDomeBands.rawValue
    @AppStorage(DisplayOptions.domeCentroidKey) private var domeCentroid = true
    /// The speaker layouts: an edit redraws the dome's labels at once.
    @ObservedObject private var speakerLayouts = SpeakerLayoutStore.shared
    /// While a drag or pinch turns or zooms the dome, which hides the pointer's reading (the camera itself lives with
    /// `DomeCamera`, so a drag does not re-render this panel).
    @State private var dragging = false
    @State private var probeLocation: CGPoint? = Diagnostics.domeProbePoint

    private var domeOptions: DisplayOptions {
        var options = model.displayOptions
        options.domeBands = domeChoice
        options.domeCentroid = domeCentroid
        return options
    }

    private var domeChoice: BandChoice { BandChoice(rawValue: domeBands) ?? BandChoice(.overall) }
    private var stageChoice: BandChoice { BandChoice(rawValue: bands) ?? BandChoice(.five) }

    var body: some View {
        let resolution = stageChoice.resolution
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                StageHeader(model: model) {
                    // One BANDS capsule in every mode: the split and each band of it alone. In Immersive its menu also
                    // switches the dome's view, which otherwise lives in the panel's settings.
                    if format == .spatial {
                        BandChoiceMenu(choice: domeChoice, select: { choice in
                            domeBands = choice.rawValue; model.displayOptions.domeBands = choice
                        }, help: L("Show the full band, 3 or 5 bands in their colours, or one band alone in the dome.")) {
                            DomeViewPicker(choice: DomeCamera.shared.choice)
                        }
                        .transition(.opacity)
                    } else {
                        BandChoiceMenu(choice: stageChoice, select: { choice in
                            bands = choice.rawValue
                            model.stageBands = choice.resolution
                            model.displayOptions.stageSolo = choice.solo
                        }, help: L("Stereo readings for the full band, 3 or 5 frequency bands, or one band alone")) { EmptyView() }
                        .transition(.opacity)
                    }
                }
                .animation(.formatText, value: format)
                GeometryReader { proxy in
                    // The well does not depend on the mode; the labels animate the format mix themselves.
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .soundstage, model: model)
                        ZoomResting {
                            SoundstageStaticLabels(size: proxy.size, mix: FormatMix(format), layout: layout,
                                                   activeRoles: activeRoles, part: .room, resolution: resolution, solo: stageChoice.solo,
                                                   markers: markers, domeOptions: domeOptions, geometry: model.displayGeometry(for: layout))
                            if format != .spatial {
                                StageReadings(readouts: model.readouts, mono: format == .mono, choice: stageChoice, running: model.running || model.frozen)
                                    .padding(.horizontal, 14).padding(.bottom, 10)
                                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                                    .transition(.modifier(active: StereoRelay(presence: 1), identity: StereoRelay(presence: 0)))
                            }
                        }
                        if format == .spatial, !dragging, let location = probeLocation {
                            PanelTimeline(interval: 1.0 / 15) {
                                if let probe = (SceneStore.existing(.soundstage) as? SoundstageScene)?
                                    .domeProbe(at: location, layout: layout) {
                                    DomeProbeTag(probe: probe)
                                        .position(x: min(max(location.x, 120), proxy.size.width - 120),
                                                  y: location.y > 40 ? location.y - 22 : location.y + 24)
                                }
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        // A held diagnostic point is not moved by the real pointer.
                        guard Diagnostics.domeProbePoint == nil else { return }
                        switch phase {
                        case .active(let point): probeLocation = point
                        case .ended: probeLocation = nil
                        }
                    }
                    // Drag across to orbit, up and down to raise or lower the camera; in the Front and Isometric views
                    // the drag carries on in the Dome view from that camera, the Top view turns, the Side view stays.
                    // Scroll or pinch to zoom; a double-click returns to the default view.
                    .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                        guard format == .spatial else { return }
                        if !dragging { dragging = true }
                        DomeCamera.shared.drag(translation: value.translation)
                    }.onEnded { _ in
                        dragging = false
                        DomeCamera.shared.endDrag()
                    })
                    .simultaneousGesture(MagnificationGesture().onChanged { scale in
                        guard format == .spatial else { return }
                        DomeCamera.shared.pinch(scale: scale)
                    }.onEnded { _ in DomeCamera.shared.endPinch() })
                    // A double-click glides back to the default view.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        guard format == .spatial else { return }
                        DomeCamera.shared.reset()
                    })
                    .animation(.formatShift, value: format)
                    .animation(.formatShift, value: resolution)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
                .background { PlotPlate() }
            }
        }
    }
}

/// Over each lit clip light, a click target that clears the overs: every channel's clip light and over fill,
/// and the held TRUE PEAK with them (one reset, as a click on TRUE PEAK does). Present only while that channel
/// has gone over since the last clear.
private struct ClipLightTargets: View {
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    let size: CGSize
    let mix: FormatMix
    let layout: SpeakerLayout
    let lanes: CGFloat
    let clear: () -> Void

    var body: some View {
        let stage = SoundstageLayout(size: size, presence: mix.presence, mono: mix.mono, layout: layout, part: .levels, lanes: lanes)
        let held = readouts.values.heldTruePeaks
        ZStack(alignment: .topLeading) {
            ForEach(Array(stage.speakers.enumerated()), id: \.offset) { index, speaker in
                let cap = stage.cap(index)
                if speaker.role < held.count, held[speaker.role] >= 1, cap.width > 1 {
                    Button(action: clear) {
                        Color.clear
                            .frame(width: max(22, cap.width + 12), height: max(22, cap.height + 12))
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(L("Click to clear the over warning"))
                        .accessibilityLabel(L("Over on %@", speaker.name))
                        .accessibilityHint(L("Click to clear the over warning"))
                        .position(x: cap.midX, y: cap.midY)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The Channel Levels card: a vertical Peak and RMS meter per channel with true-peak overs, and in Stereo the
/// L/R correlation and what it means for the listener.
struct ChannelLevelsPanel: View {
    let model: MeterModel
    let readouts: Readouts
    let activeRoles: [Bool]
    let format: ChannelFormat
    let layout: SpeakerLayout
    @ObservedObject private var l10n = Localizer.shared
    /// The correlation bar's resolution, chosen beside its title.
    @AppStorage(DisplayOptions.levelsBandsKey) private var bands = StereoBands.Resolution.five.rawValue

    var body: some View {
        let resolution = StereoBands.Resolution(rawValue: bands) ?? .five
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: L("CHANNEL LEVELS")) {
                    // The key to the bars, while the title row has room for it.
                    ViewThatFits(in: .horizontal) { MeterLegend(); Color.clear.frame(width: 0, height: 0) }
                    PanelSettingsButton(panel: .levels, model: model)
                        }
                GeometryReader { proxy in
                    let mix = FormatMix(format)
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .levels, model: model)
                        ZoomResting {
                            SoundstageStaticLabels(size: proxy.size, mix: mix, layout: layout, activeRoles: activeRoles, part: .levels,
                                                   resolution: resolution, lanes: CGFloat(resolution.count))
                            SoundstageReadouts(readouts: readouts, size: proxy.size, mix: mix, layout: layout,
                                               activeRoles: activeRoles, resolution: resolution, lanes: CGFloat(resolution.count))
                            ClipLightTargets(readouts: readouts, size: proxy.size, mix: mix, layout: layout,
                                             lanes: CGFloat(resolution.count), clear: model.resetTruePeak)
                        }
                        // The correlation section's own switcher, in its title row (Stereo only, like the section).
                        // A narrow section (the strip's side-by-side well) leaves the choice to the panel's settings.
                        let area = SoundstageLayout(size: proxy.size, presence: 0, mono: 0, layout: layout, part: .levels,
                                                    lanes: CGFloat(resolution.count)).correlationArea
                        if format == .stereo, area.width >= 380 {
                            ZoomResting {
                                BandSwitch(selection: resolution) {
                                    bands = $0.rawValue
                                    model.levelsBands = $0
                                }
                                // Right-aligned between the title and the headline reading; short labels when that is tight.
                                .frame(width: max(0, area.width - 54 - 118), alignment: .trailing)
                                .position(x: area.minX + 118 + (area.width - 54 - 118) / 2, y: area.minY + 8)
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.formatShift, value: format)
                    .animation(.formatShift, value: resolution)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
                .background { PlotPlate() }
            }
        }
    }
}

/// Picks how finely the stereo readings split the spectrum: full band, 3 bands or 5 bands. The system segmented
/// control (Liquid Glass on macOS 26), small, for a panel's frame; each panel keeps its own choice. Where the frame
/// is tight it falls back to the short labels (Full, 3, 5). A choice animates the panel on the `formatShift`
/// spring, like a mode change.
struct BandSwitch: View {
    let selection: StereoBands.Resolution
    let select: (StereoBands.Resolution) -> Void
    /// In Immersive, whether the room's band markers show; nil where they do not apply (the menu has no Off).
    var markers: Bool? = nil
    var setMarkers: (Bool) -> Void = { _ in }
    @ObservedObject private var l10n = Localizer.shared

    private static let off = "off"

    /// A pill like the loudness TARGET and CEILING: the current resolution, opening a menu of the three, and in
    /// Immersive an Off that hides the band markers.
    var body: some View {
        let hidden = markers == false
        SummaryMenu(title: L("BANDS"), value: hidden ? L("Off") : selection.title,
                    help: markers == nil ? L("Stereo readings for the full band, or split into 3 or 5 frequency bands")
                                         : L("Band markers in the room: the full band, 3 or 5 bands, or off")) {
            Picker(L("Frequency bands"), selection: Binding(get: { hidden ? Self.off : selection.rawValue }, set: { choice in
                withAnimation(.formatShift) {
                    if choice == Self.off {
                        setMarkers(false)
                    } else if let resolution = StereoBands.Resolution(rawValue: choice) {
                        if markers == false { setMarkers(true) }
                        select(resolution)
                    }
                }
            })) {
                ForEach(StereoBands.Resolution.allCases, id: \.self) { Text(verbatim: $0.title).tag($0.rawValue) }
                if markers != nil {
                    Divider()
                    Text(L("Off")).tag(Self.off)
                }
            }
        }
    }
}

/// The Soundstage's BANDS capsule (`BandChoice`): the split, then each band of it alone, checked when chosen;
/// `extra` adds further sections (Immersive's view).
struct BandChoiceMenu<Extra: View>: View {
    let choice: BandChoice
    let select: (BandChoice) -> Void
    let help: String
    @ViewBuilder var extra: () -> Extra
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        SummaryMenu(title: L("BANDS"), value: choice.title, help: help) {
            Picker(L("Frequency bands"), selection: Binding<StereoBands.Resolution?>(
                get: { choice.solo == nil ? choice.resolution : nil },
                set: { resolution in if let resolution { withAnimation(.formatShift) { select(BandChoice(resolution)) } } })) {
                ForEach(StereoBands.Resolution.allCases, id: \.self) { Text(verbatim: $0.title).tag(Optional($0)) }
            }
            Picker(L("Single band"), selection: Binding<BandChoice?>(
                get: { choice.solo == nil ? nil : choice },
                set: { single in if let single { withAnimation(.formatShift) { select(single) } } })) {
                ForEach(choice.singles, id: \.self) { single in
                    Text(verbatim: BandChoice.range(single.resolution, single.solo ?? 0)).tag(Optional(single))
                }
            }
            extra()
        }
    }
}

/// Key to the Channel Levels bars, drawn with the same shapes and colours: the solid RMS fill, the translucent
/// peak behind it and the ink peak-hold mark.
struct MeterLegend: View {
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 10) {
            item(Text(verbatim: "RMS")) { Capsule().fill(Theme.sage).frame(width: 5, height: 10) }
            item(Text(L("Peak"))) { Capsule().fill(Theme.sage.opacity(0.35)).frame(width: 5, height: 10) }
            item(Text(L("Hold"))) { Capsule().fill(Theme.ink).frame(width: 10, height: 2) }
        }
        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func item<Mark: View>(_ label: Text, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 4) { mark().frame(width: 10, height: 10); label }
    }
}

private struct WaveHeader: View {
    let model: MeterModel
    let format: ChannelFormat
    let layout: SpeakerLayout
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        // Each lane names its channel, so the title stands alone.
        PanelHeader(title: L("WAVEFORM")) {
            ViewThatFits(in: .horizontal) { WaveformKey(format: format, layout: layout); Color.clear.frame(width: 0, height: 0) }
            PanelSettingsButton(panel: .waveform, model: model)
        }
        .animation(.formatText, value: format)
    }
}

private struct StageHeader<Trailing: View>: View {
    let model: MeterModel
    @ViewBuilder var trailing: Trailing
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        // The title never truncates; the band switch drops to its short labels first.
        PanelHeader(title: L("SOUNDSTAGE")) {
            trailing.layoutPriority(1)
            // With the model: the speaker layout shown and opened is the format on screen, and the source's notes show.
            PanelSettingsButton(panel: .soundstage, model: model)
        }
    }
}

/// The key to the waveform's lane colours: left-side channels in the accent, right-side in sand, the upper layer and
/// LFE in their own hues, and the clip colour.
struct WaveformKey: View {
    let format: ChannelFormat
    let layout: SpeakerLayout
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let spatial = format == .spatial
        HStack(spacing: 10) {
            LegendDot(color: Theme.sage, text: spatial ? L("Left side") : (format == .mono ? L("Mono") : L("Left")))
            if format != .mono { LegendDot(color: Theme.sand, text: spatial ? L("Right side") : L("Right")) }
            if spatial {
                if layout.heightCount > 0 { LegendDot(color: Theme.heather, text: L("Height")) }
                if layout.hasLFE { LegendDot(color: Theme.clay, text: "LFE") }
            }
            LegendDot(color: Theme.ember, text: L("Clip"))
        }
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// Channel names beside each lane and −6 dBFS marks at its half-deflection lines, animated with `presence`.
private struct WaveformLabels: View, Animatable {
    @ObservedObject private var l10n = Localizer.shared
    let size: CGSize
    let speakers: [Speaker]
    var mix: FormatMix
    let activeRoles: [Bool]
    let scale: WaveScale
    let seconds: Int

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { mix.animatableData }
        set { mix.animatableData = newValue }
    }

    var body: some View {
        let layout = WaveformLayout(size: size, speakers: speakers, presence: mix.presence, mono: mix.mono)
        let scope = layout.waveform
        ZStack(alignment: .topLeading) {
            ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                let lane = layout.lanes[index]
                let weight = layout.weight(index)
                let active = activeRoles[speaker.role]
                Text(speaker.displayName(mono: mix.mono))
                    // Down to 7 pt, so the 16 lanes of 9.1.6 keep their names in the smallest window.
                    .font(.system(size: lane.height < 9 ? 7 : (lane.height < 18 ? 8 : 10), weight: .semibold).width(.expanded))
                    .foregroundStyle(active ? Theme.laneRGB(speaker).color : Theme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // Right-aligned against the lanes, so names of every width end at the same edge.
                    .frame(width: WaveformLayout.gutter - 8, alignment: .trailing)
                    .scaleEffect(0.8 + 0.2 * weight, anchor: .trailing)
                    .opacity(dissolve(weight) * (lane.height >= 6 ? 1 : 0))
                    .position(x: scope.minX - 4 - (WaveformLayout.gutter - 8) / 2, y: lane.midY)
                if lane.height >= WaveformLayout.labelledLane {
                    // The lane's level scale in dBFS: full scale at the top edge, the marks on both halves.
                    ForEach(scale.labelled(laneHeight: lane.height), id: \.self) { db in
                        let at = CGFloat(scale.deflection(decibels: db))
                        ForEach(db == 0 ? [CGFloat(1)] : [1, -1], id: \.self) { side in
                            Text(verbatim: db == 0 ? "0" : "−\(Int(-db))")
                                .font(.axis)
                                .foregroundStyle(db == 0 ? Theme.secondary : Theme.tertiary)
                                .opacity(dissolve(weight))
                                .position(x: scope.maxX + WaveformLayout.scaleColumn / 2,
                                          y: layout.laneY(index, amplitude: at * side) + (db == 0 ? 5 : 0))
                        }
                    }
                }
            }
            // The time ruler: whole seconds back from now, every other one on the 8 s span.
            let step = seconds > 4 ? 2 : 1
            ForEach(Array(Swift.stride(from: step, to: seconds, by: step)), id: \.self) { second in
                Text(verbatim: "−\(second)s").font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                    .position(x: layout.x(secondsAgo: Double(second), seconds: Double(seconds)),
                              y: scope.maxY + WaveformLayout.ruler / 2 + 1)
            }
            Text(L("now")).font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                .position(x: scope.maxX - 10, y: scope.maxY + WaveformLayout.ruler / 2 + 1)
        }
        .allowsHitTesting(false)
    }
}

/// The pointer over the Waveform: a cursor through every lane at that moment, and a tag with how long ago it was
/// and the sample peak there in dBFS, read from the columns the lanes draw: every lane in Stereo and Mono, the
/// lane under the pointer when there are more. Pause to read a moment at leisure.
private struct WaveformCursor: View {
    let size: CGSize
    let point: CGPoint
    let speakers: [Speaker]
    let mix: FormatMix
    let activeRoles: [Bool]
    let seconds: Int

    var body: some View {
        let layout = WaveformLayout(size: size, speakers: speakers, presence: mix.presence, mono: mix.mono)
        let scope = layout.waveform
        if scope.insetBy(dx: -1, dy: -1).contains(point) {
            let x = min(max(point.x, scope.minX), scope.maxX)
            let ago = max(0, layout.secondsAgo(x: x, seconds: Double(seconds)))
            // About one point of history, the window the lanes draw a pixel from.
            let window = Double(seconds) / Double(max(1, scope.width))
            let hovered = layout.lane(at: point.y)
            let shown = layout.lanes.indices.filter { layout.lanes[$0].height >= 6 && activeRoles[speakers[$0].role] }
            let read = shown.count <= 2 ? shown : (hovered.map { [$0] } ?? [])
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.ink.opacity(0.45)).frame(width: 1, height: scope.height)
                    .position(x: x, y: scope.midY)
                PanelTimeline(interval: 1.0 / 15) {
                    let scene = SceneStore.existing(.waveform) as? WaveformScene
                    let readings: [WaveformProbeTag.Reading] = read.map { index in
                        let speaker = speakers[index]
                        return WaveformProbeTag.Reading(name: speaker.displayName(mono: mix.mono), hue: Theme.laneRGB(speaker),
                                                        peak: scene?.peak(role: speaker.role, secondsAgo: ago, window: window))
                    }
                    WaveformProbeTag(secondsAgo: ago, readings: readings)
                        .position(x: min(max(x, scope.minX + 100), scope.maxX - 100), y: scope.minY + 12)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// The Waveform cursor's readout: time before now, then each read lane's name and sample peak (OVER past full scale).
private struct WaveformProbeTag: View {
    struct Reading {
        let name: String
        let hue: Theme.RGB
        let peak: Float?
    }
    let secondsAgo: Double
    let readings: [Reading]
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let font = Font.caption2.weight(.medium).monospacedDigit()
        HStack(spacing: 7) {
            Text(verbatim: secondsAgo < 0.005 ? L("now") : String(format: "−%.2f s", secondsAgo))
                .font(font).foregroundStyle(Theme.secondary)
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                HStack(spacing: 3) {
                    Text(verbatim: reading.name).font(font.weight(.semibold)).foregroundStyle(reading.hue.color)
                    if let peak = reading.peak, peak >= 1 {
                        Text(L("OVER")).font(font.weight(.bold)).foregroundStyle(Theme.ember)
                    } else if let peak = reading.peak, peak > 0.000_001 {
                        Text(verbatim: MeterScale.tenths(20 * log10(peak), floor: -120) + " dBFS").font(font).foregroundStyle(Theme.ink)
                    } else {
                        Text(verbatim: "−∞").font(font).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background { BadgeSurface() }
    }
}

/// The dome's views in the BANDS menu, checked at the current one; picking one glides there (`DomeCamera`).
private struct DomeViewPicker: View {
    @ObservedObject var choice: DomeViewChoice
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Picker(L("View"), selection: Binding(get: { choice.view }, set: { DomeCamera.shared.select($0) })) {
            ForEach(DomeView.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
    }
}

/// Room: the speaker names. Levels: group headers, channel names, the dB scale and the correlation title.
/// `Animatable` on `presence`, so SwiftUI re-lays it out every frame of the mode spring, as Metal does.
private struct SoundstageStaticLabels: View, Animatable {
    @ObservedObject private var l10n = Localizer.shared
    let size: CGSize
    var mix: FormatMix
    let layout: SpeakerLayout
    let activeRoles: [Bool]
    let part: SoundstageLayout.Part
    var resolution = StereoBands.Resolution.five
    /// The stereometer's single band, if one is chosen: the legend names only it.
    var solo: Int? = nil
    /// The room's band markers show (Immersive); the legend follows them there.
    var markers = true
    var domeOptions = DisplayOptions()
    /// The speaker geometry the dome is drawn with.
    var geometry: SpatialGeometry? = nil
    /// The correlation bar's lane count, animated with a band switch so labels follow the gliding bar.
    var lanes = CGFloat(StereoBands.count)

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(mix.animatableData, lanes) }
        set { mix.animatableData = newValue.first; lanes = newValue.second }
    }

    var body: some View {
        let stage = SoundstageLayout(size: size, presence: mix.presence, mono: mix.mono, layout: layout, part: part,
                                     lanes: lanes)
        ZStack(alignment: .topLeading) {
            switch part {
            case .room:
                let relay = FormatMix.relay(mix.presence)
                if relay.dome > 0.001 {
                    DomeLabelsHost(size: size, layout: layout, options: domeOptions, geometry: geometry, zoom: relay.domeZoom)
                        .opacity(relay.dome)
                }
                if relay.stereo > 0.001 {
                    Group {
                        scopeLabels(stage)
                        bandLegend(stage)
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .scaleEffect(relay.stereoScale, anchor: UnitPoint(x: stage.scopeCenter.x / max(1, size.width),
                                                                     y: stage.scopeCenter.y / max(1, size.height)))
                    .opacity(relay.stereo)
                }
            case .levels: levelLabels(stage)
            }
        }
        .allowsHitTesting(false)
    }

    /// The stereometer's labels, in Stereo and Mono: L, M and R beyond the rims (Mono keeps M alone) and the level of
    /// the arcs along the horizon.
    private func scopeLabels(_ stage: SoundstageLayout) -> some View {
        Group {
            ForEach([(-45.0, "L"), (0, "M"), (45, "R")], id: \.0) { angle, name in
                Text(verbatim: name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                    .opacity(angle == 0 ? 1 : dissolve(1 - mix.mono))
                    .position(stage.scopeLabel(angle: angle))
            }
            // The marks sit 0.4 radius apart; a small plot (a short room) keeps the ones that stay clear.
            let radius = stage.scopeRadius
            ForEach([Float(0), -24, -48].filter { $0 == 0 || radius >= ($0 == -24 ? 50 : 25) }, id: \.self) { db in
                let point = stage.scopePoint(angle: 90, fraction: SoundstageLayout.scopeFraction(decibels: db))
                Text(verbatim: db == 0 ? "0" : "−\(Int(-db))")
                    .font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                    .position(x: point.x, y: point.y + 8)
            }
        }
    }

    /// The band legend under the plot, shared by the stereometer (Stereo) and the room's band image (Immersive):
    /// each band named by its lower edge, in its colour; a single band chosen alone is named by its range.
    @ViewBuilder
    private func bandLegend(_ stage: SoundstageLayout) -> some View {
        let weight = markers ? 1 : 1 - mix.presence
        if weight > 0.001, stage.showsScopeLegend {
            let legend = stage.scopeLegend
            let groups = solo.map { $0 < resolution.count ? [$0] : [] } ?? Array(0..<resolution.count)
            // Between the readings: each band by its lower edge, then by the number alone (20 · 120 · 2k) where the
            // well is narrow; the rims' colours name the bands where neither fits.
            ViewThatFits(in: .horizontal) {
                legendLine(groups, short: false)
                legendLine(groups, short: true)
                Color.clear.frame(width: 1, height: 1)
            }
            .frame(width: legend.width, height: legend.height)
            // Keyed by the choice, so a band switch cross-fades the old legend into the new one.
            .id(BandChoice(resolution, solo: solo))
            .transition(.opacity)
            .position(x: legend.midX, y: legend.midY)
            .opacity(dissolve(weight))
        }
    }

    private func legendLine(_ groups: [Int], short: Bool) -> some View {
        HStack(spacing: short ? 8 : 10) {
            ForEach(groups, id: \.self) { group in
                HStack(spacing: 4) {
                    Circle().fill(Theme.bandColor(resolution, group)).frame(width: 6, height: 6)
                    Text(verbatim: solo == nil ? Self.edge(resolution.label(group), short: short) : BandChoice.range(resolution, group))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .fixedSize()
    }

    /// A band's lower edge, or for the short legend its number alone ("120 Hz" → "120", "2 kHz" → "2k").
    private static func edge(_ label: String, short: Bool) -> String {
        guard short else { return label }
        if label.hasSuffix(" kHz") { return String(label.dropLast(4)) + "k" }
        if label.hasSuffix(" Hz") { return String(label.dropLast(3)) }
        return label
    }

    @ViewBuilder
    private func levelLabels(_ stage: SoundstageLayout) -> some View {
        let speakers = stage.speakers
            ForEach(stage.headers, id: \.group) { header in
                Text(SoundstageLayout.groupTitle(header.group))
                    .font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(l10n.tracking(1))
                    .foregroundStyle(Theme.groupColor(header.group).opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: max(0, header.rect.width), alignment: .center)
                    .opacity(dissolve(stage.headerWeight(header.group)))
                    .position(x: header.rect.midX, y: header.rect.minY + 6)
            }
            ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                let weight = stage.weight(index)
                let width = stage.columns[index].width
                Text(speaker.displayName(mono: mix.mono))
                    .font(.system(size: width < 20 ? 8 : (width < 26 ? 9 : 11), weight: .semibold))
                    .foregroundStyle(activeRoles[speaker.role] ? Theme.groupColor(speaker.group) : Theme.tertiary)
                    // Shrinks rather than running into its neighbour where the columns are narrow.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: max(12, width < 26 ? width - 2 : width + 10))
                    .scaleEffect(0.8 + 0.2 * weight)
                    .opacity(dissolve(weight))
                    .position(stage.namePoint(index))
            }
            ForEach(visibleTicks(stage), id: \.self) { db in
                Text(verbatim: db > 0 ? "+\(Int(db))" : (db == 0 ? "0" : "−\(Int(-db))"))
                    .font(.axis)
                    .foregroundStyle(db >= 0 ? Theme.ember.opacity(0.85) : Theme.tertiary)
                    .frame(width: SoundstageLayout.axisColumn, alignment: .trailing)
                    .position(x: stage.axisMaxX - SoundstageLayout.axisColumn / 2, y: stage.y(decibels: db))
            }
            Text(L("CORRELATION"))
                .font(.eyebrow).tracking(l10n.tracking(Tracking.eyebrow))
                .foregroundStyle(Theme.tertiary)
                .frame(width: stage.correlationArea.width, alignment: .leading)
                .opacity(dissolve(stage.correlationWeight))
                .position(x: stage.correlationArea.midX, y: stage.correlationArea.minY + 8)
            // Each lane's band, by its lower edge, with the band's colour from the stereometer.
            // Keyed by resolution and lane, so a band switch cross-fades the old names into the new ones.
            ForEach(Self.lanes(resolution), id: \.self) { key in
                let band = key.lane
                HStack(spacing: 4) {
                    Circle().fill(Theme.bandColor(resolution, band)).frame(width: 5, height: 5)
                    Text(verbatim: resolution.label(band))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                    .frame(width: SoundstageLayout.laneLabelColumn - 6, alignment: .leading)
                    .opacity(dissolve(stage.correlationWeight))
                    .position(x: stage.correlationArea.minX + (SoundstageLayout.laneLabelColumn - 6) / 2,
                              y: stage.correlationLane(band, of: resolution.count).midY)
                    .transition(.opacity)
            }
    }

    /// Identity of a lane's label: the resolution and the lane, so a band switch replaces (and cross-fades) them.
    struct LaneKey: Hashable {
        let resolution: StereoBands.Resolution
        let lane: Int
    }
    static func lanes(_ resolution: StereoBands.Resolution) -> [LaneKey] {
        (0..<resolution.count).map { LaneKey(resolution: resolution, lane: $0) }
    }

    /// Scale labels at least 11 pt apart: 0 dB first, then +3, then from the loud end down.
    private func visibleTicks(_ layout: SoundstageLayout) -> [Float] {
        var result: [Float] = []
        for db in [0, SoundstageLayout.overTop] + SoundstageLayout.scaleTicks.reversed() where !result.contains(db) {
            let y = layout.y(decibels: db)
            if result.allSatisfy({ abs(layout.y(decibels: $0) - y) >= 11 }) { result.append(db) }
        }
        return result
    }
}

/// The stereometer's readings, set quietly in the well's lower corners, name over value: in Stereo the balance
/// (R against L, in dB) and the width (the side channel's share of the energy), in Mono the level, each for the
/// whole programme or for the band shown alone. Smoothed at 10 Hz (`Readouts`).
private struct StageReadings: View {
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    let mono: Bool
    let choice: BandChoice
    let running: Bool

    var body: some View {
        let group = choice.solo.map { choice.resolution.offset + $0 } ?? StereoBands.Resolution.overall.offset
        let values = readouts.values
        let level = values.bandLevel[group]
        let live = running && level > -100
        HStack(alignment: .bottom) {
            if mono {
                reading(L("LEVEL"), live ? MeterScale.tenths(level, floor: -99) : "—", unit: "dBFS", alignment: .leading)
                Spacer(minLength: 0)
            } else {
                let balance = live ? Self.balance(values.bandBalance[group]) : "—"
                reading(L("BALANCE"), balance, unit: balance == "C" || balance == "—" ? "" : "dB", alignment: .leading)
                Spacer(minLength: 0)
                reading(L("WIDTH"), live ? "\(Int((values.bandWidth[group] * 100).rounded()))" : "—", unit: "%", alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }

    private func reading(_ name: String, _ value: String, unit: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(name).font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(l10n.tracking(Tracking.eyebrow))
                .foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink)
                if !unit.isEmpty { Text(verbatim: unit).font(.axis).foregroundStyle(Theme.tertiary) }
            }
            .lineLimit(1).fixedSize()
        }
    }

    /// The energy balance as a level difference: "C" below 0.05 dB, else the louder side and by how much.
    static func balance(_ b: Float) -> String {
        let clamped = max(-0.999, min(0.999, b))
        let db = 10 * log10((1 + clamped) / (1 - clamped))
        guard abs(db) >= 0.05 else { return "C" }
        return (db < 0 ? "L " : "R ") + String(format: "%.1f", abs(db))
    }
}

/// Held peak over each column (the true-peak over, in ember, once a channel has gone above 0 dBTP) and the
/// correlation section's live parts: the reading, the zone captions, what the zone means for the listener, and
/// the level change in mono. Published at 10 Hz and animated with the columns.
private struct SoundstageReadouts: View, Animatable {
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    let size: CGSize
    var mix: FormatMix
    let layout: SpeakerLayout
    let activeRoles: [Bool]
    var resolution = StereoBands.Resolution.five
    /// The correlation bar's lane count, animated with a band switch so labels follow the gliding bar.
    var lanes = CGFloat(StereoBands.count)

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(mix.animatableData, lanes) }
        set { mix.animatableData = newValue.first; lanes = newValue.second }
    }

    var body: some View {
        let stage = SoundstageLayout(size: size, presence: mix.presence, mono: mix.mono, layout: layout, part: .levels,
                                     lanes: lanes)
        let values = readouts.values
        ZStack(alignment: .topLeading) {
            ForEach(Array(stage.speakers.enumerated()), id: \.offset) { index, speaker in
                let width = stage.columns[index].width
                if width >= 14 {
                    // Narrow columns (9.1.6 in a small window) keep each reading inside its own column.
                    readout(role: speaker.role, width: width, values: values)
                        .frame(width: width < 24 ? width - 2 : width + 6)
                        .scaleEffect(0.8 + 0.2 * stage.weight(index))
                        .opacity(dissolve(stage.weight(index)))
                        .position(stage.readoutPoint(index))
                }
            }
            if stage.correlationWeight > 0.001 {
                correlation(stage: stage, values: values)
                    .opacity(dissolve(stage.correlationWeight))
            }
        }
        .allowsHitTesting(false)
    }

    /// Tenths where the column has room, whole decibels where it is narrow.
    private func readout(role: Int, width: CGFloat, values: Readouts.Values) -> some View {
        let active = activeRoles[role]
        let over = MeterScale.decibels(values.heldTruePeaks[role])
        let peak = MeterScale.decibels(values.heldPeaks[role])
        let text: String
        if !active {
            text = "OFF"
        } else if over > 0 {
            text = width >= 30 ? MeterScale.signedTenths(over) : "+" + MeterScale.signedInteger(max(1, over))
        } else if peak <= -119 {
            text = "−∞"
        } else {
            text = width >= 30 ? MeterScale.tenths(peak, floor: -119) : MeterScale.signedInteger(peak)
        }
        let overs = active && over > 0
        // An over reads as an alarm tag, like OVER on the loudness summary: the only filled tags in the interface.
        return Text(verbatim: text)
            .font(.system(size: width >= 30 ? 10 : (width >= 20 ? 9 : 7.5), weight: overs ? .bold : .medium).monospacedDigit())
            .foregroundStyle(!active ? Theme.tertiary : (overs ? Theme.onStatus : (peak >= -3 ? Theme.ochre : Theme.ink)))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, overs ? 4 : 0)
            .padding(.vertical, overs ? 1 : 0)
            .background { if overs { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.ember) } }
    }

    private func correlation(stage: SoundstageLayout, values: Readouts.Values) -> some View {
        let area = stage.correlationArea
        let track = stage.correlationTrack
        let zone = values.correlationZone
        return ZStack(alignment: .topLeading) {
            StableNumber(text: zone == nil ? "--" : Self.signed(values.correlation), template: "+0.00",
                         font: .system(size: 12, weight: .semibold),
                         color: zone.map { Theme.correlationColor($0) } ?? Theme.tertiary)
                .frame(width: area.width, alignment: .trailing)
                .position(x: area.midX, y: area.minY + 8)
            // Each band's reading right of its lane, coloured by its zone.
            // Overall has one lane, whose reading is the headline number above it.
            ForEach(resolution == .overall ? [] : SoundstageStaticLabels.lanes(resolution), id: \.self) { key in
                let band = key.lane
                let reading = values.bandCorrelation[resolution.offset + band]
                let silent = reading == MeterSnapshot.noCorrelation
                StableNumber(text: silent ? "--" : Self.signed(reading), template: "+0.00",
                             font: .system(size: 9, weight: .medium),
                             color: silent ? Theme.tertiary : Theme.correlationColor(CorrelationZone(reading)))
                    .frame(width: SoundstageLayout.laneValueColumn, alignment: .trailing)
                    .position(x: area.maxX - SoundstageLayout.laneValueColumn / 2,
                              y: stage.correlationLane(band, of: resolution.count).midY)
                    .transition(.opacity)
            }
            if stage.compactCorrelation {
                // Compact: the lit zone's name stands in for the captions, the hint moves to its tooltip, and the
                // mono fold-down sits at the end of the same row.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let zone {
                        zoneChip(zone).help(zone.hint)
                    } else {
                        Text(L("No stereo signal."))
                            .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    monoLabel
                    monoReading(values.monoFoldDown)
                }
                .frame(width: area.width, alignment: .leading)
                .position(x: area.midX, y: track.maxY + 13)
            } else {
                // Zone names under the track, each centred in its zone; Mono is too narrow and hangs from the end.
                ForEach(CorrelationZone.allCases, id: \.self) { item in
                    let lit = item == zone
                    Text(item.caption)
                        .font(.system(size: 9, weight: lit ? .bold : .medium))
                        .foregroundStyle(lit ? Theme.correlationColor(item) : Theme.tertiary)
                        .fixedSize()
                        .frame(width: 90, alignment: item == .mono ? .trailing : .center)
                        .position(x: item == .mono ? track.maxX - 45 : stage.correlationX(Self.center(item)),
                                  y: track.maxY + 9)
                }
                HStack(alignment: .top, spacing: 8) {
                    if let zone {
                        zoneChip(zone)
                        Text(zone.hint)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("No stereo signal."))
                            .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        monoLabel
                        monoReading(values.monoFoldDown)
                    }
                }
                .frame(width: area.width, alignment: .leading)
                .position(x: area.midX, y: track.maxY + 42)
            }
        }
    }

    /// The zone as status text, like the loudness delta: a dot and the name in the zone's colour. Filled chips are
    /// kept for alarms (overs).
    private func zoneChip(_ zone: CorrelationZone) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.correlationColor(zone)).frame(width: 6, height: 6)
            Text(zone.title)
                .font(.system(size: 9, weight: .bold)).tracking(l10n.tracking(0.6))
                .foregroundStyle(Theme.correlationColor(zone))
                .lineLimit(1).fixedSize()
        }
    }

    private var monoLabel: some View {
        Text(L("IN MONO"))
            .font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(l10n.tracking(1))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1).fixedSize()
    }

    private func monoReading(_ fold: Float?) -> some View {
        Text(verbatim: fold.map { MeterScale.signedTenths($0, floor: -39.9) + " dB" } ?? "—")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(fold.map { $0 < -6 ? Theme.ember : ($0 < -3.5 ? Theme.ochre : Theme.ink) } ?? Theme.tertiary)
            .lineLimit(1).fixedSize()
    }

    /// Middle of a zone on the scale.
    private static func center(_ zone: CorrelationZone) -> Float {
        let edges: [Float] = [-1] + CorrelationZone.edges + [1]
        return (edges[zone.rawValue] + edges[zone.rawValue + 1]) / 2
    }

    private static func signed(_ value: Float) -> String {
        let text = String(format: "%.2f", abs(value))
        return value < -0.005 ? "−" + text : "+" + text
    }
}
