import CoreGraphics
import Foundation

// Pure scale and layout math shared by the Metal scenes and the SwiftUI label overlays,
// so both sides place ticks, bars and speaker nodes from one source of truth.
enum MeterScale {
    static let spectrumFloor: Float = -96
    static let loudnessFloor: Float = -36

    static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0.000001 ? 20 * log10(amplitude) : -120
    }

    /// IEC 60268-18 style deflection: expands the top 20 dB where engineers read peaks.
    static func position(decibels db: Float) -> Float {
        switch db {
        case ..<(-70): return 0
        case ..<(-60): return (db + 70) * 0.0025
        case ..<(-50): return (db + 60) * 0.005 + 0.025
        case ..<(-40): return (db + 50) * 0.0075 + 0.075
        case ..<(-30): return (db + 40) * 0.015 + 0.15
        case ..<(-20): return (db + 30) * 0.02 + 0.3
        case ..<0: return (db + 20) * 0.025 + 0.5
        default: return 1
        }
    }

    static func position(amplitude: Float) -> Float { position(decibels: decibels(amplitude)) }

    static func upperFrequency(sampleRate: Double) -> Double { min(20_000, sampleRate / 2) }

    /// Horizontal fraction of a frequency on the shared 20 Hz – upper log axis used by both analyzers.
    static func frequencyFraction(_ frequency: Double, sampleRate: Double) -> CGFloat {
        let upper = upperFrequency(sampleRate: sampleRate)
        return CGFloat(log(max(frequency, 20) / 20) / log(upper / 20))
    }

    static func spectrumFraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - spectrumFloor) / -spectrumFloor)))
    }

    static func loudnessFraction(_ lufs: Float) -> CGFloat {
        CGFloat(max(0, min(1, (lufs - loudnessFloor) / -loudnessFloor)))
    }

    /// Fixed one-decimal text with a true minus sign; silence reads as −∞.
    /// Whole number with a typographic minus, e.g. "−18".
    static func signedInteger(_ value: Float) -> String {
        let rounded = Int(value.rounded())
        return rounded < 0 ? "−\(-rounded)" : "\(rounded)"
    }

    static func tenths(_ value: Float, floor: Float = -99) -> String {
        guard value.isFinite, value > floor else { return "−∞" }
        let scaled = Int((value * 10).rounded())
        let magnitude = abs(scaled)
        return "\(scaled < 0 ? "−" : "")\(magnitude / 10).\(magnitude % 10)"
    }
}

/// Equal-tempered pitch (A4 = 440 Hz) of a frequency: MIDI = 69 + 12·log2(f / 440).
struct Pitch: Equatable {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let midi: Int
    let cents: Int

    init?(frequency: Double) {
        guard frequency.isFinite, frequency >= 8 else { return nil }
        let exact = 69 + 12 * log2(frequency / 440)
        var nearest = Int(exact.rounded())
        var cents = Int(((exact - Double(nearest)) * 100).rounded())
        // −50.4 rounds to −50 but +49.6 to +50; keep the range to −50…+49 on the nearer note.
        if cents == 50 { nearest += 1; cents = -50 }
        midi = nearest
        self.cents = cents
    }

    var name: String { Self.names[((midi % 12) + 12) % 12] }
    /// Scientific pitch notation: MIDI 60 is C4.
    var octave: Int { Int((Double(midi) / 12).rounded(.down)) - 1 }
    var label: String { "\(name)\(octave)" }
    var centsLabel: String { cents == 0 ? "±0¢" : (cents > 0 ? "+\(cents)¢" : "−\(-cents)¢") }
}

/// Readability filter for the peak readout: fast attack, short hold, gentle decay, noise gate.
struct PeakTracker: Equatable {
    static let gate: Float = -60
    static let holdTime = 0.4
    static let decayPerSecond: Float = 24

    private(set) var frequency: Float = 0
    private(set) var level: Float = -120
    private(set) var visible = false
    private var hold = 0.0

