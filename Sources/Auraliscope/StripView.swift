import AnalysisCore
import AppKit
import SwiftUI

/// The horizontal strip: the main window as one long row of panels along the bottom of a 16:9 screen, like a mini
/// meter under a DAW's mixer. The panels are the full window's own (same scenes, same settings); the loudness panel
/// is set compactly for the strip's height. Which panels it carries and their order are the user's.
enum StripLayout {
    static let defaultHeight: CGFloat = 232
    static let minHeight: CGFloat = 150
    static let minWidth: CGFloat = 720
    static let gap: CGFloat = 8
    static let controls: CGFloat = 34
    /// Flexible panels never narrow below this before the fixed ones give way.
    static let minFlexible: CGFloat = 200
    /// The Spectrum panel's two cards (`SpectrumPanel`) need about twice that.
    static let minSpectrum: CGFloat = 400

    /// A fixed width (for a panel of a natural shape) or a share of the flexible room.
    private enum Want { case fixed(CGFloat), flexible(CGFloat) }

    private static func want(_ panel: MeterPanel, height: CGFloat, spatial: Bool, channels: Int) -> Want {
        let plot = max(80, height - 70)
        switch panel {
        case .loudness: return .fixed(height < 190 ? 360 : 400)
        case .vu: return .fixed(min(400, max(240, height * 1.45)))
        // Stereo: the stereometer with its readings in the lower corners and the band legend between them.
        case .soundstage: return .fixed(spatial ? min(460, max(300, plot * 1.8 + 40)) : 440)
        case .levels: return .fixed(spatial ? min(600, max(320, CGFloat(channels) * 30 + 80)) : 440)
        case .history: return .flexible(1)
        // Two cards side by side: the waterfall and the live spectrum (`SpectrumPanel`).
        case .spectrum, .multiFFT: return .flexible(3.4)
        case .waveform: return .flexible(1.4)
        }
    }

    /// The narrowest a divider drag leaves a panel.
    static func dragMinimum(_ panel: MeterPanel) -> CGFloat {
        switch panel {
        case .loudness: return 280
        case .spectrum, .multiFFT: return 320
        case .soundstage, .levels, .vu: return 200
        case .history, .waveform: return 160
        }
    }

    /// Widths for `panels`: the user's `shares` of the room where they set one, the automatic widths for the rest,
    /// together filling the room.
    static func widths(_ panels: [MeterPanel], width: CGFloat, height: CGFloat, spatial: Bool, channels: Int,
                       shares: [MeterPanel: CGFloat]) -> [CGFloat] {
        let automatic = widths(panels, width: width, height: height, spatial: spatial, channels: channels)
        let room = max(0, width - CGFloat(max(0, panels.count - 1)) * gap)
        guard room > 0, panels.contains(where: { shares[$0] != nil }) else { return automatic }
        let fractions = zip(panels, automatic).map { panel, width in shares[panel] ?? width / room }
        let total = fractions.reduce(0, +)
        guard total > 0 else { return automatic }
        return fractions.map { ($0 / total * room).rounded(.down) }
    }

    /// The widths after the divider between panel `index` and the next is dragged to give panel `index` `requested`
    /// points: the pair trades room, each kept to its drag minimum, and the other panels keep theirs.
    static func dragged(_ panels: [MeterPanel], widths: [CGFloat], index: Int, requested: CGFloat) -> [MeterPanel: CGFloat] {
        var next = widths
        let pair = widths[index] + widths[index + 1]
        let low = dragMinimum(panels[index]), high = pair - dragMinimum(panels[index + 1])
        let leading = low <= high ? min(high, max(low, requested)) : pair * widths[index] / max(1, pair)
        next[index] = leading.rounded()
        next[index + 1] = pair - next[index]
        return Dictionary(uniqueKeysWithValues: zip(panels, next))
    }

