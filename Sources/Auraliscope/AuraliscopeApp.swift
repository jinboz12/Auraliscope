import AppKit
import CoreAudio
import AVFoundation
import SwiftUI

@MainActor
private final class WelcomeCoordinator: ObservableObject {
    @Published var presented = false
    var launchHandled = false

    private static let seenBuildKey = "welcomeSeenBuild"
    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// The first launch of each build shows the welcome, even where an earlier build was told not to: that choice
    /// is kept in the sandbox container, which outlives reinstalling the app. `-showWelcomeOnLaunch` on the
    /// command line still decides alone.
    static var firstLaunchOfBuild: Bool {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return arguments["showWelcomeOnLaunch"] == nil && UserDefaults.standard.string(forKey: seenBuildKey) != build
    }

    static func noteLaunch() { UserDefaults.standard.set(build, forKey: seenBuildKey) }
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
        Window(AppName.full, id: "meter") {
            MeterView(model: model)
                .modifier(ThemeIdentity())
                .frame(minWidth: 1000, minHeight: 628)
                .onAppear {
                    guard !welcome.launchHandled else { return }
                    welcome.launchHandled = true
                    let inputNeedsPermission = !Diagnostics.demo && model.selectedDevice?.output != true
                        && model.selectedDevice?.isBridge != true && model.selectedID.bridge == nil
                        && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
                    if Diagnostics.showWelcome || (!Diagnostics.snapshotRequested && !launchedByBridge
                                                   && (showWelcomeOnLaunch || WelcomeCoordinator.firstLaunchOfBuild || inputNeedsPermission)) {
                        if !Diagnostics.snapshotRequested { WelcomeCoordinator.noteLaunch() }
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
                    BrandItem(model: model)
                    ModeItem(model: model)
                    TrailingItems(model: model)
                }
                .modifier(FullScreenToolbarBackground())
        }
        .defaultSize(width: 1400, height: 1060)
        Window(L("Settings"), id: "settings") {
            SettingsView(model: model)
                .modifier(ThemeIdentity())
        }
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentMinSize)
        Window(L("About Auraliscope LABS"), id: "about") {
            AboutView()
                .modifier(ThemeIdentity())
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(L("About Auraliscope LABS")) { model.showAbout = true }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { model.openSettings() }
                    .keyboardShortcut(",")
            }
            AppearanceCommands()
            MeterCommands(model: model)
        }
    }
}

/// Rebuilds only the contents of a window when its palette changes. Observing the theme in the App
/// itself would invalidate all Window scene declarations, including unopened utility windows.
private struct ThemeIdentity: ViewModifier {
    @ObservedObject private var theme = ThemeSettings.shared

    func body(content: Content) -> some View { content.id(theme.signature) }
}

/// The Meter menu. Space pauses and resumes only while the meter window is focused: as an app-wide shortcut it
/// reached the menu before any control, so in Settings (with Full Keyboard Access) Space toggled capture instead of
/// the focused switch, and behind the welcome sheet it started metering.
private struct MeterCommands: Commands {
    @ObservedObject var model: MeterModel
    @ObservedObject private var focus = MeterWindowFocus.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some Commands {
        CommandMenu(L("Meter")) {
            Button(model.captureActionTitle, action: model.toggleCapture)
                .keyboardShortcut(focus.key ? KeyboardShortcut(.space, modifiers: []) : nil)
            Button(L("Reset Measurements"), action: model.resetMeasurements)
                .keyboardShortcut("r")
            Divider()
            Picker(L("Monitoring Mode"), selection: $model.formatMode) {
                ForEach(model.availableModes) { mode in Text(mode.title).tag(mode) }
            }
            Picker(L("Immersive Format"), selection: $model.speakerLayout) {
                ForEach(SpeakerLayout.allCases) { layout in Text(verbatim: layout.name).tag(layout) }
            }
            Divider()
            Button(L("Channel Routing…")) { model.openSettings(.channels) }
                .keyboardShortcut("k")
        }
    }
}

/// Whether the meter window is the key window (not Settings, About or the welcome sheet).
@MainActor
final class MeterWindowFocus: ObservableObject {
    static let shared = MeterWindowFocus()
    @Published var key = false
}

