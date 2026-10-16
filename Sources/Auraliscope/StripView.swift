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
        case .spectrum: return .flexible(2.3)
        case .waveform: return .flexible(1.4)
        }
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
        let flexibleCount = CGFloat(wants.filter { if case .flexible = $0 { return true } else { return false } }.count)
        // Without flexible panels the fixed ones share the room in proportion; with them, the fixed ones give way
        // only once the flexible ones would drop below their minimum.
        let scale: CGFloat
        if weights == 0 {
            scale = fixed > 0 ? room / fixed : 1
        } else {
            scale = min(1, max(0.55, (room - flexibleCount * minFlexible) / max(1, fixed)))
        }
        let flexibleRoom = max(0, room - fixed * scale)
        return wants.map { want in
            switch want {
            case .fixed(let width): return (width * scale).rounded()
            case .flexible(let weight): return (flexibleRoom * weight / weights).rounded(.down)
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
            let panels = placement.stripPanels.filter { !placement.detached.contains($0) }
            let inner = CGSize(width: proxy.size.width - 2 * StripLayout.gap, height: proxy.size.height - 2 * StripLayout.gap)
            let widths = StripLayout.widths(panels, width: inner.width - StripLayout.controls - StripLayout.gap,
                                            height: inner.height, spatial: model.format == .spatial,
                                            channels: model.format == .spatial ? model.shownLayout.speakers.count : 2)
            HStack(spacing: StripLayout.gap) {
                StripControls(model: model)
                    .frame(width: StripLayout.controls)
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
                }
                if panels.isEmpty {
                    Text(L("Choose the strip's panels with the button on the left."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environment(\.panelContext, .strip)
            .padding(StripLayout.gap)
        }
        // No title bar in the strip: the panels run up to the window's top edge.
        .ignoresSafeArea(.container, edges: .top)
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
            StripPanelsMenu()
            DiscButton(symbol: "rectangle.expand.vertical", help: L("Leave the strip (⌥⌘S)"), diameter: 26) {
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
        DiscButton(symbol: "rectangle.split.3x1", help: L("Strip panels"), diameter: 26, on: open) { open.toggle() }
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
            Eyebrow(L("STRIP PANELS"), color: Theme.title)
            VStack(spacing: 2) {
                ForEach(orderedPanels) { panel in
                    let included = placement.stripPanels.contains(panel)
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { included }, set: { _ in placement.toggleStripPanel(panel) })) {
                            Label(panel.title, systemImage: panel.symbol)
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 4)
                        if included {
                            Button { placement.moveStripPanel(panel, by: -1) } label: { Image(systemName: "chevron.left") }
                                .disabled(placement.stripPanels.first == panel)
                                .help(L("Move Left"))
                            Button { placement.moveStripPanel(panel, by: 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(placement.stripPanels.last == panel)
                                .help(L("Move Right"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(height: 24)
                }
            }
            Divider()
            HStack {
                Button(L("Dock to Bottom")) { placement.dockStrip() }
                    .help(L("Full width along the bottom of this screen"))
                Spacer()
                Button(L("Reset")) { placement.setStripPanels(PanelPlacement.defaultStrip) }
            }
            .controlSize(.small)
            Text(L("Drag the strip's top edge to change its height. It remembers where you leave it."))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The strip's panels in their order first, then the rest in the window's order.
    private var orderedPanels: [MeterPanel] {
        placement.stripPanels + MeterPanel.allCases.filter { !placement.stripPanels.contains($0) }
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
