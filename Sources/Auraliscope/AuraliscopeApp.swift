import AppKit
import CoreAudio
import AVFoundation
import SwiftUI

@MainActor
private final class WelcomeCoordinator: ObservableObject {
    @Published var presented = false
    var launchHandled = false
}

@main
struct AuraliscopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MeterModel()
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage("showWelcomeOnLaunch") private var showWelcomeOnLaunch = true
    @StateObject private var welcome = WelcomeCoordinator()

    init() { Diagnostics.runIfRequested() }

    var body: some Scene {
        Window("Auraliscope", id: "meter") {
            MeterView(model: model)
                .modifier(ThemeIdentity())
                .frame(minWidth: 1000, minHeight: 820)
                .onAppear {
                    guard !welcome.launchHandled else { return }
                    welcome.launchHandled = true
                    let inputNeedsPermission = !Diagnostics.demo && model.selectedDevice?.output != true
                        && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
                    if Diagnostics.showWelcome || (!Diagnostics.snapshotRequested && (showWelcomeOnLaunch || inputNeedsPermission)) {
                        welcome.presented = true
                    } else {
                        model.resume()
                    }
                    if Diagnostics.showSettings {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.showSettings = true }
                    }
                }
                .onDisappear { model.stop() }
                .sheet(isPresented: $welcome.presented, onDismiss: { if !model.running { model.resume() } }) {
                    WelcomeSheet(model: model)
                        .modifier(ThemeIdentity())
                }
                .toolbar {
                    ModeItem(model: model)
                    TrailingItems(model: model)
                }
        }
        .defaultSize(width: 1400, height: 1060)
        Window(L("Settings"), id: "settings") {
            SettingsView(model: model)
                .modifier(ThemeIdentity())
        }
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentMinSize)
        Window(L("About Auraliscope"), id: "about") {
            AboutView()
                .modifier(ThemeIdentity())
        }
        .defaultSize(width: 660, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(L("About Auraliscope")) { model.showAbout = true }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { model.openSettings() }
                    .keyboardShortcut(",")
            }
            AppearanceCommands()
            CommandMenu(L("Meter")) {
                Button(model.running ? L("Pause Capture") : L("Start Capture"), action: model.toggleCapture)
                    .keyboardShortcut(.space, modifiers: [])
                Button(L("Reset Measurements"), action: model.resetMeasurements)
                    .keyboardShortcut("r")
                Divider()
                Picker(L("Monitoring Mode"), selection: $model.formatMode) {
                    ForEach(FormatMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Picker(L("Multi Channel Format"), selection: $model.speakerLayout) {
                    ForEach(SpeakerLayout.allCases) { layout in Text(verbatim: layout.name).tag(layout) }
                }
                Divider()
                Button(L("Channel Routing…")) { model.openSettings(.channels) }
                    .keyboardShortcut("k")
            }
        }
    }
}

/// Rebuilds only the contents of a window when its palette changes. Observing the theme in the App
/// itself would invalidate all Window scene declarations, including unopened utility windows.
private struct ThemeIdentity: ViewModifier {
    @ObservedObject private var theme = ThemeSettings.shared

    func body(content: Content) -> some View { content.id(theme.signature) }
}

private struct AppearanceCommands: Commands {
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker(L("Appearance"), selection: $theme.mode) {
                ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Divider()
            Button(L("Toggle Full Screen")) { MainWindow.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.control, .command])
        }
    }
}

/// The Mono | Stereo | Spatial selector (with AUTO) in the centre of the toolbar, as the HIG places a
/// window's view switcher: the leading edge beside the window controls stays clear, which also keeps it free
/// in full screen, where the controls slide in over that corner only when the pointer reaches the top edge.
/// Actions sit at the trailing edge; the brand is in the heading row below.
private struct ModeItem: ToolbarContent {
    let model: MeterModel

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            // The selector draws its own track and thumb, so it opts out of the shared toolbar glass.
            ToolbarItem(placement: .principal) { ModeSelector(model: model) }
                .sharedBackgroundVisibility(.hidden)
            // Without it, macOS 26 packs the primary actions right after the selector instead of at the edge.
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .principal) { ModeSelector(model: model) }
        }
    }
}

