import AnalysisCore
import CoreGraphics
import Foundation

// Geometry of the analyzer wells (spectrum card, spectrogram, waveform) shared by the Metal scenes and the SwiftUI overlays.
/// Margins shared by the analyzer wells.
enum FrequencyAxis {
    /// Tick labels under a plot.
    static let labelHeight: CGFloat = 20
}

/// The live spectrum in a card of its own, as the horizontal strip shows it beside the waterfall: frequency runs left to
/// right on the log axis and level rises from the −96 dB floor, with the level labels at the left and the frequency
/// labels under the plot. The curve is worked out on the spectrum's usual axes (`canonical`, level across and
/// frequency up) and turned a quarter onto `plot`, so it is the same curve as beside the waterfall.
struct SpectrumCardLayout {
    static let levelLabels: CGFloat = 30
    /// The least room between two frequency labels across.
    static let labelSpacing: CGFloat = 34

    let plot: CGRect
    let canonical: SpectrogramLayout

    init(size: CGSize, scale: FrequencyScale = .log) {
        let top: CGFloat = 8, margin: CGFloat = 12
        plot = CGRect(x: Self.levelLabels, y: top, width: max(1, size.width - Self.levelLabels - margin),
                      height: max(1, size.height - top - FrequencyAxis.labelHeight))
        canonical = SpectrogramLayout(spectrumOnly: CGRect(x: 0, y: 0, width: plot.height, height: plot.width), scale: scale)
    }

