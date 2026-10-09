import AnalysisCore
import SwiftUI

// MARK: - Surfaces

/// A charcoal (or white) card groups each panel; a recessed well holds its live display.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { CardSurface() }
    }
}

struct CardSurface: View {
    var radius: CGFloat = Theme.cardRadius
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(LinearGradient(colors: [Theme.cardTint, Theme.cardTint.opacity(0.94)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { shape.strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.10 : 0.09), lineWidth: 0.5) }
            .shadow(color: Theme.cardShadow, radius: Theme.dark ? 11 : 9, y: Theme.dark ? 5 : 3)
    }
}

/// An obsidian (or paper) display set into the card, edged by a single hairline.
struct WellSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous)
        shape.fill(Theme.wellFill)
            .overlay { shape.strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.13 : 0.11), lineWidth: 0.5) }
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

/// Consistent title and metadata alignment; trailing legends keep their existing positions.
private struct PanelHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Eyebrow(title).layoutPriority(1)
            Text(verbatim: detail)
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Spectrum and Spectrogram

/// What the spectrum and waterfall analyse, for their headers: the input in Mono, L+R in Stereo, and the
/// power sum of every routed channel in Spatial.
func spectrumSource(format: ChannelFormat, layout: SpeakerLayout) -> String {
    switch format {
    case .mono: return "M"
    case .stereo: return "L+R"
    case .spatial: return "\(layout.name) · " + L("all channels")
    }
}

/// The Spectrum card: the spectrogram and the live spectrum in one well on one frequency axis. The waterfall
/// keeps the last 3 to 8 s (fewer as it narrows), newest at its right edge, with the piano keyboard on its left; the live
/// spectrum continues from "now" to the right with its peak holds, so a band's colour and its level read along
/// the same row (or, with the spectrum on the left, the pair mirrors; see `SpectrumSide`). The key under the
/// dominant peak lights up, and the peak badge names it.
struct SpectrumPanel: View {
    let model: MeterModel
    let sampleRate: Double
    let source: String
    @ObservedObject private var l10n = Localizer.shared
    /// Width of the live spectrum beside the waterfall, dragged by the divider between them; 0 is automatic.
    @AppStorage("layout.spectrumStrip") private var strip: Double = 0
    /// The spectrum's side, chosen in Settings › Panels.
    @AppStorage(SpectrumSide.key) private var side = SpectrumSide.right.rawValue

    var body: some View {
        let strip = CGFloat(self.strip)
        let left = side == SpectrumSide.left.rawValue
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: L("SPECTROGRAM") + " · " + L("SPECTRUM"),
                            detail: "\(source) · FFT \(SpectrogramAnalyzer.minimumLength)–\(SpectrumAnalyzer.fftSize) · " + L("pitch")) {
                    SpectrogramLegend()
                }
                GeometryReader { proxy in
                    let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left)
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .spectrogram, model: model)
                        MeterCanvas(kind: .spectrum, model: model)
                        PianoKeyboard(sampleRate: sampleRate, strip: strip, left: left)
                        PeakKey(readouts: model.readouts, sampleRate: sampleRate, strip: strip, left: left)
                        SpectrogramLabels(sampleRate: sampleRate, strip: strip, left: left)
                        SpectrogramInspector(sampleRate: sampleRate, strip: strip, left: left, source: source)
                        // Between the waterfall's "now" edge and the spectrum, like the dividers in the summary.
                        PanelDivider(axis: .horizontal, leading: layout.dividerLeading,
                                     onResize: { setStrip(layout.strip(forDivider: $0), size: proxy.size, left: left) },
                                     onReset: { setStrip(0, size: proxy.size, left: left) })
                            .frame(width: SpectrogramLayout.spectrumGap, height: layout.plot.height)
                            .offset(x: layout.dividerX, y: layout.plot.minY)
                        // In the waterfall's top corner, clear of the spectrum's frequency labels (the top one
                        // names the full range) and of the keyboard, in either orientation.
                        PeakBadge(readouts: model.readouts)
                            .padding(.top, 6)
                            .padding(.trailing, 6)
                            .frame(width: max(0, layout.plot.width), alignment: .topTrailing)
                            .offset(x: layout.plot.minX, y: layout.plot.minY)
                    }
                }
                .background { WellSurface() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
            }
        }
    }

    /// Stores the clamped width (0 keeps it automatic) and hands it to the canvases; writes only on change.
    private func setStrip(_ requested: CGFloat, size: CGSize, left: Bool) {
        let width = requested > 0 ? SpectrogramLayout(size: size, strip: requested, spectrumLeft: left).spectrum.width : 0
        if Double(width) != strip { strip = Double(width) }
        model.spectrumStrip = width
    }
}

/// Dominant peak as pitch · frequency · level, e.g. "A4 (+2¢) • 440.0 Hz • −12.4 dBFS".
/// Every field reserves its widest value so the capsule never changes size while values move.
private struct PeakBadge: View {
    @ObservedObject var readouts: Readouts

    var body: some View {
        let peak = readouts.values.peak
        let pitch = peak.visible ? Pitch(frequency: Double(peak.frequency)) : nil
        let font = Font.caption2.weight(.medium)
        HStack(spacing: 6) {
            StableNumber(text: pitch?.label ?? "--", template: "A#8", font: font.weight(.semibold),
                         color: pitch == nil ? Theme.tertiary : Theme.sage)
            StableNumber(text: pitch.map { "(\($0.centsLabel))" } ?? "", template: "(−50¢)", font: font, color: Theme.secondary)
            separator
            StableNumber(text: peak.visible ? Self.frequency(peak.frequency) : "-- Hz", template: "88.88 kHz", font: font,
                         color: peak.visible ? Theme.ink : Theme.tertiary)
            separator
            StableNumber(text: peak.visible ? MeterScale.tenths(peak.level) + " dBFS" : "-- dBFS", template: "−88.8 dBFS",
                         font: font, color: peak.visible ? Theme.ink : Theme.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background { BadgeSurface() }
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Text("•").font(.caption2).foregroundStyle(Theme.tertiary)
    }

    private static func frequency(_ hertz: Float) -> String {
        hertz < 1_000 ? String(format: "%.1f Hz", hertz) : String(format: "%.2f kHz", hertz / 1_000)
    }
}

/// A solid chip over the plot. Glass here would re-sample the live spectrum under it on every frame.
private struct BadgeSurface: View {
    var body: some View {
        Capsule().fill(Theme.wellFill.opacity(0.88))
            .overlay { Capsule().strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.16 : 0.12), lineWidth: 0.5) }
    }
}

