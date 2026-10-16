import AppKit
import SwiftUI

/// The meter's panels, each one card. Every panel is drawn in exactly one place at a time (the main window's grid,
/// the enlarged view, a window of its own or the strip): their Metal scenes are kept per kind (`SceneStore`), so two
/// canvases of one kind would advance the same history twice per frame.
enum MeterPanel: String, CaseIterable, Codable, Hashable, Identifiable {
    case loudness, history, vu, spectrum, waveform, soundstage, levels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loudness: return L("Loudness")
        case .history: return L("Loudness History")
        case .vu: return "VU"
        case .spectrum: return L("Spectrogram & Spectrum")
        case .waveform: return L("Waveform")
        case .soundstage: return L("Soundstage")
        case .levels: return L("Channel Levels")
        }
    }

    var symbol: String {
        switch self {
        case .loudness: return "gauge.with.dots.needle.33percent"
        case .history: return "chart.xyaxis.line"
        case .vu: return "gauge.open.with.lines.needle.33percent"
        case .spectrum: return "waveform.path.ecg.rectangle"
        case .waveform: return "waveform"
        case .soundstage: return "circle.circle"
        case .levels: return "chart.bar.fill"
        }
    }

    /// ⌘1…⌘7 enlarge the panels in the order they read in the window.
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((MeterPanel.allCases.firstIndex(of: self) ?? 0) + 1))) }

    /// A window of its own opens at this size the first time.
    var windowSize: CGSize {
        switch self {
        case .loudness: return CGSize(width: 760, height: 260)
        case .history: return CGSize(width: 620, height: 300)
        case .vu: return CGSize(width: 460, height: 320)
        case .spectrum: return CGSize(width: 1000, height: 560)
        case .waveform: return CGSize(width: 900, height: 360)
        case .soundstage: return CGSize(width: 560, height: 600)
        case .levels: return CGSize(width: 520, height: 560)
        }
    }

    /// Smallest window that keeps the panel legible.
    var minimumSize: CGSize {
        switch self {
        case .loudness: return CGSize(width: 640, height: 190)
        case .history: return CGSize(width: 280, height: 160)
        case .vu: return CGSize(width: 240, height: 200)
        case .spectrum: return CGSize(width: 520, height: 260)
        case .waveform: return CGSize(width: 420, height: 200)
        case .soundstage: return CGSize(width: 320, height: 300)
        case .levels: return CGSize(width: 300, height: 320)
        }
    }

    /// The panels of the summary row.
    var inSummary: Bool { self == .loudness || self == .history || self == .vu }
}

/// Where each panel is shown: enlarged over the main window, in a window of its own, hidden, and which panels the
/// horizontal strip carries in which order. Hidden panels and the strip's panels are kept across launches; enlarged
/// and detached panels are not (each launch opens the full window).
@MainActor
final class PanelPlacement: ObservableObject {
    static let shared = PanelPlacement()

    static let hiddenKey = "layout.hiddenPanels"
    static let stripKey = "strip.panels"
    static let defaultStrip: [MeterPanel] = [.loudness, .spectrum, .waveform, .soundstage, .levels, .vu]

    /// The panel filling the main window, or nil for the full arrangement.
    @Published var enlarged: MeterPanel?
    /// Panels shown in windows of their own.
    @Published private(set) var detached: Set<MeterPanel> = []
    /// Panels the user took out of the main window.
    @Published private(set) var hidden: Set<MeterPanel>
    /// The main window shows the horizontal strip instead of the full arrangement.
    @Published private(set) var strip = false
    /// The strip's panels, in order.
    @Published private(set) var stripPanels: [MeterPanel]

    private var windows: [MeterPanel: NSWindow] = [:]
    /// The main window's frame before it became the strip.
    private var frameBeforeStrip: NSRect?
    static let stripFrameName = "AuraliscopeStripWindow"

