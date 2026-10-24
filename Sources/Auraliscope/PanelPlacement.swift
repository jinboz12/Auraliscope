import AppKit
import SwiftUI

/// The meter's panels, each one card. Every panel is drawn in exactly one place at a time (the main window's grid,
/// the enlarged view, a window of its own or the strip): their Metal scenes are kept per kind (`SceneStore`), so two
/// canvases of one kind would advance the same history twice per frame.
enum MeterPanel: String, CaseIterable, Codable, Hashable, Identifiable {
    case loudness, history, vu, spectrum, waveform, soundstage, levels, multiFFT

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loudness: return L("Loudness")
        case .history: return L("Loudness History")
        case .vu: return "VU"
        case .spectrum: return L("Spectrogram & Spectrum")
        case .multiFFT: return L("Multi-FFT Spectrum (Beta)")
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
        case .multiFFT: return "chart.xyaxis.line"
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
        case .multiFFT: return CGSize(width: 900, height: 420)
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
        case .multiFFT: return CGSize(width: 460, height: 240)
        case .waveform: return CGSize(width: 420, height: 200)
        case .soundstage: return CGSize(width: 320, height: 300)
        case .levels: return CGSize(width: 300, height: 320)
        }
    }
}

/// Where each panel is shown: enlarged over the main window, in a window of its own, hidden, and which panels the
/// horizontal strip carries in which order. Hidden panels and the strip's panels are kept across launches; enlarged
/// and detached panels are not (each launch opens the full window).
@MainActor
final class PanelPlacement: ObservableObject {
    static let shared = PanelPlacement()

    static let hiddenKey = "layout.hiddenPanels"
    static let stripKey = "strip.panels"
    static let stripWidthsKey = "strip.widths"
    static let defaultStrip: [MeterPanel] = [.loudness, .spectrum, .waveform, .soundstage, .levels, .vu]

    /// The panel filling the main window, or nil for the full arrangement.
    @Published private(set) var enlarged: MeterPanel?
    /// The enlarged panel on its way in or out (`PanelZoom`), and while it fills the window.
    @Published private(set) var zoom: PanelZoom?
    /// Steps of an earlier zoom still on their way are dropped.
    private var zoomGeneration = 0
    /// Panels shown in windows of their own.
    @Published private(set) var detached: Set<MeterPanel> = []
    /// Panels the user took out of the main window.
    @Published private(set) var hidden: Set<MeterPanel>
    /// The main window shows the horizontal strip instead of the full arrangement.
    @Published private(set) var strip = false
    /// The main window on its way into or out of the strip.
    @Published private(set) var morph: StripMorph?
    /// The window's title bar and toolbar are hidden: in the strip, and from the start of the way into it.
    var chromeHidden: Bool { morph.map { $0.entering } ?? strip }
    /// The full arrangement's and the strip's sizes when last laid out, which they keep through the morph.
    private(set) var windowContentSize: CGSize = .zero
    private(set) var stripContentSize: CGSize = .zero
    /// The strip's panels, in order.
    @Published private(set) var stripPanels: [MeterPanel]
    @Published private(set) var dockSupportsMultiFFT = true
    func setDockSupportsMultiFFT(_ supported: Bool) {
        if dockSupportsMultiFFT != supported { dockSupportsMultiFFT = supported }
    }
    var usesMultiFFTInDock: Bool { dockSupportsMultiFFT && isShown(.multiFFT) }
    var displayedStripPanels: [MeterPanel] {
        DockSpectrumPolicy.displayed(stripPanels.map(\.rawValue), useMultiFFT: usesMultiFFTInDock)
            .compactMap(MeterPanel.init(rawValue:))
    }
    var dockMenuPanels: [MeterPanel] {
        MeterPanel.allCases.filter { $0 != .multiFFT }.map { $0 == .spectrum && usesMultiFFTInDock ? .multiFFT : $0 }
    }
    var displayedStripShares: [MeterPanel: CGFloat] {
        let raw = Dictionary(uniqueKeysWithValues: stripShares.map { ($0.key.rawValue,Double($0.value)) })
        return Dictionary(uniqueKeysWithValues: DockSpectrumPolicy.displayedShares(raw, useMultiFFT: usesMultiFFTInDock)
            .compactMap { key,value in MeterPanel(rawValue:key).map { ($0,CGFloat(value)) } })
    }
    func stripIncludes(_ panel: MeterPanel) -> Bool {
        stripPanels.contains(Self.stripSlot(panel))
    }
    static func stripSlot(_ panel: MeterPanel) -> MeterPanel { panel == .multiFFT ? .spectrum : panel }
    private static func canonicalStrip(_ panels: [MeterPanel]) -> [MeterPanel] {
        DockSpectrumPolicy.canonical(panels.map(\.rawValue)).compactMap(MeterPanel.init(rawValue:))
    }
    /// The widths the user gave the strip's panels with the dividers between them, as shares of the strip's room;
    /// a panel without one takes its automatic width (`StripLayout.widths`).
    @Published private(set) var stripShares: [MeterPanel: CGFloat]