    mutating func update(frequency newFrequency: Float, level newLevel: Float, deltaTime: Double) {
        let gated = newLevel < Self.gate || newFrequency <= 0
        let decayed = level - Self.decayPerSecond * Float(deltaTime)
        guard visible else {
            if !gated { accept(newFrequency, newLevel) }
            return
        }
        let sameNote = !gated && abs(12 * log2(newFrequency / frequency)) < 0.5
        if sameNote {
            // Same note: average the frequency so cents settle, attack instantly on level.
            frequency += (newFrequency - frequency) * 0.5
            level = max(newLevel, decayed)
            hold = Self.holdTime
        } else if !gated && newLevel >= level - 3 {
            accept(newFrequency, newLevel)
        } else {
            hold -= deltaTime
            level = max(newLevel, decayed)
            if hold <= 0 {
                if gated { visible = false } else { accept(newFrequency, newLevel) }
            }
        }
    }

    mutating func reset() { self = PeakTracker() }

    private mutating func accept(_ newFrequency: Float, _ newLevel: Float) {
        frequency = newFrequency
        level = newLevel
        visible = true
        hold = Self.holdTime
    }
}

/// Plot geometry shared by the Spectrum and Spectrogram panels: the same gutter and margins, so when the two
/// panels are stacked at the same width their logarithmic 20 Hz – upper frequency axes line up exactly.
enum FrequencyAxis {
    static let gutter: CGFloat = 34
    static let top: CGFloat = 10
    static let right: CGFloat = 12
    /// Frequency tick labels under the plot.
    static let labelHeight: CGFloat = 20

    static func plot(in size: CGSize) -> CGRect {
        CGRect(x: gutter, y: top, width: max(1, size.width - gutter - right),
               height: max(1, size.height - top - labelHeight))
    }

    static func x(_ frequency: Double, in plot: CGRect, sampleRate: Double) -> CGFloat {
        plot.minX + MeterScale.frequencyFraction(frequency, sampleRate: sampleRate) * plot.width
    }
}

/// The Spectrum panel's display well: live spectrum of the monitored channels in dBFS over the frequency axis.
struct SpectrumLayout {
    static let grid: [Float] = [0, -24, -48, -72]

    let plot: CGRect

    init(size: CGSize) { plot = FrequencyAxis.plot(in: size) }

    func x(frequency: Double, sampleRate: Double) -> CGFloat { FrequencyAxis.x(frequency, in: plot, sampleRate: sampleRate) }
    func y(decibels db: Float) -> CGFloat { plot.maxY - MeterScale.spectrumFraction(db) * plot.height }
}

/// The Spectrogram panel's display well, horizontal: time runs left to right (newest at the right edge) and
/// frequency bottom to top on the log axis. A vertical piano keyboard on the left shares that axis, so each
/// key sits exactly on its pitch band; octave labels (C1, C2…) sit left of the keys.
struct SpectrogramLayout {
    /// DSP publishes one analysis column per tick (see DSPWorker).
    static let analysisRate = 30.0
    /// The panel shows the most recent 8 s of the stored history.
    static let historySeconds = 8.0
    static let visibleColumns = Int(historySeconds * analysisRate)
    static let noteLabels: CGFloat = 26
    static let keyboardWidth: CGFloat = 18
    static let keyGap: CGFloat = 3

    let keyboard: CGRect
    let plot: CGRect

    init(size: CGSize) {
        let top: CGFloat = 8, right: CGFloat = 12
        let height = max(1, size.height - top - FrequencyAxis.labelHeight)
        keyboard = CGRect(x: Self.noteLabels, y: top, width: Self.keyboardWidth, height: height)
        let left = keyboard.maxX + Self.keyGap
        plot = CGRect(x: left, y: top, width: max(1, size.width - left - right), height: height)
    }

    func y(frequency: Double, sampleRate: Double) -> CGFloat {
        plot.maxY - MeterScale.frequencyFraction(frequency, sampleRate: sampleRate) * plot.height
    }
    /// Centre of a MIDI note, and its semitone band edges at ±50 cents.
    func y(midi: Double, sampleRate: Double) -> CGFloat { y(frequency: 440 * pow(2, (midi - 69) / 12), sampleRate: sampleRate) }
    func x(secondsAgo seconds: Double) -> CGFloat { plot.maxX - CGFloat(seconds / Self.historySeconds) * plot.width }

