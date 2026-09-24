import AppKit
import CoreAudio
import SwiftUI

/// Sections of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, audio, channels, metering, appearance

    static let defaultsKey = "settingsPane"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .audio: return L("Audio")
        case .channels: return L("Channels")
        case .metering: return L("Metering")
        case .appearance: return L("Appearance")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "mic"
        case .channels: return "hifispeaker.2"
        case .metering: return "gauge.with.dots.needle.33percent"
        case .appearance: return "paintpalette"
        }
    }
}

extension MeterModel {
    /// Opens the Settings window, optionally on a given pane.
    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.defaultsKey) }
        showSettings = true
    }
}

/// Settings as a page of its own: a sidebar of five panes and a scrolling detail column of grouped cards.
struct SettingsView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsPane.defaultsKey) private var paneName = SettingsPane.general.rawValue

    private var pane: SettingsPane { SettingsPane(rawValue: paneName) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .layoutPriority(1)
                .frame(maxHeight: .infinity)
                .background(Theme.windowTop.opacity(0.9))
            Rectangle().fill(Theme.hairline.opacity(Theme.dark ? 0.09 : 0.11)).frame(width: 0.5)
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(pane.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(.leading, 4)
                        switch pane {
                        case .general: GeneralPane(model: model)
                        case .audio: AudioPane(model: model)
                        case .channels: ChannelsPane(model: model)
                        case .metering: MeteringPane(model: model)
                        case .appearance: AppearancePane()
                        }
                    }
                    .frame(width: min(640, max(0, geometry.size.width - 52)), alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.top, 20)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geometry.size.width)
            }
            // The detail column owns its viewport width even when a control has a wide intrinsic size.
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            .background(Theme.windowBottom)
        }
        .frame(minWidth: 740, minHeight: 520)
        .background(UtilityWindowProbe(title: L("Settings"), capture: Diagnostics.showSettings))
        .tint(Theme.action)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            BrandMark(size: 10)
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                StatusDot(running: model.running)
                Text((model.running ? L("Live") : L("Paused")).uppercased(with: l10n.locale))
                    .font(.system(size: 10, weight: .bold).width(.expanded)).tracking(l10n.tracking(0.8))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
            Text(model.formatSummary)
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            ForEach(SettingsPane.allCases) { item in
                SidebarItem(title: item.title, symbol: item.symbol, selected: item == pane) { paneName = item.rawValue }
            }
            Spacer()
            SidebarItem(title: L("About Auraliscope"), symbol: "info.circle", selected: false) {
                openWindow(id: "about")
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
    }
}