    private init() {
        let defaults = UserDefaults.standard
        hidden = Set((defaults.string(forKey: Self.hiddenKey) ?? "").split(separator: ",").compactMap { MeterPanel(rawValue: String($0)) })
        stripPanels = Self.decode(defaults.string(forKey: Self.stripKey)) ?? Self.defaultStrip
        // Never leave the window empty: a saved state with every panel hidden starts with all of them.
        if hidden.count == MeterPanel.allCases.count { hidden = [] }
    }

    static func decode(_ text: String?) -> [MeterPanel]? {
        guard let text, !text.isEmpty else { return nil }
        let panels = text.split(separator: ",").compactMap { MeterPanel(rawValue: String($0)) }
        return panels.isEmpty ? nil : panels
    }

    // MARK: Main window

    /// Panels drawn in the main window's arrangement: neither hidden nor in a window of their own.
    func inGrid(_ panel: MeterPanel) -> Bool { !hidden.contains(panel) && !detached.contains(panel) }

    func isShown(_ panel: MeterPanel) -> Bool { !hidden.contains(panel) }

    func setShown(_ panel: MeterPanel, _ shown: Bool) {
        var next = hidden
        if shown { next.remove(panel) } else { next.insert(panel) }
        // The last panel stays.
        guard next.count < MeterPanel.allCases.count else { return NSSound.beep() }
        withAnimation(.panelMove) { hidden = next }
        if !shown, enlarged == panel { enlarged = nil }
        UserDefaults.standard.set(MeterPanel.allCases.filter(next.contains).map(\.rawValue).joined(separator: ","), forKey: Self.hiddenKey)
    }

    func showAll() {
        withAnimation(.panelMove) { hidden = [] }
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
    }

    /// Replaces the hidden set (a layout preset).
    func setHidden(_ panels: Set<MeterPanel>) {
        let valid = panels.count < MeterPanel.allCases.count ? panels : []
        withAnimation(.panelMove) { hidden = valid }
        UserDefaults.standard.set(MeterPanel.allCases.filter(valid.contains).map(\.rawValue).joined(separator: ","), forKey: Self.hiddenKey)
    }

    func toggleEnlarged(_ panel: MeterPanel) {
        guard !strip else { return }
        if detached.contains(panel) { return focusWindow(panel) }
        withAnimation(.panelZoom) { enlarged = enlarged == panel ? nil : panel }
    }

    func restore() {
        guard enlarged != nil else { return }
        withAnimation(.panelZoom) { enlarged = nil }
    }

    // MARK: Windows of their own

    /// A panel whose window the main window should open (menus cannot open windows themselves).
    @Published var windowRequest: MeterPanel?

    func requestWindow(_ panel: MeterPanel) {
        guard !detached.contains(panel) else { return focusWindow(panel) }
        willDetach(panel)
        windowRequest = panel
    }

    /// Takes the panel out of the main window before its window opens, so its scene is never drawn twice.
    func willDetach(_ panel: MeterPanel) {
        if enlarged == panel { enlarged = nil }
        withAnimation(.panelMove) { _ = detached.insert(panel) }
    }

    func attached(_ panel: MeterPanel, window: NSWindow) {
        windows[panel] = window
        if !detached.contains(panel) { detached.insert(panel) }
    }

    /// The panel's window closed: it returns to the main window.
    func returned(_ panel: MeterPanel) {
        windows[panel] = nil
        guard detached.contains(panel) else { return }
        withAnimation(.panelMove) { _ = detached.remove(panel) }
    }

    func focusWindow(_ panel: MeterPanel) { windows[panel]?.makeKeyAndOrderFront(nil) }

    func closeWindow(_ panel: MeterPanel) { windows[panel]?.close() }

    /// The main window is closing: the panels' windows go with it.
    func closeAllWindows() { for window in windows.values { window.close() } }

    // MARK: Strip

    func setStripPanels(_ panels: [MeterPanel]) {
        guard !panels.isEmpty else { return NSSound.beep() }
        withAnimation(.panelMove) { stripPanels = panels }
        UserDefaults.standard.set(panels.map(\.rawValue).joined(separator: ","), forKey: Self.stripKey)
    }