    /// Height of one semitone. The axis is logarithmic, so this is constant and `y(midi:)` is affine in MIDI.
    func semitoneHeight(sampleRate: Double) -> CGFloat {
        plot.height * CGFloat(log(2.0) / 12 / log(MeterScale.upperFrequency(sampleRate: sampleRate) / 20))
    }

    /// Bit n set for each black pitch class n (C#, D#, F#, G#, A#).
    private static let blackMask = 0b0101_0100_1010
    static func isBlack(_ midi: Int) -> Bool { blackMask & (1 << (((midi % 12) + 12) % 12)) != 0 }
}

/// The Waveform panel's display well: one lane per channel, stacked top to bottom in the layout's display
/// order, channel names in the left gutter and −6 dBFS marks in the right one. `size` is the well itself.
///
/// L always weighs 1, R weighs `1 − mono`, and every other lane weighs `presence` (1 Spatial, 0 Stereo). The
/// scope keeps its height, so as extended lanes grow in, L and R shrink to make room, and in Mono the single
/// lane takes it all: the panel never changes size.
struct WaveformLayout {
    static let gutter: CGFloat = 32
    static let scaleColumn: CGFloat = 30
    static let inset: CGFloat = 8
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
                          height: max(1, well.height - Self.inset * 2))
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

    /// Where a linear amplitude (−1…1) lands inside a lane.
    func laneY(_ index: Int, amplitude: CGFloat) -> CGFloat { lanes[index].midY - amplitude * lanes[index].height / 2 }
}

/// The left column below the loudness summary: Spectrum, then Spectrogram, then Waveform, separated by two
/// draggable dividers. Heights are stored as fractions of the panel area so they scale with the window.
/// Dragging a divider only trades size between the two panels it separates, and every panel keeps a
/// minimum at which its contents stay legible.
struct PanelLayout {
    /// A divider's hit strip, which is also the gap between the two panels.
    static let divider: CGFloat = 14
    static let minSpectrum: CGFloat = 110
    static let minSpectrogram: CGFloat = 90
    static let minWaveform: CGFloat = 120
    static let defaultSpectrum: CGFloat = 0.34
    static let defaultSpectrogram: CGFloat = 0.30

    let spectrum: CGFloat
    let spectrogram: CGFloat
    let waveform: CGFloat

    /// `height` is the whole column, dividers included.
    init(height: CGFloat, spectrum spectrumFraction: CGFloat, spectrogram spectrogramFraction: CGFloat) {
        let panels = max(0, height - 2 * Self.divider)
        func valid(_ value: CGFloat, _ fallback: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : fallback }
        spectrum = Self.clamp((valid(spectrumFraction, Self.defaultSpectrum) * panels).rounded(),
                              Self.minSpectrum, panels - Self.minSpectrogram - Self.minWaveform)
        spectrogram = Self.clamp((valid(spectrogramFraction, Self.defaultSpectrogram) * panels).rounded(),
                                 Self.minSpectrogram, panels - spectrum - Self.minWaveform)
        waveform = max(0, panels - spectrum - spectrogram)
    }

    var panels: CGFloat { spectrum + spectrogram + waveform }

    /// Fractions after dragging the first divider so the Spectrum is `height` tall; the Waveform stays put.
    func draggingSpectrum(to height: CGFloat) -> (spectrum: CGFloat, spectrogram: CGFloat) {
        let pair = spectrum + spectrogram
        let newSpectrum = Self.clamp(height.rounded(), Self.minSpectrum, pair - Self.minSpectrogram)
        return (newSpectrum / max(1, panels), (pair - newSpectrum) / max(1, panels))
    }

    /// Spectrogram fraction after dragging the second divider so it is `height` tall; the Spectrum stays put.
    func draggingSpectrogram(to height: CGFloat) -> CGFloat {
        Self.clamp(height.rounded(), Self.minSpectrogram, spectrogram + waveform - Self.minWaveform) / max(1, panels)
    }

    /// Clamp that favours the minimum when the window is too small for both limits.
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { max(lower, min(upper, value)) }
}