    /// Widths for `panels` across a strip `width` wide (the controls and gaps excluded) and `height` tall.
    static func widths(_ panels: [MeterPanel], width: CGFloat, height: CGFloat, spatial: Bool, channels: Int) -> [CGFloat] {
        guard !panels.isEmpty else { return [] }
        let room = max(0, width - CGFloat(panels.count - 1) * gap)
        let wants = panels.map { want($0, height: height, spatial: spatial, channels: channels) }
        var fixed: CGFloat = 0, weights: CGFloat = 0
        for want in wants {
            switch want {
            case .fixed(let width): fixed += width
            case .flexible(let weight): weights += weight
            }
        }
        func minimum(_ panel: MeterPanel) -> CGFloat { panel == .spectrum || panel == .multiFFT ? minSpectrum : minFlexible }
        let flexibleMinimum = zip(panels, wants).reduce(CGFloat(0)) { total, pair in
            guard case .flexible = pair.1 else { return total }
            return total + minimum(pair.0)
        }
        // Without flexible panels the fixed ones share the room in proportion; with them, the fixed ones give way
        // only once the flexible ones would drop below their minimum.
        let compactMinimum = fixed*0.55 + flexibleMinimum
        if weights > 0, room < compactMinimum {
            // At very small widths keep every selected panel nonzero instead of giving all space to fixed cards.
            return zip(panels,wants).map { panel,want in
                let base: CGFloat
                switch want { case .fixed(let width): base = width*0.55; case .flexible: base = minimum(panel) }
                return (base*room/max(1,compactMinimum)).rounded(.down)
            }
        }
        let scale: CGFloat
        if weights == 0 {
            scale = fixed > 0 ? room / fixed : 1
        } else {
            scale = min(1, max(0.55, (room - flexibleMinimum) / max(1, fixed)))
        }
        // Each flexible panel has its minimum first (while the room allows); what is left is shared by weight.
        let flexibleRoom = max(0, room - fixed * scale)
        let floor = min(1, flexibleRoom / max(1, flexibleMinimum))
        let surplus = max(0, flexibleRoom - flexibleMinimum)
        return zip(panels, wants).map { panel, want in
            switch want {
            case .fixed(let width): return (width * scale).rounded()
            case .flexible(let weight): return (minimum(panel) * floor + surplus * weight / weights).rounded(.down)
            }
        }
    }
}

struct StripView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let panels = placement.displayedStripPanels.filter { !placement.detached.contains($0) }
            let inner = CGSize(width: proxy.size.width - 2 * StripLayout.gap, height: proxy.size.height - 2 * StripLayout.gap)
            let room = inner.width - StripLayout.controls - StripLayout.gap
            let widths = StripLayout.widths(panels, width: room, height: inner.height, spatial: model.format == .spatial,
                                            channels: model.format == .spatial ? model.shownLayout.speakers.count : 2,
                                            shares: placement.displayedStripShares)
            HStack(spacing: 0) {
                StripControls(model: model)
                    .frame(width: StripLayout.controls)
                Color.clear.frame(width: StripLayout.gap)
                ForEach(Array(panels.enumerated()), id: \.element) { index, panel in
                    Group {
                        if panel == .loudness {
                            StripLoudness(model: model, readouts: model.readouts)
                        } else {
                            PanelView(panel: panel, model: model)
                        }
                    }
                    .frame(width: index < widths.count ? widths[index] : 0)
                    .transition(.opacity)
                    // The gap after each panel but the last resizes it against the next, like the full window's.
                    if index + 1 < panels.count, index + 1 < widths.count {
                        PanelDivider(axis: .horizontal, leading: widths[index],
                                     onResize: { requested in
                                         let next = StripLayout.dragged(panels, widths: widths, index: index, requested: requested)
                                         placement.setStripWidths(next, room: max(1, room - CGFloat(panels.count - 1) * StripLayout.gap))
                                     },
                                     onReset: { placement.resetStripWidths() },
                                     identifier: "strip.gap")
                            .frame(width: StripLayout.gap)
                    }
                }
                if panels.isEmpty {
                    Text(L("Choose the dock's panels with the button on the left."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: max(0, inner.width), height: max(0, inner.height))
            .environment(\.panelContext, .strip)
            .padding(StripLayout.gap)
        }
        .onAppear { model.configureSpectrumArchitecture() }
        .onChange(of: model.format) { _ in model.configureSpectrumArchitecture() }
        .onChange(of: model.sourceIsBridge) { _ in model.configureSpectrumArchitecture() }
        // MeterView measures the full window in Dock mode; keep the padded row inside those same bounds.
    }
}

