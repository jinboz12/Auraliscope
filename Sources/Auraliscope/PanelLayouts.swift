import AnalysisCore
import CoreGraphics
import Foundation

// Geometry of the window's panels (columns, the loudness hero, the Soundstage) shared by the Metal scenes and the SwiftUI overlays.
/// The left column below the loudness summary: the Spectrum card (spectrogram and live spectrum together), then
/// the Waveform, separated by a draggable divider. The Spectrum's height is stored as a fraction of the panel
/// area so it scales with the window, and both panels keep a minimum at which their contents stay legible.
struct PanelLayout {
    /// A divider's hit strip, which is also the gap between the two panels.
    static let divider: CGFloat = 10
    static let minSpectrum: CGFloat = 180
    static let minWaveform: CGFloat = 120
    static let defaultSpectrum: CGFloat = 0.64

    let spectrum: CGFloat
    let waveform: CGFloat

    /// `height` is the whole column, divider included.
    init(height: CGFloat, spectrum spectrumFraction: CGFloat) {
        let panels = max(0, height - Self.divider)
        let valid = spectrumFraction.isFinite && spectrumFraction > 0 ? spectrumFraction : Self.defaultSpectrum
        spectrum = Self.clamp((valid * panels).rounded(), Self.minSpectrum, panels - Self.minWaveform)
        waveform = max(0, panels - spectrum)
    }

    var panels: CGFloat { spectrum + waveform }

    /// Spectrum fraction after dragging the divider so the Spectrum is `height` tall.
    func draggingSpectrum(to height: CGFloat) -> CGFloat {
        Self.clamp(height.rounded(), Self.minSpectrum, panels - Self.minWaveform) / max(1, panels)
    }

    /// Clamp that favours the minimum when the window is too small for both limits.
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { max(lower, min(upper, value)) }
}

/// Width split between the analyzer column and the full-height Soundstage column on the right.
/// Height of the loudness summary, dragged by the divider under it. Stored in points; 0 means the default for
/// the window's arrangement. The analyzer rows below always keep their minimum heights.
enum HeroLayout {
    /// Low enough for a 720p screen; below `gaugeHeight` the gauge folds away and the tiles keep their size.
    static let minHeight: CGFloat = 150
    static let maxHeight: CGFloat = 420
    /// The taller of the two columns below at their minimum (the Soundstage column), plus the status bar and the
    /// gaps around it. The analyzer column's minimum is shorter.
    static let reservedBelow: CGFloat = max(ColumnLayout.minColumn,
                                            PanelLayout.minSpectrum + PanelLayout.minWaveform + PanelLayout.divider) + 42

    static func defaultHeight(tall: Bool) -> CGFloat { tall ? 192 : 182 }

    /// What the summary's content needs at scale 1, padding excluded: the title row, the gauge with its axis and
    /// two rows of tiles, with the spacing between them. Measured with the Chinese titles, the tallest.
    static let content: CGFloat = 164
    /// The gauge, its axis and the spacing under it.
    static let gaugeBlock: CGFloat = 37
    /// The gauge shows when the summary holds it with at least 8 pt above and below; shorter (a 720p screen, or a
    /// summary dragged short) it folds away rather than squeezing the tiles.
    static func showsGauge(height: CGFloat) -> Bool { height >= content + 16 }

    /// Top and bottom padding: the arrangement's padding where there is room, closing to 8 pt so the tiles never
    /// run past the edge.
    static func verticalPadding(height: CGFloat, compact: Bool) -> CGFloat {
        let need = content - (showsGauge(height: height) ? 0 : gaugeBlock)
        return max(8, min(compact ? 14 : 18, ((height - need) / 2).rounded(.down)))
    }

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
    /// Between the short-term reading and the loudness column.
    static func gap(compact: Bool) -> CGFloat { compact ? 14 : 22 }
    /// The loudness panel's inner margins: its title lines up with the titles of the panels below it.
    static let inset: CGFloat = 18
    static let trailingInset: CGFloat = 16
    /// Between the loudness column and the history card, and between the history and VU cards: the panels' gutter.
    static let cardGap: CGFloat = PanelLayout.divider
    static func defaultVU(compact: Bool) -> CGFloat { compact ? 170 : 236 }
    /// The loudness column keeps room for its tiles' full titles; unset, it grows to `max` before the history does.
    static func loudnessRange(compact: Bool) -> (min: CGFloat, max: CGFloat) { compact ? (380, 410) : (430, 560) }