/// Width split between the analyzer column and the full-height Soundstage column on the right.
/// Height of the loudness summary, dragged by the divider under it. Stored in points; 0 means the default for
/// the window's arrangement. The analyzer rows below always keep their minimum heights.
enum HeroLayout {
    static let minHeight: CGFloat = 170
    static let maxHeight: CGFloat = 420
    /// The analyzer rows and dividers at their minimum, plus the heading, status bar and gaps.
    static let reservedBelow: CGFloat = PanelLayout.minSpectrum + PanelLayout.minSpectrogram + PanelLayout.minWaveform
        + 2 * PanelLayout.divider + 110

    static func defaultHeight(tall: Bool) -> CGFloat { tall ? 192 : 182 }

    /// How much the loudness column's readings grow when the summary is dragged taller: 1 up to the tall default
    /// height, then in step with the extra height, up to 1.8 (1.5 in the compact arrangement). The column's width
    /// caps it too, so a narrowed column never grows readings its tiles cannot hold (1.8 needs the full 560 pt).
    static func contentScale(height: CGFloat, compact: Bool, loudnessWidth: CGFloat? = nil) -> CGFloat {
        let extra = max(0, height - defaultHeight(tall: true))
        let byWidth = loudnessWidth.map { max(1, $0 / loudnessRange(compact: false).max * 1.8) } ?? .infinity
        return min(compact ? 1.5 : 1.8, byWidth, 1 + extra / 160)
    }

    /// Widths across the summary row: the short-term reading (fixed), then the loudness column, the 15 s
    /// history and the VU meter, one gap apart. The dividers either side of the history set the loudness column
    /// and the VU width (0 = automatic); the history takes what is left and never drops below `minHistory`.
    struct Columns: Equatable {
        var loudness: CGFloat
        var history: CGFloat
        var vu: CGFloat
    }
    static let minHistory: CGFloat = 110
    /// Narrower and the pivot hub meets the "0 VU = …" caption.
    static let minVU: CGFloat = 170
    static let maxVU: CGFloat = 640

    static func leadWidth(compact: Bool) -> CGFloat { compact ? 190 : 250 }
    static func gap(compact: Bool) -> CGFloat { compact ? 14 : 22 }
    static func defaultVU(compact: Bool) -> CGFloat { compact ? 170 : 236 }
    /// The loudness column keeps room for its tiles' full titles; unset, it grows to `max` before the history does.
    static func loudnessRange(compact: Bool) -> (min: CGFloat, max: CGFloat) { compact ? (380, 440) : (430, 560) }

    /// Width left for the loudness column, history and VU inside a row `width` wide (padding excluded).
    static func available(width: CGFloat, compact: Bool) -> CGFloat {
        max(0, width - leadWidth(compact: compact) - 3 * gap(compact: compact))
    }

    static func columns(width: CGFloat, compact: Bool, loudness requestedLoudness: CGFloat, vu requestedVU: CGFloat) -> Columns {
        let available = available(width: width, compact: compact)
        let range = loudnessRange(compact: compact)
        let vuUpper = max(minVU, min(maxVU, available - range.min - minHistory))
        let vu = PanelLayout.clamp((requestedVU > 0 ? requestedVU : defaultVU(compact: compact)).rounded(), minVU, vuUpper)
        let loudnessUpper = max(range.min, available - vu - minHistory)
        let loudness = requestedLoudness > 0
            ? PanelLayout.clamp(requestedLoudness.rounded(), range.min, loudnessUpper)
            : PanelLayout.clamp(available - vu - minHistory, range.min, min(range.max, loudnessUpper))
        return Columns(loudness: loudness, history: max(0, available - loudness - vu), vu: vu)
    }

    static func height(_ requested: CGFloat, tall: Bool, window: CGFloat) -> CGFloat {
        let valid = requested.isFinite && requested > 0 ? requested : defaultHeight(tall: tall)
        let upper = max(minHeight, min(maxHeight, window - reservedBelow))
        return PanelLayout.clamp(valid.rounded(), minHeight, upper)
    }
}