/// The colour scale in the header: the range's floor and ceiling either side of a bar that runs the tone curve
/// itself (`SpectrogramTone`), linear in dB, with a notch every 24 dB; and the display slope when one is set.
private struct SpectrogramLegend: View {
    @AppStorage(SpectrogramRange.key) private var rangeKey = SpectrogramRange.standard.rawValue
    @AppStorage(SpectrumTilt.key) private var tiltKey = SpectrumTilt.flat.rawValue
    @AppStorage(DisplayOptions.averageSpectrumKey) private var average = true
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let range = SpectrogramRange(rawValue: rangeKey) ?? .standard
        let tilt = SpectrogramLegend.tiltLabel(SpectrumTilt(rawValue: tiltKey) ?? .flat)
        // Narrow headers drop the average's key, then the tilt, before the scale itself.
        ViewThatFits(in: .horizontal) {
            legend(range, tilt: tilt, average: average)
            legend(range, tilt: tilt, average: false)
            legend(range, tilt: nil, average: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Color scale from %@ to %@ dBFS", MeterScale.signedInteger(range.floor), MeterScale.signedInteger(range.ceiling)))
    }

    static func tiltLabel(_ tilt: SpectrumTilt) -> String? { tilt == .flat ? nil : "+" + tilt.title }

    private func legend(_ range: SpectrogramRange, tilt: String?, average: Bool) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: MeterScale.signedInteger(range.floor)).font(.axis).foregroundStyle(Theme.tertiary)
            Canvas { context, size in
                let steps = 24
                let span = range.ceiling - range.floor
                let stops = (0...steps).map { step -> Gradient.Stop in
                    let fraction = Float(step) / Float(steps)
                    let color = Theme.ramp(decibels: range.floor + span * fraction, range: range).color
                    return Gradient.Stop(color: color, location: CGFloat(fraction))
                }
                let bar = Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: 5), cornerRadius: 2.5)
                context.fill(bar, with: .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                context.stroke(bar, with: .color(Theme.hairline.opacity(0.12)), lineWidth: 0.5)
                var db = (range.floor / 24).rounded(.up) * 24
                if db <= range.floor { db += 24 }
                while db < range.ceiling {
                    let x = CGFloat((db - range.floor) / span) * size.width
                    context.fill(Path(CGRect(x: x - 0.25, y: 6, width: 0.5, height: 2)), with: .color(Theme.tertiary))
                    db += 24
                }
            }
            .frame(width: 64, height: 8)
            .offset(y: 1.5)
            Text(verbatim: MeterScale.signedInteger(range.ceiling) + " dB").font(.axis).foregroundStyle(Theme.tertiary)
            if let tilt {
                Text(verbatim: "· " + tilt).font(.axis).foregroundStyle(Theme.secondary)
            }
            if average {
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { _ in Capsule().fill(Theme.sand).frame(width: 4, height: 2) }
                }
                .padding(.leading, 4)
                Text(L("avg")).font(.axis).foregroundStyle(Theme.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Hover over the Spectrum well to read it: over the waterfall, the level of the very cell on screen, with its
/// row's pitch and centre frequency, how long ago its audio was, and the analysis behind it; over the live spectrum,
/// the level of the band under the pointer. A crosshair marks the spot, with the harmonics of its frequency marked
/// above it over the waterfall. Pause first to read a moment at leisure: the waterfall holds still and so do its
/// values.
private struct SpectrogramInspector: View {
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool
    /// What is analysed, for an exported image's caption.
    let source: String
    @State private var location: CGPoint? = Diagnostics.inspectPoint
    @AppStorage(SpectrogramSpan.key) private var spanKey = SpectrogramSpan.auto.rawValue
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left,
                                           span: (SpectrogramSpan(rawValue: spanKey) ?? .auto).seconds)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        // A held diagnostic point (`--snapshot-inspect`) is not moved by the real pointer.
                        guard Diagnostics.inspectPoint == nil else { return }
                        switch phase {
                        case .active(let point): location = point
                        case .ended: location = nil
                        }
                    }
                    .contextMenu {
                        Button(L("Copy Spectrogram Image")) { if let image = image() { SpectrogramImage.copy(image) } }
                        Button(L("Save Spectrogram Image…")) { if let image = image() { SpectrogramImage.save(image) } }
                    }
                if let location, let reading = reading(at: location, layout: layout) {
                    TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
                        overlay(self.reading(at: location, layout: layout) ?? reading, at: location, layout: layout, size: proxy.size)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The columns on screen as an image (`SpectrogramImage`); nil before any column has arrived.
    private func image() -> CGImage? {
        guard let scene = SceneStore.existing(.spectrogram) as? SpectrogramScene else { return nil }
        let options = DisplayOptions.stored
        return SpectrogramImage.make(history: scene.history, columns: Int(scene.span), sampleRate: sampleRate, options: options,
                                     caption: SpectrogramImage.caption(source: source, options: options))
    }

    private struct Reading {
        let frequency: Double
        let level: Float?
        /// How long ago the cell's audio was, over the waterfall; nil over the live spectrum.
        let secondsAgo: Double?
        /// The long-term average of the band, over the live spectrum while it is shown.
        var average: Float? = nil
        /// The analysis behind the cell (window, length, duration), over the waterfall.
        var resolution: String? = nil
    }

    private func reading(at point: CGPoint, layout: SpectrogramLayout) -> Reading? {
        guard point.y >= layout.plot.minY, point.y <= layout.plot.maxY else { return nil }
        let frequency = layout.frequency(y: point.y, sampleRate: sampleRate)
        if layout.plot.contains(point) {
            // The cell under the pointer, as analysed: its row's centre frequency, its level, and the instant its
            // column is centred on, which is half the analysis span (about 85 ms) before the column was made.
            let scene = SceneStore.existing(.spectrogram) as? SpectrogramScene
            let rows = SpectrogramHistory.rows
            let row = max(0, min(rows - 1, Int(layout.row(y: point.y, rows: rows).rounded())))
            let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
            let centre = 20 * pow(upper / 20, (Double(row) + 0.5) / Double(rows))
            let delay = Double(SpectrumAnalyzer.historyLength(sampleRate: sampleRate)) / 2 / sampleRate
            let cell = scene?.level(atU: layout.timeFraction(x: point.x), row: Double(row))
            return Reading(frequency: centre, level: cell?.level,
                           secondsAgo: (cell?.secondsAgo ?? (1 - layout.timeFraction(x: point.x)) * layout.seconds) + delay,
                           resolution: SpectrogramResolution.describe(row: row, sampleRate: sampleRate))
        }
        if point.x >= layout.spectrum.minX, point.x <= layout.spectrum.maxX {
            let scene = SceneStore.existing(.spectrum) as? SpectrumScene
            let bands = scene?.shown ?? []
            let band = Int(layout.row(y: point.y, rows: MeterSnapshot.bandCount).rounded())
            let average = DisplayOptions.stored.averageSpectrum ? scene?.average : nil
            return Reading(frequency: frequency, level: bands.indices.contains(band) ? bands[band] : nil, secondsAgo: nil,
                           average: average.flatMap { $0.indices.contains(band) ? $0[band] : nil })
        }
        return nil
    }

    @ViewBuilder
    private func overlay(_ reading: Reading, at point: CGPoint, layout: SpectrogramLayout, size: CGSize) -> some View {
        let lineColor = Theme.ink.opacity(Theme.dark ? 0.45 : 0.4)
        let dash = StrokeStyle(lineWidth: 0.75, dash: [3, 3])
        let span = layout.plot.union(layout.spectrum)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: span.minX, y: point.y))
                path.addLine(to: CGPoint(x: span.maxX, y: point.y))
                if reading.secondsAgo != nil {
                    path.move(to: CGPoint(x: point.x, y: layout.plot.minY))
                    path.addLine(to: CGPoint(x: point.x, y: layout.plot.maxY))
                }
            }
            .stroke(lineColor, style: dash)
            // The harmonic cursor: where the 2nd to 8th harmonics of the frequency under the pointer fall, so an
            // overtone series (or a resonance's partials) can be checked at a glance.
            if reading.secondsAgo != nil {
                let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
                ForEach(Array(2...8).filter { Double($0) * reading.frequency < upper }, id: \.self) { harmonic in
                    let y = layout.y(frequency: Double(harmonic) * reading.frequency, sampleRate: sampleRate)
                    let opacity = (Theme.dark ? 0.75 : 0.65) * (1 - Double(harmonic - 2) * 0.08)
                    Capsule().fill(Theme.ink.opacity(opacity)).frame(width: 12, height: 1.5)
                        .offset(x: point.x - 6, y: y - 0.75)
                    if harmonic <= 4 {
                        Text(verbatim: "\(harmonic)×").font(.system(size: 8, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink.opacity(opacity)).fixedSize()
                            .offset(x: point.x + 8, y: y - 6)
                    }
                }
            }
            let tag = InspectorTag(reading: reading)
            let width = InspectorTag.width(reading)
            let flip = point.x + 14 + width > span.maxX
            let x = flip ? point.x - 14 - width : point.x + 14
            let y = min(max(span.minY + 2, point.y - (reading.resolution == nil ? 30 : 40)), span.maxY - (reading.resolution == nil ? 24 : 36))
            tag.frame(width: width, alignment: .leading).offset(x: max(span.minX + 2, x), y: y)
        }
    }

    private struct InspectorTag: View {
        let reading: Reading
        @ObservedObject private var l10n = Localizer.shared

        /// Fixed per kind, so the tag never changes size as the pointer moves.
        static func width(_ reading: Reading) -> CGFloat { reading.secondsAgo != nil ? 246 : (reading.average == nil ? 200 : 268) }

        var body: some View {
            let pitch = Pitch(frequency: reading.frequency)
            let font = Font.caption2.weight(.medium).monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: pitch.map { "\($0.label) \($0.centsLabel)" } ?? "--").font(font.weight(.semibold)).foregroundStyle(Theme.sage)
                    dot
                    Text(verbatim: Self.frequency(reading.frequency)).font(font).foregroundStyle(Theme.ink)
                    if let seconds = reading.secondsAgo {
                        dot
                        Text(verbatim: seconds < 0.02 ? L("now") : String(format: "−%.2f s", seconds)).font(font).foregroundStyle(Theme.secondary)
                    }
                    dot
                    Text(verbatim: reading.level.map { MeterScale.tenths($0, floor: -119.9) + " dBFS" } ?? "-- dBFS")
                        .font(font).foregroundStyle(reading.level == nil ? Theme.tertiary : Theme.ink)
                    if reading.secondsAgo == nil {
                        Text(L("live")).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                    if let average = reading.average {
                        dot
                        Text(verbatim: MeterScale.tenths(average, floor: -119.9)).font(font).foregroundStyle(Theme.sand)
                        Text(L("avg")).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                }
                if let resolution = reading.resolution {
                    Text(verbatim: resolution).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { BadgeSurface() }
        }

        private var dot: some View { Text("•").font(.caption2).foregroundStyle(Theme.tertiary) }

        static func frequency(_ hertz: Double) -> String {
            hertz < 100 ? String(format: "%.1f Hz", hertz)
                : hertz < 1_000 ? String(format: "%.0f Hz", hertz) : String(format: "%.2f kHz", hertz / 1_000)
        }
    }
}

