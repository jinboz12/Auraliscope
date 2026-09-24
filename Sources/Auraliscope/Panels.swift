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

    var body: some View {
        ZStack(alignment: .trailing) {
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
    case .spatial: return "\(layout.name) · all channels"
    }
}

/// The Spectrum card: live spectrum of the monitored channels with the dominant-peak badge. Its frequency axis
/// matches the Spectrogram card below, since both are placed from `FrequencyAxis` at the same width.
struct SpectrumPanel: View {
    let model: MeterModel
    let sampleRate: Double
    let source: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "SPECTRUM", detail: "\(source) · FFT \(SpectrumAnalyzer.fftSize)") { EmptyView() }
                ZStack {
                    MeterCanvas(kind: .spectrum, model: model)
                    SpectrumLabels(sampleRate: sampleRate)
                }
                .overlay(alignment: .topTrailing) {
                    PeakBadge(readouts: model.readouts)
                        .padding(.top, 8)
                        .padding(.trailing, 14)
                }
                .background { WellSurface() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
            }
        }
    }
}

/// The Spectrogram card: the last `historySeconds` of spectra scrolling down from "now" at the top.
struct SpectrogramPanel: View {
    let model: MeterModel
    let sampleRate: Double
    let source: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "SPECTROGRAM", detail: "\(source) · \(Int(SpectrogramLayout.historySeconds)) s · pitch") {
                    WaterfallLegend()
                }
                ZStack {
                    MeterCanvas(kind: .spectrogram, model: model)
                    PianoKeyboard(sampleRate: sampleRate)
                    SpectrogramLabels(sampleRate: sampleRate)
                }
                .background { WellSurface() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
            }
        }
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

/// Liquid Glass floating over the plot on macOS 26, a thin material before it.
private struct BadgeSurface: View {
    var body: some View {
        Capsule().fill(.clear).glassSurface(Capsule())
    }
}

private struct WaterfallLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("−100").font(.axis).foregroundStyle(Theme.tertiary)
            // Same stops as the waterfall shader's auroraMap.
            Capsule()
                .fill(LinearGradient(colors: Theme.rampStops.map(\.color), startPoint: .leading, endPoint: .trailing))
                .frame(width: 64, height: 5)
                .overlay { Capsule().strokeBorder(Theme.hairline.opacity(0.10), lineWidth: 0.5) }
            Text("−12 dB").font(.axis).foregroundStyle(Theme.tertiary)
        }
    }
}

/// Frequency tick labels under a plot; sparse when the plot is narrow.
private struct FrequencyTicks: View {
    let plot: CGRect
    let sampleRate: Double