/// Trailing cluster: capture controls share one glass capsule; pin, appearance and settings share another.
private struct TrailingItems: ToolbarContent {
    let model: MeterModel

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItemGroup(placement: .primaryAction) { TransportButtons(model: model) }
            // Without the spacer, macOS 26 merges neighbouring items into one shared glass background.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                AlwaysOnTopButton(model: model)
                AppearanceButton()
                SettingsButton(model: model)
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) { TransportButtons(model: model) }
            ToolbarItemGroup(placement: .primaryAction) {
                AlwaysOnTopButton(model: model)
                AppearanceButton()
                SettingsButton(model: model)
            }
        }
    }
}



final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Light, Dark or Auto for the whole app, so system controls, menus, popovers and sheets match the
        // custom surfaces.
        ThemeSettings.shared.attach()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Diagnostics.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Diagnostics.logMenus() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The meter window, registered by its probe so menus and Settings can act on it.
enum MainWindow {
    static weak var window: NSWindow?
    static func toggleFullScreen() {
        guard let window else { return }
        allowFullScreen(window)
        // A floating window cannot become a full-screen Space; `WindowProbe` restores the level on exit.
        if !window.styleMask.contains(.fullScreen) { window.level = .normal }
        guard !window.isKeyWindow else { return window.toggleFullScreen(nil) }
        // AppKit ignores the request for a window that is not key (e.g. from the Settings window's button),
        // so bring the meter forward first and toggle once it has become key.
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window] in window?.toggleFullScreen(nil) }
    }

    /// SwiftUI marks its `Window` scenes `.fullScreenNone`, which makes AppKit ignore the green button and
    /// `toggleFullScreen`; the meter window opts back in as a primary full-screen window. SwiftUI applies its
    /// default again after launch, so `WindowProbe` watches the property and calls this whenever it reverts.
    static func allowFullScreen(_ window: NSWindow) {
        guard window.collectionBehavior.contains(.fullScreenNone) || window.collectionBehavior.contains(.fullScreenAuxiliary)
                || !window.collectionBehavior.contains(.fullScreenPrimary) else { return }
        window.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    /// The green button enters full screen even while the meter floats above other apps: AppKit would only zoom
    /// a floating-level window, so the click goes through `toggleFullScreen`, which drops to the normal level
    /// first (restored on exit). Option-click keeps the standard zoom.
    static func adoptGreenButton(_ window: NSWindow) {
        guard let zoom = window.standardWindowButton(.zoomButton), zoom.action != #selector(GreenButton.press(_:)) else { return }
        zoom.target = GreenButton.shared
        zoom.action = #selector(GreenButton.press(_:))
    }
}

private final class GreenButton: NSObject {
    static let shared = GreenButton()

    @objc func press(_ sender: Any?) {
        MainActor.assumeIsolated {
            if NSEvent.modifierFlags.contains(.option), let window = MainWindow.window, !window.styleMask.contains(.fullScreen) {
                window.zoom(nil)
            } else {
                MainWindow.toggleFullScreen()
            }
        }
    }
}

/// Configures the meter window: native chrome over the vibrancy layer, frame autosave, "always on top",
/// and full screen. A full-screen window gets its own Space, so it drops the floating level while there
/// and restores it on the way out.
private final class WindowProbe: NSView {
    private static let frameName = "AuraliscopeMainWindow"
    var floating = true { didSet { applyLevel() } }
    private var captured = false
    private var observers: [NSObjectProtocol] = []
    private var behaviorObservation: NSKeyValueObservation?

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
        // SwiftUI finishes its own titlebar/toolbar setup after the hosting view lands in the window.
        DispatchQueue.main.async { [weak self] in self?.configure() }
    }

    private var fullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    private func applyLevel() {
        guard let window else { return }
        window.level = floating && !fullScreen ? .floating : .normal
    }

    private func configure() {
        guard let window else { return }
        MainWindow.window = window
        // Standard titled chrome keeps the native traffic lights; full-size content puts them on the vibrancy layer.
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        // The window follows the app's appearance (Light, Dark or Auto) rather than fixing its own.
        window.appearance = nil
        window.isMovableByWindowBackground = true
        // The green button and View ▸ Enter Full Screen take the meter into its own Space.
        MainWindow.allowFullScreen(window)
        MainWindow.adoptGreenButton(window)
        applyLevel()
        if !captured {
            captured = true
            // SwiftUI re-applies `.fullScreenNone` after this setup; opt back in each time it does.
            behaviorObservation = window.observe(\.collectionBehavior, options: [.new]) { window, _ in
                DispatchQueue.main.async {
                    MainWindow.allowFullScreen(window)
                    MainWindow.adoptGreenButton(window)
                }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    guard let window = note.object as? NSWindow else { return }
                    MainWindow.allowFullScreen(window)
                    MainWindow.adoptGreenButton(window)
                })
            }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    guard let self, let window = self.window else { return }
                    // Entering: a floating window would sit above the menu bar reveal; leaving: restore the preference.
                    window.level = note.name == NSWindow.willEnterFullScreenNotification ? .normal : (self.floating ? .floating : .normal)
                })
            }
            // Remember position and size across launches: AppKit restores the saved frame now (clamped to a
            // visible screen) and writes it back on every move or resize. Snapshot runs leave it untouched.
            if !Diagnostics.snapshotRequested {
                window.setFrameAutosaveName(Self.frameName)
                window.setFrameUsingName(Self.frameName)
            }
            // Settings and About snapshots capture their own window instead.
            if !Diagnostics.showAbout && !Diagnostics.showSettings { Diagnostics.captureWindowIfRequested(window) }
            Diagnostics.testFullScreenIfRequested(window)
            Diagnostics.probeWindowIfRequested(window)
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.floating = floating
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) { view.floating = floating }
}