/// The waterfall's analysis at a row, for the inspector: the window and its length and duration at the source's
/// rate, as this build analyses it (in Labs and in the plugins).
@MainActor
private enum SpectrogramResolution {
    private static var analyzer: SpectrogramAnalyzer?

    static func describe(row: Int, sampleRate: Double) -> String? {
        if analyzer?.sampleRate != sampleRate {
            analyzer = SpectrogramAnalyzer(sampleRate: sampleRate, span: SpectrumAnalyzer.historyLength(sampleRate: sampleRate))
        }
        guard let analyzer, row >= 0, row < analyzer.rows else { return nil }
        let length = analyzer.length(ofRow: row)
        let window = analyzer.window(ofRow: row) == .hann ? "Hann" : "Blackman–Harris"
        return "FFT \(length) · \(window) · " + String(format: "%.0f ms", Double(length) / sampleRate * 1_000)
    }
}

/// Octave labels, the time axis under the waterfall, and the spectrum's level axis under it with its frequency
/// marks inside it.
private struct SpectrogramLabels: View {
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool
    @AppStorage(SpectrogramSpan.key) private var spanKey = SpectrogramSpan.auto.rawValue
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left,
                                           span: (SpectrogramSpan(rawValue: spanKey) ?? .auto).seconds)
            let octave = abs(layout.y(midi: 60, sampleRate: sampleRate) - layout.y(midi: 72, sampleRate: sampleRate))
            let labelStep = max(1, Int(ceil(18 / max(1, octave))))
            let perSecond = layout.plot.width / CGFloat(layout.seconds)
            let timeStep = max(1, Int((36 / max(0.01, perSecond)).rounded(.up)))
            ZStack(alignment: .topLeading) {
                ForEach((0...10).filter { ($0 - 4) % labelStep == 0 }, id: \.self) { number in
                    let y = layout.y(midi: Double(12 * (number + 1)), sampleRate: sampleRate)
                    if y > layout.plot.minY + 4 && y < layout.plot.maxY - 2 {
                        Text(verbatim: "C\(number)")
                            .font(.axis)
                            .foregroundStyle(number == 4 ? Theme.secondary : Theme.tertiary)
                            .frame(width: SpectrogramLayout.noteLabels - 4, alignment: left ? .leading : .trailing)
                            .position(x: layout.noteLabelX, y: y)
                    }
                }
                Text(L("now")).font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                    .position(x: layout.nowX + (left ? 10 : -10), y: layout.plot.maxY + FrequencyAxis.labelHeight / 2)
                ForEach(Array(Swift.stride(from: timeStep, to: Int(layout.seconds), by: timeStep)), id: \.self) { seconds in
                    Text(verbatim: "−\(seconds)s").font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                        .position(x: layout.x(secondsAgo: Double(seconds)), y: layout.plot.maxY + FrequencyAxis.labelHeight / 2)
                }
                let strip = layout.spectrum
                ForEach(SpectrogramLayout.grid.filter { $0 > -96 && (strip.width >= 150 || $0 != -24 && $0 != -72) }, id: \.self) { db in
                    Text(verbatim: db == 0 ? "0 dB" : "−\(Int(-db))").font(.axis)
                        .foregroundStyle(Theme.tertiary).fixedSize()
                        .position(x: db == 0 ? layout.fullScaleX + (left ? 14 : -14) : layout.x(decibels: db),
                                  y: strip.maxY + FrequencyAxis.labelHeight / 2)
                }
                ForEach(SpectrogramLayout.frequencyTicks(layout, sampleRate: sampleRate), id: \.0) { tick in
                    let decade = [100.0, 1_000, 10_000].contains(tick.0)
                    Text(verbatim: tick.1).font(.axis)
                        .foregroundStyle(decade ? Theme.secondary : Theme.tertiary).fixedSize()
                        .position(x: layout.fullScaleX + (left ? 12 : -12),
                                  y: layout.y(frequency: tick.0, sampleRate: sampleRate)
                                      + (SpectrogramLayout.isTopEdge(tick.0, sampleRate: sampleRate) ? 7 : -6))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The notes sounding together, lit on the keyboard: every note the analyzer finds (`NoteHolds`) in the accent,
/// stronger the louder it is against the loudest, with a short tick into the plot beside it; and the dominant
/// one, which the badge names, at full strength with a hairline carrying its pitch across the waterfall to the
/// spectrum. Follows the 10 Hz readouts (gated and held).
private struct PeakKey: View {
    @ObservedObject var readouts: Readouts
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool

    var body: some View {
        Canvas { context, size in
            let layout = SpectrogramLayout(size: size, strip: strip, spectrumLeft: left)
            let semitone = layout.semitoneHeight(sampleRate: sampleRate)
            let keys = layout.keyboard
            let height = max(2, semitone)
            func light(_ midi: Int, opacity: Double) -> Bool {
                let y = layout.y(midi: Double(midi), sampleRate: sampleRate)
                guard y > layout.plot.minY, y < layout.plot.maxY else { return false }
                let black = SpectrogramLayout.isBlack(midi)
                let keyWidth = keys.width * (black ? 0.6 : 1)
                let key = CGRect(x: black ? layout.blackKeyX(width: keyWidth) : keys.minX, y: y - height / 2, width: keyWidth, height: height)
                context.fill(Path(roundedRect: key, cornerRadius: min(2, height / 2)), with: .color(Theme.sage.opacity(opacity)))
                return true
            }
            let peak = readouts.values.peak
            let dominant = peak.visible ? Pitch(frequency: Double(peak.frequency))?.midi : nil
            // The loudest few held notes (`SpectrumAnalyzer.litNotes`), fainter the further below the loudest.
            let notes = readouts.values.notes.notes.sorted { $0.level > $1.level }.prefix(SpectrumAnalyzer.litNotes)
            let loudest = notes.first?.level ?? -120
            for note in notes where note.midi != dominant {
                let strength = Double(max(0, min(1, 1 - (loudest - note.level) / 18)))
                guard light(note.midi, opacity: 0.35 + 0.4 * strength) else { continue }
                let y = layout.y(midi: Double(note.midi), sampleRate: sampleRate)
                let inner = layout.keysInnerX
                let tick = CGRect(x: left ? inner - 7 : inner + 1, y: y - 0.5, width: 6, height: 1)
                context.fill(Path(tick), with: .color(Theme.sage.opacity(0.35 + 0.35 * strength)))
            }
            guard let dominant, light(dominant, opacity: 0.95) else { return }
            let exact = layout.y(frequency: Double(peak.frequency), sampleRate: sampleRate)
            var line = Path()
            if left {
                line.move(to: CGPoint(x: layout.spectrum.minX, y: exact))
                line.addLine(to: CGPoint(x: keys.minX - 1, y: exact))
            } else {
                line.move(to: CGPoint(x: keys.maxX + 1, y: exact))
                line.addLine(to: CGPoint(x: max(layout.spectrum.maxX, layout.plot.maxX), y: exact))
            }
            context.stroke(line, with: .color(Theme.sage.opacity(0.35)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// At small heights, show octave groups instead of squeezing ~120 keys into a strip.
/// Individual black keys fade in only when each semitone has enough vertical space.
/// The axis is affine in MIDI, so every edge comes from one origin and slope, and each layer is batched into a
/// single path (four fills per redraw instead of one per key).
private struct PianoKeyboard: View {
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool

    var body: some View {
        Canvas { context, size in
            let layout = SpectrogramLayout(size: size, strip: strip, spectrumLeft: left)
            let keys = layout.keyboard
            let semitone = layout.semitoneHeight(sampleRate: sampleRate)
            // Anchor at A4: y(midi:) clamps below 20 Hz, so MIDI 0 would not lie on the line.
            let a4 = layout.y(midi: 69, sampleRate: sampleRate)
            func y(_ midi: Double) -> CGFloat { a4 - CGFloat(midi - 69) * semitone }
            // Visible MIDI range; the 20 Hz floor clamps the axis, so notes below it are skipped.
            let low = (69 + 12 * log2(20 / 440.0)).rounded(.up)
            let high = (69 + 12 * log2(MeterScale.upperFrequency(sampleRate: sampleRate) / 440)).rounded(.down)
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: keys)
            context.clip(to: shape)
            context.fill(shape, with: .color(Theme.ink.opacity(0.045)))
            // Alternating octave bands give the eye a small number of coherent groups.
            var bands = Path(), ticks = Path()
            var middleC = CGRect.null
            for octave in 0...10 {
                let c = Double((octave + 1) * 12)
                guard c + 12 > low - 0.5 && c < high + 0.5 else { continue }
                let top = y(c + 12), bottom = y(c)
                if octave.isMultiple(of: 2) {
                    bands.addRect(CGRect(x: keys.minX, y: top, width: keys.width, height: bottom - top))
                }
                // Ticks run in from the edge nearer the plot.
                let inner = layout.keysInnerX
                if octave == 4 {
                    middleC = CGRect(x: left ? inner : inner - 12, y: bottom - 0.5, width: 12, height: 1)
                } else {
                    ticks.addRect(CGRect(x: left ? inner : inner - 7, y: bottom - 0.5, width: 7, height: 1))
                }
            }
            context.fill(bands, with: .color(Theme.ink.opacity(Theme.dark ? 0.065 : 0.05)))
            context.fill(ticks, with: .color(Theme.ink.opacity(Theme.dark ? 0.30 : 0.34)))
            if !middleC.isNull { context.fill(Path(middleC), with: .color(Theme.sage.opacity(0.9))) }
            let keyDetail = min(1, max(0, (semitone - 3) / 2))
            guard keyDetail > 0, low <= high else { return }
            var black = Path()
            let height = max(1, semitone - 1)
            for midi in Int(low)...Int(high) where SpectrogramLayout.isBlack(midi) {
                black.addRoundedRect(in: CGRect(x: layout.blackKeyX(width: keys.width * 0.6), y: y(Double(midi) + 0.5) + 0.5,
                                                width: keys.width * 0.6, height: height),
                                     cornerSize: CGSize(width: 1, height: 1))
            }
            // Black keys are the darkest thing on the keyboard in either appearance.
            context.fill(black, with: .color(Theme.dark ? Theme.display.opacity(0.9 * keyDetail) : Theme.ink.opacity(0.34 * keyDetail)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Loudness

/// Loudness delivery standards offered on the summary. A standard sets the short-term target (gauge, delta,
/// history band), the VU alignment (0 VU = target, in dBFS) and its true-peak ceiling, which can still be
/// changed on its own. Stereo (with Mono) and Spatial each keep their own standard.
struct LoudnessStandard: Hashable {
    let target: Double
    let ceiling: Double
    /// A published specification keeps its own name; a description of a use is a localization key.
    let name: String

    /// Menu label in the current language.
    var title: String { L(name) }

    static let all: [LoudnessStandard] = [
        LoudnessStandard(target: -9, ceiling: -1, name: LKey("Loud master · club, EDM")),
        LoudnessStandard(target: -14, ceiling: -1, name: LKey("Streaming · Spotify, YouTube, Tidal")),
        LoudnessStandard(target: -16, ceiling: -1, name: LKey("Apple Music · podcasts")),
        LoudnessStandard(target: -18, ceiling: -1, name: "Dolby Atmos Music"),
        LoudnessStandard(target: -23, ceiling: -1, name: "EBU R128"),
        LoudnessStandard(target: -24, ceiling: -2, name: "ATSC A/85"),
        LoudnessStandard(target: -27, ceiling: -2, name: LKey("Netflix · film and series"))
    ]
    /// True-peak ceilings offered on the summary, in dBTP.
    static let ceilings: [Double] = [-0.1, -0.5, -1, -2, -3]

    static func standard(target: Double) -> LoudnessStandard? { all.first { $0.target == target } }
}

/// Where short-term loudness sits against the target, as a solid status chip: accent on target, ochre above,
/// slate below. The fill carries the colour and the type contrasts with it, so the chip reads on the tinted
/// summary in both appearances.
struct DeltaBadge: View {
    let value: Float
    let target: Float

    var body: some View {
        let valid = value > -70
        let (text, color) = Self.describe(value - target, valid: valid)
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(Localizer.shared.tracking(0.4))
            .monospacedDigit()
            .foregroundStyle(valid ? Theme.onStatus : Theme.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { Capsule().fill(valid ? color : Theme.chipFill) }
            .fixedSize()
    }

    private static func describe(_ delta: Float, valid: Bool) -> (String, Color) {
        guard valid else { return ("—", Theme.tertiary) }
        if abs(delta) <= 1 { return (L("ON TARGET"), Theme.sage) }
        return ((delta > 0 ? "+" : "") + MeterScale.tenths(delta) + " LU", delta > 0 ? Theme.ochre : Theme.slate)
    }
}

struct LoudnessGauge: View {
    let value: Float
    let target: Float
    /// Grows the bar and target mark with a taller summary (`HeroLayout.contentScale`).
    var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let fraction = MeterScale.loudnessFraction(value)
                let delta = value - target
                let fill = abs(delta) <= 1 ? Theme.sage : (delta > 0 ? Theme.ochre : Theme.slate)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline.opacity(0.08))
                        .overlay { Capsule().strokeBorder(Theme.hairline.opacity(0.06), lineWidth: 0.5) }
                    Capsule().fill(fill).frame(width: max(6, width * fraction))
                        .opacity(value > MeterScale.loudnessFloor ? 1 : 0)
                    Capsule().fill(Theme.ink)
                        .frame(width: 2, height: 14 + 8 * (scale - 1))
                        .offset(x: width * MeterScale.loudnessFraction(target) - 1)
                }
                .frame(height: 6 + 6 * (scale - 1))
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14 + 8 * (scale - 1))
            HStack {
                ForEach([-36, -24, -12, 0], id: \.self) { tick in
                    if tick != -36 { Spacer(minLength: 0) }
                    Text(tick == 0 ? "0" : "−\(-tick)").font(.axis).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

/// One statistic on the loudness summary: the title with the reading flush left under it, centred as a group in
/// whatever height the tile is given, and the unit after the reading. The template reserves the usual width of
/// the reading, so the unit holds still while the digits change.
struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    var color: Color = Theme.ink
    var template = "−88.8"
    /// Grows the reading with a taller summary; the tile itself stretches to the height it is offered.
    var scale: CGFloat = 1
    /// A warning chip beside the title (OVER); it also tints the tile in ember.
    var alert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 6) {
                Eyebrow(title, color: Theme.tertiary)
                if let alert {
                    Text(alert)
                        .font(.system(size: 8, weight: .heavy)).tracking(Localizer.shared.tracking(0.6))
                        .foregroundStyle(Theme.onStatus)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.ember))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                StableNumber(text: value, template: template, font: .system(size: 17 * scale, weight: .medium),
                             color: color, alignment: .leading)
                if !unit.isEmpty {
                    Text(verbatim: unit).font(.system(size: 9 * (1 + (scale - 1) * 0.5), weight: .medium)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.tileFill)
            if alert != nil {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.ember.opacity(0.14))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.ember.opacity(0.55), lineWidth: 1)
            }
        }
    }
}

/// Last 15 s of short-term (sage) over momentary (faint), with the ±1 LU target band and 5 s time marks.
struct LoudnessHistory: View {
    let short: [Float]
    let momentary: [Float]
    let target: Float
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 22)
            func y(_ lufs: Float) -> CGFloat { rect.maxY - MeterScale.loudnessFraction(lufs) * rect.height }
            let band = CGRect(x: rect.minX, y: y(target + 1), width: rect.width, height: max(1, y(target - 1) - y(target + 1)))
            context.fill(Path(band), with: .color(Theme.sage.opacity(Theme.dark ? 0.10 : 0.12)))
            for lufs: Float in [-12, -24] {
                context.fill(Path(CGRect(x: rect.minX, y: y(lufs), width: rect.width, height: 0.5)), with: .color(Theme.hairline.opacity(0.08)))
            }
            for seconds in stride(from: 5.0, to: Readouts.historySeconds, by: 5) {
                let x = rect.maxX - CGFloat(seconds / Readouts.historySeconds) * rect.width
                context.fill(Path(CGRect(x: x, y: rect.minY, width: 0.5, height: rect.height)), with: .color(Theme.hairline.opacity(0.07)))
            }
            let step = rect.width / CGFloat(max(1, Readouts.historyLength - 1))
            func path(_ values: [Float]) -> Path {
                var path = Path()
                let start = rect.maxX - CGFloat(values.count - 1) * step
                var drawing = false
                for (index, value) in values.enumerated() {
                    guard value > MeterScale.loudnessFloor - 12 else { drawing = false; continue }
                    let point = CGPoint(x: start + CGFloat(index) * step, y: min(rect.maxY, y(value)))
                    if drawing { path.addLine(to: point) } else { path.move(to: point) }
                    drawing = true
                }
                return path
            }
            context.stroke(path(momentary), with: .color(Theme.ink.opacity(Theme.dark ? 0.28 : 0.30)), lineWidth: 1)
            context.stroke(path(short), with: .color(Theme.sage), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
        .overlay(alignment: .topLeading) {
            Eyebrow(L("LAST 15 S"), color: Theme.tertiary).padding(.top, 7).padding(.leading, 9)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(L("now")).font(.axis).foregroundStyle(Theme.tertiary).padding(.bottom, 5).padding(.trailing, 8)
        }
        .background { WellSurface() }
        .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
    }
}

// MARK: - Waveform and Soundstage

/// Spring shared by every SwiftUI element that follows the monitoring mode; the Metal scene's critically
/// damped presence uses the same 0.55 s response, so text and graphics move as one.
extension Animation {
    static let formatShift = Animation.spring(response: 0.55, dampingFraction: 1)
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

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                WaveHeader(layout: layout, format: format)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .waveform, model: model)
                        WaveformLabels(size: proxy.size, speakers: layout.speakers, mix: FormatMix(format),
                                       activeRoles: activeRoles)
                    }
                    .animation(.formatShift, value: format)
                }
                .background { WellSurface() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
            }
        }
    }
}

/// The Soundstage card: the top-down room of the current format, with its own header and well.
struct SoundstagePanel: View {
    let model: MeterModel
    let activeRoles: [Bool]
    let format: ChannelFormat
    let layout: SpeakerLayout
    /// The stereometer's and the band map's resolution, chosen on the header.
    @AppStorage("soundstage.bands") private var bands = StereoBands.Resolution.five.rawValue
    /// The room's band markers in Immersive; hidden with the BANDS menu's Off.
    @AppStorage(DisplayOptions.bandMarkersKey) private var markers = true

    var body: some View {
        let resolution = StereoBands.Resolution(rawValue: bands) ?? .five
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                StageHeader(format: format, layout: layout) {
                    // Mono has neither the stereometer nor the band map.
                    if format != .mono {
                        BandSwitch(selection: resolution, select: {
                            bands = $0.rawValue
                            model.stageBands = $0
                        }, markers: format == .spatial ? markers : nil, setMarkers: {
                            markers = $0
                            model.displayOptions.bandMarkers = $0
                        })
                    }
                }
                GeometryReader { proxy in
                    // The well does not depend on the mode; the labels animate the format mix themselves.
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .soundstage, model: model)
                        SoundstageStaticLabels(size: proxy.size, mix: FormatMix(format), layout: layout,
                                               activeRoles: activeRoles, part: .room, resolution: resolution, markers: markers)
                    }
                    .animation(.formatShift, value: format)
                    .animation(.formatShift, value: resolution)
                }
                .background { WellSurface() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
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
    @AppStorage("levels.bands") private var bands = StereoBands.Resolution.five.rawValue

    var body: some View {
        let resolution = StereoBands.Resolution(rawValue: bands) ?? .five
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: L("CHANNEL LEVELS"), detail: "dBFS") { MeterLegend() }
                GeometryReader { proxy in
                    let mix = FormatMix(format)
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .levels, model: model)
                        SoundstageStaticLabels(size: proxy.size, mix: mix, layout: layout, activeRoles: activeRoles, part: .levels,
                                               resolution: resolution, lanes: CGFloat(resolution.count))
                        SoundstageReadouts(readouts: readouts, size: proxy.size, mix: mix, layout: layout,
                                           activeRoles: activeRoles, resolution: resolution, lanes: CGFloat(resolution.count))
                        ClipLightTargets(readouts: readouts, size: proxy.size, mix: mix, layout: layout,
                                         lanes: CGFloat(resolution.count), clear: model.resetTruePeak)
                        // The correlation section's own switcher, in its title row (Stereo only, like the section).
                        if format == .stereo {
                            let area = SoundstageLayout(size: proxy.size, presence: 0, mono: 0, layout: layout, part: .levels,
                                                        lanes: CGFloat(resolution.count)).correlationArea
                            BandSwitch(selection: resolution) {
                                bands = $0.rawValue
                                model.levelsBands = $0
                            }
                            // Right-aligned between the title and the headline reading; short labels when that is tight.
                            .frame(width: max(0, area.width - 54 - 118), alignment: .trailing)
                            .position(x: area.minX + 118 + (area.width - 54 - 118) / 2, y: area.minY + 8)
                            .transition(.opacity)
                        }
                    }
                    .animation(.formatShift, value: format)
                    .animation(.formatShift, value: resolution)
                }
                .background { WellSurface() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
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

/// Where the live spectrum sits beside the spectrogram. On the left the whole pair mirrors: the waterfall's
/// newest column meets the spectrum at the waterfall's left edge, and the spectrum's levels rise toward the keys.
enum SpectrumSide: String, CaseIterable {
    case right, left

    static let key = "spectrum.side"
    static var stored: SpectrumSide { SpectrumSide(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .right }

    /// Offered as the panel's orientation: standard, or mirrored left to right.
    var title: String { self == .right ? L("Standard") : L("Mirrored") }
}

/// The loudness summary's main reading: the large number, its gauge and its delta to the target. The other two
/// LUFS readings take the tiles beside it.
enum LoudnessReading: String, CaseIterable {
    case momentary, shortTerm, integrated

    static let key = "loudness.headline"
    static var stored: LoudnessReading { LoudnessReading(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .shortTerm }

    var title: String {
        switch self {
        case .momentary: return L("Momentary")
        case .shortTerm: return L("Short-term")
        case .integrated: return L("Integrated")
        }
    }
    /// Over the main reading.
    var heading: String {
        switch self {
        case .momentary: return L("MOMENTARY LOUDNESS")
        case .shortTerm: return L("SHORT-TERM LOUDNESS")
        case .integrated: return L("INTEGRATED LOUDNESS")
        }
    }
    /// On a tile.
    var tileTitle: String {
        switch self {
        case .momentary: return L("MOMENTARY")
        case .shortTerm: return L("SHORT-TERM")
        case .integrated: return L("INTEGRATED")
        }
    }
    func value(_ values: Readouts.Values) -> Float {
        switch self {
        case .momentary: return values.momentary
        case .shortTerm: return values.shortTerm
        case .integrated: return values.integrated
        }
    }
}

/// Display choices that shape the panels, read by the canvases every frame.
struct DisplayOptions: Equatable {
    var spectrumSide = SpectrumSide.right
    /// The live spectrum's per-band peak dashes.
    var peakHolds = true
    /// Seconds across the Waveform lanes.
    var waveSeconds = 4
    /// The Immersive room's band markers (the BANDS menu's Off hides them).
    var bandMarkers = true
    /// The levels the spectrogram's colors span, and the display slope of the spectrum and spectrogram.
    var spectrogramRange = SpectrogramRange.standard
    var tilt = SpectrumTilt.flat
    /// The live spectrum's long-term average since the last reset.
    var averageSpectrum = true
    /// Seconds across the spectrogram.
    var spectrogramSpan = SpectrogramSpan.auto

    static let peakHoldsKey = "spectrum.peakHolds"
    static let waveSecondsKey = "waveform.seconds"
    static let bandMarkersKey = "soundstage.bandMarkers"
    static let averageSpectrumKey = "spectrum.average"
    static let waveChoices = [2, 4, 8]

    static var stored: DisplayOptions {
        let defaults = UserDefaults.standard
        let seconds = defaults.integer(forKey: waveSecondsKey)
        return DisplayOptions(spectrumSide: .stored,
                              peakHolds: defaults.object(forKey: peakHoldsKey) == nil ? true : defaults.bool(forKey: peakHoldsKey),
                              waveSeconds: waveChoices.contains(seconds) ? seconds : 4,
                              bandMarkers: defaults.object(forKey: bandMarkersKey) == nil ? true : defaults.bool(forKey: bandMarkersKey),
                              spectrogramRange: .stored, tilt: .stored,
                              averageSpectrum: defaults.object(forKey: averageSpectrumKey) == nil ? true : defaults.bool(forKey: averageSpectrumKey),
                              spectrogramSpan: .stored)
    }
}

/// How the Stereo stereometer draws each band: the sample cloud, the outline of where the band's samples reach,
/// or that outline over a tinted fill. Chosen in Settings › Metering.
enum StageStyle: String, CaseIterable {
    case dots, outline, filled

    static let key = "soundstage.style"
    static var stored: StageStyle { StageStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dots }

    var title: String {
        switch self {
        case .dots: return L("Dots")
        case .outline: return L("Outlines")
        case .filled: return L("Filled")
        }
    }
}

/// A segmented switch for the panels, built and behaving exactly like the toolbar's Stereo | Immersive switch:
/// the system segmented control (Liquid Glass on macOS 26, with its own sliding selection) on a glass capsule
/// lightly tinted with the accent, the selection in the app's accent. Each segment carries its full name for
/// VoiceOver.
struct GlassSegments<Value: Hashable>: View {
    let label: String
    /// Value, the title shown, and the full name for accessibility.
    let options: [(Value, String, String)]
    let selection: Value
    let select: (Value) -> Void

    var body: some View {
        Picker(label, selection: Binding(get: { selection }, set: { choice in
            withAnimation(.formatShift) { select(choice) }
        })) {
            ForEach(options, id: \.0) { value, title, name in
                Text(verbatim: title).accessibilityLabel(name).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        // Inside a panel the selected segment is filled with the tint; left to the system it would take the
        // macOS accent (blue by default) instead of the app's.
        .tint(Theme.sage)
        .fixedSize()
        .padding(2)
        .glassSurface(Capsule(), tint: Theme.sage.opacity(Theme.dark ? 0.12 : 0.08))
    }
}

/// Key to the Channel Levels bars, drawn with the same shapes and colours: the solid RMS fill, the translucent
/// peak behind it and the ink peak-hold mark.
private struct MeterLegend: View {
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 10) {
            item(Text(verbatim: "RMS")) { Capsule().fill(Theme.sage).frame(width: 5, height: 10) }
            item(Text(L("Peak"))) { Capsule().fill(Theme.sage.opacity(0.35)).frame(width: 5, height: 10) }
            item(Text(L("Hold"))) { Capsule().fill(Theme.ink).frame(width: 10, height: 2) }
        }
        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
        .lineLimit(1)
    }

    private func item<Mark: View>(_ label: Text, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 4) { mark().frame(width: 10, height: 10); label }
    }
}

private struct WaveHeader: View {
    let layout: SpeakerLayout
    let format: ChannelFormat
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(DisplayOptions.waveSecondsKey) private var seconds = 4

    var body: some View {
        let spatial = format == .spatial
        PanelHeader(title: L("WAVEFORM"), detail: "\(spatial ? layout.name : (format == .mono ? "M" : "L/R")) · \(DisplayOptions.waveChoices.contains(seconds) ? seconds : 4) s · " + L("linear") + " · " + L("min/max")) {
            LegendDot(color: Theme.sage, text: spatial ? L("Left side") : (format == .mono ? L("Mono") : L("Left")))
            if format != .mono { LegendDot(color: Theme.sand, text: spatial ? L("Right side") : L("Right")) }
            // Left out, not faded, outside Immersive: hidden entries kept their width and pushed the legend off
            // the trailing edge.
            if spatial {
                if layout.heightCount > 0 { LegendDot(color: Theme.heather, text: L("Height")) }
                if layout.hasLFE { LegendDot(color: Theme.clay, text: "LFE") }
            }
            LegendDot(color: Theme.ember, text: L("Clip"))
        }
    }
}

private struct StageHeader<Trailing: View>: View {
    let format: ChannelFormat
    let layout: SpeakerLayout
    @ViewBuilder var trailing: Trailing
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The title and format never truncate; the band switch drops to its short labels first.
            Eyebrow(L("SOUNDSTAGE")).fixedSize()
            Text(verbatim: format == .spatial ? layout.name : format.title)
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.sage)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Theme.sage.opacity(0.13)))
                .fixedSize()
            Spacer(minLength: 4)
            trailing.layoutPriority(1)
        }
        .padding(.horizontal, 4)
    }
}