    private var windows: [MeterPanel: NSWindow] = [:]
    /// A detached panel still needs fresh numbers when the main window is minimised or covered.
    var hasVisiblePanelWindows: Bool {
        windows.values.contains { $0.occlusionState.contains(.visible) }
    }
    /// The main window's frame before it became the strip.
    private var frameBeforeStrip: NSRect?
    /// The window is moving into or out of the strip: its moves are ours, not the user's, so none is saved as the
    /// strip's frame (a late one would store the full window's).
    private var settling = false
    /// The window is being resized into or out of the strip (`move`).
    private var resizing = false

    private func settle() {
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.settling = false }
    }
    static let stripFrameName = "AuraliscopeStripWindow"

    private init() {
        let defaults = UserDefaults.standard
        hidden = Set((defaults.string(forKey: Self.hiddenKey) ?? "").split(separator: ",").compactMap { MeterPanel(rawValue: String($0)) })
        stripPanels = Self.canonicalStrip(Self.decode(defaults.string(forKey: Self.stripKey)) ?? Self.defaultStrip)
        stripShares = Self.decodeShares(defaults.string(forKey: Self.stripWidthsKey))
        if !defaults.bool(forKey: MultiFFTPreferences.optInKey) { hidden.insert(.multiFFT) }
        // Never leave the window empty: a saved state with every panel hidden starts with all of them.
        if hidden.count == MeterPanel.allCases.count { hidden = [.multiFFT] }
    }

    static func decode(_ text: String?) -> [MeterPanel]? {
        guard let text, !text.isEmpty else { return nil }
        let panels = text.split(separator: ",").compactMap { MeterPanel(rawValue: String($0)) }
        return panels.isEmpty ? nil : panels
    }

    /// "panel:share,…", shares between 0 and 1.
    static func decodeShares(_ text: String?) -> [MeterPanel: CGFloat] {
        var shares: [MeterPanel: CGFloat] = [:]
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let panel = MeterPanel(rawValue: String(parts[0])), let share = Double(parts[1]),
                  share > 0, share < 1 else { continue }
            shares[panel] = CGFloat(share)
        }
        let raw = Dictionary(uniqueKeysWithValues: shares.map { ($0.key.rawValue,Double($0.value)) })
        return Dictionary(uniqueKeysWithValues: DockSpectrumPolicy.canonicalShares(raw)
            .compactMap { key,value in MeterPanel(rawValue:key).map { ($0,CGFloat(value)) } })
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
        if panel == .multiFFT { UserDefaults.standard.set(shown, forKey: MultiFFTPreferences.optInKey) }
        withAnimation(.panelMove) { hidden = next }
        if !shown, enlarged == panel { dropZoom() }
        UserDefaults.standard.set(MeterPanel.allCases.filter(next.contains).map(\.rawValue).joined(separator: ","), forKey: Self.hiddenKey)
    }

    func showAll() {
        withAnimation(.panelMove) { hidden = UserDefaults.standard.bool(forKey: MultiFFTPreferences.optInKey) ? [] : [.multiFFT] }
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
    }

    /// Replaces the hidden set (a layout preset).
    /// Takes up the stored panels again after a settings preset rewrote them: which show, the dock's and their widths.
    func reloadStored() {
        let defaults = UserDefaults.standard
        setHidden(Set((defaults.string(forKey: Self.hiddenKey) ?? "").split(separator: ",").compactMap { MeterPanel(rawValue: String($0)) }))
        setStripPanels(Self.decode(defaults.string(forKey: Self.stripKey)) ?? Self.defaultStrip)
        stripShares = Self.decodeShares(defaults.string(forKey: Self.stripWidthsKey))
        restore()
    }

    func setHidden(_ panels: Set<MeterPanel>) {
        var valid = panels.count < MeterPanel.allCases.count ? panels : []
        if !UserDefaults.standard.bool(forKey: MultiFFTPreferences.optInKey) { valid.insert(.multiFFT) }
        withAnimation(.panelMove) { hidden = valid }
        UserDefaults.standard.set(MeterPanel.allCases.filter(valid.contains).map(\.rawValue).joined(separator: ","), forKey: Self.hiddenKey)
    }

    func toggleEnlarged(_ panel: MeterPanel) {
        guard !strip else { return }
        if detached.contains(panel) { return focusWindow(panel) }
        if enlarged == panel { restore() } else { enlarge(panel) }
    }

    /// The panel grows out of its place in the grid to fill the window while the rest of the grid recedes. Its card is
    /// laid over its place and starts growing on the next frame; once the card's canvas has drawn (two frames), the
    /// grid's copy under it steps aside for an empty card, and once the zoom has settled the grid leaves the window.
    private func enlarge(_ panel: MeterPanel) {
        // Another panel enlarged, or still on its way: the new one starts from the full arrangement.
        if enlarged != nil || zoom != nil { dropZoom() }
        let generation = nextZoom()
        zoom = PanelZoom(panel: panel, moving: true)
        afterZoomStep(Self.zoomFrame, generation) { [self] in
            withAnimation(.panelZoom) {
                zoom?.expanded = true
                zoom?.moving = true
                enlarged = panel
            }
            afterZoomStep(Self.zoomHandover, generation) { [self] in zoom?.placeholder = true }
            afterZoomStep(Self.zoomArrival, generation) { [self] in withAnimation(Self.textReturn) { zoom?.moving = false } }
            afterZoomStep(Self.zoomDuration, generation) { [self] in zoom?.gridShown = false }
        }
    }

    /// The enlarged panel shrinks back into its place while the grid, back under it, comes forward; once it has
    /// arrived its text returns, then the grid's own copy takes over, and two frames later, once that has drawn, the
    /// zoomed card leaves.
    func restore() {
        guard let panel = enlarged else { return }
        let generation = nextZoom()
        if zoom == nil { zoom = PanelZoom(panel: panel, expanded: true, gridShown: false, placeholder: true) }
        zoom?.placeholder = true
        zoom?.gridShown = true
        zoom?.moving = true
        afterZoomStep(Self.zoomFrame, generation) { [self] in
            withAnimation(.panelZoom) {
                zoom?.expanded = false
                enlarged = nil
            }
            afterZoomStep(Self.zoomArrival, generation) { [self] in
                withAnimation(Self.textReturn) { zoom?.moving = false }
                afterZoomStep(Self.textReturnDuration, generation) { [self] in
                    zoom?.placeholder = false
                    afterZoomStep(Self.zoomHandover, generation) { [self] in zoom = nil }
                }
            }
        }
    }

    /// The full arrangement at once, without the zoom (a panel enlarged is hidden, detached or the strip starts).
    private func dropZoom() {
        _ = nextZoom()
        zoom = nil
        enlarged = nil
    }

    /// How long the zoom takes to settle (`Animation.panelZoom`), and to come within a few points of its place, when the
    /// plots' text returns; the frame the zoomed card is laid out in before it moves; and the two frames a new canvas
    /// needs to draw before its other copy steps aside.
    private static let zoomDuration = 0.46
    private static let zoomArrival = 0.3
    private static let zoomFrame = 0.017
    private static let zoomHandover = 0.034
    /// The plots' text fading back in once the zoom has settled.
    private static let textReturnDuration = 0.16
    private static var textReturn: Animation { .easeOut(duration: textReturnDuration) }

    private func nextZoom() -> Int {
        zoomGeneration += 1
        return zoomGeneration
    }

    private func afterZoomStep(_ delay: Double, _ generation: Int, _ step: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.zoomGeneration == generation else { return }
                step()
            }
        }
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
        if enlarged == panel { dropZoom() }
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

    func setStripPanels(_ requested: [MeterPanel]) {
        let panels = Self.canonicalStrip(requested)
        guard !panels.isEmpty else { return NSSound.beep() }
        withAnimation(.panelMove) { stripPanels = panels }
        UserDefaults.standard.set(panels.map(\.rawValue).joined(separator: ","), forKey: Self.stripKey)
    }

    func toggleStripPanel(_ requested: MeterPanel) {
        let panel = Self.stripSlot(requested)
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

    func moveStripPanel(_ requested: MeterPanel, by offset: Int) {
        let panel = Self.stripSlot(requested)
        guard let index = stripPanels.firstIndex(of: panel) else { return }
        let target = index + offset
        guard stripPanels.indices.contains(target) else { return }
        var next = stripPanels
        next.swapAt(index, target)
        setStripPanels(next)
    }

    /// The strip shows the spectrogram and the live spectrum as two cards side by side (`SpectrumPanel`), so the
    /// canvases draw the waterfall alone and the spectrum on its own horizontal axes.
    var splitsSpectrum: Bool { strip && displayedStripPanels.contains(.spectrum) && !detached.contains(.spectrum) }
    /// Stores the strip's panel widths (from a divider drag) as shares of `room`.
    func setStripWidths(_ widths: [MeterPanel: CGFloat], room: CGFloat) {
        guard room > 0 else { return }
        let raw = Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue,Double($0.value)) })
        stripShares = Dictionary(uniqueKeysWithValues: DockSpectrumPolicy.canonicalShares(raw)
            .compactMap { key,value in MeterPanel(rawValue:key).map { ($0,min(0.99,max(0.01,CGFloat(value)/room))) } })
        UserDefaults.standard.set(stripShares.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\(String(format: "%.4f", Double($0.value)))" }.joined(separator: ","),
            forKey: Self.stripWidthsKey)
    }

    /// The strip's panels go back to their automatic widths.
    func resetStripWidths() {
        withAnimation(.panelMove) { stripShares = [:] }
        UserDefaults.standard.removeObject(forKey: Self.stripWidthsKey)
    }

    /// The strip goes to the Dock (its window controls are hidden, so ⌘M and the strip's own button do this).
    func minimizeStrip() {
        guard let window = MainWindow.window, !window.isMiniaturized else { return }
        MainWindow.miniaturize(window)
    }

    func toggleStrip() { strip ? leaveStrip() : enterStrip() }

    /// The main window becomes one long strip along the bottom of its screen, full width, as a mini meter.
    /// The full arrangement's frame is kept and comes back on leaving. The strip's own frame is remembered.
    /// The title bar goes and the full arrangement fades, holding its picture and its size, while the window glides
    /// down to the bottom of its screen, full width; there the strip, laid out at its own size, fades in. The full
    /// arrangement's frame is kept and comes back on leaving. The strip's own frame is remembered.
    func enterStrip() {
        guard !strip, !resizing, morph == nil, let window = MainWindow.window else { return }
        if window.styleMask.contains(.fullScreen) {
            // Leave full screen first; the strip follows once the window is back on the desktop.
            MainWindow.toggleFullScreen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.enterStrip() }
            return
        }
        frameBeforeStrip = window.frame
        settle()
        dropZoom()
        // A strip already laid out once this session is built at its size before the glide and arrives during its last
        // part; the first one, whose size is not known yet, is laid out once the window is there.
        let early = stripContentSize != .zero
        morph = StripMorph(entering: true, prepared: early)
        MainWindow.setChromeHidden(true)
        withAnimation(.stripFade(out: true)) { morph?.outgoing = false }
        DiagnosticLog.event("Strip: on")
        DispatchQueue.main.async { [self] in
            let screen = window.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return self.finishMorph() }
            var target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: StripLayout.defaultHeight)
            if let saved = UserDefaults.standard.string(forKey: Self.stripFrameName) {
                let frame = NSRectFromString(saved)
                // A strip frame no shorter than half its screen is the full window's, stored by an earlier build's
                // race on the way out; the strip then docks afresh.
                if frame.width >= StripLayout.minWidth, frame.height < visible.height / 2,
                   NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    target = frame
                }
            }
            self.move(window, to: target) { [weak self] in
                guard let self else { return }
                if !self.strip { self.strip = true }
                MinimizeRouter.route()
                if !early { DispatchQueue.main.async { self.arrive() } }
            }
            if early {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalLead) { [weak self] in
                    guard let self, self.morph?.entering == true else { return }
                    self.strip = true
                    DispatchQueue.main.async { self.arrive() }
                }
            }
        }
    }

    /// The strip fades, holding its picture, while the title bar returns and the window glides back to the full
    /// arrangement's frame; the arrangement, built at its own size from the start, fades in once the window is there.
    func leaveStrip() {
        guard strip, !resizing, morph == nil, let window = MainWindow.window else { if !resizing, morph == nil { strip = false }; return }
        saveStripFrame(window)
        settle()
        let target = frameBeforeStrip ?? NSRect(x: window.frame.minX, y: window.frame.minY, width: 1400, height: 900)
        morph = StripMorph(entering: false, prepared: true)
        strip = false
        MainWindow.setChromeHidden(false)
        withAnimation(.stripFade(out: true)) { morph?.outgoing = false }
        DiagnosticLog.event("Strip: off")
        DispatchQueue.main.async { [self] in
            // Built at its own size from the start, the arrangement fades in during the last part of the glide.
            self.move(window, to: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalLead) { [weak self] in self?.arrive() }
        }
    }

    /// The view arriving fades in, and the morph ends once it has and the window has its frame.
    private func arrive() {
        guard morph != nil, !(morph?.incoming ?? true) else { return }
        withAnimation(.stripFade(out: false)) { morph?.incoming = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalDuration) { [weak self] in self?.finishMorph() }
    }

    private func finishMorph() {
        guard morph != nil else { return }
        // Still gliding: once the window has its frame.
        guard !resizing else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.finishMorph() }
        }
        morph = nil
    }

    /// How far into the window's glide the view arriving starts to fade in, and how long it takes.
    private static let arrivalLead = 0.2
    private static let arrivalDuration = 0.24

    /// Records the main window's content size, the full arrangement's or the strip's, while neither is on its way.
    func noteContentSize(_ size: CGSize) {
        guard morph == nil, size.width > 0, size.height > 0 else { return }
        if strip { stripContentSize = size } else { windowContentSize = size }
    }

    /// Resizes the window into or out of the strip. Through the window's animator rather than `setFrame(animate:)`,
    /// whose animation holds the main thread (about 0.4 s into the strip), so the meters froze until it ended; this one
    /// leaves the display link drawing every frame. Reduce Motion moves it at once.
    /// The strip toggles are ignored while it runs.
    private func move(_ window: NSWindow, to frame: NSRect, then done: @escaping () -> Void = {}) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            return done()
        }
        resizing = true
        NSAnimationContext.runAnimationGroup({ context in
            // A calm glide: under way at once, easing into place without a snap at the end.
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.75, 0.2, 1)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.resizing = false
                done()
            }
        })
    }

    func saveStripFrame(_ window: NSWindow) {
        guard strip, !settling, !window.styleMask.contains(.fullScreen), !Diagnostics.snapshotRequested else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.stripFrameName)
    }

    /// Snaps the strip back to the bottom edge of its screen, full width.
    func dockStrip() {
        guard strip, let window = MainWindow.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: window.frame.height)
        move(window, to: target) { [weak self] in self?.saveStripFrame(window) }
    }
}