enum ColumnLayout {
    static let minStage: CGFloat = 300
    static let maxStage: CGFloat = 620
    static let defaultStage: CGFloat = 380
    static let minAnalyzers: CGFloat = 600

    /// Soundstage width for a requested width inside `total` (both columns and the divider).
    static func stageWidth(_ requested: CGFloat, total: CGFloat) -> CGFloat {
        let valid = requested.isFinite && requested > 0 ? requested : defaultStage
        let upper = min(maxStage, total - PanelLayout.divider - minAnalyzers)
        return PanelLayout.clamp(valid.rounded(), minStage, upper)
    }
}

extension SpeakerLayout {
    /// What Stereo mode shows, whatever layout is selected.
    static let stereoSpeakers = [Speaker(role: Role.left, name: "L", group: .front, azimuth: -30),
                                 Speaker(role: Role.right, name: "R", group: .front, azimuth: 30)]
}

extension Speaker {
    /// How present a channel is for a format mix: `presence` runs 0 (Stereo) → 1 (Spatial), `mono` 0 → 1 (Mono).
    /// L always shows (it carries the mono programme), R recedes in Mono, every other channel follows Spatial.
    func weight(presence: CGFloat, mono: CGFloat) -> CGFloat {
        switch role {
        case Role.left: return 1
        case Role.right: return presence + (1 - presence) * (1 - mono)
        default: return presence
        }
    }

    /// L reads "M" once the display is mostly Mono.
    func displayName(mono: CGFloat) -> String { role == Role.left && mono >= 0.5 ? "M" : name }
}

/// The Soundstage panel's display well, a tall column: the top-down room above, then one horizontal meter
/// row per channel grouped under FRONT / LFE / SURROUND / HEIGHT headers, the dB axis, and the L/R phase
/// correlation meter at the foot. `size` is the well.
///
/// `presence` runs from 1 (Spatial) to 0 (Stereo). Every rect is a pure function of the size, the speaker
/// layout and the presence, so Metal (stepping its own spring) and SwiftUI (animating `presence`) place bars,
/// nodes and labels identically on every frame of the transition. In Stereo the extended rows and their
/// headers collapse and dissolve while L and R grow; the room takes the freed height and zooms onto the
/// ±30° stereo stage.
struct SoundstageLayout {
    static let groupTitles: [SpeakerGroup: String] = [.front: "FRONT", .lfe: "LFE", .surround: "SURROUND", .height: "HEIGHT"]
    static let scaleTicks: [Float] = [-60, -48, -36, -24, -18, -12, -6, 0]
    /// Meter row, left to right: channel name, bar, clip LED, held-peak readout.
    static let nameColumn: CGFloat = 36
    static let clipColumn: CGFloat = 16
    static let readoutColumn: CGFloat = 44
    static let headerHeight: CGFloat = 20
    static let axisHeight: CGFloat = 16
    static let correlationHeight: CGFloat = 46
    static let roomGap: CGFloat = 14
    /// Row pitch L and R grow to in Stereo, and the single row in Mono, when the column allows it.
    static let stereoPitch: CGFloat = 46
    static let monoPitch: CGFloat = 58
    /// Row pitch in Spatial: small layouts get taller rows (41 pt for 3.0, 36 for 5.1.2) down to 30 pt for 14 or
    /// more channels. A column too short for that compresses every row alike.
    static func spatialPitch(channels: Int) -> CGFloat { max(30, min(42, 44 - CGFloat(channels))) }
    /// Label offset beyond a node's rim, shared by the stereo fit below and `label(_:)`.
    static let labelOffset: CGFloat = 12

    let speakers: [Speaker]
    let presence: CGFloat
    let mono: CGFloat
    let stageWell: CGRect
    /// Square the room is fitted into; the room itself zooms within it as presence changes.
    let radar: CGRect
    let center: CGPoint
    let bedRadius: CGFloat
    let heightRadius: CGFloat
    let nodeRadius: CGFloat
    /// Everything under the room: headers, names, bars, LEDs, readouts, the dB axis and correlation.
    let meterArea: CGRect
    /// Horizontal extent of every bar; −70 dBFS at `minX`, 0 dBFS at `maxX`.
    let scale: CGRect
    /// One full-width row slot per entry of `speakers`. Receding rows collapse to zero height.
    let rows: [CGRect]
    /// Header slot per group present, in display order; receding headers collapse too.
    let headers: [(group: SpeakerGroup, rect: CGRect)]
    /// Vertical span of headers and rows.
    let block: CGRect
    /// The mirrored correlation track (−1 at both ends, +1 at the centre) and its whole area.
    let correlationTrack: CGRect
    let correlationArea: CGRect