/// The strip's own controls in a column at its leading edge: the live light, pause and reset, the strip's panels,
/// and the way back to the full window.
private struct StripControls: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        VStack(spacing: 6) {
            StatusLight(running: model.running, paused: !model.running && model.frozen)
                .frame(height: 14)
                .help(model.running ? L("LIVE") : L("PAUSED"))
            DiscButton(symbol: model.running ? "pause.fill" : "play.fill", help: model.captureActionTitle, diameter: 26,
                       fill: model.running ? nil : Theme.action, action: model.toggleCapture)
            DiscButton(symbol: "arrow.counterclockwise",
                       help: L("Reset: clear peak holds and clip latches, and restart Integrated LUFS"), diameter: 26,
                       action: model.resetMeasurements)
            Spacer(minLength: 0)
            DiscButton(symbol: "minus", help: L("Minimize (⌘M)"), diameter: 26) {
                placement.minimizeStrip()
            }
            StripPanelsMenu()
            DiscButton(symbol: "dock.arrow.up.rectangle", help: L("Leave Dock mode (⌥⌘S)"), diameter: 26) {
                placement.leaveStrip()
            }
        }
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .background { DockTrack(radius: StripLayout.controls / 2) }
    }
}

/// The live light: the accent dot with its glow while measuring, a pause bar paused, an empty ring at standby.
private struct StatusLight: View {
    let running: Bool
    let paused: Bool

    var body: some View {
        Group {
            if running {
                Circle().fill(Theme.sage).frame(width: 7, height: 7)
                    .background { Circle().fill(Theme.glow(Theme.sage, 0.5)).frame(width: 14, height: 14).blur(radius: 3) }
            } else if paused {
                Image(systemName: "pause.fill").font(.system(size: 8, weight: .black)).foregroundStyle(Theme.ink)
            } else {
                Circle().strokeBorder(Theme.tertiary, lineWidth: 1).frame(width: 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.18), value: running)
    }
}

/// Which panels the strip carries and in what order, and the strip's placement.
struct StripPanelsMenu: View {
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared
    @State private var open = false

    var body: some View {
        DiscButton(symbol: "rectangle.split.3x1", help: L("Dock panels"), diameter: 26, on: open) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .trailing) {
                StripPanelsForm().padding(14).frame(width: 300)
            }
    }
}