extension Animation {
    /// Panels taking or giving up room: the main window reflowing when one is hidden, shown or detached.
    static var panelMove: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.9)
    }
    /// A panel enlarging to fill the window, and back: a calm glide that settles without overshooting the window's
    /// edges. With Reduce Motion, a short cross-fade instead (`PanelZoom`).
    static var panelZoom: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.94)
    }
    /// The main window's content leaving as it glides into or out of the strip, and arriving once it is there.
    static func stripFade(out: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : (out ? .easeOut(duration: 0.16) : .easeOut(duration: 0.22))
    }
    /// The rest of the grid around a zooming panel: out in a moment as the panel starts to grow, back in as it lands.
    static func panelGridFade(out: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : (out ? .easeOut(duration: 0.14) : .easeOut(duration: 0.2).delay(0.16))
    }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The main window into the strip (`entering`) or out of it. The view leaving holds its picture and its size while it
/// fades (`outgoing` turns false at once, animated) and the window glides; the view arriving is shown once the window
/// has its frame, at its own size, and fades in (`incoming`).
struct StripMorph: Equatable {
    let entering: Bool
    /// The view arriving is in the window from the start, hidden and holding still, so it is built before the glide
    /// rather than during it: always on the way out, and on the way in once the strip's size is known.
    var prepared = false
    var outgoing = true
    var incoming = false
}