    var body: some View {
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        let dense = plot.width > 460
        let ticks: [(Double, String)] = [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
                                         (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"), (20_000, "20k")]
        ForEach(ticks.filter { $0.0 <= upper && (dense || [20, 100, 1_000, 10_000, 20_000].contains($0.0)) }, id: \.0) { tick in
            let x = FrequencyAxis.x(tick.0, in: plot, sampleRate: sampleRate)
            Text(tick.1)
                .font(.axis)
                .foregroundStyle([100, 1_000, 10_000].contains(tick.0) ? Theme.secondary : Theme.tertiary)
                .fixedSize()
                .position(x: min(plot.maxX - 8, max(plot.minX + 8, x)), y: plot.maxY + FrequencyAxis.labelHeight / 2)
        }
    }
}

/// A right-aligned label in the gutter left of a plot.
private func gutterLabel(_ text: String, y: CGFloat) -> some View {
    Text(text)
        .font(.axis)
        .foregroundStyle(Theme.tertiary)
        .frame(width: FrequencyAxis.gutter - 8, alignment: .trailing)
        .position(x: (FrequencyAxis.gutter - 8) / 2 + 1, y: y)
}

/// dBFS gutter and frequency axis for the Spectrum well.
private struct SpectrumLabels: View {
    let sampleRate: Double

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrumLayout(size: proxy.size)
            // Grid labels at least 14 pt apart, always keeping 0 dBFS.
            let spacing = layout.y(decibels: SpectrumLayout.grid[1]) - layout.y(decibels: SpectrumLayout.grid[0])
            let stride = spacing >= 14 ? 1 : 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(SpectrumLayout.grid.enumerated()).filter { $0.offset % stride == 0 }, id: \.offset) { _, db in
                    gutterLabel(db == 0 ? "0" : "−\(Int(-db))", y: layout.y(decibels: db))
                }
                FrequencyTicks(plot: layout.plot, sampleRate: sampleRate)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Piano keyboard, octave labels and time axis for the horizontal Spectrogram well.
private struct SpectrogramLabels: View {
    let sampleRate: Double

    var body: some View {
        GeometryReader { proxy in
            let layout = SpectrogramLayout(size: proxy.size)
            let octave = abs(layout.y(midi: 60, sampleRate: sampleRate) - layout.y(midi: 72, sampleRate: sampleRate))
            let labelStep = max(1, Int(ceil(18 / max(1, octave))))
            let perSecond = layout.plot.width / CGFloat(SpectrogramLayout.historySeconds)
            let timeStep = 2 * max(1, Int((36 / max(0.01, perSecond * 2)).rounded(.up)))
            ZStack(alignment: .topLeading) {
                ForEach((0...10).filter { ($0 - 4) % labelStep == 0 }, id: \.self) { number in
                    let y = layout.y(midi: Double(12 * (number + 1)), sampleRate: sampleRate)
                    if y > layout.plot.minY + 4 && y < layout.plot.maxY - 2 {
                        Text(verbatim: "C\(number)")
                            .font(.axis)
                            .foregroundStyle(number == 4 ? Theme.secondary : Theme.tertiary)
                            .frame(width: SpectrogramLayout.noteLabels - 4, alignment: .trailing)
                            .position(x: (SpectrogramLayout.noteLabels - 4) / 2, y: y)
                    }
                }
                Text(verbatim: "now").font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                    .position(x: layout.plot.maxX - 10, y: layout.plot.maxY + FrequencyAxis.labelHeight / 2)
                ForEach(Array(Swift.stride(from: timeStep, to: Int(SpectrogramLayout.historySeconds), by: timeStep)), id: \.self) { seconds in
                    Text(verbatim: "−\(seconds)s").font(.axis).foregroundStyle(Theme.tertiary).fixedSize()
                        .position(x: layout.x(secondsAgo: Double(seconds)), y: layout.plot.maxY + FrequencyAxis.labelHeight / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// At small heights, show octave groups instead of squeezing ~120 keys into a strip.
/// Individual black keys fade in only when each semitone has enough vertical space.
/// The axis is affine in MIDI, so every edge comes from one origin and slope, and each layer is batched into a
/// single path (four fills per redraw instead of one per key).
private struct PianoKeyboard: View {
    let sampleRate: Double

    var body: some View {
        Canvas { context, size in
            let layout = SpectrogramLayout(size: size)
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
                if octave == 4 {
                    middleC = CGRect(x: keys.maxX - 12, y: bottom - 0.5, width: 12, height: 1)
                } else {
                    ticks.addRect(CGRect(x: keys.maxX - 7, y: bottom - 0.5, width: 7, height: 1))
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
                black.addRoundedRect(in: CGRect(x: keys.minX, y: y(Double(midi) + 0.5) + 0.5,
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
            .tracking(0.4)
            .monospacedDigit()
            .foregroundStyle(valid ? Theme.onStatus : Theme.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { Capsule().fill(valid ? color : Theme.chipFill) }
            .fixedSize()
    }

    private static func describe(_ delta: Float, valid: Bool) -> (String, Color) {
        guard valid else { return ("—", Theme.tertiary) }
        if abs(delta) <= 1 { return ("ON TARGET", Theme.sage) }
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

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    var color: Color = Theme.ink
    var template = "−88.8"
    /// Grows the reading with a taller summary; the tile itself stretches to the height it is offered.
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            Eyebrow(title, color: Theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                StableNumber(text: value, template: template, font: .system(size: 17 * scale, weight: .medium), color: color)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 9 * (1 + (scale - 1) * 0.5), weight: .medium)).foregroundStyle(Theme.tertiary)
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
        }
    }
}

/// Last 15 s of short-term (sage) over momentary (faint), with the ±1 LU target band and 5 s time marks.
struct LoudnessHistory: View {
    let short: [Float]
    let momentary: [Float]
    let target: Float

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
            Eyebrow("LAST 15 S", color: Theme.tertiary).padding(.top, 7).padding(.leading, 9)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(verbatim: "now").font(.axis).foregroundStyle(Theme.tertiary).padding(.bottom, 5).padding(.trailing, 8)
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

/// The Soundstage card: a full-height column with its own header and well.
struct SoundstagePanel: View {
    let model: MeterModel
    let readouts: Readouts
    let activeRoles: [Bool]
    let format: ChannelFormat
    let layout: SpeakerLayout

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                StageHeader(format: format, layout: layout)
                GeometryReader { proxy in
                    // The well does not depend on the mode; the labels animate the format mix themselves.
                    let mix = FormatMix(format)
                    ZStack(alignment: .topLeading) {
                        MeterCanvas(kind: .soundstage, model: model)
                        SoundstageStaticLabels(size: proxy.size, mix: mix, layout: layout, activeRoles: activeRoles)
                        SoundstageReadouts(readouts: readouts, size: proxy.size, mix: mix, layout: layout,
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

private struct WaveHeader: View {
    let layout: SpeakerLayout
    let format: ChannelFormat

    var body: some View {
        let spatial = format == .spatial
        PanelHeader(title: "WAVEFORM", detail: "\(spatial ? layout.name : (format == .mono ? "M" : "L/R")) · \(Int(Double(WaveformScene.visibleColumns) / WaveformEnvelope.columnRate)) s · linear · min/max") {
            LegendDot(color: Theme.sage, text: spatial ? "Left side" : (format == .mono ? "Mono" : "Left"))
            if format != .mono { LegendDot(color: Theme.sand, text: spatial ? "Right side" : "Right") }
            Group {
                if layout.heightCount > 0 { LegendDot(color: Theme.heather, text: "Height") }
                if layout.hasLFE { LegendDot(color: Theme.clay, text: "LFE") }
            }
            .opacity(spatial ? 1 : 0)
            LegendDot(color: Theme.ember, text: "Clip")
        }
    }
}

private struct StageHeader: View {
    let format: ChannelFormat
    let layout: SpeakerLayout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Eyebrow("SOUNDSTAGE")
            Text(verbatim: format == .spatial ? layout.name : format.title)
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.sage)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Theme.sage.opacity(0.13)))
            Spacer(minLength: 4)
            Text(verbatim: "Peak · RMS · dBFS").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
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
                    .font(.system(size: lane.height < 18 ? 8 : 10, weight: .semibold).width(.expanded))
                    .foregroundStyle(active ? Theme.laneRGB(speaker).color : Theme.tertiary)
                    .fixedSize()
                    .scaleEffect(0.8 + 0.2 * weight)
                    .opacity(dissolve(weight) * (lane.height >= 7 ? 1 : 0))
                    .position(x: scope.minX - WaveformLayout.gutter / 2 + 1, y: lane.midY)
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

/// Speaker names in the room, group headers, channel names, the dB axis and the correlation scale.
/// `Animatable` on `presence`, so SwiftUI re-lays it out every frame of the mode spring, as Metal does.
private struct SoundstageStaticLabels: View, Animatable {
    let size: CGSize
    var mix: FormatMix
    let layout: SpeakerLayout
    let activeRoles: [Bool]

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { mix.animatableData }
        set { mix.animatableData = newValue }
    }

    var body: some View {
        let stage = SoundstageLayout(size: size, presence: mix.presence, mono: mix.mono, layout: layout)
        let pair = dissolve(1 - mix.mono)
        let speakers = stage.speakers
        ZStack(alignment: .topLeading) {
            ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                let weight = stage.weight(index)
                Text(speaker.displayName(mono: mix.mono))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(activeRoles[speaker.role] ? Theme.groupColor(speaker.group).opacity(0.95) : Theme.tertiary)
                    .fixedSize()
                    .blur(radius: (1 - weight) * 3)
                    .opacity(dissolve(weight))
                    .position(stage.label(speaker))
            }
            ForEach(stage.headers, id: \.group) { header in
                let weight = stage.headerWeight(header.group)
                HStack(spacing: 6) {
                    Capsule().fill(Theme.groupColor(header.group)).frame(width: 8, height: 3)
                    Text(verbatim: SoundstageLayout.groupTitles[header.group] ?? "")
                        .font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(1)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: header.rect.width, height: 12)
                .opacity(dissolve(weight))
                .position(x: header.rect.midX, y: header.rect.maxY - 11)
            }
            ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                let weight = stage.weight(index)
                Text(speaker.displayName(mono: mix.mono))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(activeRoles[speaker.role] ? Theme.groupColor(speaker.group) : Theme.tertiary)
                    .fixedSize()
                    .scaleEffect(0.8 + 0.2 * weight)
                    .opacity(dissolve(weight))
                    .position(x: stage.nameX, y: stage.rows[index].midY)
            }
            ForEach(visibleTicks(stage), id: \.self) { db in
                Text(db == 0 ? "0" : "−\(Int(-db))")
                    .font(.axis)
                    .foregroundStyle(db == 0 ? Theme.ember.opacity(0.85) : Theme.tertiary)
                    .fixedSize()
                    .position(x: stage.x(decibels: db), y: stage.axisY)
            }
            Text(verbatim: "CORRELATION")
                .font(.eyebrow).tracking(Tracking.eyebrow)
                .foregroundStyle(Theme.tertiary)
                .frame(width: stage.correlationArea.width, alignment: .leading)
                .opacity(pair)
                .position(x: stage.correlationArea.midX, y: stage.correlationArea.minY + 8)
            ForEach(0..<5, id: \.self) { index in
                Text(verbatim: index == 2 ? "+1" : (index.isMultiple(of: 2) ? "−1" : "0"))
                    .font(.axis)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
                    .opacity(pair)
                    .position(x: stage.correlationTrack.minX + stage.correlationTrack.width * CGFloat(index) / 4,
                              y: stage.correlationTrack.maxY + 9)
            }
        }
        .allowsHitTesting(false)
    }

    /// Axis labels at least 20 pt apart, keeping 0 dBFS and the loud end of the scale.
    private func visibleTicks(_ layout: SoundstageLayout) -> [Float] {
        var result: [Float] = []
        var lastX = CGFloat.infinity
        for db in SoundstageLayout.scaleTicks.reversed() {
            let x = layout.x(decibels: db)
            if lastX - x >= 20 {
                result.append(db)
                lastX = x
            }
        }
        return result
    }
}

/// Held sample peak at the end of each row and the correlation reading, published at 10 Hz and animated
/// with the rows.
private struct SoundstageReadouts: View, Animatable {
    @ObservedObject var readouts: Readouts
    let size: CGSize
    var mix: FormatMix
    let layout: SpeakerLayout
    let activeRoles: [Bool]

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { mix.animatableData }
        set { mix.animatableData = newValue }
    }

    var body: some View {
        let stage = SoundstageLayout(size: size, presence: mix.presence, mono: mix.mono, layout: layout)
        let correlation = readouts.values.correlation
        ZStack(alignment: .topLeading) {
            ForEach(Array(stage.speakers.enumerated()), id: \.offset) { index, speaker in
                let active = activeRoles[speaker.role]
                let peak = MeterScale.decibels(readouts.values.heldPeaks[speaker.role])
                let weight = stage.weight(index)
                StableNumber(text: active ? MeterScale.tenths(peak, floor: -119) : "OFF", template: "−88.8",
                             font: .system(size: 10, weight: .medium),
                             color: !active ? Theme.tertiary : (peak >= 0 ? Theme.ember : Theme.ink))
                    .frame(width: SoundstageLayout.readoutColumn, alignment: .trailing)
                    .scaleEffect(0.8 + 0.2 * weight, anchor: .trailing)
                    .opacity(dissolve(weight))
                    .position(x: stage.readoutMaxX - SoundstageLayout.readoutColumn / 2, y: stage.rows[index].midY)
            }
            let silent = correlation == MeterSnapshot.noCorrelation
            StableNumber(text: silent ? "--" : Self.signed(correlation), template: "+0.00",
                         font: .system(size: 11, weight: .semibold),
                         color: silent ? Theme.tertiary : (correlation < -0.1 ? Theme.ember : (correlation < 0.3 ? Theme.ochre : Theme.ink)))
                .frame(width: SoundstageLayout.readoutColumn, alignment: .trailing)
                .opacity(dissolve(1 - mix.mono))
                .position(x: stage.readoutMaxX - SoundstageLayout.readoutColumn / 2, y: stage.correlationTrack.midY)
        }
        .allowsHitTesting(false)
    }

    private static func signed(_ value: Float) -> String {
        let text = String(format: "%.2f", abs(value))
        return value < -0.005 ? "−" + text : "+" + text
    }
}
