import AnalysisCore
import SwiftUI

// MARK: - Spectrum and Spectrogram

/// What the spectrum and waterfall analyse, for their headers: the input in Mono, L+R in Stereo, and the
/// power sum of every routed channel in Spatial, named as the format (`layoutName`: a DAW plugin's bus).
func spectrumSource(format: ChannelFormat, layoutName: String) -> String {
    switch format {
    case .mono: return "M"
    case .stereo: return "L+R"
    case .spatial: return "\(layoutName) · " + L("all channels")
    }
}

/// The Spectrum card: the spectrogram and the live spectrum in one well on one frequency axis. The waterfall
/// keeps the last 3 to 8 s (fewer as it narrows), newest at its right edge, with the piano keyboard on its left; the live
/// spectrum continues from "now" to the right with its peak holds, so a band's colour and its level read along
/// the same row (or, with the spectrum on the left, the pair mirrors; see `SpectrumSide`). The key under the
/// dominant peak lights up, and the peak badge names it.
///
/// The horizontal strip is too short for a frequency axis that runs up the well, so there the two are cards side by
/// side: the waterfall alone, and the live spectrum on its own with frequency across (`SpectrumCardLayout`).
struct SpectrumPanel: View {
    let model: MeterModel
    let sampleRate: Double
    let source: String
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.panelContext) private var context
    /// Width of the live spectrum beside the waterfall, dragged by the divider between them; 0 is automatic.
    @AppStorage(MeterModel.spectrumStripKey) private var strip: Double = 0
    /// The spectrum's side, the spectrogram's analysis and its view, chosen in the panel's settings.
    @AppStorage(SpectrumSide.key) private var side = SpectrumSide.right.rawValue
    @AppStorage(SpectrogramAnalysis.key) private var analysis = SpectrogramAnalysis.classic.rawValue
    @AppStorage(SpectrogramView.key) private var view = SpectrogramView.flat.rawValue
    @AppStorage(FrequencyScale.key) private var scaleKey = FrequencyScale.log.rawValue
    private var scale: FrequencyScale { FrequencyScale(rawValue: scaleKey) ?? .log }
    /// The peak badge's size, so the hover readout can keep clear of it, and whether the pointer or the readout is over
    /// it (the badge then fades, so the cells and the readout under it can be read).
    @State private var badgeSize = CGSize.zero
    @State private var badgeCovered = false

    /// In the strip, the live spectrum card's share of the two cards' room, set by the gap between them; 0 is the
    /// automatic `stripSpectrumShare`. A share, so the split holds as the strip is resized.
    static let stripShareKey = "strip.spectrumShare"
    @AppStorage(SpectrumPanel.stripShareKey) private var stripShare: Double = 0
    static let stripSpectrumShare: CGFloat = 0.42
    /// Neither card narrows below this while the panel has room for both.
    static let stripCardMinimum: CGFloat = 150

    /// The spectrum card's width in `room` (the two cards, the gap left out) for a stored `share` (0: automatic).
    static func stripSpectrumWidth(room: CGFloat, share: CGFloat) -> CGFloat {
        let wanted = room * (share > 0 ? share : stripSpectrumShare)
        guard room >= 2 * stripCardMinimum else { return wanted.rounded() }
        return min(room - stripCardMinimum, max(stripCardMinimum, wanted)).rounded()
    }

    var body: some View {
        if context == .strip {
            GeometryReader { proxy in
                let room = max(0, proxy.size.width - StripLayout.gap)
                let spectrum = Self.stripSpectrumWidth(room: room, share: CGFloat(stripShare))
                HStack(spacing: 0) {
                    waterfallCard(strip: SpectrogramLayout.split)
                        .frame(width: max(0, room - spectrum))
                    // The gap between the cards moves the split, like the gaps between the strip's panels.
                    PanelDivider(axis: .horizontal, leading: room - spectrum,
                                 onResize: { waterfall in
                                     guard room > 0 else { return }
                                     let width = Self.stripSpectrumWidth(room: room, share: (room - waterfall) / room)
                                     let share = Double(width / room)
                                     if abs(share - stripShare) > 0.0001 { stripShare = share }
                                 },
                                 onReset: { stripShare = 0 },
                                 identifier: "strip.spectrumSplit")
                        .frame(width: StripLayout.gap)
                    spectrumCard
                        .frame(width: spectrum)
                }
            }
        } else {
            waterfallCard(strip: CGFloat(self.strip))
        }
    }

    /// The spectrogram, with the live spectrum beside it unless `strip` is `SpectrogramLayout.split`.
    private func waterfallCard(strip: CGFloat) -> some View {
        let left = side == SpectrumSide.left.rawValue
        let flat = view != SpectrogramView.surface.rawValue
        let split = strip == SpectrogramLayout.split
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: split ? L("SPECTROGRAM") : L("SPECTROGRAM") + " · " + L("SPECTRUM"), detail: source) {
                    SpectrogramLegend(showsAverage: !split)
                    if !split { PanelSettingsButton(panel: .spectrum, model: model) }
                }
                GeometryReader { proxy in
                    let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left, scale: scale)
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .spectrogram, model: model)
                        if !split { MeterCanvas(kind: .spectrum, model: model) }
                        ZoomResting {
                            // The keyboard, its notes and the hover readings follow the flat image's rows; the 3D view
                            // labels its own depth instead.
                            if flat {
                                PianoKeyboard(sampleRate: sampleRate, strip: strip, left: left, scale: scale)
                                PeakKey(readouts: model.readouts, sampleRate: sampleRate, strip: strip, left: left, scale: scale)
                            } else {
                                SurfaceLabels(sampleRate: sampleRate, strip: strip, left: left, scale: scale)
                            }
                            SpectrogramLabels(sampleRate: sampleRate, strip: strip, left: left, scale: scale, notes: flat)
                            // In the waterfall's top corner, clear of the spectrum's frequency labels and of the keyboard,
                            // in either orientation; under the hover readout, which must never be hidden.
                            let badge = layout.plot.width >= 250 && badgeSize.width > 0
                                ? CGRect(x: layout.plot.maxX - 6 - badgeSize.width, y: layout.plot.minY + 6,
                                         width: badgeSize.width, height: badgeSize.height) : nil
                            PeakBadge(readouts: model.readouts)
                                .onGeometryChange(for: CGSize.self) { $0.size } action: { badgeSize = $0 }
                                .opacity(layout.plot.width >= 250 ? (badgeCovered ? 0.12 : 1) : 0)
                                .animation(.easeOut(duration: 0.15), value: badgeCovered)
                                .padding(.top, 6)
                                .padding(.trailing, 6)
                                .frame(width: max(0, layout.plot.width), alignment: .topTrailing)
                                .offset(x: layout.plot.minX, y: layout.plot.minY)
                                .allowsHitTesting(false)
                            SpectrogramInspector(sampleRate: sampleRate, strip: strip, left: left, scale: scale, source: source, waterfall: flat,
                            badge: badge, badgeCovered: $badgeCovered,
                            sharedSize: model.sourceIsBridge || model.format == .spatial || DisplayOptions.stored.spectrogramAnalysis == .enhanced ? 0 : MultiFFTPreferences.legacySTFT.rawValue)
                        }
                        // Between the waterfall's "now" edge and the spectrum, like the dividers in the summary.
                        if !split {
                            PanelDivider(axis: .horizontal, leading: layout.dividerLeading,
                                         onResize: { setStrip(layout.strip(forDivider: $0), size: proxy.size, left: left) },
                                         onReset: { setStrip(0, size: proxy.size, left: left) })
                                .frame(width: SpectrogramLayout.spectrumGap, height: layout.plot.height)
                                .offset(x: layout.dividerX, y: layout.plot.minY)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
                .background { PlotPlate() }
            }
        }
    }

    /// The live spectrum in a card of its own, frequency across (the strip). It carries the panel's controls.
    private var spectrumCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: L("SPECTRUM"), detail: source) {
                    ViewThatFits(in: .horizontal) { AverageKey(); Color.clear.frame(width: 0, height: 0) }
                    PanelSettingsButton(panel: .spectrum, model: model)
                }
                ZStack(alignment: .topLeading) {
                    MeterCanvas(kind: .spectrum, model: model)
                    SpectrumCardLabels(sampleRate: sampleRate, scale: scale)
                    SpectrumCardInspector(sampleRate: sampleRate, scale: scale)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
                .background { PlotPlate() }
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

/// The three strongest peaks, one per row as pitch (cents) · frequency · level, e.g. "1  A4 (+2¢) • 440.0 Hz • −12.4 dBFS".
/// Row 1 is the dominant peak of the whole spectrum (`PeakTracker`); rows 2 and 3 are the next loudest notes the analyzer
/// finds sounding with it (`NoteHolds`: tonal peaks from 27 Hz to 4.2 kHz within 18 dB of the loudest, overtones left
/// out), skipping any note within a semitone of the dominant peak. Every field reserves its widest value and an empty row keeps its place,
/// so the tag never changes size while values move.
private struct PeakBadge: View {
    @ObservedObject var readouts: Readouts

    private struct Row {
        let frequency: Float
        let level: Float
    }

    var body: some View {
        let values = readouts.values
        let peak = values.peak
        let first = peak.visible ? Row(frequency: peak.frequency, level: peak.level) : nil
        // The dominant peak's estimate and a note's can differ by a few hertz for one partial, so any note within a
        // semitone of it is that same peak.
        let others = values.notes.notes
            .filter { note in first.map { abs(1200 * log2(Double(note.frequency / $0.frequency))) >= 100 } ?? true }
            .sorted { $0.level > $1.level }
            .prefix(2)
            .map { Row(frequency: $0.frequency, level: $0.level) }
        let rows: [Row?] = [first, others.first, others.dropFirst().first]
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<3, id: \.self) { rank in row(rank, rows[rank]) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background { BadgeSurface() }
        .accessibilityElement(children: .combine)
    }

    /// The dominant row reads strongest; the two below it a step quieter, so the ranking shows at a glance.
    private func row(_ rank: Int, _ row: Row?) -> some View {
        let pitch = row.flatMap { Pitch(frequency: Double($0.frequency)) }
        let font = Font.caption2.weight(.medium)
        let ink = rank == 0 ? Theme.ink : Theme.secondary
        return HStack(spacing: 6) {
            Text(verbatim: "\(rank + 1)").font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.tertiary).frame(width: 7, alignment: .leading)
            StableNumber(text: pitch?.label ?? "—", template: "A#8", font: font.weight(.semibold),
                         color: pitch == nil ? Theme.disabled : (rank == 0 ? Theme.sage : ink), alignment: .leading)
            StableNumber(text: pitch.map { "(\($0.centsLabel))" } ?? "", template: "(−50¢)", font: font, color: Theme.tertiary,
                         alignment: .leading)
            separator
            StableNumber(text: row.map { Self.frequency($0.frequency) } ?? "— Hz", template: "88.88 kHz", font: font,
                         color: row == nil ? Theme.disabled : ink)
            separator
            StableNumber(text: row.map { MeterScale.tenths($0.level) + " dBFS" } ?? "— dBFS", template: "−88.8 dBFS",
                         font: font, color: row == nil ? Theme.disabled : ink)
        }
    }

    private var separator: some View {
        Text("•").font(.caption2).foregroundStyle(Theme.tertiary)
    }

    static func frequency(_ hertz: Float) -> String {
        hertz < 1_000 ? String(format: "%.1f Hz", hertz) : String(format: "%.2f kHz", hertz / 1_000)
    }
}