/// A panel enlarging: its card grows out of its place in the grid (`ZoomSources`) to fill the window, and shrinks back.
/// A panel's scene is drawn in one place at a time, so while the zoomed card is over the grid, the grid shows an empty
/// card in its place (`placeholder`), and the grid leaves the window once the panel fills it (`gridShown`).
struct PanelZoom: Equatable {
    let panel: MeterPanel
    /// At full size; else over its place in the grid.
    var expanded = false
    /// The grid is mounted beneath the zoomed card.
    var gridShown = true
    /// The grid shows an empty card in the panel's place.
    var placeholder = false
    /// The card is growing or shrinking: its plots' text rests (`ZoomResting`).
    var moving = false
}

private struct ZoomMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The panel is zooming (`PanelZoom.moving`).
    var zoomMotion: Bool {
        get { self[ZoomMotionKey.self] }
        set { self[ZoomMotionKey.self] = newValue }
    }
}

/// A plot's text (scales, names, readings and hover readouts) steps out while its panel zooms and fades back in as the
/// zoom settles. Laid out afresh at every step of the zoom, it would cost the motion its frames; the plot itself keeps
/// drawing at every size, so the panel still reads as itself on the way.
struct ZoomResting<Content: View>: View {
    @Environment(\.zoomMotion) private var moving
    @ViewBuilder var content: Content