    /// A point on the canonical axes, turned onto the plot.
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: plot.minX + (plot.width - p.y), y: plot.maxY - p.x) }
    func rect(_ r: CGRect) -> CGRect {
        let a = point(CGPoint(x: r.minX, y: r.minY)), b = point(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func x(frequency: Double, sampleRate: Double) -> CGFloat {
        point(CGPoint(x: 0, y: canonical.y(frequency: frequency, sampleRate: sampleRate))).x
    }
    func y(decibels db: Float) -> CGFloat { point(CGPoint(x: canonical.x(decibels: db), y: 0)).y }
    func frequency(x: CGFloat, sampleRate: Double) -> Double {
        canonical.frequency(y: plot.width - (x - plot.minX), sampleRate: sampleRate)
    }
    /// The fine band (of `rows`) under `x`, as `SpectrogramLayout.row(y:rows:sampleRate:)`.
    func row(x: CGFloat, rows: Int, sampleRate: Double) -> Double {
        canonical.row(y: plot.width - (x - plot.minX), rows: rows, sampleRate: sampleRate)
    }

    func frequencyTicks(sampleRate: Double) -> [(Double, String)] {
        SpectrogramLayout.frequencyTicks(canonical, sampleRate: sampleRate, spacing: Self.labelSpacing)
    }
}

/// The Spectrum card's display well, which holds the spectrogram and the live spectrum on one frequency axis:
/// frequency runs bottom to top on the log axis. A vertical piano keyboard on the left shares that axis, so
/// each key sits exactly on its pitch band, with octave labels (C1, C2…) left of the keys. The waterfall
/// (`plot`) runs left to right in time, newest at its right edge, and the live spectrum (`spectrum`) continues
/// from "now" to the right: level in dBFS grows rightward from the −96 dB floor, so a band's colour in the
/// waterfall and its length in the spectrum read along the same row.
struct SpectrogramLayout {
    /// DSP publishes one analysis column per tick (see DSPWorker).
    static let analysisRate = 30.0
    /// The waterfall shows the most recent 3 to 8 s of the stored history, whole seconds at about 100 pt per
    /// second, so narrowing it (by widening the spectrum or the window) shortens the span instead of squeezing it.
    static let maxSeconds = 8.0
    static let minSeconds = 3.0
    static let pointsPerSecond: CGFloat = 100
    static let noteLabels: CGFloat = 26
    static let keyboardWidth: CGFloat = 18
    static let keyGap: CGFloat = 3
    /// Gap between the waterfall's "now" edge and the spectrum; it holds the divider that resizes them.
    static let spectrumGap: CGFloat = 14
    /// The spectrum's width: `0` is automatic (about a quarter of the well), a dragged width is kept within these
    /// limits and always leaves the waterfall `minWaterfall`.
    static let minStrip: CGFloat = 96
    static let minWaterfall: CGFloat = 160
    /// Level grid of the spectrum, in dBFS.
    static let grid: [Float] = [0, -24, -48, -72]
    /// The `strip` width for the waterfall alone: the horizontal strip shows the live spectrum in a card of its own
    /// (`SpectrumCardLayout`), so the waterfall takes the whole well.
    static let split: CGFloat = -1

    let keyboard: CGRect
    /// The waterfall.
    let plot: CGRect
    /// The live spectrum.
    let spectrum: CGRect
    /// Seconds the waterfall spans, and the analysis columns that takes.
    let seconds: Double
    /// The spectrum sits left of the waterfall, and the pair mirrors: "now" is the waterfall's left edge, and the
    /// spectrum's 0 dBFS is its left edge, so the newest column still meets the spectrum's floor.
    let mirrored: Bool
    /// How frequency is spaced up the well (`FrequencyScale`).
    let scale: FrequencyScale
    var visibleColumns: Int { Int(seconds * Self.analysisRate) }

    /// `strip` is the requested spectrum width in points, `0` for automatic; `spectrumLeft` mirrors the pair;
    /// `span` fixes the seconds shown (`SpectrogramSpan`), `0` fits them to the width.
    init(size: CGSize, strip requested: CGFloat = 0, spectrumLeft: Bool = false, span: Double = 0, scale: FrequencyScale = .log) {
        mirrored = spectrumLeft
        self.scale = scale
        let top: CGFloat = 8, margin: CGFloat = 12
        let height = max(1, size.height - top - FrequencyAxis.labelHeight)
        // Mirrored, the keyboard and its octave labels move to the right edge, beside the waterfall's oldest
        // column, and the pair starts at the left margin.
        let keysX = spectrumLeft ? size.width - Self.noteLabels - Self.keyboardWidth : Self.noteLabels
        keyboard = CGRect(x: keysX, y: top, width: Self.keyboardWidth, height: height)
        let left = spectrumLeft ? margin : keyboard.maxX + Self.keyGap
        let right = spectrumLeft ? size.width - keyboard.minX + Self.keyGap : margin
        let available = max(1, size.width - left - right)
        if requested == Self.split {
            plot = CGRect(x: left, y: top, width: available, height: height)
            spectrum = CGRect(x: spectrumLeft ? plot.minX : plot.maxX, y: top, width: 0, height: height)
            seconds = span > 0 ? span : max(Self.minSeconds, min(Self.maxSeconds, Double((available / Self.pointsPerSecond).rounded())))
            return
        }
        let automatic = min(240, max(Self.minStrip, (available * 0.24).rounded()))
        let upper = max(Self.minStrip, available - Self.spectrumGap - Self.minWaterfall)
        let valid = requested.isFinite && requested > 0 ? requested.rounded() : automatic
        let strip = max(1, min(available - Self.spectrumGap - 1, PanelLayout.clamp(valid, Self.minStrip, upper)))
        let waterfall = max(1, available - strip - Self.spectrumGap)
        let spectrumWidth = max(1, available - waterfall - Self.spectrumGap)
        if spectrumLeft {
            spectrum = CGRect(x: left, y: top, width: spectrumWidth, height: height)
            plot = CGRect(x: spectrum.maxX + Self.spectrumGap, y: top, width: waterfall, height: height)
        } else {
            plot = CGRect(x: left, y: top, width: waterfall, height: height)
            spectrum = CGRect(x: plot.maxX + Self.spectrumGap, y: top, width: spectrumWidth, height: height)
        }
        seconds = span > 0 ? span : max(Self.minSeconds, min(Self.maxSeconds, Double((waterfall / Self.pointsPerSecond).rounded())))
    }

    /// The live spectrum alone in `rect`, on its usual axes (level across from the floor at the left, frequency up),
    /// for `SpectrumCardLayout`, which turns it a quarter so frequency runs across.
    init(spectrumOnly rect: CGRect, scale: FrequencyScale = .log) {
        mirrored = false
        self.scale = scale
        keyboard = .zero
        plot = rect
        spectrum = rect
        seconds = Self.minSeconds
    }

    /// Whether the live spectrum shares the well (it does not in the horizontal strip).
    var showsSpectrum: Bool { spectrum.width > 0 }

    /// Centre of the octave labels' column, beside the keyboard on its outer side.
    var noteLabelX: CGFloat { mirrored ? keyboard.maxX + 2 + (Self.noteLabels - 4) / 2 : (Self.noteLabels - 4) / 2 }
    /// Where the white keys' octave ticks and the black keys sit: the keyboard's edge nearer the plot has the
    /// ticks, the outer edge holds the black keys.
    var keysInnerX: CGFloat { mirrored ? keyboard.minX : keyboard.maxX }
    func blackKeyX(width: CGFloat) -> CGFloat { mirrored ? keyboard.maxX - width : keyboard.minX }

    /// The waterfall's "now" edge, and the spectrum's floor and 0 dBFS edges.
    var nowX: CGFloat { mirrored ? plot.minX : plot.maxX }
    var floorX: CGFloat { mirrored ? spectrum.maxX : spectrum.minX }
    var fullScaleX: CGFloat { mirrored ? spectrum.minX : spectrum.maxX }
    /// The divider's position (the gap between the two) and the width before it.
    var dividerX: CGFloat { mirrored ? spectrum.maxX : plot.maxX }
    var dividerLeading: CGFloat { mirrored ? spectrum.width : plot.width }

    func y(frequency: Double, sampleRate: Double) -> CGFloat {
        plot.maxY - MeterScale.frequencyFraction(frequency, sampleRate: sampleRate, scale: scale) * plot.height
    }
    /// Centre of a MIDI note, and its semitone band edges at ±50 cents.
    func y(midi: Double, sampleRate: Double) -> CGFloat { y(frequency: 440 * pow(2, (midi - 69) / 12), sampleRate: sampleRate) }
    func x(secondsAgo seconds: Double) -> CGFloat {
        let offset = CGFloat(seconds / self.seconds) * plot.width
        return mirrored ? plot.minX + offset : plot.maxX - offset
    }
    /// Where a spectrum level lands: from the floor at the edge beside "now" to 0 dBFS at the far edge.
    func x(decibels db: Float) -> CGFloat {
        let offset = MeterScale.spectrumFraction(db) * spectrum.width
        return mirrored ? spectrum.maxX - offset : spectrum.minX + offset
    }

    /// Inverse of `y(frequency:)`: the frequency at `y` on the shared axis.
    func frequency(y: CGFloat, sampleRate: Double) -> Double {
        MeterScale.frequency(fraction: Double((plot.maxY - y) / max(1, plot.height)), sampleRate: sampleRate, scale: scale)
    }
    /// The fractional waterfall row (and spectrum band, with `rows` the fine bands) at `y`, row 0 centred on the bottom
    /// one. The analysis' rows always run up the 20 Hz log axis, whatever the well's scale.
    func row(y: CGFloat, rows: Int, sampleRate: Double) -> Double {
        let frequency = self.frequency(y: y, sampleRate: sampleRate)
        return Double(MeterScale.frequencyFraction(frequency, sampleRate: sampleRate)) * Double(rows) - 0.5
    }
    /// Across the waterfall at `x`: 0 at its oldest edge, 1 at "now", whichever side "now" is on.
    func timeFraction(x: CGFloat) -> Double {
        let fraction = Double((x - plot.minX) / max(1, plot.width))
        return mirrored ? 1 - fraction : fraction
    }

    /// Frequency marks along the spectrum: 20, 50, 100, 200, 500 Hz… up to the ceiling, each at least 13 pt
    /// from the last one kept and from the plot's edges.
    static let frequencyMarks: [(Double, String)] = [(20, "20"), (30, "30"), (50, "50"), (100, "100"), (200, "200"),
        (300, "300"), (500, "500"), (1_000, "1k"), (2_000, "2k"), (3_000, "3k"), (5_000, "5k"), (10_000, "10k"), (20_000, "20k")]

    static func frequencyTicks(_ layout: SpectrogramLayout, sampleRate: Double, spacing: CGFloat = 13) -> [(Double, String)] {
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        // The top of the axis is always named (20k at 44.1 kHz and above), so the full range reads at a glance;
        // its label sits just under the edge (`isTopEdge`).
        let top = (upper, upper >= 1_000 ? "\(Int((upper / 1_000).rounded()))k" : "\(Int(upper))")
        var kept: [(Double, String)] = [top]
        // Decades first so 100, 1k and 10k survive wherever there is room, then the rest where they fit.
        let marks = layout.scale.marks
        let order = marks.filter { layout.scale.isMajor($0.0) } + marks.filter { !layout.scale.isMajor($0.0) }
        for mark in order where mark.0 < upper {
            let y = layout.y(frequency: mark.0, sampleRate: sampleRate)
            guard y - spacing + 1 > layout.spectrum.minY, y < layout.spectrum.maxY + 1 else { continue }
            // The top label hangs below its line, toward the marks under it, so it needs twice the room.
            if kept.allSatisfy({ abs(layout.y(frequency: $0.0, sampleRate: sampleRate) - y) >= ($0.0 >= upper ? 2 * spacing : spacing) }) {
                kept.append(mark)
            }
        }
        return kept.sorted { $0.0 < $1.0 }
    }

    /// Whether a tick from `frequencyTicks` is the top of the axis, labelled under its line instead of above it.
    static func isTopEdge(_ frequency: Double, sampleRate: Double) -> Bool {
        frequency >= MeterScale.upperFrequency(sampleRate: sampleRate)
    }

    /// Spectrum width for a drag that makes the waterfall `waterfall` points wide (before clamping).
    func strip(forWaterfall waterfall: CGFloat) -> CGFloat {
        spectrum.maxX - (plot.minX + waterfall + Self.spectrumGap)
    }

    /// The spectrum width for a divider drag to `leading` points: the waterfall's width on the right, the
    /// spectrum's own when it leads.
    func strip(forDivider leading: CGFloat) -> CGFloat { mirrored ? leading : strip(forWaterfall: leading) }

    /// Height of one semitone at `midi`. On the log axis this is the same everywhere and `y(midi:)` is affine in
    /// MIDI; on the linear axis it grows with the pitch.
    func semitoneHeight(sampleRate: Double, midi: Double = 69) -> CGFloat {
        switch scale {
        case .log: return plot.height * CGFloat(log(2.0) / 12 / log(MeterScale.upperFrequency(sampleRate: sampleRate) / 20))
        case .linear: return abs(y(midi: midi - 0.5, sampleRate: sampleRate) - y(midi: midi + 0.5, sampleRate: sampleRate))
        }
    }

    /// Bit n set for each black pitch class n (C#, D#, F#, G#, A#).
    private static let blackMask = 0b0101_0100_1010
    static func isBlack(_ midi: Int) -> Bool { blackMask & (1 << (((midi % 12) + 12) % 12)) != 0 }
}

/// The Waveform panel's display well: one lane per channel, stacked top to bottom in the layout's display
/// order, channel names in the left gutter, the level scale (`WaveScale`) in the right one and the time ruler
/// under the lanes. `size` is the well itself.
///
/// L always weighs 1, R weighs `1 − mono`, and every other lane weighs `presence` (1 Spatial, 0 Stereo). The
/// scope keeps its height, so as extended lanes grow in, L and R shrink to make room, and in Mono the single
/// lane takes it all: the panel never changes size.
struct WaveformLayout {
    static let gutter: CGFloat = 32
    static let scaleColumn: CGFloat = 30
    static let inset: CGFloat = 8
    /// The time ruler under the lanes: −1 s … now.
    static let ruler: CGFloat = 16
    /// Gap between neighbouring lanes, scaled by the lower lane's weight.
    static let laneGap: CGFloat = 4
    /// Lanes shorter than this drop their −6 dBFS labels and graticule text.
    static let labelledLane: CGFloat = 34

    let well: CGRect
    let waveform: CGRect
    let speakers: [Speaker]
    let presence: CGFloat
    let mono: CGFloat
    /// One rect per speaker; receding lanes collapse to zero height.
    let lanes: [CGRect]

    init(size: CGSize, speakers: [Speaker] = SpeakerLayout.stereoSpeakers, presence: CGFloat = 0, mono: CGFloat = 0) {
        let p = max(0, min(1, presence))
        let m = max(0, min(1, mono))
        self.presence = p
        self.mono = m
        self.speakers = speakers
        well = CGRect(origin: .zero, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        waveform = CGRect(x: Self.gutter, y: Self.inset,
                          width: max(1, well.width - Self.gutter - Self.scaleColumn),
                          height: max(1, well.height - Self.inset - Self.ruler))
        let weights = speakers.map { $0.weight(presence: p, mono: m) }
        // Gaps never take more than a quarter of a short well, so 16 lanes still fit.
        let requested = weights.dropFirst().reduce(0) { $0 + $1 * Self.laneGap }
        let gap = Self.laneGap * min(1, waveform.height * 0.25 / max(0.0001, requested))
        let gaps = requested * gap / Self.laneGap
        let unit = max(0, waveform.height - gaps) / max(0.0001, weights.reduce(0, +))
        var y = waveform.minY
        var result: [CGRect] = []
        for (index, weight) in weights.enumerated() {
            if index > 0 { y += gap * weight }
            let height = unit * weight
            result.append(CGRect(x: waveform.minX, y: y, width: waveform.width, height: height))
            y += height
        }
        lanes = result
    }

    func weight(_ index: Int) -> CGFloat { speakers[index].weight(presence: presence, mono: mono) }

    /// Where a lane deflection (−1…1, `WaveScale.deflection`) lands inside a lane.
    func laneY(_ index: Int, amplitude: CGFloat) -> CGFloat { lanes[index].midY - amplitude * lanes[index].height / 2 }

    /// Where the history `secondsAgo` before now sits across the lanes (`seconds` across the whole width).
    func x(secondsAgo: Double, seconds: Double) -> CGFloat {
        waveform.maxX - CGFloat(secondsAgo / max(0.001, seconds)) * waveform.width
    }

    /// Seconds before now at `x`.
    func secondsAgo(x: CGFloat, seconds: Double) -> Double {
        Double((waveform.maxX - x) / max(1, waveform.width)) * seconds
    }

    /// The lane under `y`, if any (receding lanes never match).
    func lane(at y: CGFloat) -> Int? {
        lanes.indices.first { lanes[$0].height >= 6 && y >= lanes[$0].minY - 2 && y <= lanes[$0].maxY + 2 }
    }
}