struct StripPanelsForm: View {
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(L("DOCK PANELS"), color: Theme.title)
            VStack(spacing: 2) {
                ForEach(orderedPanels) { panel in
                    let included = placement.stripIncludes(panel)
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { included }, set: { _ in placement.toggleStripPanel(panel) })) {
                            Label(panel.title, systemImage: panel.symbol)
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 4)
                        if included {
                            Button { placement.moveStripPanel(panel, by: -1) } label: { Image(systemName: "chevron.left") }
                                .disabled(placement.displayedStripPanels.first == panel)
                                .help(L("Move Left"))
                            Button { placement.moveStripPanel(panel, by: 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(placement.displayedStripPanels.last == panel)
                                .help(L("Move Right"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(height: 24)
                }
            }
            Divider()
            HStack {
                Button { placement.dockStrip() } label: { Label(L("Move to Bottom"), systemImage: "dock.arrow.down.rectangle") }
                    .help(L("Full width along the bottom of this screen"))
                Spacer()
                Button {
                    placement.setStripPanels(PanelPlacement.defaultStrip)
                    placement.resetStripWidths()
                    UserDefaults.standard.removeObject(forKey: SpectrumPanel.stripShareKey)
                } label: {
                    Label(L("Reset"), systemImage: "arrow.counterclockwise")
                }
                .help(L("The default panels at their automatic widths"))
            }
            .controlSize(.small)
            Text(L("Drag the dock's top edge to change its height, and any gap in it to change the widths on either side (double-click a gap for the automatic widths). It remembers where you leave it."))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The strip's panels in their order first, then the rest in the window's order.
    private var orderedPanels: [MeterPanel] {
        placement.displayedStripPanels + placement.dockMenuPanels.filter { !placement.displayedStripPanels.contains($0) }
    }
}

/// The loudness panel set for the strip: the main reading large with its delta to the target, and the other loudness
/// readings, range and true peak in a grid beside it.
private struct StripLoudness: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(LoudnessReading.key) private var reading = LoudnessReading.shortTerm.rawValue
    @AppStorage(LoudnessUnit.key) private var unitKey = LoudnessUnit.lufs.rawValue

    var body: some View {
        let values = readouts.values
        let unit = LoudnessUnit(rawValue: unitKey) ?? .lufs
        let main = LoudnessReading(rawValue: reading) ?? .shortTerm
        let target = Float(model.loudnessTarget)
        let ceiling = Float(model.truePeakCeiling)
        let value = main.value(values)
        GlassCard {
            GeometryReader { proxy in
                let roomy = proxy.size.height >= 170
                VStack(alignment: .leading, spacing: roomy ? 8 : 4) {
                    HStack(spacing: 8) {
                        Eyebrow(L("LOUDNESS"), color: Theme.title).fixedSize()
                        Text(verbatim: "\(MeterScale.signedInteger(target)) LUFS")
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.tertiary)
                            .help(L("TARGET: the loudness standard of the current mode. The gauge, delta, history band and VU meter read against it. Stereo and Immersive each keep their own and follow the mode."))
                        Spacer(minLength: 4)
                        PanelSettingsButton(panel: .loudness, model: model, window: false)
                        PanelWindowButton(panel: .loudness)
                    }
                    .frame(height: 24)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Eyebrow(main.heading, color: Theme.sage)
                                .lineLimit(1)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                StableNumber(text: unit.text(value, target: target), template: "−88.8",
                                             font: .system(size: roomy ? 38 : 28, weight: .semibold), alignment: .leading)
                                Text(verbatim: unit.title).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.ink.opacity(0.72))
                            }
                            DeltaBadge(value: value, target: target)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The other readings as a hardware meter's readout: the standard abbreviation, the value on
                        // its decimal point and the unit.
                        let truePeak = values.truePeakDecibels
                        VStack(alignment: .leading, spacing: roomy ? 5 : 2) {
                            ForEach(LoudnessReading.allCases.filter { $0 != main }, id: \.self) { other in
                                StripReading(name: other.abbreviation, help: other.title,
                                             value: unit.text(other.value(values), target: target), unit: unit.title)
                            }
                            StripReading(name: "LRA", help: L("RANGE"),
                                         value: values.range < 0 ? "—" : MeterScale.tenths(values.range, floor: -1), unit: "LU")
                            StripReading(name: "TP", help: L("TRUE PEAK"),
                                         value: truePeak > 0.05 ? MeterScale.signedTenths(truePeak) : MeterScale.tenths(truePeak, floor: -119),
                                         unit: "dBTP",
                                         color: truePeak >= 0 ? Theme.ember : (truePeak > ceiling ? Theme.ochre : Theme.ink))
                        }
                        .fixedSize()
                    }
                    if roomy {
                        Spacer(minLength: 0)
                        // The main reading on the summary's gauge, against the target.
                        LoudnessGauge(value: value, target: target, scale: 0.9)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Loudness"))
    }
}

/// One row of the strip's loudness readout: abbreviation, value and unit on fixed columns.
private struct StripReading: View {
    let name: String
    let help: String
    let value: String
    let unit: String
    var color: Color = Theme.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: name)
                .font(.system(size: 9, weight: .semibold).width(.expanded))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 30, alignment: .leading)
            StableNumber(text: value, template: "−88.8", font: .system(size: 15, weight: .medium), color: color)
            Text(verbatim: unit)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 28, alignment: .leading)
        }
        .help(help)
    }
}