private struct AppearanceCommands: Commands {
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L("Show Diagnostic Logs")) {
                NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.folder])
            }
        }
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

/// The toolbar is the window's only header, in a window and in full screen alike: the brand and the stream at
/// the leading edge (after the window controls; in full screen, where those only slide in with the menu bar,
/// it takes the corner itself), the mode selector in the centre as the HIG places a view switcher, and the
/// actions at the trailing edge. Folding the former heading row into it gives the panels its height.
private struct BrandItem: ToolbarContent {
    let model: MeterModel

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            // Plain text on the bar, not a glass control.
            ToolbarItem(placement: .navigation) { ToolbarBrand(model: model) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { ToolbarBrand(model: model) }
        }
    }
}

/// The mode selector (Stereo | Atmos, Mono when enabled, with AUTO) in the centre of the toolbar.
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
        DiagnosticLog.start()
        // Light, Dark or Auto for the whole app, so system controls, menus, popovers and sheets match the
        // custom surfaces.
        ThemeSettings.shared.attach()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The privacy indicators start from the real permissions, not from whatever the last session saw.
        AudioPermission.shared.checkAtLaunch()
        // The menu bar's AppKit items follow a language change at once (see `SystemMenus`).
        DispatchQueue.main.async {
            SystemMenus.follow()
            SettingsDraft.shared.follow()
        }
        if Diagnostics.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Diagnostics.logMenus() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        // A preview is not kept: put back what the app had before quitting.
        SettingsDraft.shared.revert()
        DiagnosticLog.finish("Quit")
    }
}

/// The meter window, registered by its probe so menus and Settings can act on it.
/// Whether the meter window is in full screen, for the views that dress differently there.
@MainActor
final class FullScreenState: ObservableObject {
    static let shared = FullScreenState()
    @Published var active = false
}

/// In a window the toolbar is transparent over the backdrop. In full screen AppKit moves it into a bar of its own
/// with the system's grey; this gives that bar the backdrop's top colour, so the header reads the same in both.
private struct FullScreenToolbarBackground: ViewModifier {
    @ObservedObject private var state = FullScreenState.shared
    @ObservedObject private var theme = ThemeSettings.shared

    // One view whatever the state: branching here would give the whole window content a new identity on every
    // switch, and its `onDisappear` would stop capture.
    func body(content: Content) -> some View {
        let dressed = content
            .toolbarBackground(Theme.backdropTop, for: .windowToolbar)
            .toolbarBackground(state.active ? .visible : .automatic, for: .windowToolbar)
        // A visible bar would also print the window title beside the brand; the brand already names the app.
        if #available(macOS 15, *) {
            dressed.toolbar(removing: .title)
        } else {
            dressed
        }
    }
}

enum MainWindow {
    static weak var window: NSWindow?
    /// The saved frame has been applied this launch; later window probes must not apply it again.
    static var frameRestored = false
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
        // Opaque: the backdrop covers the whole window, so the window server need not blend it with the desktop
        // on every frame the meters draw (a translucent window about doubled the GPU load).
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        // The window follows the app's appearance (Light, Dark or Auto) rather than fixing its own.
        window.appearance = nil
        window.isMovableByWindowBackground = !UserDefaults.standard.bool(forKey: "experimentNoBackgroundDrag")
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
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    let key = note.name == NSWindow.didBecomeKeyNotification
                    MainActor.assumeIsolated {
                        if MeterWindowFocus.shared.key != key { MeterWindowFocus.shared.key = key }
                    }
                })
            }
            MeterWindowFocus.shared.key = window.isKeyWindow
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    guard let self, let window = self.window else { return }
                    let entering = note.name == NSWindow.willEnterFullScreenNotification
                    // Entering: a floating window would sit above the menu bar reveal; leaving: restore the preference.
                    window.level = entering ? .normal : (self.floating ? .floating : .normal)
                    MainActor.assumeIsolated { FullScreenState.shared.active = entering }
                    DiagnosticLog.event(entering ? "Full screen: on" : "Full screen: off")
                })
            }
            // Remember position and size across launches. The saved frame is restored once per launch (clamped
            // to a visible screen). A palette or appearance change rebuilds this view, and SwiftUI puts its own
            // autosave name back on the window meanwhile, so a rebuilt probe only takes the name back and leaves
            // the window where it is. Every move and resize is saved under our name explicitly, so the saved
            // frame is current whichever name the window carries. Snapshot runs leave it untouched.
            if !Diagnostics.snapshotRequested {
                if window.frameAutosaveName != Self.frameName {
                    let current = window.frame
                    window.setFrameAutosaveName(Self.frameName)
                    if MainWindow.frameRestored {
                        if window.frame != current { window.setFrame(current, display: false) }
                    } else {
                        MainWindow.frameRestored = true
                        window.setFrameUsingName(Self.frameName)
                    }
                }
                for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                        guard let window = note.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
                        window.saveFrame(usingName: Self.frameName)
                    })
                }
            }
            // Settings and About snapshots capture their own window instead.
            if !Diagnostics.showAbout && !Diagnostics.showSettings { Diagnostics.captureWindowIfRequested(window) }
            Diagnostics.testFullScreenIfRequested(window)
            Diagnostics.testThemeSwitchIfRequested(window)
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
/// keeps its title in the current language (SwiftUI names a `Window` scene once, when it opens), and leaves it out
/// of window restoration.
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
            // Settings and About open when asked, never on their own because they were open at the last quit.
            window.isRestorable = false
            if capture { Diagnostics.captureWindowIfRequested(window) }
        }
    }
}