/// Keeps a secondary window (Settings, About) above the floating meter and available over its full-screen Space,
/// and keeps its title in the current language: SwiftUI names a `Window` scene once, when it opens.
struct UtilityWindowProbe: NSViewRepresentable {
    let title: String
    var capture = false
    func makeNSView(context: Context) -> NSView { Probe(title: title, capture: capture) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.title = title }

    private final class Probe: NSView {
        let capture: Bool
        var title: String { didSet { if title != oldValue { window?.title = title } } }
        init(title: String, capture: Bool) {
            self.title = title
            self.capture = capture
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.title = title
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.titlebarAppearsTransparent = true
            window.appearance = nil
            if capture { Diagnostics.captureWindowIfRequested(window) }
        }
    }
}

private struct VibrantWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Slate (or pale grey) dashboard backdrop with a quiet pool of light at the upper edge.
private struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            VibrantWindowBackground()
            LinearGradient(colors: [Theme.windowTop.opacity(0.99), Theme.windowBottom.opacity(0.995)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.dark ? Theme.ink.opacity(0.045) : Color.white.opacity(0.7), .clear],
                           center: .top, startRadius: 0, endRadius: 720)
        }
        .ignoresSafeArea()
    }
}

struct StatusDot: View {
    let running: Bool
    var body: some View {
        Circle()
            .fill(running ? Theme.sage : Theme.tertiary)
            .frame(width: 7, height: 7)
    }
}

private struct TransportButtons: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Button(action: model.toggleCapture) {
            Image(systemName: model.running ? "pause.fill" : "play.fill")
        }
        .help(model.running ? L("Pause Capture") : L("Start Capture"))
        .accessibilityLabel(model.running ? L("Pause Capture") : L("Start Capture"))
        Button(action: model.resetMeasurements) {
            Image(systemName: "arrow.counterclockwise")
        }
        .help(L("Reset: clear peak holds and clip latches, and restart Integrated LUFS"))
        .accessibilityLabel(L("Reset Measurements"))
    }
}

/// Keeps the meter above other windows; the window probe suspends floating while full screen.
private struct AlwaysOnTopButton: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Button { model.floating.toggle() } label: {
            Image(systemName: model.floating ? "pin.fill" : "pin")
                .foregroundStyle(model.floating ? Theme.sage : Theme.secondary)
        }
        .help(L("Always on top"))
        .accessibilityLabel(L("Always on top"))
        .accessibilityValue(model.floating ? L("Enabled") : L("Disabled"))
    }
}

/// Flips between Light and Dark; its symbol is the appearance a click switches to. Settings and
/// View ▸ Appearance also offer Auto.
private struct AppearanceButton: View {
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let label = theme.dark ? L("Switch to Light Appearance") : L("Switch to Dark Appearance")
        Button(action: theme.toggle) {
            if #available(macOS 14, *) {
                Image(systemName: theme.dark ? "sun.max" : "moon")
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: theme.dark ? "sun.max" : "moon")
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Opens the Settings window.
private struct SettingsButton: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Button { model.openSettings() } label: {
            Image(systemName: "gearshape")
        }
        .help(L("Settings"))
        .accessibilityLabel(L("Settings"))
    }
}