    func toggleStripPanel(_ panel: MeterPanel) {
        if let index = stripPanels.firstIndex(of: panel) {
            var next = stripPanels
            next.remove(at: index)
            setStripPanels(next)
        } else {
            // In the main window's reading order.
            setStripPanels(MeterPanel.allCases.filter { stripPanels.contains($0) || $0 == panel }
                .sorted { (stripPanels.firstIndex(of: $0) ?? 99, MeterPanel.allCases.firstIndex(of: $0)!)
                    < (stripPanels.firstIndex(of: $1) ?? 99, MeterPanel.allCases.firstIndex(of: $1)!) })
        }
    }

    func moveStripPanel(_ panel: MeterPanel, by offset: Int) {
        guard let index = stripPanels.firstIndex(of: panel) else { return }
        let target = index + offset
        guard stripPanels.indices.contains(target) else { return }
        var next = stripPanels
        next.swapAt(index, target)
        setStripPanels(next)
    }

    func toggleStrip() { strip ? leaveStrip() : enterStrip() }

    /// The main window becomes one long strip along the bottom of its screen, full width, as a mini meter.
    /// The full arrangement's frame is kept and comes back on leaving. The strip's own frame is remembered.
    func enterStrip() {
        guard !strip, let window = MainWindow.window else { return }
        if window.styleMask.contains(.fullScreen) {
            // Leave full screen first; the strip follows once the window is back on the desktop.
            MainWindow.toggleFullScreen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.enterStrip() }
            return
        }
        frameBeforeStrip = window.frame
        enlarged = nil
        strip = true
        MainWindow.setChromeHidden(true)
        DiagnosticLog.event("Strip: on")
        DispatchQueue.main.async {
            let screen = window.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            var target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: StripLayout.defaultHeight)
            if let saved = UserDefaults.standard.string(forKey: Self.stripFrameName) {
                let frame = NSRectFromString(saved)
                if frame.width >= StripLayout.minWidth, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    target = frame
                }
            }
            window.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    func leaveStrip() {
        guard strip, let window = MainWindow.window else { strip = false; return }
        saveStripFrame(window)
        let target = frameBeforeStrip ?? NSRect(x: window.frame.minX, y: window.frame.minY, width: 1400, height: 900)
        window.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        strip = false
        MainWindow.setChromeHidden(false)
        DiagnosticLog.event("Strip: off")
    }

    func saveStripFrame(_ window: NSWindow) {
        guard strip, !window.styleMask.contains(.fullScreen), !Diagnostics.snapshotRequested else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.stripFrameName)
    }

    /// Snaps the strip back to the bottom edge of its screen, full width.
    func dockStrip() {
        guard strip, let window = MainWindow.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: window.frame.height)
        window.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        saveStripFrame(window)
    }
}

extension Animation {
    /// Panels taking or giving up room: the main window reflowing when one is hidden, shown or detached.
    static var panelMove: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.9)
    }
    /// A panel enlarging to fill the window, and back. With Reduce Motion, a short cross-fade instead.
    static var panelZoom: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86)
    }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A round control's face, as `DiscButton` draws it, for controls that are menus.
struct DiscFace: View {
    let symbol: String
    var diameter: CGFloat = 22
    var hovering = false
    var lit = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.43, weight: .semibold))
            .foregroundStyle(lit ? Theme.onLit : (hovering ? Theme.ink : Theme.secondary))
            .frame(width: diameter, height: diameter)
            .background {
                if lit {
                    Circle().fill(Theme.lit)
                        .shadow(color: Theme.litHalo, radius: 11)
                        .shadow(color: .black.opacity(Theme.dark ? 0 : 0.16), radius: 2, y: 1)
                } else {
                    Circle().fill(hovering ? Theme.controlHover : Theme.controlFill)
                        .overlay {
                            Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(Theme.dark ? 0.12 : 0.9),
                                                                          Color.white.opacity(Theme.dark ? 0.0 : 0.2)],
                                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                        }
                }
            }
            .contentShape(Circle())
    }
}