/// The window's backdrop: the atmosphere the panels float in, and the only place the palette is used as light.
/// On dark: a deep blue-black, the palette's light pooled softly behind the top row and a faint cool counter-light low
/// on the right. On light: the palette's pale wash at the top, turning into a cool grey, with white light rising from
/// the bottom. Static gradients, drawn once per size.
private struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            if Theme.dark {
                LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.bannerAccent.opacity(0.42), Theme.bannerAccent.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.28, y: -0.05), startRadius: 0, endRadius: 900)
                RadialGradient(colors: [Theme.bannerAccent.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: 700)
            } else {
                LinearGradient(stops: [.init(color: Theme.backdropTop, location: 0),
                                       .init(color: Theme.backdropMiddle, location: 0.26),
                                       .init(color: Theme.windowTop, location: 0.55),
                                       .init(color: Theme.windowBottom, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.bannerAccent.opacity(0.40), .clear],
                               center: UnitPoint(x: 0.02, y: 0.62), startRadius: 0, endRadius: 640)
                RadialGradient(colors: [Color.white.opacity(0.70), .clear],
                               center: UnitPoint(x: 0.6, y: 1.08), startRadius: 0, endRadius: 820)
            }
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
        // Paused, the button offers to resume in the accent, the colour of the live signal it brings back.
        Button(action: model.toggleCapture) {
            Image(systemName: model.running ? "pause.fill" : "play.fill")
                .foregroundStyle(model.running ? Theme.secondary : Theme.sage)
        }
        .help(model.captureActionTitle)
        .accessibilityLabel(model.captureActionTitle)
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

/// The toolbar's leading item: the brand mark, a hairline, then the stream on the wordmark's baseline, values
/// set firmly and units quieter. Capture state is on the loudness summary's chip and the transport button.
private struct ToolbarBrand: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BrandMark(size: 13)
            Rectangle().fill(Theme.hairline.opacity(0.18))
                .frame(width: 1, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ForEach(Array(model.streamParts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Text(verbatim: "·").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tertiary.opacity(0.6))
                    }
                    (Text(verbatim: part.value).font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.secondary)
                     + Text(verbatim: part.unit.isEmpty ? "" : "\u{2009}" + part.unit).font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.tertiary))
                        .fixedSize()
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The loudness summary: short-term reading, gauge, statistics tiles, 15 s history and VU meter.
/// Only the parts that print a reading observe `readouts` (the gauge, the short-term reading, the tiles and the
/// history), so the 10 Hz readings re-render those and not the title, chip and menus around them.
private struct DashboardHero: View {
    @ObservedObject var model: MeterModel
    let readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    /// Set by the dividers either side of the 15 s history, in points; 0 = automatic.
    @AppStorage("layout.summaryLoudnessWidth") private var loudnessWidth: Double = 0
    @AppStorage("layout.vuWidth") private var vuWidth: Double = 0