private struct LegendDot: View {
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
    let size: CGSize
    let speakers: [Speaker]
    var mix: FormatMix
    let activeRoles: [Bool]

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
                    ForEach([CGFloat(0.5), -0.5], id: \.self) { amplitude in
                        Text("−6")
                            .font(.axis)
                            .foregroundStyle(Theme.tertiary)
                            .opacity(dissolve(weight))
                            .position(x: scope.maxX + WaveformLayout.scaleColumn / 2, y: layout.laneY(index, amplitude: amplitude))
                    }
                }
            }
        }
        .allowsHitTesting(false)
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
    /// The room's band markers show (Immersive); the legend follows them there.
    var markers = true
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
                roomLabels(stage)
                    .opacity(dissolve(1 - (1 - mix.presence) * (1 - mix.mono)))
                scopeLabels(stage)
                bandLegend(stage)
            case .levels: levelLabels(stage)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func roomLabels(_ stage: SoundstageLayout) -> some View {
        ForEach(Array(stage.speakers.enumerated()), id: \.offset) { index, speaker in
            let weight = stage.weight(index)
            Text(speaker.displayName(mono: mix.mono))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(activeRoles[speaker.role] ? Theme.groupColor(speaker.group).opacity(0.95) : Theme.tertiary)
                .fixedSize()
                .blur(radius: (1 - weight) * 3)
                .opacity(stage.showsRoomLabel(speaker) ? dissolve(weight) : 0)
                .position(stage.label(speaker))
        }
    }

    /// The stereometer's labels, in Stereo: L, M and R beyond the rims and the level of the arcs along the horizon.
    @ViewBuilder
    private func scopeLabels(_ stage: SoundstageLayout) -> some View {
        let weight = (1 - mix.presence) * (1 - mix.mono)
        if weight > 0.001 {
            Group {
                ForEach([(-45.0, "L"), (0, "M"), (45, "R")], id: \.0) { angle, name in
                    Text(verbatim: name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
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
            .opacity(dissolve(weight))
        }
    }

    /// The band legend under the plot, shared by the stereometer (Stereo) and the room's band image (Immersive):
    /// each band named by its lower edge, in its colour. Mono has neither, so it folds away there.
    @ViewBuilder
    private func bandLegend(_ stage: SoundstageLayout) -> some View {
        let weight = (1 - mix.mono) * (markers ? 1 : 1 - mix.presence)
        if weight > 0.001, stage.showsScopeLegend {
            let legend = stage.scopeLegend
            HStack(spacing: 0) {
                ForEach(0..<resolution.count, id: \.self) { group in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.bandColor(resolution, group)).frame(width: 6, height: 6)
                        Text(verbatim: resolution.label(group))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: legend.width, height: legend.height)
            // Keyed by resolution, so a band switch cross-fades the old legend into the new one.
            .id(resolution)
            .transition(.opacity)
            .position(x: legend.midX, y: legend.midY)
            .opacity(dissolve(weight))
        }
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
        // An over reads as a status pill, like ON TARGET and OVER on the loudness summary.
        return Text(verbatim: text)
            .font(.system(size: width >= 30 ? 10 : (width >= 20 ? 9 : 7.5), weight: overs ? .bold : .medium).monospacedDigit())
            .foregroundStyle(!active ? Theme.tertiary : (overs ? Theme.onStatus : (peak >= -3 ? Theme.ochre : Theme.ink)))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, overs ? 4 : 0)
            .padding(.vertical, overs ? 1 : 0)
            .background { if overs { Capsule().fill(Theme.ember) } }
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

    private func zoneChip(_ zone: CorrelationZone) -> some View {
        Text(zone.title)
            .font(.system(size: 9, weight: .bold)).tracking(l10n.tracking(0.6))
            .foregroundStyle(Theme.onStatus)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.correlationColor(zone)))
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