    var body: some View {
        if !moving {
            ZStack(alignment: .topLeading) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }
}

/// Where each panel sits in the main window's grid, in the meter area's coordinates (`ZoomSources.space`): an enlarged
/// panel grows out of its place and shrinks back into it.
struct ZoomSources: PreferenceKey {
    static let space = "meterArea"
    static var defaultValue: [MeterPanel: CGRect] = [:]
    static func reduce(value: inout [MeterPanel: CGRect], nextValue: () -> [MeterPanel: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this grid panel's place (`ZoomSources`), and while the panel is zoomed over it shows an empty card there.
    func zoomSource(_ panel: MeterPanel) -> some View { modifier(ZoomSource(panel: panel)) }
}

private struct ZoomSource: ViewModifier {
    let panel: MeterPanel
    @ObservedObject private var placement = PanelPlacement.shared

    func body(content: Content) -> some View {
        Group {
            if let zoom = placement.zoom, zoom.panel == panel, zoom.placeholder {
                GlassCard { Color.clear }
            } else {
                content
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ZoomSources.self, value: [panel: proxy.frame(in: .named(ZoomSources.space))])
            }
        }
    }
}

/// The zoomed card's frame, laid out afresh at every step of the zoom, so the panel's text and its canvas (which both
/// place everything from the panel's live size) move as one.
struct ZoomFrame: ViewModifier, Animatable {
    var rect: CGRect
    var animatableData: CGRect.AnimatableData {
        get { rect.animatableData }
        set { rect.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .offset(x: rect.minX, y: rect.minY)
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
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var items: some View {
        switch context {
        case .grid, .enlarged:
            Button { placement.toggleEnlarged(panel) } label: {
                Label(placement.enlarged == panel ? L("Restore Panel") : L("Enlarge Panel"),
                      systemImage: placement.enlarged == panel ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Button { placement.requestWindow(panel) } label: { Label(L("Open in New Window"), systemImage: "macwindow.badge.plus") }
            Divider()
            Button { placement.setShown(panel, false) } label: { Label(L("Hide Panel"), systemImage: "eye.slash") }
        case .window:
            Button { placement.closeWindow(panel) } label: { Label(L("Return to Main Window"), systemImage: "macwindow") }
        case .strip:
            Button { placement.moveStripPanel(panel, by: -1) } label: { Label(L("Move Left"), systemImage: "arrow.left") }
                .disabled(placement.displayedStripPanels.first == panel)
            Button { placement.moveStripPanel(panel, by: 1) } label: { Label(L("Move Right"), systemImage: "arrow.right") }
                .disabled(placement.displayedStripPanels.last == panel)
            Button { placement.requestWindow(panel) } label: { Label(L("Open in New Window"), systemImage: "macwindow.badge.plus") }
            Divider()
            Button { placement.toggleStripPanel(panel) } label: { Label(L("Remove from Dock"), systemImage: "minus.circle") }
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
        case .strip: return L("Arrange this panel in the dock")
        }
    }
}

/// Where a panel is being drawn, so its title row offers what fits there.

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
        Group { content }.modifier(PanelRenderingScope(panel: panel))
    }

    @ViewBuilder private var content: some View {
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
        case .multiFFT:
            MultiFFTPanel(model: model)
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
                            target: target, model: model, panel: .history, title: span.heading,
                            newest: readouts.values.historyTime)
        } else {
            PanelTimeline(interval: 1) {
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
        var floating = false { didSet { if floating != oldValue { applyLevel() } } }
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

/// The Minimize item's target: the meter window in the strip through `MainWindow.miniaturize`, any other window
/// as AppKit would.
final class MinimizeRouter: NSObject, NSMenuItemValidation {
    static let shared = MinimizeRouter()

    /// Window ▸ Minimize (⌘M) targets the router, so it also minimizes the strip, whose window buttons are hidden.
    /// The item keeps its action, so `SystemMenus` still finds and localizes it by it. Runs after every menu pass.
    @MainActor
    static func route() {
        SystemMenus.afterRelocalize = route
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(NSWindow.performMiniaturize(_:)), item.target !== shared { item.target = shared }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
    }

    @objc func performMiniaturize(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return NSSound.beep() }
            if window === MainWindow.window, PanelPlacement.shared.strip {
                PanelPlacement.shared.minimizeStrip()
            } else {
                window.performMiniaturize(sender)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
            return window.styleMask.contains(.miniaturizable) && !window.isMiniaturized
        }
    }
}