    init(size: CGSize, presence: CGFloat = 1, mono: CGFloat = 0, layout: SpeakerLayout = .standard) {
        let p = max(0, min(1, presence))
        let m = max(0, min(1, mono))
        self.presence = p
        self.mono = m
        speakers = layout.speakers
        stageWell = CGRect(origin: .zero, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        let inner = stageWell.insetBy(dx: 12, dy: 10)

        // Columns shared by rows, the dB axis and the correlation meter.
        let barLeft = inner.minX + Self.nameColumn + 2
        scale = CGRect(x: barLeft, y: inner.minY,
                       width: max(1, inner.maxX - Self.readoutColumn - Self.clipColumn - barLeft), height: inner.height)

        // Stack, top to bottom: room, rows block, dB axis, correlation meter. The rows take the height they
        // want (up to a comfortable pitch), the room the largest square left, and the whole stack is centred
        // so a tall column has no dead band in the middle.
        let groups = layout.groups
        let weights = speakers.map { $0.weight(presence: p, mono: m) }
        let totalWeight = weights.reduce(0, +)
        let headerWeights = groups.map { $0 == .front ? CGFloat(1) : p }
        let headerTotal = headerWeights.reduce(0, +) * Self.headerHeight
        // Mono has no L/R pair, so the correlation meter folds away with R.
        let footer = Self.axisHeight + Self.correlationHeight * (1 - m)
        let minimumRoom = min(inner.width, 150)
        let spatialPitch = Self.spatialPitch(channels: layout.channelCount)
        let pairPitch = Self.stereoPitch + (Self.monoPitch - Self.stereoPitch) * m
        let maxPitch = pairPitch + (spatialPitch - pairPitch) * p
        let rowsSpace = inner.height - footer - minimumRoom - Self.roomGap - headerTotal
        let pitch = max(4, min(maxPitch, rowsSpace / max(0.0001, totalWeight)))
        let blockHeight = pitch * totalWeight + headerTotal
        let side = max(1, min(inner.width, inner.height - footer - blockHeight - Self.roomGap))
        let stackHeight = side + Self.roomGap + blockHeight + footer
        let top = inner.minY + max(0, (inner.height - stackHeight) / 2)
        radar = CGRect(x: (inner.midX - side / 2).rounded(), y: top.rounded(), width: side, height: side)
        let blockTop = radar.maxY + Self.roomGap
        let blockBottom = blockTop + blockHeight
        correlationArea = CGRect(x: inner.minX, y: blockBottom + Self.axisHeight, width: inner.width, height: Self.correlationHeight)
        correlationTrack = CGRect(x: scale.minX, y: correlationArea.minY + 20, width: scale.width, height: 8)

        var y = blockTop
        var rowRects = [CGRect](repeating: .zero, count: speakers.count)
        var headerRects: [(SpeakerGroup, CGRect)] = []
        for (groupIndex, group) in groups.enumerated() {
            let headerHeight = Self.headerHeight * headerWeights[groupIndex]
            headerRects.append((group, CGRect(x: inner.minX, y: y, width: inner.width, height: headerHeight)))
            y += headerHeight
            for (index, speaker) in speakers.enumerated() where speaker.group == group {
                let height = pitch * weights[index]
                rowRects[index] = CGRect(x: inner.minX, y: y, width: inner.width, height: height)
                y += height
            }
        }
        rows = rowRects
        headers = headerRects
        block = CGRect(x: inner.minX, y: blockTop, width: inner.width, height: blockHeight)
        meterArea = CGRect(x: inner.minX, y: block.minY, width: inner.width, height: correlationArea.maxY - block.minY)
        nodeRadius = max(5, min(9, side * 0.028))

        // Spatial: the whole room centred in the square. Stereo: zoom onto the listener–L–R triangle and
        // centre it, labels included, so the stage fills the square.
        let spatialRadius = side * 0.36
        let stereoRadius = side * 0.68
        let reach = stereoRadius + nodeRadius + Self.labelOffset + 6
        // L and R close in to a single front-centre source as Mono takes over.
        let stereoTop = -reach * cos(.pi / 6 * (1 - m)), stereoBottom: CGFloat = 8
        let spatialCenter = CGPoint(x: radar.midX, y: radar.midY)
        let stereoCenter = CGPoint(x: radar.midX, y: radar.midY - (stereoTop + stereoBottom) / 2)
        center = CGPoint(x: stereoCenter.x + (spatialCenter.x - stereoCenter.x) * p,
                         y: stereoCenter.y + (spatialCenter.y - stereoCenter.y) * p)
        bedRadius = stereoRadius + (spatialRadius - stereoRadius) * p
        heightRadius = bedRadius * 0.54
    }

    /// L always weighs 1, R recedes in Mono, every other channel follows the Spatial presence.
    func weight(_ index: Int) -> CGFloat { speakers[index].weight(presence: presence, mono: mono) }
    func headerWeight(_ group: SpeakerGroup) -> CGFloat { group == .front ? 1 : presence }

    /// The bar inside a row: thickness follows the row pitch, so collapsing rows thin out as they fade.
    func bar(_ index: Int) -> CGRect {
        let row = rows[index]
        let thickness = min(row.height * 0.56, max(3, min(18, row.height * 0.46)))
        return CGRect(x: scale.minX, y: row.midY - thickness / 2, width: scale.width, height: thickness)
    }

    func x(decibels db: Float) -> CGFloat { scale.minX + CGFloat(MeterScale.position(decibels: db)) * scale.width }
    /// How far each mirrored marker moves from −1 at an end toward +1 at the centre.
    func correlationInset(_ value: Float) -> CGFloat {
        CGFloat((max(-1, min(1, value)) + 1) / 2) * correlationTrack.width / 2
    }

    var nameX: CGFloat { meterArea.minX + Self.nameColumn / 2 }
    var clipX: CGFloat { scale.maxX + Self.clipColumn / 2 }
    var readoutMaxX: CGFloat { meterArea.maxX }
    var axisY: CGFloat { block.maxY + Self.axisHeight / 2 + 1 }

    static func direction(_ azimuth: Double) -> CGVector {
        let radians = azimuth * .pi / 180
        return CGVector(dx: sin(radians), dy: -cos(radians))
    }

    /// A speaker's azimuth on screen: L and R slide to front centre as Mono takes over.
    func azimuth(_ speaker: Speaker) -> Double? {
        guard let azimuth = speaker.azimuth else { return nil }
        return speaker.role == Role.left || speaker.role == Role.right ? azimuth * Double(1 - mono) : azimuth
    }

    func direction(_ speaker: Speaker) -> CGVector { Self.direction(azimuth(speaker) ?? 0) }

    func node(_ speaker: Speaker) -> CGPoint {
        guard let azimuth = azimuth(speaker) else { return center }
        let radius = speaker.group == .height ? heightRadius : bedRadius
        let direction = Self.direction(azimuth)
        return CGPoint(x: center.x + direction.dx * radius, y: center.y + direction.dy * radius)
    }

    /// Where a speaker's name sits: radially outside its node, or under the listener for LFE.
    func label(_ speaker: Speaker) -> CGPoint {
        guard let azimuth = azimuth(speaker) else { return CGPoint(x: center.x, y: center.y + nodeRadius + 13) }
        let point = node(speaker)
        let direction = Self.direction(azimuth)
        // Bed labels sit outside the ring; upper-layer labels inside theirs, clear of the bed labels.
        let offset = (nodeRadius + Self.labelOffset) * (speaker.group == .height ? -1 : 1)
        return CGPoint(x: point.x + direction.dx * offset, y: point.y + direction.dy * offset)
    }
}