    var body: some View {
        let target = model.loudnessTarget
        let ceiling = model.truePeakCeiling
        // Three sibling panels in one row: loudness, the 15 s history and the VU meter, none nested in another.
        GeometryReader { geometry in
            // The VU panel joined the row in Beta 3, so the compact arrangement starts at a wider summary.
            let compact = geometry.size.width < 1240
            let gap = HeroLayout.gap(compact: compact)
            let row = geometry.size.width - HeroLayout.inset - HeroLayout.trailingInset
            let columns = HeroLayout.columns(width: row, compact: compact, loudness: CGFloat(loudnessWidth), vu: CGFloat(vuWidth))
            let scale = HeroLayout.contentScale(height: geometry.size.height, compact: compact, loudnessWidth: columns.loudness)
            let gauge = HeroLayout.showsGauge(height: geometry.size.height)
            HStack(alignment: .top, spacing: 0) {
                // A grid over the short-term reading and the loudness column: the title row spans both, the
                // gauge sits over the readings, and the short-term reading is centred beside them.
                VStack(alignment: .leading, spacing: 6 * scale) {
                    HStack(spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { heroTitle; StatusReading(model: model, detail: formatName) }
                            HStack(spacing: 12) { heroTitle; StatusReading(model: model) }
                            heroTitle
                        }
                        Spacer(minLength: 8)
                        LoudnessStandardMenus(model: model)
                    }
                    .frame(height: 24)
                    if gauge {
                        HeroGauge(readouts: readouts, target: Float(target), scale: scale)
                            .padding(.leading, HeroLayout.leadWidth(compact: compact) + gap)
                    }
                    HStack(alignment: .top, spacing: 0) {
                        HeroShortTerm(readouts: readouts, target: Float(target), compact: compact, scale: scale)
                        .frame(width: HeroLayout.leadWidth(compact: compact), alignment: .leading)
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, gap)

                        // Dragging the summary taller stretches this column: the reading rows share the extra
                        // height and their readings grow with it.
                        HeroTiles(readouts: readouts, ceiling: Float(ceiling), scale: scale, resetTruePeak: model.resetTruePeak)
                        .frame(width: columns.loudness)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(width: HeroLayout.leadWidth(compact: compact) + gap + columns.loudness)
                .padding(.leading, HeroLayout.inset)
                .padding(.trailing, HeroLayout.trailingInset)
                .padding(.vertical, HeroLayout.verticalPadding(height: geometry.size.height, compact: compact))
                .frame(maxHeight: .infinity, alignment: .top)
                .background { CardSurface() }

                // The dividers in the gaps either side of the history resize it against its neighbours.
                PanelDivider(axis: .horizontal, leading: columns.loudness,
                             onResize: { setLoudness($0, row: row, compact: compact) },
                             onReset: { loudnessWidth = 0 })
                    .frame(width: HeroLayout.cardGap)
                HeroHistory(model: model, readouts: readouts, target: Float(target))
                    .frame(width: columns.history)
                PanelDivider(axis: .horizontal, leading: columns.history,
                             onResize: { setVU(history: $0, loudness: columns.loudness, row: row, compact: compact) },
                             onReset: { vuWidth = 0 })
                    .frame(width: HeroLayout.cardGap)
                VUMeterPanel(model: model, readouts: readouts)
                    .frame(width: columns.vu)
            }
        }
    }

    private var heroTitle: some View {
        HStack(alignment: .center, spacing: 8) {
            Eyebrow(L("LOUDNESS"), color: Theme.title).fixedSize()
            PanelSettingsButton(panel: .loudness)
        }
    }

    /// The monitoring format beside the status, when there is room for it.
    private var formatName: String { model.format == .spatial ? model.speakerLayout.name : model.format.title }

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
}

private struct HeroGauge: View {
    @ObservedObject var readouts: Readouts
    let target: Float
    let scale: CGFloat
    @AppStorage(LoudnessReading.key) private var reading = LoudnessReading.shortTerm.rawValue

    var body: some View {
        let main = LoudnessReading(rawValue: reading) ?? .shortTerm
        LoudnessGauge(value: main.value(readouts.values), target: target, scale: scale)
    }
}