    /// Width left for the loudness column, history and VU inside a row `width` wide (the inset excluded).
    static func available(width: CGFloat, compact: Bool) -> CGFloat {
        max(0, width - leadWidth(compact: compact) - gap(compact: compact) - 2 * cardGap)
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

    /// Below this window height (a 720p screen) the columns under the summary would drop under their full
    /// minimums, so the summary starts at its minimum instead: without the gauge, a few points taller buy nothing.
    static let shortWindow: CGFloat = defaultHeight(tall: false) + ColumnLayout.minRoom + PanelLayout.divider
        + ColumnLayout.minLevels + 42

    static func height(_ requested: CGFloat, tall: Bool, window: CGFloat) -> CGFloat {
        let automatic = window < shortWindow ? minHeight : defaultHeight(tall: tall)
        let valid = requested.isFinite && requested > 0 ? requested : automatic
        let upper = max(minHeight, min(maxHeight, window - reservedBelow))
        return PanelLayout.clamp(valid.rounded(), minHeight, upper)
    }
}

enum ColumnLayout {
    /// The divider between the analyzers and the Soundstage column moves freely between these: the Soundstage column
    /// as narrow as its stereometer and readings stay legible, the analyzers as narrow as the Spectrum panel's own
    /// window may be (`MeterPanel.minimumSize`), so either side can take most of a wide window.
    static let minStage: CGFloat = 280
    static let defaultStage: CGFloat = 380
    static let minAnalyzers: CGFloat = 520

    /// The right-hand column holds the Soundstage room above the Channel Levels panel; the room's share of the
    /// column's height is stored, and each panel keeps its minimum.
    static let defaultRoomShare: CGFloat = 0.42
    static let minRoom: CGFloat = 200
    static let minLevels: CGFloat = 310
    /// In a short column (a 720p screen) the minimums close in, Channel Levels first, down to these. Channel Levels
    /// then shows its correlation section compact (`SoundstageLayout.compactCorrelation`), and a short room folds
    /// its band legend away (`SoundstageLayout.showsScopeLegend`).
    static let shortRoom: CGFloat = 150
    static let shortLevels: CGFloat = 272
    /// The column at its shortest: both panels at their short minimum and the divider.
    static let minColumn: CGFloat = shortRoom + PanelLayout.divider + shortLevels

    /// Minimum heights in a column `total` tall: the full ones where they fit, closing in continuously (Channel
    /// Levels before the room, whose stereometer needs the height more) as the column shortens, so a resize never
    /// makes a panel jump.
    /// In Immersive, Channel Levels has meters only (no correlation section), so in a short column it closes in
    /// further and the dome, which needs height more than anything else there, keeps its full minimum longer.
    static let shortLevelsImmersive: CGFloat = 214

    static func minimums(total: CGFloat, spatial: Bool = false) -> (room: CGFloat, levels: CGFloat) {
        let panels = total - PanelLayout.divider
        let shortest = spatial ? shortLevelsImmersive : shortLevels
        let room = min(minRoom, max(shortRoom, panels - shortest))
        return (room, min(minLevels, max(shortest, panels - room)))
    }

    /// Soundstage (room) panel height for a stored share of a column `total` points tall (both panels and the divider).
    static func roomHeight(share: CGFloat, total: CGFloat, spatial: Bool = false) -> CGFloat {
        let valid = share.isFinite && share > 0 ? share : defaultRoomShare
        let least = minimums(total: total, spatial: spatial)
        let upper = max(least.room, total - PanelLayout.divider - least.levels)
        return PanelLayout.clamp((valid * total).rounded(), least.room, upper)
    }