private struct SidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.sage : Theme.secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.sage.opacity(0.16) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage("showWelcomeOnLaunch") private var showWelcomeOnLaunch = true

    var body: some View {
        SettingsSection(title: L("LANGUAGE")) {
            SettingsRow(title: L("Language")) {
                Picker(L("Language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in Text(verbatim: language.nativeName).tag(language) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsNote(L("Switches instantly; metering carries on. Menu items supplied by macOS follow at the next launch. The meter itself keeps its English labels (units, channel names, modes, panel titles), as on consoles and DAWs."))
        }
        SettingsSection(title: L("WINDOW")) {
            SettingsRow(title: L("Full screen")) {
                Button(L("Toggle Full Screen")) { MainWindow.toggleFullScreen() }
            }
            SettingsNote(L("Or use the green window button, or View ▸ Enter Full Screen (⌃⌘F). Always on top pauses in full screen."))
        }
        SettingsSection(title: L("STARTUP")) {
            SettingsRow(title: L("Show welcome at launch")) {
                Toggle(L("Show welcome at launch"), isOn: $showWelcomeOnLaunch).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
    }
}

private struct AudioPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        SettingsSection(title: L("DEVICE")) {
            SettingsRow(title: L("Source")) {
                HStack(spacing: 6) {
                    Picker(L("Source"), selection: Binding(get: { model.selectedID }, set: model.select)) {
                        let inputs = model.devices.filter { !$0.output }, outputs = model.devices.filter(\.output)
                        Section(L("Inputs")) {
                            Text(L("No input device")).tag(SourceID.none)
                            ForEach(inputs) { device in
                                Text(verbatim: "\(device.name) · \(device.channels) ch").tag(device.id)
                            }
                        }
                        Section(L("Outputs · what apps play to them")) {
                            Text(L("No output device")).tag(SourceID.noOutput)
                            ForEach(outputs) { device in
                                Text(verbatim: "\(L("%@ (output)", device.name)) · \(device.channels) ch").tag(device.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Button(action: model.refreshDevices) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help(L("Refresh devices"))
                }
            }
            Divider()
            SettingsRow(title: L("Status")) {
                Text(model.status.text)
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.status.text)
            }
            SettingsNote(L("Inputs are read directly. An output (macOS 14.2 or later) is read through a Core Audio tap: Auraliscope meters what every app plays to it, such as your DAW's monitor or headphone bus, without changing or delaying the signal."))
        }
        SettingsSection(title: L("PRIVACY")) {
            SettingsRow(title: L("Microphone access")) { PermissionControl() }
            SettingsNote(L("Needed to meter any input. After changing it in System Settings, click the arrow to check again."))
            Divider()
            SettingsRow(title: L("System audio recording")) {
                Button(L("Open System Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            }
            SettingsNote(L("Needed to meter an output. macOS asks when output capture starts. If the meters stay silent, allow Auraliscope in Privacy & Security → Screen & System Audio Recording, then choose the output again."))
        }
    }
}

private struct ChannelsPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        SettingsSection(title: L("FORMAT")) {
            // The four-segment mode picker gets a full-width row of its own: beside the diagram it made the
            // pane wider than the window's default size.
            HStack(alignment: .center, spacing: 16) {
                LayoutDiagram(layout: model.speakerLayout)
                    .frame(width: 96, height: 96)
                SettingsRow(title: L("Multi Channel format")) {
                    Picker(L("Multi Channel format"), selection: $model.speakerLayout) {
                        ForEach(SpeakerLayout.allCases) { layout in
                            Text(L("%@ · %d channels", layout.name, layout.channelCount)).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Monitoring mode"))
                    .font(.system(size: 13))
                Picker(L("Monitoring mode"), selection: $model.formatMode) {
                    ForEach(FormatMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            SettingsNote(L("Multi Channel shows every channel of this format in Soundstage and Waveform; Stereo shows L and R; Mono reads only the input routed to L. Auto picks Mono when a single input is routed, and otherwise follows the programme between Stereo and Multi Channel."))
        }
        SettingsSection(title: L("ROUTING")) {
            HStack {
                Text(verbatim: model.selectedDevice.map { "\($0.output ? L("%@ (output)", $0.name) : $0.name) · \($0.channels) ch" } ?? L("No audio device"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("Default Order")) { model.resetAssignment() }
                    .help(L("Input 1 to the first channel, input 2 to the second, and so on"))
            }
            .frame(minHeight: 34)
            ForEach(model.speakerLayout.groups, id: \.self) { group in
                Divider()
                HStack(spacing: 6) {
                    Capsule().fill(Theme.groupColor(group)).frame(width: 8, height: 3)
                    Text(group.localizedName.uppercased(with: l10n.locale))
                        .font(.system(size: 9, weight: .semibold).width(.expanded)).tracking(l10n.tracking(1))
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                }
                .padding(.top, 8)
                ForEach(model.speakerLayout.speakers.filter { $0.group == group }, id: \.role) { speaker in
                    RoutingRow(model: model, speaker: speaker)
                }
            }
            SettingsNote(L("Routing is saved per device and format. A change restarts capture and resets Integrated LUFS. LFE shows Peak and RMS but is excluded from LUFS, per BS.1770."))
        }
    }
}

private struct RoutingRow: View {
    @ObservedObject var model: MeterModel
    let speaker: Speaker
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        SettingsRow(title: speaker.name, monospaced: true) {
            Picker(selection: Binding(get: { model.sourceForRole[speaker.role] },
                                      set: { model.assign(role: speaker.role, source: $0) })) {
                Text(L("Off")).tag(Int32(-1))
                ForEach(0..<Int(min(model.selectedDevice?.channels ?? 0, 64)), id: \.self) { source in
                    Text(model.selectedDevice?.output == true ? L("Output %d", source + 1) : L("Input %d", source + 1)).tag(Int32(source))
                }
            } label: {
                Text(speaker.name)
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .frame(minHeight: 28)
    }
}

private struct MeteringPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        SettingsSection(title: L("MEASUREMENT")) {
            SettingsRow(title: L("Reset measurements")) {
                Button(L("Reset")) { model.resetMeasurements() }
            }
            SettingsNote(L("Momentary, Short-term and Integrated LUFS follow ITU-R BS.1770-5, including its gating. Range follows EBU Tech 3342. True Peak is measured with 4× oversampling below 96 kHz."))
            SettingsNote(L("Set the loudness target and True Peak ceiling from the TARGET and CEILING menus on the loudness summary. Stereo and Multi Channel each keep their own."))
        }
    }
}

private struct AppearancePane: View {
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some View {
        SettingsSection(title: L("INTERFACE")) {
            HStack(spacing: 18) {
                ForEach(AppearanceMode.allCases) { mode in
                    AppearanceOption(mode: mode, palette: theme.palette, selected: theme.mode == mode) { theme.mode = mode }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .padding(.bottom, 10)
            SettingsNote(L("Auto follows macOS. The sun and moon button in the toolbar, or View ▸ Appearance, switches between Light and Dark at any time."))
        }
        SettingsSection(title: L("COLOR")) {
            SettingsRow(title: L("Color theme")) {
                ThemePicker(selection: Binding(get: { theme.palette.rawValue },
                                               set: { theme.palette = Theme.Palette(rawValue: $0) ?? .sage }))
                    .frame(width: 205, height: 26)
            }
            SettingsNote(L("The accent colors controls, traces and level meters in both appearances. In Light it is deepened just enough to stay legible on white."))
        }
    }
}

/// One choice of Auto | Light | Dark, shown as macOS shows its own: a miniature of the meter window drawn with
/// the palette that appearance would use, ringed in the accent when selected.
private struct AppearanceOption: View {
    let mode: AppearanceMode
    let palette: Theme.Palette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                MeterMiniature(mode: mode, palette: palette)
                    .frame(width: 118, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.hairline.opacity(0.16), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(Theme.dark ? 0.25 : 0.10), radius: 3, y: 1)
                    .padding(3.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Theme.action : .clear, lineWidth: 2.5)
                    }
                Text(mode.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The meter window in a few strokes: title bar, the tinted loudness summary, the analyzer column with a
/// spectrum trace, and the Soundstage column with level bars. Auto shows light and dark split on a diagonal.
private struct MeterMiniature: View {
    let mode: AppearanceMode
    let palette: Theme.Palette

    var body: some View {
        let light = Theme.Style(palette: palette, dark: false), dark = Theme.Style(palette: palette, dark: true)
        switch mode {
        case .light: sketch(light)
        case .dark: sketch(dark)
        case .system:
            ZStack {
                sketch(light)
                sketch(dark).mask {
                    GeometryReader { proxy in
                        Path { path in
                            let size = proxy.size
                            path.move(to: CGPoint(x: size.width * 0.62, y: 0))
                            path.addLine(to: CGPoint(x: size.width, y: 0))
                            path.addLine(to: CGPoint(x: size.width, y: size.height))
                            path.addLine(to: CGPoint(x: size.width * 0.38, y: size.height))
                            path.closeSubpath()
                        }
                    }
                }
            }
        }
    }

    private func sketch(_ style: Theme.Style) -> some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func fill(_ rect: CGRect, _ radius: CGFloat, _ color: Color) {
                context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(color))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [style.windowTop.color, style.windowBottom.color]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            // Traffic lights and the mode selector.
            for (index, hex) in [0xEC6A5E, 0xF4BF4F, 0x61C554].enumerated() {
                context.fill(Path(ellipseIn: CGRect(x: 5 + CGFloat(index) * 5, y: 4, width: 3, height: 3)),
                             with: .color(Theme.RGB(hex: UInt32(hex)).color))
            }
            fill(CGRect(x: w * 0.36, y: 3.5, width: w * 0.28, height: 4), 2, style.ink.color.opacity(0.14))
            // Loudness summary: a wash of the accent under the big reading.
            let hero = CGRect(x: 5, y: 11, width: w - 10, height: h * 0.25)
            context.fill(Path(roundedRect: hero, cornerRadius: 3.5, style: .continuous),
                         with: .linearGradient(Gradient(colors: [style.banner.color.opacity(0.92), style.windowBottom.color]),
                                               startPoint: hero.origin, endPoint: CGPoint(x: hero.maxX, y: hero.maxY)))
            fill(CGRect(x: hero.minX + 4, y: hero.minY + hero.height * 0.42, width: hero.width * 0.2, height: 5), 1.5,
                 style.ink.color.opacity(0.9))
            fill(CGRect(x: hero.minX + hero.width * 0.32, y: hero.minY + 4, width: hero.width * 0.34, height: 2.5), 1.25,
                 style.accent.color)
            for column in 0..<3 {
                fill(CGRect(x: hero.minX + hero.width * (0.32 + CGFloat(column) * 0.118), y: hero.minY + 9,
                            width: hero.width * 0.105, height: hero.height - 13), 1.5,
                     style.dark ? style.ink.color.opacity(0.07) : Color.white.opacity(0.65))
            }
            fill(CGRect(x: hero.minX + hero.width * 0.70, y: hero.minY + 3, width: hero.width * 0.28, height: hero.height - 6), 2,
                 style.display.color)
            // Analyzer and Soundstage cards, each with its display well.
            let top = hero.maxY + 4
            let left = CGRect(x: 5, y: top, width: w * 0.6, height: h - top - 5)
            let right = CGRect(x: left.maxX + 4, y: top, width: w - left.maxX - 9, height: left.height)
            for card in [left, right] { fill(card, 3.5, style.card.color) }
            let plot = left.insetBy(dx: 3, dy: 3)
            fill(plot, 2.5, style.display.color)
            var trace = Path()
            for step in 0...24 {
                let x = plot.minX + 2 + CGFloat(step) / 24 * (plot.width - 4)
                let t = CGFloat(step) / 24
                let y = plot.minY + plot.height * (0.45 + 0.22 * t - 0.18 * exp(-pow((t - 0.2) * 7, 2)) - 0.12 * exp(-pow((t - 0.72) * 9, 2)))
                if step == 0 { trace.move(to: CGPoint(x: x, y: y)) } else { trace.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(trace, with: .color(style.accent.color), lineWidth: 1.1)
            let well = right.insetBy(dx: 3, dy: 3)
            fill(well, 2.5, style.display.color)
            for (row, level) in [0.78, 0.66, 0.84, 0.42, 0.58].enumerated() {
                let bar = CGRect(x: well.minX + 3, y: well.minY + 4 + CGFloat(row) * (well.height - 6) / 5,
                                 width: well.width - 6, height: 2.5)
                fill(bar, 1.25, style.ink.color.opacity(0.10))
                let hue = level > 0.8 ? style.ochre : style.accent
                fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * level, height: bar.height), 1.25, hue.color)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Building blocks

extension SpeakerGroup {
    /// Group name in Settings, in the current language; the Soundstage on the meter prints `groupTitles`.
    var localizedName: String {
        switch self {
        case .front: return L("Front")
        case .lfe: return "LFE"
        case .surround: return L("Surround")
        case .height: return L("Height")
        }
    }
}

/// A top-down sketch of a layout: bed ring, height ring and one dot per speaker in its group colour.
struct LayoutDiagram: View {
    let layout: SpeakerLayout

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let bed = min(size.width, size.height) / 2 - 10
            let top = bed * 0.54
            func ring(_ r: CGFloat, dashed: Bool, color: Color) {
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color),
                               style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
            }
            ring(bed, dashed: false, color: Theme.ink.opacity(0.18))
            if layout.heightCount > 0 { ring(top, dashed: true, color: Theme.heather.opacity(0.45)) }
            for speaker in layout.speakers {
                let color = Theme.groupColor(speaker.group)
                guard let azimuth = speaker.azimuth else {
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)),
                                   with: .color(color.opacity(0.8)), lineWidth: 1.2)
                    continue
                }
                let r = speaker.group == .height ? top : bed
                let d = SoundstageLayout.direction(azimuth)
                let p = CGPoint(x: c.x + d.dx * r, y: c.y + d.dy * r)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
            }
            context.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Theme.ink.opacity(0.7)))
        }
        .background(Theme.display.opacity(Theme.dark ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(Text(verbatim: layout.name))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(Localizer.shared.tracking(0.6))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.09 : 0.10), lineWidth: 0.5)
                }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var monospaced = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            // The title never truncates; long control labels (device names, targets) do instead.
            Text(title)
                .font(monospaced ? .system(size: 13, weight: .medium).monospaced() : .system(size: 13))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 36)
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .lineSpacing(Localizer.shared.paragraphSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
    }
}