/// Heading row: the brand mark (logo and AURALISCOPE), the stream format, and the capture state.
/// Shorter windows get a slimmer row, so the brand is always on screen.
private struct DashboardHeading: View {
    @ObservedObject var model: MeterModel
    var tall = true

    var body: some View {
        HStack(spacing: 12) {
            BrandMark(size: tall ? 15 : 13)
            Text(model.formatSummary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Circle().fill(model.running ? Theme.sage : Theme.tertiary).frame(width: 6, height: 6)
            Text(verbatim: model.running ? "LIVE" : "PAUSED")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.secondary)
        }
        .frame(height: tall ? 34 : 26)
    }
}

/// The loudness summary. Its labels are instrument vocabulary and stay in English; only the tooltips of the
/// standard menus are translated.
private struct DashboardHero: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var readouts: Readouts
    /// Set by the dividers either side of the 15 s history, in points; 0 = automatic.
    @AppStorage("layout.summaryLoudnessWidth") private var loudnessWidth: Double = 0
    @AppStorage("layout.vuWidth") private var vuWidth: Double = 0

    var body: some View {
        let values = readouts.values
        let target = model.loudnessTarget
        let ceiling = model.truePeakCeiling
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(LinearGradient(colors: [Theme.bannerAccent.opacity(0.90),
                                              Theme.bannerAccent.opacity(0.68),
                                              Theme.windowBottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HeroArtwork()
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            LinearGradient(colors: Theme.dark ? [.black.opacity(0.04), .black.opacity(0.34)]
                                              : [Color.white.opacity(0.10), Theme.ink.opacity(0.04)],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            GeometryReader { geometry in
                // The VU panel joined the row in Beta 3, so the compact arrangement starts at a wider summary.
                let compact = geometry.size.width < 1240
                let padding: CGFloat = compact ? 14 : 18
                let gap = HeroLayout.gap(compact: compact)
                let row = geometry.size.width - 2 * padding
                let columns = HeroLayout.columns(width: row, compact: compact, loudness: CGFloat(loudnessWidth), vu: CGFloat(vuWidth))
                let scale = HeroLayout.contentScale(height: geometry.size.height, compact: compact, loudnessWidth: columns.loudness)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Circle().fill(model.running ? Theme.ink : Theme.ink.opacity(0.45))
                                .frame(width: 6, height: 6)
                            Text(verbatim: model.running ? "LIVE" : "PAUSED")
                                .font(.system(size: 10, weight: .bold)).tracking(1)
                            Text("·")
                            Text(verbatim: model.format == .spatial ? model.speakerLayout.name : model.format.title)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Theme.ink.opacity(0.95))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.chipFill, in: Capsule())
                        Spacer(minLength: 10)
                        Eyebrow("SHORT-TERM LOUDNESS", color: Theme.ink.opacity(0.82))
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(MeterScale.tenths(values.shortTerm))
                                .font(.system(size: (compact ? 35 : 45) * (1 + (scale - 1) * 0.5), weight: .semibold).monospacedDigit())
                            Text("LUFS").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.ink)
                        DeltaBadge(value: values.shortTerm, target: Float(target))
                            .padding(.top, 5)
                    }
                    .frame(width: HeroLayout.leadWidth(compact: compact), alignment: .leading)
                    .padding(.trailing, gap)

                    // Dragging the summary taller stretches this column: the tile rows share the extra height
                    // and their readings grow with it.
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        HStack(spacing: 6) {
                            Eyebrow("LOUDNESS", color: Theme.ink.opacity(0.88))
                            Spacer(minLength: 4)
                            LoudnessStandardMenus(model: model)
                        }
                        LoudnessGauge(value: values.shortTerm, target: Float(target), scale: scale)
                        HStack(spacing: 7) {
                            StatTile(title: "MOMENTARY", value: MeterScale.tenths(values.momentary), unit: "LUFS", scale: scale)
                            StatTile(title: "INTEGRATED", value: MeterScale.tenths(values.integrated), unit: "LUFS",
                                     color: Theme.ink, scale: scale)
                            StatTile(title: "RANGE", value: values.range < 0 ? "—" : MeterScale.tenths(values.range, floor: -1),
                                     unit: "LU", template: "88.8", scale: scale)
                        }
                        HStack(spacing: 7) {
                            let truePeak = values.truePeakDecibels
                            StatTile(title: "TRUE PEAK", value: MeterScale.tenths(truePeak, floor: -119), unit: "dBTP",
                                     color: truePeak >= 0 ? Theme.ember : (truePeak > Float(ceiling) ? Theme.ochre : Theme.ink), scale: scale)
                            let peak = MeterScale.decibels(values.maxPeak)
                            StatTile(title: "PEAK", value: MeterScale.tenths(peak, floor: -119), unit: "dBFS",
                                     color: peak >= 0 ? Theme.ember : Theme.ink, scale: scale)
                            StatTile(title: "TIME", value: clock(values.elapsed), unit: "", template: "88:88:88", scale: scale)
                        }
                    }
                    .frame(width: columns.loudness)

                    // The dividers in the gaps either side of the history resize it against its neighbours.
                    PanelDivider(axis: .horizontal, leading: columns.loudness,
                                 onResize: { setLoudness($0, row: row, compact: compact) },
                                 onReset: { loudnessWidth = 0 })
                        .frame(width: gap)
                    LoudnessHistory(short: values.shortHistory, momentary: values.momentaryHistory, target: Float(target))
                        .frame(width: columns.history)
                    PanelDivider(axis: .horizontal, leading: columns.history,
                                 onResize: { setVU(history: $0, loudness: columns.loudness, row: row, compact: compact) },
                                 onReset: { vuWidth = 0 })
                        .frame(width: gap)
                    VUMeterPanel(model: model, readouts: readouts)
                        .frame(width: columns.vu)
                }
                .padding(padding)
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.10 : 0.08), lineWidth: 0.5) }
        .shadow(color: Theme.dark ? .clear : Theme.cardShadow, radius: 9, y: 3)
    }

    // Store the clamped result, so a drag held against a limit does not churn user defaults.
    private func setLoudness(_ width: CGFloat, row: CGFloat, compact: Bool) {
        let loudness = Double(HeroLayout.columns(width: row, compact: compact, loudness: width, vu: CGFloat(vuWidth)).loudness)
        if loudness != loudnessWidth { loudnessWidth = loudness }
    }

    /// Dragging the divider after the history sizes the history; the VU meter takes the difference.
    private func setVU(history: CGFloat, loudness: CGFloat, row: CGFloat, compact: Bool) {
        let requested = HeroLayout.available(width: row, compact: compact) - loudness - history
        let vu = Double(HeroLayout.columns(width: row, compact: compact, loudness: loudness, vu: requested).vu)
        if vu != vuWidth { vuWidth = vu }
        // Pin the loudness column where it is, so the VU meter grows into the history and nothing else moves.
        if loudnessWidth == 0 { loudnessWidth = Double(loudness) }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// TARGET and CEILING: the loudness standard of each mode. A view of its own, so the 10 Hz readouts that
/// redraw the summary never rebuild these menus.
private struct LoudnessStandardMenus: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let target = model.loudnessTarget
        let ceiling = model.truePeakCeiling
        HStack(spacing: 6) {
            SummaryMenu(title: "TARGET", value: "\(MeterScale.signedInteger(Float(target))) LUFS",
                        help: L("TARGET: the loudness standard of the current mode. The gauge, delta, history band and VU meter read against it. Stereo and Multi Channel each keep their own and follow the mode.")) {
                ForEach(modeOrder, id: \.self) { spatial in
                    Section(sectionTitle(spatial: spatial)) {
                        Picker(L("Loudness target"), selection: Binding(
                            get: { spatial ? model.spatialTarget : model.stereoTarget },
                            set: { model.setTarget($0, spatial: spatial) })) {
                            ForEach(LoudnessStandard.all, id: \.target) { option in
                                Text(verbatim: "\(MeterScale.signedInteger(Float(option.target))) LUFS · \(option.title)").tag(option.target)
                            }
                        }
                    }
                }
            }
            SummaryMenu(title: "CEILING", value: "\(MeterScale.tenths(Float(ceiling))) dBTP",
                        help: L("CEILING: the True Peak limit of the current mode. TRUE PEAK turns amber above it.")) {
                ForEach(modeOrder, id: \.self) { spatial in
                    Section(sectionTitle(spatial: spatial)) {
                        Picker(L("True Peak ceiling"), selection: Binding(
                            get: { spatial ? model.spatialCeiling : model.stereoCeiling },
                            set: { model.setCeiling($0, spatial: spatial) })) {
                            ForEach(LoudnessStandard.ceilings, id: \.self) { value in
                                Text(verbatim: "\(MeterScale.tenths(Float(value))) dBTP").tag(value)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The mode in use first.
    private var modeOrder: [Bool] { model.format == .spatial ? [true, false] : [false, true] }

    private func sectionTitle(spatial: Bool) -> String {
        let title = spatial ? L("Multi Channel") : L("Stereo & Mono")
        return (model.format == .spatial) == spatial ? L("%@ · in use", title) : title
    }

}

/// A pill on the summary showing a preset (loudness target, true-peak ceiling) that opens a menu of choices.
/// Interactive Liquid Glass on macOS 26; a quiet capsule on the summary before it.
private struct SummaryMenu<Content: View>: View {
    let title: String
    let value: String
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content.pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(Tracking.eyebrow)
                    .foregroundStyle(Theme.ink.opacity(0.72))
                Text(value)
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.72))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .glassSurface(Capsule(), interactive: true, fallback: Theme.dark ? Color.black.opacity(0.22) : Color.white.opacity(0.55))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

private struct HeroArtwork: View {
    var body: some View {
        Canvas { context, size in
            let horizon = size.height * 0.70
            for index in 0..<18 {
                let y = horizon + CGFloat(index) * 7
                let alpha = max(0.01, 0.15 - Double(index) * 0.006)
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color((Theme.dark ? Color.black : Theme.ink).opacity(Theme.dark ? alpha : alpha * 0.35)), lineWidth: 1)
            }
            for row in 0..<5 {
                var line = Path()
                let baseline = size.height * (0.34 + CGFloat(row) * 0.09)
                for step in 0...180 {
                    let x = CGFloat(step) / 180 * size.width
                    let phase = x / max(1, size.width) * .pi * 8
                    let swell = exp(-pow((x / max(1, size.width) - 0.66) * 4, 2))
                    let y = baseline + sin(phase + CGFloat(row) * 0.6) * swell * (10 + CGFloat(row) * 4)
                    if step == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(line, with: .color(Theme.dark ? Color.white.opacity(0.09) : Theme.ink.opacity(0.06)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The meter window: the loudness summary across the full width, and below it the analyzer column (Spectrum,
/// Spectrogram, Waveform) on the left and the Soundstage column on the right, split by a draggable divider.
private struct MeterView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.openWindow) private var openWindow
    // Divider positions: row fractions of the analyzer panels, and the Soundstage width in points.
    @AppStorage("layout.spectrumShare") private var spectrumFraction: Double = Double(PanelLayout.defaultSpectrum)
    @AppStorage("layout.spectrogramShare") private var spectrogramFraction: Double = Double(PanelLayout.defaultSpectrogram)
    @AppStorage("layout.stageWidth") private var stageWidth: Double = Double(ColumnLayout.defaultStage)
    /// Loudness summary height in points; 0 follows the window's default.
    @AppStorage("layout.heroHeight") private var heroHeight: Double = 0

    var body: some View {
        GeometryReader { window in
            let tall = window.size.height >= 940
            let gutter: CGFloat = tall ? 20 : 14
            let total = max(1, window.size.width - gutter * 2)
            let stage = ColumnLayout.stageWidth(CGFloat(stageWidth), total: total)
            let analyzers = max(1, total - PanelLayout.divider - stage)
            let spacing: CGFloat = tall ? 10 : 8
            let hero = HeroLayout.height(CGFloat(heroHeight), tall: tall, window: window.size.height)
            VStack(spacing: spacing) {
                DashboardHeading(model: model, tall: tall)
                DashboardHero(model: model, readouts: model.readouts)
                    .frame(height: hero)
                    // Centred in the gap under the summary, so the gap keeps its width.
                    .overlay(alignment: .bottom) {
                        PanelDivider(axis: .vertical, leading: hero,
                                     onResize: { setHero($0, tall: tall, window: window.size.height) },
                                     onReset: { heroHeight = 0 })
                            .frame(height: PanelLayout.divider)
                            .offset(y: (PanelLayout.divider + spacing) / 2)
                    }
                    .zIndex(1)
                HStack(spacing: 0) {
                    analyzerPanels
                        .frame(width: analyzers)
                    PanelDivider(axis: .horizontal, leading: analyzers,
                                 onResize: { setStage(total - PanelLayout.divider - $0, total: total) },
                                 onReset: { setStage(ColumnLayout.defaultStage, total: total) })
                        .frame(width: PanelLayout.divider)
                    SoundstagePanel(model: model, readouts: model.readouts, activeRoles: model.routedRoles,
                                    format: model.format, layout: model.speakerLayout)
                        .frame(width: stage)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(L("Soundstage: channel map and per-channel Peak and RMS meters"))
                }
                StatusBar(status: model.status.text, running: model.running, droppedFrames: model.droppedFrames)
            }
            .padding(.horizontal, gutter)
            .padding(.top, tall ? 8 : 2)
            .padding(.bottom, 8)
        }
        .background { WindowBackdrop() }
        .background(WindowConfigurator(floating: model.floating))
        .background(WindowOpeners(model: model))
        .tint(Theme.action)
    }

    private var analyzerPanels: some View {
        GeometryReader { proxy in
            let layout = PanelLayout(height: proxy.size.height, spectrum: CGFloat(spectrumFraction),
                                     spectrogram: CGFloat(spectrogramFraction))
            VStack(spacing: 0) {
                let source = spectrumSource(format: model.format, layout: model.speakerLayout)
                SpectrumPanel(model: model, sampleRate: model.sampleRate, source: source)
                    .frame(height: layout.spectrum)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Spectrum, 20 Hz to 20 kHz"))
                PanelDivider(axis: .vertical, leading: layout.spectrum,
                             onResize: { setRows(layout.draggingSpectrum(to: $0)) },
                             onReset: { setRows(layout.draggingSpectrum(to: PanelLayout.defaultSpectrum * layout.panels)) })
                    .frame(height: PanelLayout.divider)
                SpectrogramPanel(model: model, sampleRate: model.sampleRate, source: source)
                    .frame(height: layout.spectrogram)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Spectrogram, last 8 seconds"))
                PanelDivider(axis: .vertical, leading: layout.spectrogram,
                             onResize: { setSpectrogram(layout.draggingSpectrogram(to: $0)) },
                             onReset: { setSpectrogram(layout.draggingSpectrogram(to: PanelLayout.defaultSpectrogram * layout.panels)) })
                    .frame(height: PanelLayout.divider)
                WaveformPanel(model: model, layout: model.speakerLayout, format: model.format,
                              activeRoles: model.routedRoles)
                    .frame(height: layout.waveform)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Waveform of each channel, last 4 seconds"))
            }
        }
    }

    // Writes only on change, so a drag held against a limit does not churn user defaults.
    private func setRows(_ rows: (spectrum: CGFloat, spectrogram: CGFloat)) {
        if Double(rows.spectrum) != spectrumFraction { spectrumFraction = Double(rows.spectrum) }
        setSpectrogram(rows.spectrogram)
    }

    private func setSpectrogram(_ fraction: CGFloat) {
        if Double(fraction) != spectrogramFraction { spectrogramFraction = Double(fraction) }
    }

    private func setHero(_ height: CGFloat, tall: Bool, window: CGFloat) {
        let clamped = Double(HeroLayout.height(height, tall: tall, window: window))
        if clamped != heroHeight { heroHeight = clamped }
    }

    private func setStage(_ width: CGFloat, total: CGFloat) {
        let clamped = Double(ColumnLayout.stageWidth(width, total: total))
        if clamped != stageWidth { stageWidth = clamped }
    }
}

/// Turns the model's window requests (menus, toolbar, diagnostics) into `openWindow` calls.
private struct WindowOpeners: View {
    @ObservedObject var model: MeterModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                Diagnostics.testLanguageSwitchIfRequested(model: model)
                Diagnostics.testAppearanceSwitchIfRequested(model: model)
                Diagnostics.testSystemAppearanceSwitchIfRequested()
                Diagnostics.testDeviceSourceSelectionIfRequested(model: model)
                guard Diagnostics.showAbout else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openWindow(id: "about") }
            }
            .onChange(of: model.showSettings) { requested in
                guard requested else { return }
                model.showSettings = false
                openWindow(id: "settings")
            }
            .onChange(of: model.showAbout) { requested in
                guard requested else { return }
                model.showAbout = false
                openWindow(id: "about")
            }
    }
}

private struct StatusBar: View {
    let status: String
    let running: Bool
    let droppedFrames: UInt64
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(status).lineLimit(1).truncationMode(.middle).help(status)
            Spacer(minLength: 8)
            if droppedFrames > 0 {
                Label(L("Dropped %d", Int(droppedFrames)), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.ochre)
            }
            Text("ITU-R BS.1770-5 · EBU R128 · 60 Hz")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 8)
    }
}