// MARK: - The panel's own control

/// The window control at the trailing end of every panel's title row: a small disc whose menu enlarges the panel to
/// fill the main window (or restores it), opens it in a window of its own (or brings it back), or hides it.
struct PanelWindowButton: View {
    let panel: MeterPanel
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.panelContext) private var context
    @State private var hovering = false

    var body: some View {
        Group {
            if context == .strip {
                // In the strip a click opens the menu: there is no one main thing to do.
                Menu { items } label: { disc }
            } else {
                Menu { items } label: { disc } primaryAction: {
                    // A click does the panel's main thing; the menu (hold) holds the rest.
                    switch context {
                    case .grid, .enlarged: placement.toggleEnlarged(panel)
                    case .window: placement.closeWindow(panel)
                    case .strip: break
                    }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var items: some View {
        switch context {
        case .grid, .enlarged:
            Button(placement.enlarged == panel ? L("Restore Panel") : L("Enlarge Panel")) { placement.toggleEnlarged(panel) }
            Button(L("Open in New Window")) { placement.requestWindow(panel) }
            Divider()
            Button(L("Hide Panel")) { placement.setShown(panel, false) }
        case .window:
            Button(L("Return to Main Window")) { placement.closeWindow(panel) }
        case .strip:
            Button(L("Move Left")) { placement.moveStripPanel(panel, by: -1) }
                .disabled(placement.stripPanels.first == panel)
            Button(L("Move Right")) { placement.moveStripPanel(panel, by: 1) }
                .disabled(placement.stripPanels.last == panel)
            Button(L("Open in New Window")) { placement.requestWindow(panel) }
            Divider()
            Button(L("Remove from Strip")) { placement.toggleStripPanel(panel) }
        }
    }

    private var disc: some View {
        DiscFace(symbol: icon, hovering: hovering, lit: lit)
    }

    private var lit: Bool { context == .enlarged }

    private var icon: String {
        switch context {
        case .grid: return "arrow.up.left.and.arrow.down.right"
        case .enlarged: return "arrow.down.right.and.arrow.up.left"
        case .window: return "rectangle.portrait.and.arrow.forward"
        case .strip: return "ellipsis"
        }
    }

    private var help: String {
        switch context {
        case .grid: return L("Enlarge this panel (click), or open it in a window of its own (hold)")
        case .enlarged: return L("Restore the full window (Esc)")
        case .window: return L("Return this panel to the main window")
        case .strip: return L("Arrange this panel in the strip")
        }
    }
}

/// Where a panel is being drawn, so its title row offers what fits there.
enum PanelContext { case grid, enlarged, window, strip }

private struct PanelContextKey: EnvironmentKey { static let defaultValue = PanelContext.grid }

extension EnvironmentValues {
    var panelContext: PanelContext {
        get { self[PanelContextKey.self] }
        set { self[PanelContextKey.self] = newValue }
    }
}

extension PanelKind {
    var meterPanel: MeterPanel {
        switch self {
        case .loudness: return .loudness
        case .history: return .history
        case .vu: return .vu
        case .spectrum: return .spectrum
        case .waveform: return .waveform
        case .soundstage: return .soundstage
        case .levels: return .levels
        }
    }
}

// MARK: - One panel, wherever it is shown

/// Draws `panel` at the size it is given.
struct PanelView: View {
    let panel: MeterPanel
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        switch panel {
        case .loudness:
            LoudnessPanel(model: model, readouts: model.readouts)
        case .history:
            LoudnessHistoryPanel(model: model, readouts: model.readouts)
        case .vu:
            VUMeterPanel(model: model, readouts: model.readouts)
        case .spectrum:
            SpectrumPanel(model: model, sampleRate: model.sampleRate,
                          source: spectrumSource(format: model.format, layoutName: model.shownLayoutName))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Spectrogram and spectrum, 20 Hz to 20 kHz, last 3 to 8 seconds"))
        case .waveform:
            WaveformPanel(model: model, layout: model.shownLayout, format: model.format, activeRoles: model.routedRoles)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Waveform of each channel, last 4 seconds"))
        case .soundstage:
            SoundstagePanel(model: model, activeRoles: model.routedRoles, format: model.format, layout: model.shownLayout)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Soundstage: channel map"))
        case .levels:
            ChannelLevelsPanel(model: model, readouts: model.readouts, activeRoles: model.routedRoles,
                               format: model.format, layout: model.shownLayout)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Channel levels: Peak and RMS meters per channel, and correlation in Stereo"))
        }
    }
}

/// The loudness history panel, wherever it is shown: the readouts' last 15 s, or a longer span from the session log,
/// redrawn once a second.
struct LoudnessHistoryPanel: View {
    let model: MeterModel
    @ObservedObject var readouts: Readouts
    @AppStorage(HistorySpan.key) private var spanKey = HistorySpan.fifteen.rawValue
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let span = HistorySpan(rawValue: spanKey) ?? .fifteen
        let target = Float(model.loudnessTarget)
        if span == .fifteen {
            LoudnessHistory(short: readouts.values.shortHistory, momentary: readouts.values.momentaryHistory,
                            target: target, model: model, panel: .history, title: span.heading)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let log = readouts.session
                let seconds = span.seconds ?? max(60, log.seconds)
                let window = log.window(seconds: span.seconds, points: 360)
                LoudnessHistory(short: window.short, momentary: window.momentary, target: target, model: model,
                                panel: .history, seconds: seconds, covered: min(1, log.seconds / seconds), title: span.heading)
            }
        }
    }
}