/// The main loudness reading (Short-term unless chosen otherwise in the panel's settings), its value and the delta
/// chip.
private struct HeroShortTerm: View {
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    let target: Float
    let compact: Bool
    let scale: CGFloat
    @AppStorage(LoudnessReading.key) private var reading = LoudnessReading.shortTerm.rawValue

    var body: some View {
        let main = LoudnessReading(rawValue: reading) ?? .shortTerm
        let shortTerm = main.value(readouts.values)
        VStack(alignment: .leading, spacing: 3 * scale) {
            Eyebrow(main.heading, color: Theme.sage)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MeterScale.tenths(shortTerm))
                    .font(.system(size: (compact ? 35 : 45) * (1 + (scale - 1) * 0.5), weight: .semibold).monospacedDigit())
                Text(verbatim: "LUFS").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.72))
            }
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            DeltaBadge(value: shortTerm, target: target)
                .padding(.top, 2)
        }
    }
}

/// The statistics. Dragging the summary taller stretches this column: the rows share the extra height and their
/// readings grow with it.
private struct HeroTiles: View {
    @ObservedObject var readouts: Readouts
    @ObservedObject private var l10n = Localizer.shared
    let ceiling: Float
    let scale: CGFloat
    /// Clears the held true peaks alone; offered while the reading warns (above the ceiling or over 0 dBTP).
    let resetTruePeak: () -> Void
    @AppStorage(LoudnessReading.key) private var reading = LoudnessReading.shortTerm.rawValue

    var body: some View {
        let values = readouts.values
        let main = LoudnessReading(rawValue: reading) ?? .shortTerm
        // Two rows on three columns, set like a hardware panel's parameters: the second row's readings sit under
        // the first row's, and its third place stays open.
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                // The two LUFS readings the main one leaves, in their usual order.
                ForEach(LoudnessReading.allCases.filter { $0 != main }, id: \.self) { other in
                    StatTile(title: other.tileTitle, value: MeterScale.tenths(other.value(values)), unit: "LUFS", scale: scale)
                }
                StatTile(title: L("RANGE"), value: values.range < 0 ? "—" : MeterScale.tenths(values.range, floor: -1),
                         unit: "LU", template: "8.8", scale: scale)
            }
            HStack(spacing: 16) {
                let truePeak = values.truePeakDecibels
                // Above 0 dBTP the reading is an over: signed, in ember, flagged OVER.
                let over = truePeak > 0.05
                StatTile(title: L("TRUE PEAK"),
                         value: over ? MeterScale.signedTenths(truePeak) : MeterScale.tenths(truePeak, floor: -119),
                         unit: "dBTP",
                         color: truePeak >= 0 ? Theme.ember : (truePeak > ceiling ? Theme.ochre : Theme.ink),
                         template: "−8.8", scale: scale, alert: over ? L("OVER") : nil)
                    .modifier(TruePeakReset(active: truePeak > ceiling, reset: resetTruePeak))
                let peak = MeterScale.decibels(values.maxPeak)
                StatTile(title: L("PEAK"), value: MeterScale.tenths(peak, floor: -119), unit: "dBFS",
                         color: peak >= 0 ? Theme.ember : Theme.ink, template: "−8.8", scale: scale)
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }
}

/// While TRUE PEAK warns, a click on its tile clears the held true peaks alone, so the next overshoot can be
/// caught without resetting integrated loudness or the rest of the session.
private struct TruePeakReset: ViewModifier {
    let active: Bool
    let reset: () -> Void
    @ObservedObject private var l10n = Localizer.shared

    func body(content: Content) -> some View {
        if active {
            Button(action: reset) {
            content
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 6).padding(.trailing, 8)
                        .accessibilityHidden(true)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
                .buttonStyle(.plain)
                .help(L("Click to reset True Peak"))
                .accessibilityHint(L("Click to reset True Peak"))
        } else {
            content
        }
    }
}

private struct HeroHistory: View {
    let model: MeterModel
    @ObservedObject var readouts: Readouts
    let target: Float