/// A solid chip over the plot. Glass here would re-sample the live spectrum under it on every frame.
struct BadgeSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.tagRadius, style: .continuous)
        shape.fill(Theme.display)
            .overlay { shape.strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.10 : 0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(Theme.dark ? 0.35 : 0.10), radius: 4, y: 2)
    }
}

/// The colour scale in the header: the range's floor and ceiling either side of a bar that runs the tone curve
/// itself (`SpectrogramTone`), linear in dB, with a notch every 24 dB; and the display slope when one is set.
private struct SpectrogramLegend: View {
    /// The average spectrum's key; off where the spectrum has a card of its own (`AverageKey` there).
    var showsAverage = true
    @AppStorage(SpectrogramRange.key) private var rangeKey = SpectrogramRange.standard.rawValue
    @AppStorage(SpectrogramColors.key) private var colorsKey = SpectrogramColors.heat.rawValue
    @AppStorage(SpectrumTilt.key) private var tiltSlope = 0.0
    @AppStorage(DisplayOptions.averageSpectrumKey) private var average = true
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let range = SpectrogramRange(rawValue: rangeKey) ?? .standard
        let tilt = SpectrogramLegend.tiltLabel(SpectrumTilt(stored: tiltSlope))
        // Narrow headers drop the average's key, then the tilt, before the scale itself.
        ViewThatFits(in: .horizontal) {
            legend(range, tilt: tilt, average: average && showsAverage)
            legend(range, tilt: tilt, average: false)
            legend(range, tilt: nil, average: false)
            // The strip's narrow cards drop the scale before their title.
            Color.clear.frame(width: 0, height: 0)
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
                let colors = SpectrogramColors(rawValue: colorsKey) ?? .heat
                let stops = (0...steps).map { step -> Gradient.Stop in
                    let fraction = Float(step) / Float(steps)
                    let color = Theme.ramp(decibels: range.floor + span * fraction, range: range, colors: colors).color
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
                Capsule().fill(Theme.sand).frame(width: 10, height: 1.5)
                    .padding(.leading, 4)
                Text(L("avg")).font(.axis).foregroundStyle(Theme.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The average spectrum's key, for the spectrum's own card.
private struct AverageKey: View {
    @AppStorage(DisplayOptions.averageSpectrumKey) private var average = true
    @AppStorage(SpectrumTilt.key) private var tiltSlope = 0.0
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 5) {
            if let tilt = SpectrogramLegend.tiltLabel(SpectrumTilt(stored: tiltSlope)) {
                Text(verbatim: tilt).font(.axis).foregroundStyle(Theme.secondary)
            }
            if average {
                Capsule().fill(Theme.sand).frame(width: 10, height: 1.5)
                    .padding(.leading, 4)
                Text(L("avg")).font(.axis).foregroundStyle(Theme.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The spectrum card's axes: levels at the left, frequencies under the plot (`SpectrumCardLayout`).
private struct SpectrumCardLabels: View {
    let sampleRate: Double
    let scale: FrequencyScale

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrumCardLayout(size: proxy.size, scale: scale)
            ZStack(alignment: .topLeading) {
                ForEach(SpectrogramLayout.grid.filter { $0 > -96 && (layout.plot.height >= 110 || $0 != -24 && $0 != -72) }, id: \.self) { db in
                    Text(verbatim: db == 0 ? "0 dB" : "−\(Int(-db))").font(.axis)
                        .foregroundStyle(Theme.tertiary).fixedSize()
                        .position(x: layout.plot.minX - SpectrumCardLayout.levelLabels / 2,
                                  y: db == 0 ? layout.y(decibels: db) + 7 : layout.y(decibels: db))
                }
                ForEach(layout.frequencyTicks(sampleRate: sampleRate), id: \.0) { tick in
                    let decade = scale.isMajor(tick.0)
                    // The top of the axis is named just inside the plot's right edge.
                    let edge = SpectrogramLayout.isTopEdge(tick.0, sampleRate: sampleRate)
                    Text(verbatim: tick.1).font(.axis)
                        .foregroundStyle(decade ? Theme.secondary : Theme.tertiary).fixedSize()
                        .position(x: layout.x(frequency: tick.0, sampleRate: sampleRate) - (edge ? 10 : 0),
                                  y: layout.plot.maxY + FrequencyAxis.labelHeight / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hover over the spectrum card to read the band under the pointer: its pitch, frequency and live level, with the
/// long-term average while it is shown, as the Spectrum card's inspector reads the spectrum beside the waterfall.
private struct SpectrumCardInspector: View {
    let sampleRate: Double
    let scale: FrequencyScale
    @State private var location: CGPoint?
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrumCardLayout(size: proxy.size, scale: scale)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): location = point
                        case .ended: location = nil
                        }
                    }
                if let location, layout.plot.insetBy(dx: -1, dy: -1).contains(location) {
                    PanelTimeline(interval: 1.0 / 15) {
                        overlay(at: location, layout: layout)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func overlay(at point: CGPoint, layout: SpectrumCardLayout) -> some View {
        let scene = SceneStore.existing(.spectrum) as? SpectrumScene
        let count = SpectrumScene.pointCount
        let band = max(0, min(count - 1, Int(layout.row(x: point.x, rows: count, sampleRate: sampleRate).rounded())))
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        let frequency = LogFrequencyAxis.centre(band, of: count, upper: upper)
        let level = scene.flatMap { $0.shown.indices.contains(band) ? $0.shown[band] : nil }
        let average = DisplayOptions.stored.averageSpectrum ? scene?.average.flatMap { $0.indices.contains(band) ? $0[band] : nil } : nil
        let x = layout.x(frequency: frequency, sampleRate: sampleRate)
        let pitch = Pitch(frequency: frequency)
        let font = Font.caption2.weight(.medium).monospacedDigit()
        let tag = HStack(spacing: 5) {
            Text(verbatim: pitch.map { "\($0.label) \($0.centsLabel)" } ?? "--").font(font.weight(.semibold)).foregroundStyle(Theme.sage)
            Text(verbatim: frequency < 1_000 ? String(format: "%.0f Hz", frequency) : String(format: "%.2f kHz", frequency / 1_000))
                .font(font).foregroundStyle(Theme.ink)
            Text(verbatim: level.map { MeterScale.tenths($0, floor: -119.9) + " dBFS" } ?? "-- dBFS")
                .font(font).foregroundStyle(level == nil ? Theme.tertiary : Theme.ink)
            if let average {
                Text(verbatim: MeterScale.tenths(average, floor: -119.9)).font(font).foregroundStyle(Theme.sand)
                Text(L("avg")).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background { BadgeSurface() }
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: layout.plot.minY))
                path.addLine(to: CGPoint(x: x, y: layout.plot.maxY))
            }
            .stroke(Theme.ink.opacity(Theme.dark ? 0.55 : 0.5), style: StrokeStyle(lineWidth: 0.5))
            tag
                .frame(width: layout.plot.width, alignment: x > layout.plot.midX ? .leading : .trailing)
                .padding(.horizontal, 4)
                .offset(x: layout.plot.minX - 4, y: layout.plot.minY + 4)
        }
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
    let scale: FrequencyScale
    /// What is analysed, for an exported image's caption.
    let source: String
    /// Whether the plot shows the flat waterfall, whose cells the pointer reads (the 3D view has no such cells).
    var waterfall = true
    /// The peak badge's frame in the well, which the readout keeps clear of; nil while it is hidden.
    var badge: CGRect? = nil
    @Binding var badgeCovered: Bool
    var sharedSize = 0
    @State private var location: CGPoint? = Diagnostics.inspectPoint
    @AppStorage(SpectrogramSpan.key) private var spanKey = SpectrogramSpan.auto.rawValue
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left,
                                           span: (SpectrogramSpan(rawValue: spanKey) ?? .auto).seconds, scale: scale)
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
                        noteBadge(layout: layout)
                    }
                    .onAppear { noteBadge(layout: layout) }
                    .onChange(of: badge) { _ in noteBadge(layout: layout) }
                    .contextMenu {
                        Button { if let image = image() { SpectrogramImage.copy(image) } } label: { Label(L("Copy Spectrogram Image"), systemImage: "doc.on.doc") }
                        Button { if let image = image() { SpectrogramImage.save(image) } } label: { Label(L("Save Spectrogram Image…"), systemImage: "square.and.arrow.down") }
                    }
                if let location, let reading = reading(at: location, layout: layout) {
                    PanelTimeline(interval: 1.0 / 15) {
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
                                     caption: SpectrogramImage.caption(source: source, sampleRate: sampleRate, options: options))
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
        if waterfall && layout.plot.contains(point) {
            // The cell under the pointer, as analysed: its row's centre frequency, its level, and the instant its
            // column is centred on, which is half the analysis span (about 85 ms) before the column was made.
            let scene = SceneStore.existing(.spectrogram) as? SpectrogramScene
            let rows = SpectrogramHistory.rows
            let row = max(0, min(rows - 1, Int(layout.row(y: point.y, rows: rows, sampleRate: sampleRate).rounded())))
            let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
            let centre = LogFrequencyAxis.centre(row, of: rows, upper: upper)
            let shared = sharedSize
            let delay = Double(shared > 0 ? shared : SpectrumAnalyzer.historyLength(sampleRate: sampleRate)) / 2 / sampleRate
            let cell = scene?.level(atU: layout.timeFraction(x: point.x), row: Double(row))
            return Reading(frequency: centre, level: cell?.level,
                           secondsAgo: (cell?.secondsAgo ?? (1 - layout.timeFraction(x: point.x)) * layout.seconds) + delay,
                           resolution: SpectrogramResolution.describe(row: row, sampleRate: sampleRate,
                                                                      analysis: DisplayOptions.stored.spectrogramAnalysis, sharedSize: shared))
        }
        if layout.showsSpectrum, point.x >= layout.spectrum.minX, point.x <= layout.spectrum.maxX {
            let scene = SceneStore.existing(.spectrum) as? SpectrumScene
            let bands = scene?.shown ?? []
            let count = SpectrumScene.pointCount
            let band = max(0, min(count - 1, Int(layout.row(y: point.y, rows: count, sampleRate: sampleRate).rounded())))
            let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
            let low = LogFrequencyAxis.edge(band, of: count, upper: upper)
            let high = LogFrequencyAxis.edge(band + 1, of: count, upper: upper)
            let frequency = (low * high).squareRoot()
            let bandwidth = high < 1000 ? String(format: "%.1f–%.1f Hz", low, high)
                                       : String(format: "%.2f–%.2f kHz", low / 1000, high / 1000)
            let average = DisplayOptions.stored.averageSpectrum ? scene?.average : nil
            return Reading(frequency: frequency, level: bands.indices.contains(band) ? bands[band] : nil, secondsAgo: nil,
                           average: average.flatMap { $0.indices.contains(band) ? $0[band] : nil }, resolution: bandwidth)
        }
        return nil
    }

    @ViewBuilder
    private func overlay(_ reading: Reading, at point: CGPoint, layout: SpectrogramLayout, size: CGSize) -> some View {
        // A precise solid crosshair, a ring at the point read, and the readout on an opaque tag beside it.
        let lineColor = Theme.ink.opacity(Theme.dark ? 0.55 : 0.5)
        let dash = StrokeStyle(lineWidth: 0.5)
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
            Circle().strokeBorder(Theme.ink, lineWidth: 1.25)
                .background(Circle().fill(Theme.display.opacity(0.6)))
                .frame(width: 9, height: 9)
                .offset(x: point.x - 4.5, y: point.y - 4.5)
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
            let place = Self.tagOrigin(at: point, size: InspectorTag.size(reading), span: span, badge: badge)
            tag.frame(width: InspectorTag.width(reading), alignment: .leading).offset(x: place.x, y: place.y)
        }
    }

    /// Fades the peak badge while the pointer is on it or the readout cannot keep clear of it (a short well), so
    /// neither ever covers the other's text.
    private func noteBadge(layout: SpectrogramLayout) {
        var covered = false
        if let badge, let point = location, let reading = reading(at: point, layout: layout) {
            let size = InspectorTag.size(reading)
            let origin = Self.tagOrigin(at: point, size: size, span: layout.plot.union(layout.spectrum), badge: badge)
            covered = badge.contains(point) || CGRect(origin: origin, size: size).intersects(badge)
        }
        if covered != badgeCovered { badgeCovered = covered }
    }

    /// Where the readout goes: beside the pointer, above it, on whichever side has room; never over the pointer and,
    /// where it can be helped, never over the peak badge: it moves under the badge, beside it, to the pointer's other
    /// side, or below the pointer, the first of these that is clear.
    static func tagOrigin(at point: CGPoint, size: CGSize, span: CGRect, badge: CGRect?) -> CGPoint {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: max(span.minX + 2, min(span.maxX - 2 - size.width, p.x)), y: max(span.minY + 2, min(span.maxY - 2 - size.height, p.y)))
        }
        let right = point.x + 14, left = point.x - 14 - size.width
        let above = point.y - size.height - 8, below = point.y + 12
        let preferred = point.x + 14 + size.width > span.maxX ? left : right
        let other = preferred == right ? left : right
        var candidates = [CGPoint(x: preferred, y: above), CGPoint(x: other, y: above)]
        if let badge {
            candidates.append(CGPoint(x: preferred, y: badge.maxY + 4))
            for y in [above, below] {
                candidates += [CGPoint(x: badge.minX - 4 - size.width, y: y), CGPoint(x: badge.maxX + 4, y: y)]
            }
        }
        candidates += [CGPoint(x: preferred, y: below), CGPoint(x: other, y: below)]
        let ring = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        let blocked = badge?.insetBy(dx: -3, dy: -3)
        for candidate in candidates.map(clamp) {
            let rect = CGRect(origin: candidate, size: size)
            if !rect.intersects(ring) && !(blocked.map(rect.intersects) ?? false) { return candidate }
        }
        return clamp(candidates[0])
    }

    private struct InspectorTag: View {
        let reading: Reading
        @ObservedObject private var l10n = Localizer.shared

        /// Fixed per kind, so the tag never changes size as the pointer moves.
        static func width(_ reading: Reading) -> CGFloat { reading.secondsAgo != nil ? 246 : (reading.average == nil ? 200 : 268) }
        static func size(_ reading: Reading) -> CGSize { CGSize(width: width(reading), height: reading.resolution == nil ? 22 : 34) }

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
enum SpectrogramResolution {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedRate: Double = 0
    nonisolated(unsafe) private static var cachedRows: [SpectrogramAnalyzer.Resolution] = []

    private static func resolutions(_ sampleRate: Double) -> [SpectrogramAnalyzer.Resolution] {
        lock.lock()
        defer { lock.unlock() }
        if cachedRate != sampleRate {
            cachedRows = SpectrogramAnalyzer.rowResolutions(sampleRate: sampleRate,
                span: SpectrumAnalyzer.historyLength(sampleRate: sampleRate))
            cachedRate = sampleRate
        }
        return cachedRows
    }

    static func range(sampleRate: Double) -> String {
        let rows = resolutions(sampleRate)
        let lengths = rows.flatMap { [$0.length, $0.previousLength ?? $0.length] }
        guard let low = lengths.min(), let high = lengths.max() else { return "FFT \(SpectrumAnalyzer.fftSize)" }
        return "FFT \(low)–\(high)"
    }

    static func describe(row: Int, sampleRate: Double, analysis: SpectrogramAnalysis = .classic, sharedSize: Int = 0) -> String? {
        if sharedSize > 0 { return "FFT \(sharedSize) · Hann · " + String(format: "%.0f ms", Double(sharedSize) / sampleRate * 1000) }
        if analysis == .enhanced {
            let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
            let centre = LogFrequencyAxis.centre(row, of: SpectrogramHistory.rows, upper: upper)
            let length = ReassignedSpectrogram.length(frequency: centre, sampleRate: sampleRate,
                                                      span: SpectrumAnalyzer.historyLength(sampleRate: sampleRate))
            return "FFT \(length) · Hann · " + L("reassigned")
        }
        let rows = resolutions(sampleRate)
        guard rows.indices.contains(row) else { return nil }
        let resolution = rows[row]
        func name(_ window: SpectralWindow) -> String { window == .hann ? "Hann" : "Blackman–Harris" }
        if let previousLength = resolution.previousLength, let previousWindow = resolution.previousWindow {
            let length = previousLength == resolution.length ? "\(resolution.length)" : "\(resolution.length)–\(previousLength)"
            let window = previousWindow == resolution.window ? name(resolution.window) : "Hann / Blackman–Harris"
            return "FFT \(length) · \(window)"
        }
        return "FFT \(resolution.length) · \(name(resolution.window)) · " + String(format: "%.0f ms", Double(resolution.length) / sampleRate * 1_000)
    }

}

/// Octave labels, the time axis under the waterfall, and the spectrum's level axis under it with its frequency
/// marks inside it.
private struct SpectrogramLabels: View {
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool
    let scale: FrequencyScale
    /// The octave labels beside the keyboard (the flat view only).
    var notes = true
    @AppStorage(SpectrogramSpan.key) private var spanKey = SpectrogramSpan.auto.rawValue
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left,
                                           span: (SpectrogramSpan(rawValue: spanKey) ?? .auto).seconds, scale: scale)
            let octaves = notes ? Self.octaveLabels(layout, sampleRate: sampleRate) : []
            let perSecond = layout.plot.width / CGFloat(layout.seconds)
            let timeStep = max(1, Int((36 / max(0.01, perSecond)).rounded(.up)))
            ZStack(alignment: .topLeading) {
                ForEach(octaves, id: \.self) { number in
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
                // Without the spectrum beside it (the strip), the waterfall has neither level nor frequency marks.
                ForEach(SpectrogramLayout.grid.filter { layout.showsSpectrum && $0 > -96 && (strip.width >= 150 || $0 != -24 && $0 != -72) }, id: \.self) { db in
                    Text(verbatim: db == 0 ? "0 dB" : "−\(Int(-db))").font(.axis)
                        .foregroundStyle(Theme.tertiary).fixedSize()
                        .position(x: db == 0 ? layout.fullScaleX + (left ? 14 : -14) : layout.x(decibels: db),
                                  y: strip.maxY + FrequencyAxis.labelHeight / 2)
                }
                ForEach(layout.showsSpectrum ? SpectrogramLayout.frequencyTicks(layout, sampleRate: sampleRate) : [], id: \.0) { tick in
                    let decade = scale.isMajor(tick.0)
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

    /// The octaves named beside the keyboard: on the log axis every octave or every few, counted from C4, as room
    /// allows; on the linear one, from the top down, each where it keeps 18 pt from the one above.
    static func octaveLabels(_ layout: SpectrogramLayout, sampleRate: Double) -> [Int] {
        switch layout.scale {
        case .log:
            let octave = abs(layout.y(midi: 60, sampleRate: sampleRate) - layout.y(midi: 72, sampleRate: sampleRate))
            let step = max(1, Int(ceil(18 / max(1, octave))))
            return (0...10).filter { ($0 - 4) % step == 0 }
        case .linear:
            var kept: [Int] = [], last = -CGFloat.infinity
            for number in (0...10).reversed() {
                let y = layout.y(midi: Double(12 * (number + 1)), sampleRate: sampleRate)
                guard y > layout.plot.minY + 4, y < layout.plot.maxY - 2, y - last >= 18 else { continue }
                kept.append(number); last = y
            }
            return kept
        }
    }
}

/// The 3D view's depth axis: 100 Hz, 1 kHz and 10 kHz beside the floor's left edge (right, mirrored), where the floor
/// grid's lines start.
private struct SurfaceLabels: View {
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool
    let scale: FrequencyScale
    @AppStorage(SpectrogramSpan.key) private var spanKey = SpectrogramSpan.auto.rawValue

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrogramLayout(size: proxy.size, strip: strip, spectrumLeft: left,
                                           span: (SpectrogramSpan(rawValue: spanKey) ?? .auto).seconds, scale: scale)
            let projection = SurfaceProjection(plot: layout.plot)
            let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
            ZStack(alignment: .topLeading) {
                ForEach(SurfaceProjection.marks(scale).filter { $0.0 < upper }, id: \.0) { frequency, label in
                    let point = projection.point(u: layout.mirrored ? 1 : 0, d: SurfaceProjection.depth(frequency: frequency, upper: upper, scale: scale))
                    Text(verbatim: label).font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                        .position(x: point.x + (layout.mirrored ? 14 : -14), y: point.y)
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
    let scale: FrequencyScale

    var body: some View {
        Canvas { context, size in
            let layout = SpectrogramLayout(size: size, strip: strip, spectrumLeft: left, scale: scale)
            let keys = layout.keyboard
            func light(_ midi: Int, opacity: Double) -> Bool {
                let height = max(2, layout.semitoneHeight(sampleRate: sampleRate, midi: Double(midi)))
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
/// Individual black keys fade in only where each semitone has enough vertical space: everywhere or nowhere on the log
/// axis, where every semitone is as tall; from the treble down on the linear one, where they grow with the pitch.
/// Each layer is batched into a single path (four fills per redraw instead of one per key).
private struct PianoKeyboard: View {
    let sampleRate: Double
    let strip: CGFloat
    let left: Bool
    let scale: FrequencyScale

    var body: some View {
        Canvas { context, size in
            let layout = SpectrogramLayout(size: size, strip: strip, spectrumLeft: left, scale: scale)
            let keys = layout.keyboard
            func y(_ midi: Double) -> CGFloat { layout.y(midi: midi, sampleRate: sampleRate) }
            // Visible MIDI range; the 20 Hz floor clamps the log axis, so notes below it are skipped.
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
                // Ticks run in from the edge nearer the plot; on the linear axis only where the octave has room.
                guard bottom - top >= 3 || octave == 4 else { continue }
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
            guard low <= high else { return }
            // Black keys are the darkest thing on the keyboard in either appearance; drawn in four steps of detail.
            for level in 1...4 {
                var black = Path()
                for midi in Int(low)...Int(high) where SpectrogramLayout.isBlack(midi) {
                    let semitone = layout.semitoneHeight(sampleRate: sampleRate, midi: Double(midi))
                    let detail = min(1, max(0, (semitone - 3) / 2))
                    guard detail > 0, Int((detail * 4).rounded(.up)) == level else { continue }
                    black.addRoundedRect(in: CGRect(x: layout.blackKeyX(width: keys.width * 0.6), y: y(Double(midi) + 0.5) + 0.5,
                                                    width: keys.width * 0.6, height: max(1, semitone - 1)),
                                         cornerSize: CGSize(width: 1, height: 1))
                }
                let keyDetail = Double(level) / 4
                context.fill(black, with: .color(Theme.dark ? Color.black.opacity(0.6 * keyDetail) : Theme.ink.opacity(0.34 * keyDetail)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