// MARK: - A panel's own window

enum PanelWindow {
    static let sceneID = "panel"
}

/// The contents of a panel's window: the window's backdrop and the panel filling it.
struct PanelWindowContent: View {
    let panel: MeterPanel
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        PanelView(panel: panel, model: model)
            .environment(\.panelContext, .window)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .padding(.top, 30)
            .frame(minWidth: panel.minimumSize.width, minHeight: panel.minimumSize.height)
            .background { WindowBackdrop() }
            .background(PanelWindowProbe(panel: panel, title: panel.title, floating: model.floating))
            .tint(Theme.action)
    }
}

/// Configures a panel's window like the meter's: transparent title bar over the backdrop, its own remembered frame,
/// floating with the meter, available over its full-screen Space, and never restored at launch (the panel would be
/// in the main window then).
private struct PanelWindowProbe: NSViewRepresentable {
    let panel: MeterPanel
    let title: String
    let floating: Bool

    func makeNSView(context: Context) -> Probe { Probe(panel: panel) }
    func updateNSView(_ view: Probe, context: Context) {
        view.title = title
        view.floating = floating
    }

    final class Probe: NSView {
        let panel: MeterPanel
        var title = "" { didSet { window?.title = title } }
        var floating = true { didSet { if floating != oldValue { applyLevel() } } }
        private var closeObserver: NSObjectProtocol?

        init(panel: MeterPanel) {
            self.panel = panel
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

        private func applyLevel() { window?.level = floating ? .floating : .normal }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.title = title
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = true
            window.isRestorable = false
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.tabbingMode = .disallowed
            applyLevel()
            let name = "AuraliscopePanelWindow." + panel.rawValue
            if window.frameAutosaveName != name {
                window.setFrameAutosaveName(name)
                if !window.setFrameUsingName(name) {
                    window.setContentSize(panel.windowSize)
                    window.center()
                }
            }
            let panel = self.panel
            MainActor.assumeIsolated { PanelPlacement.shared.attached(panel, window: window) }
            if closeObserver == nil {
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                       queue: .main) { _ in
                    MainActor.assumeIsolated { PanelPlacement.shared.returned(panel) }
                }
            }
        }
    }
}