    var body: some View {
        LoudnessHistory(short: readouts.values.shortHistory, momentary: readouts.values.momentaryHistory, target: target,
                        model: model)
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
            SummaryMenu(title: L("TARGET"), value: "\(MeterScale.signedInteger(Float(target))) LUFS",
                        help: L("TARGET: the loudness standard of the current mode. The gauge, delta, history band and VU meter read against it. Stereo and Immersive each keep their own and follow the mode.")) {
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
            SummaryMenu(title: L("CEILING"), value: "\(MeterScale.tenths(Float(ceiling))) dBTP",
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
        let title = spatial ? L("Immersive") : L("Stereo & Mono")
        return (model.format == .spatial) == spatial ? L("%@ · in use", title) : title
    }

}

/// A pill on the summary showing a preset (loudness target, true-peak ceiling) that opens a menu of choices.
/// Interactive Liquid Glass on macOS 26; a quiet capsule before it.
struct SummaryMenu<Content: View>: View {
    let title: String
    let value: String
    let help: String
    @ViewBuilder var content: Content
    @State private var hovering = false

    /// A field on the panel's control scale: the name in the heading voice, the value, and the menu's chevron, on a
    /// quiet rounded rectangle that lifts under the pointer. One shape for every menu (TARGET, CEILING, BANDS).
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius - 1, style: .continuous)
        Menu { content.pickerStyle(.inline) } label: {
            label
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background {
                    shape.fill(hovering ? Theme.controlHover : Theme.controlFill)
                        .overlay { shape.strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.09 : 0.08), lineWidth: 0.5) }
                }
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
    }

    /// One Text, not a stack: the menu button keeps only the first view of a stacked label.
    private var label: some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold).width(.expanded)).tracking(Localizer.shared.tracking(Tracking.eyebrow))
            .foregroundColor(Theme.tertiary)
        + Text(verbatim: "  ")
        + Text(value)
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundColor(Theme.ink)
        + Text(verbatim: " ")
        + Text(Image(systemName: "chevron.up.chevron.down"))
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(Theme.tertiary)
    }
}