    /// Soundstage width for a requested width inside `total` (both columns and the divider).
    static func stageWidth(_ requested: CGFloat, total: CGFloat) -> CGFloat {
        let valid = requested.isFinite && requested > 0 ? requested : defaultStage
        let upper = max(minStage, total - PanelLayout.divider - minAnalyzers)
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

/// The two wells of the right-hand column. `.room`: the Soundstage panel's top-down room. `.levels`: the Channel
/// Levels panel, one vertical meter per channel grouped under FRONT / LFE / SURROUND / HEIGHT headers, with the
/// dB scale on the left and a true-peak over zone above 0 dB, and the L/R correlation section at the foot in
/// Stereo. `size` is the well.
///
/// `presence` runs from 1 (Spatial) to 0 (Stereo). Every rect is a pure function of the size, the speaker
/// layout and the presence, so Metal (stepping its own spring) and SwiftUI (animating `presence`) place bars,
/// nodes and labels identically on every frame of the transition. In Stereo the extended columns and their
/// headers narrow to nothing and dissolve while L and R widen, the correlation section unfolds, and the room
/// zooms onto the ±30° stereo stage.
struct SoundstageLayout {
    enum Part { case room, levels }

    /// Group header over the meter columns, in the current language; LFE is a channel label and stays as is.
    static func groupTitle(_ group: SpeakerGroup) -> String {
        switch group {
        case .front: return L("FRONT")
        case .lfe: return "LFE"
        case .surround: return L("SURROUND")
        case .height: return L("HEIGHT")
        }
    }
    static let scaleTicks: [Float] = [-60, -48, -36, -24, -18, -12, -6, 0]
    /// The meters read up to +3 dBTP, so a true-peak over shows how far it went.
    static let overTop: Float = 3
    /// Share of the bar height above 0 dB.
    static let overShare: CGFloat = 0.1
    /// Meter block, top to bottom: group headers, held-peak readouts, bars, channel names; the dB scale on the left.
    static let headerHeight: CGFloat = 16
    static let readoutHeight: CGFloat = 16
    /// Band over each bar for its clip light, latched by a true-peak over or a full-scale sample.
    static let capHeight: CGFloat = 12
    /// Diameter of the clip light.
    static let capDiameter: CGFloat = 6
    static let nameHeight: CGFloat = 18
    static let axisColumn: CGFloat = 26
    static let groupGap: CGFloat = 6
    /// Correlation section: title row, the bar (one lane per band group), zone captions and the listener hint.
    /// Compact, in a short Channel Levels panel, it keeps the title row and the bar and puts the lit zone and the
    /// mono fold-down on one row under the bar, in place of the captions and the hint.
    static func correlationHeight(lanes: CGFloat, compact: Bool = false) -> CGFloat {
        22 + trackHeight(lanes: lanes) + (compact ? 22 : 60)
    }
    /// The meter block's fixed rows in Stereo: held-peak readouts, clip lights and channel names.
    static let meterRows: CGFloat = readoutHeight + capHeight + nameHeight
    /// Bars shorter than this with the full correlation section switch it to the compact one.
    static let compactBars: CGFloat = 90
    /// One lane per band group, the highest at the top like every frequency axis in the window; fewer lanes are
    /// a little taller (the full-band lane is the classic single bar).
    static func laneHeight(lanes: Int) -> CGFloat { lanes <= 1 ? 12 : (lanes <= 3 ? 11 : 9) }
    static let laneGap: CGFloat = 3
    /// Half the height of the lanes' rounded ends, where −1 and +1 sit.
    static let laneCap: CGFloat = 4.5
    static func trackHeight(count: Int) -> CGFloat {
        CGFloat(count) * laneHeight(lanes: count) + CGFloat(max(0, count - 1)) * laneGap
    }
    /// The bar's height for a lane count that may be between resolutions while a band switch animates: straight
    /// between the heights of 1, 3 and 5 lanes, so the section glides instead of jumping.
    private static let laneCounts = StereoBands.Resolution.allCases.map(\.count).sorted()
    static func trackHeight(lanes: CGFloat) -> CGFloat {
        let counts = laneCounts
        let clamped = max(CGFloat(counts.first!), min(CGFloat(counts.last!), lanes))
        for (low, high) in zip(counts, counts.dropFirst()) where clamped <= CGFloat(high) {
            let t = (clamped - CGFloat(low)) / CGFloat(high - low)
            return trackHeight(count: low) + (trackHeight(count: high) - trackHeight(count: low)) * t
        }
        return trackHeight(count: counts.last!)
    }
    /// Band names left of the lanes and band readings right of them.
    static let laneLabelColumn: CGFloat = 50
    static let laneValueColumn: CGFloat = 34
    static let roomGap: CGFloat = 14
    /// Column pitch L and R widen to in Stereo, and the single column in Mono, when the well allows it.
    static let stereoPitch: CGFloat = 112
    static let monoPitch: CGFloat = 128
    /// Bar thickness limit: 9 pt in Spatial, up to 16 pt for the wide Stereo and Mono columns.
    static let spatialBar: CGFloat = 9
    static let pairBar: CGFloat = 16
    /// Column pitch in Spatial: small layouts get wider columns (41 pt for 3.0, 36 for 5.1.2) down to 30 pt for 14
    /// or more channels. A narrow well compresses every column alike.
    static func spatialPitch(channels: Int) -> CGFloat { max(30, min(42, 44 - CGFloat(channels))) }

    let speakers: [Speaker]
    let presence: CGFloat
    let mono: CGFloat
    /// 1 in Stereo, folding to 0 toward Multi Channel and toward Mono: correlation is an L/R measure, and in
    /// Multi Channel L/R alone says little about what reaches the listener.
    let correlationWeight: CGFloat
    let stageWell: CGRect
    /// The stereometer's listener point and radius in the well (fixed by its size, so worked out once: the plot
    /// asks for them at every point it draws).
    let scopeCenter: CGPoint
    let scopeRadius: CGFloat
    /// Square the room is fitted into; the room itself zooms within it as presence changes.
    let radar: CGRect
    /// The listener on screen, and the length of one room unit (the bed ring's radius) at the listener, in points.
    let stageOrigin: CGPoint
    let stageScale: CGFloat
    let nodeRadius: CGFloat
    /// The vertical meters: headers, readouts, bars, names and the dB scale.
    let block: CGRect
    /// Vertical extent of every bar (−70 dBFS at `maxY`, +3 dB at `minY`) across the columns' horizontal span.
    let scale: CGRect
    /// One full-height column slot per entry of `speakers`. Receding columns narrow to zero width.
    let columns: [CGRect]
    /// Height of the group header row: full in Spatial, none in Stereo and Mono.
    let headerSpace: CGFloat
    /// Header slot per group present, over its columns; receding headers narrow too.
    let headers: [(group: SpeakerGroup, rect: CGRect)]
    /// The correlation track (−1 at the left, 0 at the centre, +1 at the right) and its whole section.
    let correlationTrack: CGRect
    let correlationArea: CGRect
    /// Below this well height (inside its margins) a wide Channel Levels well sets the correlation beside the meters.
    static let sideBySideHeight: CGFloat = 200
    /// The meters' share of the width then.
    static let sideBySideMeters: CGFloat = 0.42

    /// Lanes of the correlation bar: 1 (full band), 3 or 5 (`StereoBands.Resolution`), or a value between them
    /// while a band switch animates; the bar's height follows it.
    let lanes: CGFloat
    /// The correlation section in its compact form (`correlationHeight(lanes:compact:)`), for a short panel.
    let compactCorrelation: Bool

    init(size: CGSize, presence: CGFloat = 1, mono: CGFloat = 0, layout: SpeakerLayout = .standard, part: Part,
         lanes: CGFloat = CGFloat(StereoBands.count)) {
        self.lanes = max(1, lanes)
        let p = max(0, min(1, presence))
        let m = max(0, min(1, mono))
        self.presence = p
        self.mono = m
        correlationWeight = (1 - p) * (1 - m)
        speakers = layout.speakers
        stageWell = CGRect(origin: .zero, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        let inner = stageWell.insetBy(dx: 12, dy: 10)
        let scopeHeight = inner.height - (Self.showsLegend(wellHeight: stageWell.height) ? Self.legendHeight + 6 : 0)
        scopeRadius = max(20, min(inner.width / 2 - Self.scopeMargin + 6, scopeHeight - Self.scopeMargin - 16))
        scopeCenter = CGPoint(x: inner.midX,
                              y: inner.minY + Self.scopeMargin + scopeRadius + max(0, scopeHeight - Self.scopeMargin - scopeRadius - 16) / 2)
        // Decided for the full section at its tallest (five lanes) and independent of the format mix, so the section
        // keeps its form through band switches and mode changes, and fewer lanes always give the bars more height.
        let fullSection = Self.correlationHeight(lanes: CGFloat(StereoBands.count)) + Self.roomGap
        // Short and wide (the horizontal strip): the meters on the left and the correlation section beside them,
        // as tall as the well. The main window's columns never get this short.
        let sideBySide = part == .levels && inner.height < Self.sideBySideHeight && inner.width >= 360
        compactCorrelation = part == .levels
            && (sideBySide ? inner.height < Self.correlationHeight(lanes: CGFloat(StereoBands.count)) + 8
                           : inner.height - fullSection - Self.meterRows < Self.compactBars)
        let correlationHeight = Self.correlationHeight(lanes: max(1, lanes), compact: compactCorrelation)
        let correlationGap = compactCorrelation ? 10 : Self.roomGap

        // Room: the largest centred square. Levels: the meters fill the well above the correlation section, which
        // takes its height only as far as it is shown.
        let side: CGFloat
        let meterHeight: CGFloat
        switch part {
        case .room:
            side = max(1, min(inner.width, inner.height))
            radar = CGRect(x: (inner.midX - side / 2).rounded(), y: (inner.midY - side / 2).rounded(), width: side, height: side)
            meterHeight = 0
            block = CGRect(x: inner.minX, y: inner.maxY, width: inner.width, height: 0)
        case .levels:
            side = 0
            radar = CGRect(x: inner.midX, y: inner.minY, width: 0, height: 0)
            if sideBySide {
                // The correlation section's share folds into the meters as Stereo gives way to Mono or Immersive.
                let meters = (inner.width * Self.sideBySideMeters).rounded()
                meterHeight = inner.height
                block = CGRect(x: inner.minX, y: inner.minY, width: inner.width - (inner.width - meters) * correlationWeight,
                               height: meterHeight)
            } else {
                meterHeight = max(1, inner.height - (correlationHeight + correlationGap) * correlationWeight)
                block = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: meterHeight)
            }
        }
        if sideBySide {
            let start = inner.minX + (inner.width * Self.sideBySideMeters).rounded() + 14
            correlationArea = CGRect(x: start, y: inner.minY + max(0, (inner.height - correlationHeight) / 2),
                                     width: max(1, inner.maxX - start), height: correlationHeight)
        } else {
            correlationArea = CGRect(x: inner.minX, y: block.maxY + correlationGap, width: inner.width, height: correlationHeight)
        }
        correlationTrack = CGRect(x: correlationArea.minX + Self.laneLabelColumn, y: correlationArea.minY + 22,
                                  width: max(1, correlationArea.width - Self.laneLabelColumn - Self.laneValueColumn),
                                  height: Self.trackHeight(lanes: max(1, lanes)))

        // Columns: each takes a pitch share by its weight, groups sit a small gap apart, and the set is centred
        // over the space right of the dB scale.
        let groups = layout.groups
        let weights = speakers.map { $0.weight(presence: p, mono: m) }
        let totalWeight = weights.reduce(0, +)
        // Group headers name the groups of a multichannel layout; Stereo and Mono have only the front pair, so
        // FRONT folds away with the other headers and gives its height to the bars.
        let headerWeights = groups.map { $0 == .front ? CGFloat(1) : p }
        headerSpace = Self.headerHeight * p
        let gaps = headerWeights.dropFirst().reduce(0, +) * Self.groupGap
        let area = CGRect(x: block.minX + Self.axisColumn, y: block.minY, width: max(1, block.width - Self.axisColumn),
                          height: meterHeight)
        let spatialPitch = Self.spatialPitch(channels: layout.channelCount)
        let pairPitch = Self.stereoPitch + (Self.monoPitch - Self.stereoPitch) * m
        let maxPitch = pairPitch + (spatialPitch - pairPitch) * p
        let pitch = max(1, min(maxPitch, (area.width - gaps) / max(0.0001, totalWeight)))
        let used = pitch * totalWeight + gaps
        var x = area.minX + max(0, (area.width - used) / 2)
        var columnRects = [CGRect](repeating: .zero, count: speakers.count)
        var headerRects: [(SpeakerGroup, CGRect)] = []
        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 { x += Self.groupGap * headerWeights[groupIndex] }
            let start = x
            for (index, speaker) in speakers.enumerated() where speaker.group == group {
                let width = pitch * weights[index]
                columnRects[index] = CGRect(x: x, y: area.minY, width: width, height: area.height)
                x += width
            }
            headerRects.append((group, CGRect(x: start, y: area.minY, width: x - start, height: Self.headerHeight)))
        }
        columns = columnRects
        headers = headerRects
        let barsTop = area.minY + headerSpace + Self.readoutHeight + Self.capHeight
        scale = CGRect(x: area.minX, y: barsTop, width: area.width,
                       height: max(0, area.maxY - Self.nameHeight - barsTop))
        nodeRadius = max(5, min(9, side * 0.028))

        // Immersive: the room drawn flat (`flat`), fitted with its speaker names into the well above
        // the band legend. The fit depends on the format only, so the room holds still through mode changes and
        // only its speakers come and go.
        let well = CGRect(x: inner.minX, y: inner.minY, width: inner.width,
                          height: max(1, inner.height - (Self.showsLegend(wellHeight: stageWell.height) ? Self.legendHeight + 6 : 0) * (1 - m)))
        let extent = Self.roomExtents[layout]!
        let fit = CGRect(x: well.minX + Self.labelSide, y: well.minY + Self.labelTop,
                         width: max(1, well.width - 2 * Self.labelSide), height: max(1, well.height - Self.labelTop - 6))
        stageScale = max(8, min(fit.width / max(0.01, extent.width), fit.height / max(0.01, extent.height)))
        stageOrigin = CGPoint(x: fit.midX - extent.midX * stageScale, y: fit.midY - extent.midY * stageScale)
    }

    /// The room's unscaled bounds depend only on its speaker layout, not the panel size or animation. Compute
    /// the floor ring, markers and axis once for each format instead of repeating their trigonometry per frame.
    private static let roomExtents: [SpeakerLayout: CGRect] = Dictionary(uniqueKeysWithValues: SpeakerLayout.allCases.map { layout in
        var points = (0..<36).map { flat(roomPoint(azimuth: Double($0) * 10, height: false)).point }
        for speaker in layout.speakers {
            guard let azimuth = speaker.azimuth else { continue }
            let at = flat(roomPoint(azimuth: azimuth, height: speaker.group == .height))
            let reach = 0.09 * at.scale
            points += [CGPoint(x: at.point.x - reach, y: at.point.y - reach), CGPoint(x: at.point.x + reach, y: at.point.y + reach)]
        }
        points.append(flat(Point3(x: 0, y: axisTop, z: 0)).point)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        return (layout, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    })

    /// L always weighs 1, R recedes in Mono, every other channel follows the Spatial presence.
    func weight(_ index: Int) -> CGFloat { speakers[index].weight(presence: presence, mono: mono) }
    func headerWeight(_ group: SpeakerGroup) -> CGFloat { presence }

    /// The bar inside a column: thickness follows the column pitch, so narrowing columns thin out as they fade.
    func bar(_ index: Int) -> CGRect {
        let column = columns[index]
        // Narrow in Immersive; the two wide Stereo columns carry fuller bars.
        let limit = Self.pairBar + (Self.spatialBar - Self.pairBar) * presence
        let thickness = min(column.width * 0.6, max(3, min(limit, column.width * 0.4)))
        return CGRect(x: column.midX - thickness / 2, y: scale.minY, width: thickness, height: scale.height)
    }

    /// The clip light over a bar: a dot centred on it, narrower for thin bars.
    func cap(_ index: Int) -> CGRect {
        let bar = bar(index)
        let diameter = min(Self.capDiameter, bar.width)
        return CGRect(x: bar.midX - diameter / 2, y: scale.minY - Self.capHeight / 2 - diameter / 2,
                      width: diameter, height: diameter)
    }

    /// The part of a bar above 0 dB, up to `overTop`: tinted in the track, filled in ember by an over.
    func overTrack(_ index: Int) -> CGRect {
        let bar = bar(index)
        return CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: max(0, y(decibels: 0) - bar.minY))
    }

    /// Height fraction of a level on the bar: the IEC deflection up to 0 dB, then linear to `overTop`.
    static func fraction(decibels db: Float) -> CGFloat {
        guard db > 0 else { return CGFloat(MeterScale.position(decibels: db)) * (1 - overShare) }
        return 1 - overShare + CGFloat(min(db, overTop) / overTop) * overShare
    }

    func y(decibels db: Float) -> CGFloat { scale.maxY - Self.fraction(decibels: db) * scale.height }
    /// Where a correlation reading sits on the track: −1 and +1 at the centres of the lanes' rounded ends, 0 halfway.
    func correlationX(_ value: Float) -> CGFloat {
        let cap = Self.laneCap
        return correlationTrack.minX + cap + CGFloat((max(-1, min(1, value)) + 1) / 2) * (correlationTrack.width - 2 * cap)
    }

    /// The lane of band group `band` (0 = lowest) when the bar shows `count` lanes: the top group on top. The
    /// lanes share the bar's current height, so during a band switch the outgoing and incoming sets both fit it.
    func correlationLane(_ band: Int, of count: Int) -> CGRect {
        let n = CGFloat(max(1, count))
        let height = max(1, (correlationTrack.height - (n - 1) * Self.laneGap) / n)
        let row = n - 1 - CGFloat(band)
        return CGRect(x: correlationTrack.minX, y: correlationTrack.minY + row * (height + Self.laneGap),
                      width: correlationTrack.width, height: height)
    }

    /// Centre of a column's held-peak readout, and of its channel name.
    func readoutPoint(_ index: Int) -> CGPoint {
        CGPoint(x: columns[index].midX, y: block.minY + headerSpace + Self.readoutHeight / 2)
    }
    func namePoint(_ index: Int) -> CGPoint { CGPoint(x: columns[index].midX, y: scale.maxY + Self.nameHeight / 2 + 1) }
    /// Right edge of the dB labels.
    var axisMaxX: CGFloat { scale.minX - 5 }

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

    // MARK: Surround scope (Immersive)

    /// A point of the room in room units: the listener at the origin, the bed ring's radius 1, x to the right,
    /// y up, z toward the front.
    struct Point3 {
        var x: CGFloat, y: CGFloat, z: CGFloat
        static func + (a: Point3, b: Point3) -> Point3 { Point3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func * (a: Point3, k: CGFloat) -> Point3 { Point3(x: a.x * k, y: a.y * k, z: a.z * k) }
    }
    /// The room is drawn flat, with no perspective: the floor circle squashed to an ellipse (`floorTilt`) and
    /// height as a straight lift up the screen (`liftRatio`), so every room circle is an ellipse and every
    /// position a multiply-add. A small linear size cue (`sizeCue`) keeps the rear of the room nearer.
    static let floorTilt: CGFloat = 0.42
    static let liftRatio: CGFloat = 0.95
    static let sizeCue: CGFloat = 0.14
    /// The upper layer: raised above the bed, a little inside its ring.
    static let heightReach: CGFloat = 0.78
    static let heightLift: CGFloat = 1.0
    /// The vertical axis through the listener reaches this high.
    static let axisTop: CGFloat = 1.2
    /// A speaker marker's radius, in room units at the listener, and its limits in points.
    static let markerSize: CGFloat = 0.055
    static let markerLimits: ClosedRange<CGFloat> = 5...9
    /// Room kept around the room for the speaker names: above the markers and to either side.
    static let labelTop: CGFloat = 12
    static let labelSide: CGFloat = 16

    /// Unfitted screen offset of a room point (y down), and its size cue: 1 at the listener, larger toward the rear.
    static func flat(_ p: Point3) -> (point: CGPoint, scale: CGFloat) {
        (CGPoint(x: p.x, y: -(p.z * floorTilt + p.y * liftRatio)), 1 - sizeCue * p.z)
    }

    /// Where a speaker at `azimuth` stands in the room: on the bed ring at ear level, or raised in the upper layer.
    static func roomPoint(azimuth: Double, height: Bool) -> Point3 {
        let radians = azimuth * .pi / 180
        let reach = height ? heightReach : 1
        return Point3(x: CGFloat(sin(radians)) * reach, y: height ? heightLift : 0, z: CGFloat(cos(radians)) * reach)
    }

    /// A speaker in the room (L and R slide to front centre in Mono); LFE, which has no direction, at the listener.
    func position(_ speaker: Speaker) -> Point3 {
        guard let azimuth = azimuth(speaker) else { return Point3(x: 0, y: 0, z: 0) }
        return Self.roomPoint(azimuth: azimuth, height: speaker.group == .height)
    }

    /// A room point on screen and its size cue. Points lower on screen are nearer, so drawing in screen order
    /// top to bottom lays near over far.
    func project(_ p: Point3) -> (point: CGPoint, scale: CGFloat) {
        let raw = Self.flat(p)
        return (CGPoint(x: stageOrigin.x + raw.point.x * stageScale, y: stageOrigin.y + raw.point.y * stageScale), raw.scale)
    }

    func point(_ p: Point3) -> CGPoint { project(p).point }

    /// A speaker marker's radius where `p` stands.
    func markerRadius(_ p: Point3) -> CGFloat {
        let minimum = compactRoom ? max(2.5, min(5, stageScale / 12)) : Self.markerLimits.lowerBound
        let base = min(Self.markerLimits.upperBound, max(minimum, stageScale * Self.markerSize))
        return base * Self.flat(p).scale
    }

    /// Dense layouts in a short well keep orientation labels; the full channel names remain in Channel Levels.
    var compactRoom: Bool { speakers.count > 8 && stageScale < 64 }

    // MARK: Stereometer (Stereo)

    /// Level scale of the stereometer's cloud: a sample at this level or below sits at the centre, 0 dBFS on the rim.
    static let scopeFloor: Float = -60
    /// Band rims just outside the plot: one arc per band, the lowest innermost.
    static let rimGap: CGFloat = 7
    static let rimPitch: CGFloat = 5
    /// Room kept outside the plot for the rims and the L, M, R labels.
    static let scopeMargin: CGFloat = rimGap + rimPitch * CGFloat(StereoBands.count - 1) + 16
    static let legendHeight: CGFloat = 18

    /// The stereometer's half disc, in Stereo: a polar sample plot, mid (L+R) straight up and side (R−L) to the
    /// right, so a mono sample points to M, a sample on L alone to the upper left (−45°), on R alone to the upper
    /// right (+45°), and an out-of-phase one lies along the horizon. Distance from the centre is the sample's level.
    /// The band legend shows while the stereometer keeps a 40 pt radius with it; in a shorter room (a 720p
    /// screen) it folds away and the rims' colours name the bands.
    var showsScopeLegend: Bool { Self.showsLegend(wellHeight: stageWell.height) }
    static func showsLegend(wellHeight: CGFloat) -> Bool { wellHeight - 20 - legendHeight - 6 - scopeMargin - 16 >= 40 }
    /// A point of the plot: `angle` in degrees from M (−90 = −S, +90 = +S), `fraction` of the radius.
    func scopePoint(angle: Double, fraction: CGFloat) -> CGPoint {
        let radians = angle * .pi / 180
        let radius = scopeRadius * fraction
        return CGPoint(x: scopeCenter.x + CGFloat(sin(radians)) * radius, y: scopeCenter.y - CGFloat(cos(radians)) * radius)
    }
    /// A cloud sample's offset in a unit semicircle (up is negative y). Normalising the mid/side vector
    /// directly avoids converting each dot to an angle and immediately back through sine and cosine.
    static func scopeSample(left: Float, right: Float) -> CGPoint? {
        let amplitude = (left * left + right * right).squareRoot()
        guard amplitude > 0.001, amplitude.isFinite else { return nil }
        let fraction = scopeFraction(decibels: 20 * log10(amplitude))
        guard fraction > 0 else { return nil }
        var mid = Double(left) + Double(right), side = Double(right) - Double(left)
        if mid < 0 { mid = -mid; side = -side }
        let scale = Double(fraction) / hypot(mid, side)
        return CGPoint(x: side * scale, y: -mid * scale)
    }
    /// Radius of a band's rim arc.
    func rimRadius(_ band: Int) -> CGFloat { scopeRadius + Self.rimGap + Self.rimPitch * CGFloat(band) }
    /// Where the L, M and R labels sit: beyond the outermost rim.
    func scopeLabel(angle: Double) -> CGPoint {
        scopePoint(angle: angle, fraction: (rimRadius(StereoBands.count - 1) + 10) / max(1, scopeRadius))
    }
    /// Width kept in each lower corner of the well for the stereometer's readings (BALANCE, WIDTH, LEVEL).
    static let readingColumn: CGFloat = 72
    /// The band legend under the plot, on the readings' line between them.
    var scopeLegend: CGRect {
        let inner = stageWell.insetBy(dx: 12, dy: 10)
        let side = min(Self.readingColumn, inner.width / 4)
        return CGRect(x: inner.minX + side, y: inner.maxY - Self.legendHeight, width: max(1, inner.width - side * 2),
                      height: Self.legendHeight)
    }
    /// Where a sample's level lands on the radius.
    static func scopeFraction(decibels db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - scopeFloor) / -scopeFloor)))
    }

    /// Where a speaker's name sits: just above its marker and level ring, or under the listener for LFE.
    func label(_ speaker: Speaker) -> CGPoint {
        let at = position(speaker)
        let projected = point(at)
        guard speaker.azimuth != nil else { return CGPoint(x: projected.x, y: projected.y + 14) }
        return CGPoint(x: projected.x, y: projected.y - markerRadius(at) - 12)
    }
}