/// The meter window: the loudness summary across the full width, and below it the analyzer column (Spectrum
/// with its spectrogram, then Waveform) on the left and the Soundstage column on the right, split by a draggable divider.
private struct MeterView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.openWindow) private var openWindow
    // Divider positions: row fractions of the analyzer panels, and the Soundstage width in points.
    // 1.1 merged Spectrum and Spectrogram into one card, so the share has a key of its own.
    @AppStorage("layout.analyzerShare") private var spectrumFraction: Double = Double(PanelLayout.defaultSpectrum)
    @AppStorage("layout.stageWidth") private var stageWidth: Double = Double(ColumnLayout.defaultStage)
    /// The Soundstage room's share of the right-hand column's height; Channel Levels takes the rest.
    @AppStorage("layout.roomShare") private var roomShare: Double = Double(ColumnLayout.defaultRoomShare)
    /// Loudness summary height in points; 0 follows the window's default.
    @AppStorage("layout.heroHeight") private var heroHeight: Double = 0

    var body: some View {
        GeometryReader { window in
            let tall = window.size.height >= 940
            let gutter: CGFloat = tall ? 14 : 10
            let total = max(1, window.size.width - gutter * 2)
            let stage = ColumnLayout.stageWidth(CGFloat(stageWidth), total: total)
            let analyzers = max(1, total - PanelLayout.divider - stage)
            let spacing: CGFloat = PanelLayout.divider
            let hero = HeroLayout.height(CGFloat(heroHeight), tall: tall, window: window.size.height)
            VStack(spacing: spacing) {
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
                    stagePanels
                        .frame(width: stage)
                }
                StatusBar(status: model.status.text, running: model.running, droppedFrames: model.droppedFrames,
                          silentOutput: model.silentOutput, breaks: model.measurementBreaks,
                          missingSeconds: model.missingSeconds)
            }
            .padding(.horizontal, gutter)
            .padding(.top, tall ? 8 : 2)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .bottom) {
            PreviewBanner(model: model)
                .padding(.bottom, 30)
        }
        .background { WindowBackdrop() }
        .background(WindowConfigurator(floating: model.floating))
        .background(WindowOpeners(model: model))
        .tint(Theme.action)
    }

    private var analyzerPanels: some View {
        GeometryReader { proxy in
            let layout = PanelLayout(height: proxy.size.height, spectrum: CGFloat(spectrumFraction))
            VStack(spacing: 0) {
                let source = spectrumSource(format: model.format, layout: model.speakerLayout)
                SpectrumPanel(model: model, sampleRate: model.sampleRate, source: source)
                    .frame(height: layout.spectrum)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Spectrogram and spectrum, 20 Hz to 20 kHz, last 3 to 8 seconds"))
                PanelDivider(axis: .vertical, leading: layout.spectrum,
                             onResize: { setSpectrum(layout.draggingSpectrum(to: $0)) },
                             onReset: { setSpectrum(PanelLayout.defaultSpectrum) })
                    .frame(height: PanelLayout.divider)
                WaveformPanel(model: model, layout: model.speakerLayout, format: model.format,
                              activeRoles: model.routedRoles)
                    .frame(height: layout.waveform)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Waveform of each channel, last 4 seconds"))
            }
        }
    }

    /// The right-hand column: the Soundstage room above Channel Levels, split by a divider.
    private var stagePanels: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            let room = ColumnLayout.roomHeight(share: CGFloat(roomShare), total: total)
            VStack(spacing: 0) {
                SoundstagePanel(model: model, activeRoles: model.routedRoles, format: model.format, layout: model.speakerLayout)
                    .frame(height: room)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Soundstage: channel map"))
                PanelDivider(axis: .vertical, leading: room,
                             onResize: { setRoom($0, total: total) },
                             onReset: { roomShare = Double(ColumnLayout.defaultRoomShare) })
                    .frame(height: PanelLayout.divider)
                ChannelLevelsPanel(model: model, readouts: model.readouts, activeRoles: model.routedRoles,
                                   format: model.format, layout: model.speakerLayout)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("Channel levels: Peak and RMS meters per channel, and correlation in Stereo"))
            }
        }
    }

    private func setRoom(_ height: CGFloat, total: CGFloat) {
        let share = Double(ColumnLayout.roomHeight(share: height / max(1, total), total: total) / max(1, total))
        if abs(share - roomShare) > 0.0005 { roomShare = share }
    }

    // Writes only on change, so a drag held against a limit does not churn user defaults.
    private func setSpectrum(_ fraction: CGFloat) {
        if Double(fraction) != spectrumFraction { spectrumFraction = Double(fraction) }
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
                Diagnostics.testThemeFadeIfRequested()
                Diagnostics.benchmarkThemeSwitchIfRequested()
                Diagnostics.testSystemAppearanceSwitchIfRequested()
                Diagnostics.testDeviceSourceSelectionIfRequested(model: model)
                Diagnostics.testPauseResumeIfRequested(model: model)
                Diagnostics.testSourceSwitchIfRequested(model: model)
                Diagnostics.testSpaceShortcutIfRequested(model: model)
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
    let silentOutput: Bool
    /// Breaks in the analysed audio since the analysis started, and the seconds known missing at them.
    let breaks: Int
    let missingSeconds: Double
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(status).lineLimit(1).truncationMode(.middle).help(status)
            if silentOutput {
                Label(L("No sound from this output"), systemImage: "speaker.slash")
                    .lineLimit(1)
                    .foregroundStyle(Theme.ochre)
                    .help(L("Only digital silence has arrived so far. If an app is playing to this output, allow Auraliscope LABS in Privacy & Security → Screen & System Audio Recording, then choose the output again."))
            }
            Spacer(minLength: 8)
            if breaks > 0 {
                Label(missingSeconds >= 0.05 ? L("Interrupted %d× · %@ s missing", breaks, String(format: "%.1f", missingSeconds))
                                             : L("Interrupted %d×", breaks),
                      systemImage: "waveform.path.badge.minus")
                    .lineLimit(1)
                    .foregroundStyle(Theme.ochre)
                    .help(L("The analysed audio broke off and resumed. Integrated loudness, loudness range and the held peaks span the breaks; momentary, short-term, the spectrum and every filter started again after each one. Reset to measure one continuous stretch."))
            }
            if droppedFrames > 0 {
                Label(L("Dropped %d", Int(droppedFrames)), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.ochre)
            }
            Text(verbatim: AppName.prototypeNote)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ochre)
                .lineLimit(1)
                .fixedSize()
            Text("ITU-R BS.1770-5 · EBU R128 · 60 Hz")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 8)
    }
}
