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
        WindowGroup(AppName.full, id: "meter") {
            MeterView(model: model)
                .modifier(ThemeIdentity())
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
        // A panel in a window of its own (Layout ▸ Open Panel in New Window, or the panel's window button).
        WindowGroup(id: PanelWindow.sceneID, for: MeterPanel.self) { $panel in
            if let panel {
                PanelWindowContent(panel: panel, model: model)
                    .modifier(ThemeIdentity())
            }
        }
        .windowResizability(.contentMinSize)
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
        .windowResizability(.contentSize)
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
            MeterCommands(model: model)
            LayoutCommands()
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
            Button(L("Export Loudness Report…")) { LoudnessReportExport.export(model: model, csv: false) }
                .keyboardShortcut("e")
            Button(L("Export Loudness Data as CSV…")) { LoudnessReportExport.export(model: model, csv: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Picker(L("Monitoring Mode"), selection: $model.formatMode) {
                ForEach(model.availableModes) { mode in Text(mode.title).tag(mode) }
            }
            // A DAW plugin's immersive bus sets the format while it is the source.
            Picker(L("Immersive Format"), selection: $model.speakerLayout) {
                ForEach(SpeakerLayout.allCases) { layout in Text(verbatim: layout.name).tag(layout) }
            }
            .disabled(model.layoutFromPlugin)
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

/// Trailing cluster: one dock of round buttons, the capture controls and then pin, appearance and settings, split by
/// a hairline. The dock draws its own track, so on macOS 26 it opts out of the toolbar's shared glass.
private struct TrailingItems: ToolbarContent {
    let model: MeterModel

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { TrailingDock(model: model) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { TrailingDock(model: model) }
        }
    }
}

private struct TrailingDock: View {
    let model: MeterModel
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some View {
        ToolbarDock {
            TransportButtons(model: model)
            Capsule().fill(Theme.hairline.opacity(Theme.dark ? 0.16 : 0.14))
                .frame(width: 1, height: Theme.dockButton * 0.55)
                .padding(.horizontal, 3)
            WindowButtons(model: model)
        }
        .id(theme.signature)
    }
}

/// A row of round buttons on a recessed capsule track, like a dock.
struct ToolbarDock<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 4) { content }
            .padding(3)
            .background { DockTrack(radius: (Theme.dockButton + 6) / 2) }
            .fixedSize()
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
        // In a window the bar is hidden outright, so the sky runs up under the brand and the docks.
        let dressed = content
            .toolbarBackground(Theme.dark ? Theme.backdropTop : Theme.skyTop, for: .windowToolbar)
            .toolbarBackground(state.active ? .visible : .hidden, for: .windowToolbar)
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
    /// The strip has no title bar of its own: the window controls hide, and the strip's controls take their place.
    static func setChromeHidden(_ hidden: Bool) {
        guard let window else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }

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
            // Panels in windows of their own go with the meter window.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                    queue: .main) { _ in
                MainActor.assumeIsolated { PanelPlacement.shared.closeAllWindows() }
            })
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
                        // The strip keeps a frame of its own; the full window's is the one it returns to.
                        MainActor.assumeIsolated {
                            if PanelPlacement.shared.strip {
                                PanelPlacement.shared.saveStripFrame(window)
                            } else {
                                window.saveFrame(usingName: Self.frameName)
                            }
                        }
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

/// The window's backdrop: a sky the panels float in, and the only place the palette is used as light.
/// On dark: night, near-black with the palette's light pooled behind the top row and a faint glow rising from the
/// horizon at the bottom. On light: the palette's colour deep at the top, thinning through haze to white light low
/// on the horizon. A fine static grain lies over both. Static gradients and one tiled image, drawn once per size.
struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            if Theme.dark {
                LinearGradient(stops: [.init(color: Theme.windowTop, location: 0),
                                       .init(color: Theme.windowBottom, location: 0.55),
                                       .init(color: Theme.windowBottom, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.bannerAccent.opacity(0.95), Theme.bannerAccent.opacity(0.40), .clear],
                               center: UnitPoint(x: 0.3, y: -0.15), startRadius: 0, endRadius: 1100)
                // The horizon: the palette's light rising from below, as a city's does under a night sky.
                RadialGradient(colors: [Theme.bannerAccent.opacity(0.55), Theme.bannerAccent.opacity(0.18), .clear],
                               center: UnitPoint(x: 0.62, y: 1.2), startRadius: 0, endRadius: 1000)
                // A warm counter-light low on the left, so the night is not one hue.
                RadialGradient(colors: [Theme.sand.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.05, y: 1.05), startRadius: 0, endRadius: 520)
                Image(nsImage: Grain.tile)
                    .resizable(resizingMode: .tile)
                    .opacity(Grain.opacity)
                    .blendMode(.screen)
            } else {
                LinearGradient(stops: [.init(color: Theme.skyTop, location: 0),
                                       .init(color: Theme.skyTop, location: 0.08),
                                       .init(color: Theme.backdropTop, location: 0.3),
                                       .init(color: Theme.backdropMiddle, location: 0.55),
                                       .init(color: Theme.windowTop, location: 0.8),
                                       .init(color: Theme.horizon, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.bannerAccent.opacity(0.5), .clear],
                               center: UnitPoint(x: 0.0, y: 0.45), startRadius: 0, endRadius: 760)
                RadialGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.35), .clear],
                               center: UnitPoint(x: 0.55, y: 1.15), startRadius: 0, endRadius: 980)
                // Warm haze on the horizon's left, as in a hazy sky over a city: the cool sky meets a little sand.
                RadialGradient(colors: [Theme.sand.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.05, y: 1.0), startRadius: 0, endRadius: 560)
                Image(nsImage: Grain.tile)
                    .resizable(resizingMode: .tile)
                    .opacity(Grain.opacity)
                    .blendMode(.multiply)
            }
        }
        .compositingGroup()
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

/// Pause/resume and reset. Paused, the resume button is lit in the accent, the colour of the live signal it
/// brings back.
private struct TransportButtons: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        DiscButton(symbol: model.running ? "pause.fill" : "play.fill", help: model.captureActionTitle,
                   fill: model.running ? nil : Theme.action, action: model.toggleCapture)
        DiscButton(symbol: "arrow.counterclockwise",
                   help: L("Reset: clear peak holds and clip latches, and restart Integrated LUFS"),
                   action: model.resetMeasurements)
            .accessibilityLabel(L("Reset Measurements"))
    }
}

/// Always on top (lit while the window floats; the window probe suspends floating while full screen), the
/// appearance flip (its symbol is the appearance a click switches to; Settings and View ▸ Appearance also offer
/// Auto) and Settings.
private struct WindowButtons: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let appearance = theme.dark ? L("Switch to Light Appearance") : L("Switch to Dark Appearance")
        LayoutMenuButton()
        DiscButton(symbol: model.floating ? "pin.fill" : "pin", help: L("Always on top"), on: model.floating) {
            model.floating.toggle()
        }
        .accessibilityValue(model.floating ? L("Enabled") : L("Disabled"))
        DiscButton(symbol: theme.dark ? "sun.max" : "moon", help: appearance, action: theme.toggle)
        DiscButton(symbol: "gearshape", help: L("Settings")) { model.openSettings() }
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

/// The loudness summary: the loudness panel (short-term reading, gauge, statistics tiles), the 15 s history and the
/// VU meter, in one row. Each can be hidden or shown in a window of its own; the panels left take the room.
/// Only the parts that print a reading observe `readouts` (the gauge, the short-term reading, the tiles and the
/// history), so the 10 Hz readings re-render those and not the title, chip and menus around them.
private struct DashboardHero: View {
    @ObservedObject var model: MeterModel
    let readouts: Readouts
    /// The summary's panels to draw, of loudness, history and VU.
    let panels: Set<MeterPanel>
    @ObservedObject private var l10n = Localizer.shared
    /// Set by the dividers either side of the 15 s history, in points; 0 = automatic.
    @AppStorage("layout.summaryLoudnessWidth") private var loudnessWidth: Double = 0
    @AppStorage("layout.vuWidth") private var vuWidth: Double = 0

    var body: some View {
        // Three sibling panels in one row: loudness, the 15 s history and the VU meter, none nested in another.
        GeometryReader { geometry in
            // The VU panel joined the row in Beta 3, so the compact arrangement starts at a wider summary.
            let compact = geometry.size.width < 1240
            let row = geometry.size.width - HeroLayout.inset - HeroLayout.trailingInset
            let columns = HeroLayout.columns(width: row, compact: compact, loudness: CGFloat(loudnessWidth), vu: CGFloat(vuWidth))
            let widths = arrangement(total: geometry.size.width, columns: columns)
            HStack(alignment: .top, spacing: 0) {
                if panels.contains(.loudness) {
                    LoudnessCard(model: model, readouts: readouts, compact: compact, loudness: widths.loudness,
                                 height: geometry.size.height)
                        .transition(.opacity)
                }
                if panels.contains(.loudness) && panels.contains(.history) {
                    // The dividers in the gaps either side of the history resize it against its neighbours.
                    PanelDivider(axis: .horizontal, leading: columns.loudness,
                                 onResize: { setLoudness($0, row: row, compact: compact) },
                                 onReset: { loudnessWidth = 0 })
                        .frame(width: HeroLayout.cardGap)
                } else if panels.contains(.loudness) && panels.contains(.vu) {
                    Color.clear.frame(width: HeroLayout.cardGap)
                }
                if panels.contains(.history) {
                    HeroHistory(model: model, readouts: readouts, target: Float(model.loudnessTarget))
                        .frame(width: widths.history)
                        .transition(.opacity)
                }
                if panels.contains(.history) && panels.contains(.vu) {
                    PanelDivider(axis: .horizontal, leading: widths.history,
                                 onResize: { setVU(history: $0, loudness: columns.loudness, row: row, compact: compact) },
                                 onReset: { vuWidth = 0 })
                        .frame(width: HeroLayout.cardGap)
                }
                if panels.contains(.vu) {
                    VUMeterPanel(model: model, readouts: readouts)
                        .frame(width: widths.vu)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Widths of the panels present: the loudness column (its tiles), the history and the VU meter. A missing panel's
    /// room goes to its neighbour: the history's to the loudness column, the VU's to the history (or to the loudness
    /// column without the history). Without the loudness panel the history and VU share the row.
    private func arrangement(total: CGFloat, columns: HeroLayout.Columns) -> HeroLayout.Columns {
        let gap = HeroLayout.cardGap
        let showsHistory = panels.contains(.history), showsVU = panels.contains(.vu)
        guard panels.contains(.loudness) else {
            if showsHistory && showsVU {
                let wanted = vuWidth > 0 ? CGFloat(vuWidth) : HeroLayout.defaultVU(compact: total < 1240)
                let vu = PanelLayout.clamp(wanted, HeroLayout.minVU, max(HeroLayout.minVU, min(HeroLayout.maxVU, total - gap - HeroLayout.minHistory)))
                return .init(loudness: 0, history: max(0, total - gap - vu), vu: vu)
            }
            return .init(loudness: 0, history: showsHistory ? total : 0, vu: showsVU ? total : 0)
        }
        var result = columns
        if !showsHistory {
            result.loudness += result.history + gap
            result.history = 0
        }
        if !showsVU {
            if showsHistory { result.history += result.vu + gap } else { result.loudness += result.vu + gap }
            result.vu = 0
        }
        return result
    }

    // Store the clamped result, so a drag held against a limit does not churn user defaults.
    private func setLoudness(_ width: CGFloat, row: CGFloat, compact: Bool) {
        let loudness = Double(HeroLayout.columns(width: row, compact: compact, loudness: width, vu: CGFloat(vuWidth)).loudness)
        if loudness != loudnessWidth { loudnessWidth = loudness }
    }

    /// Dragging the divider after the history sizes the history; the VU meter takes the difference.
    private func setVU(history: CGFloat, loudness: CGFloat, row: CGFloat, compact: Bool) {
        if !panels.contains(.loudness) {
            // History and VU alone: the VU takes what the history leaves.
            let vu = Double(PanelLayout.clamp(row + HeroLayout.inset + HeroLayout.trailingInset - HeroLayout.cardGap - history,
                                              HeroLayout.minVU, HeroLayout.maxVU))
            if vu != vuWidth { vuWidth = vu }
            return
        }
        let requested = HeroLayout.available(width: row, compact: compact) - loudness - history
        let vu = Double(HeroLayout.columns(width: row, compact: compact, loudness: loudness, vu: requested).vu)
        if vu != vuWidth { vuWidth = vu }
        // Pin the loudness column where it is, so the VU meter grows into the history and nothing else moves.
        if loudnessWidth == 0 { loudnessWidth = Double(loudness) }
    }
}

/// The loudness panel: title row with the standard's menus, the gauge, the main reading and the statistics tiles.
/// `loudness` is the tiles' column width; the card adds the main reading and its margins.
private struct LoudnessCard: View {
    @ObservedObject var model: MeterModel
    let readouts: Readouts
    let compact: Bool
    let loudness: CGFloat
    let height: CGFloat
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let target = model.loudnessTarget
        let ceiling = model.truePeakCeiling
        let gap = HeroLayout.gap(compact: compact)
        let scale = HeroLayout.contentScale(height: height, compact: compact, loudnessWidth: loudness)
        let gauge = HeroLayout.showsGauge(height: height)
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
                PanelWindowButton(panel: .loudness)
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
                HeroTiles(readouts: readouts, ceiling: Float(ceiling), scale: scale, resetTruePeak: model.resetTruePeak,
                          standard: model.loudnessStandard, target: target)
                    .frame(width: max(0, loudness))
            }
            .frame(maxHeight: .infinity)
            .background { PlotPlate().padding(.horizontal, -8).padding(.bottom, -6) }
        }
        .frame(width: HeroLayout.leadWidth(compact: compact) + gap + max(0, loudness))
        .padding(.leading, HeroLayout.inset)
        .padding(.trailing, HeroLayout.trailingInset)
        .padding(.vertical, HeroLayout.verticalPadding(height: height, compact: compact))
        .frame(maxHeight: .infinity, alignment: .top)
        .background { CardSurface() }
    }

    private var heroTitle: some View {
        HStack(alignment: .center, spacing: 8) {
            Eyebrow(L("LOUDNESS"), color: Theme.title).fixedSize()
            PanelSettingsButton(panel: .loudness, model: model, window: false)
        }
    }

    /// The monitoring format beside the status, when there is room for it.
    private var formatName: String { model.format == .spatial ? model.shownLayoutName : model.format.title }
}

/// The loudness panel on its own (enlarged, or in a window of its own): the card at the width it is given.
struct LoudnessPanel: View {
    @ObservedObject var model: MeterModel
    let readouts: Readouts

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 860
            let loudness = geometry.size.width - HeroLayout.inset - HeroLayout.trailingInset
                - HeroLayout.leadWidth(compact: compact) - HeroLayout.gap(compact: compact)
            LoudnessCard(model: model, readouts: readouts, compact: compact, loudness: loudness, height: geometry.size.height)
        }
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
    @AppStorage(LoudnessUnit.key) private var unitKey = LoudnessUnit.lufs.rawValue

    var body: some View {
        let main = LoudnessReading(rawValue: reading) ?? .shortTerm
        let unit = LoudnessUnit(rawValue: unitKey) ?? .lufs
        let shortTerm = main.value(readouts.values)
        VStack(alignment: .leading, spacing: 3 * scale) {
            Eyebrow(main.heading, color: Theme.sage)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(unit.text(shortTerm, target: target))
                    .font(.system(size: (compact ? 35 : 45) * (1 + (scale - 1) * 0.5), weight: .semibold).monospacedDigit())
                Text(verbatim: unit.title).font(.system(size: 12, weight: .semibold))
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
    /// The standard in use (nil: Custom) and its target, for the compliance tile.
    let standard: LoudnessStandard?
    let target: Double
    @AppStorage(LoudnessReading.key) private var reading = LoudnessReading.shortTerm.rawValue
    @AppStorage(LoudnessUnit.key) private var unitKey = LoudnessUnit.lufs.rawValue

    var body: some View {
        let values = readouts.values
        let main = LoudnessReading(rawValue: reading) ?? .shortTerm
        let unit = LoudnessUnit(rawValue: unitKey) ?? .lufs
        // Two rows on three columns, set like a hardware panel's parameters: the second row's readings sit under
        // the first row's, and its third place holds the verdict against the standard.
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                // The two LUFS readings the main one leaves, in their usual order.
                ForEach(LoudnessReading.allCases.filter { $0 != main }, id: \.self) { other in
                    StatTile(title: other.tileTitle, value: unit.text(other.value(values), target: Float(target)), unit: unit.title,
                             scale: scale)
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
                         template: "−8.8", scale: scale,
                         alert: over ? (values.overs > 1 ? L("OVER ×%d", values.overs) : L("OVER")) : nil)
                    .modifier(TruePeakReset(active: truePeak > ceiling, reset: resetTruePeak))
                let peak = MeterScale.decibels(values.maxPeak)
                StatTile(title: L("PEAK"), value: MeterScale.tenths(peak, floor: -119), unit: "dBFS",
                         color: peak >= 0 ? Theme.ember : Theme.ink, template: "−8.8", scale: scale)
                ComplianceTile(readouts: readouts, standard: standard, target: target, ceiling: Double(ceiling), scale: scale)
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
    let readouts: Readouts
    let target: Float

    var body: some View { LoudnessHistoryPanel(model: model, readouts: readouts) }
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
            SummaryMenu(title: L("TARGET"), value: "\(Self.lufs(target)) LUFS",
                        help: L("TARGET: the loudness standard of the current mode. The gauge, delta, history band and VU meter read against it. Stereo and Immersive each keep their own and follow the mode.")) {
                ForEach(modeOrder, id: \.self) { spatial in
                    Section(sectionTitle(spatial: spatial)) {
                        let chosen = model.standard(spatial: spatial)
                        Picker(L("Loudness target"), selection: Binding(
                            get: { chosen?.id ?? "custom" },
                            set: { id in if let standard = LoudnessStandard.with(id: id) { model.setStandard(standard, spatial: spatial) } })) {
                            ForEach(LoudnessStandard.all) { option in
                                Text(verbatim: Self.row(target: option.target, ceiling: option.ceiling,
                                                        title: option.title + " · " + option.rule)).tag(option.id)
                            }
                            // A target or ceiling set by hand (the panel's settings) shows as its own, checked row.
                            if chosen == nil {
                                Text(verbatim: Self.row(target: spatial ? model.spatialTarget : model.stereoTarget,
                                                        ceiling: spatial ? model.spatialCeiling : model.stereoCeiling,
                                                        title: L("Custom"))).tag("custom")
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

    /// A target in whole LU, or to a tenth when set in half steps.
    static func lufs(_ value: Double) -> String {
        value.rounded() == value ? MeterScale.signedInteger(Float(value)) : MeterScale.signedTenths(Float(value))
    }

    /// "−24 LUFS · ATSC A/85 · Free TV OP-59 · Prime Video  −2.0 dBTP"
    static func row(target: Double, ceiling: Double, title: String) -> String {
        "\(lufs(target)) LUFS · \(title)  (\(MeterScale.tenths(Float(ceiling))) dBTP)"
    }

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
    /// quiet capsule that lifts under the pointer. One shape for every menu (TARGET, CEILING, BANDS).
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        Menu { content.pickerStyle(.inline) } label: {
            label
                .padding(.horizontal, 11)
                .frame(height: 22)
                .background {
                    shape.fill(hovering ? Theme.controlHover : Theme.controlFill)
                        .overlay {
                            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(Theme.dark ? 0.12 : 0.9),
                                                                       Color.white.opacity(Theme.dark ? 0.0 : 0.2)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                        }
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
/// A panel hidden or in a window of its own gives its room to its neighbours; one panel can be enlarged to fill the
/// window; and the window can become a horizontal strip of panels along the bottom of the screen.
private struct MeterView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var placement = PanelPlacement.shared
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
        ZStack {
            if placement.strip {
                StripView(model: model)
                    .transition(.opacity)
            } else {
                window
                    .transition(.opacity)
            }
        }
        .animation(.panelZoom, value: placement.strip)
        .overlay(alignment: .bottom) {
            if !placement.strip {
                PreviewBanner(model: model)
                    .padding(.bottom, 30)
            }
        }
        .frame(minWidth: placement.strip ? StripLayout.minWidth : 1000, minHeight: placement.strip ? StripLayout.minHeight : 628)
        .toolbar(placement.strip ? .hidden : .visible, for: .windowToolbar)
        .background { WindowBackdrop() }
        .background(WindowConfigurator(floating: model.floating))
        .background(WindowOpeners(model: model))
        .background {
            // Esc restores an enlarged panel.
            if placement.enlarged != nil {
                Button("") { placement.restore() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .tint(Theme.action)
    }

    private var window: some View {
        GeometryReader { window in
            let tall = window.size.height >= 940
            let gutter: CGFloat = tall ? 14 : 10
            VStack(spacing: PanelLayout.divider) {
                ZStack {
                    // Never two canvases of one kind at once: the grid leaves at once and the enlarged panel grows in
                    // (and back), so a shared scene is never drawn twice in a frame.
                    if let panel = placement.enlarged {
                        PanelView(panel: panel, model: model)
                            .environment(\.panelContext, .enlarged)
                            .transition(.asymmetric(insertion: .scale(scale: 0.965).combined(with: .opacity), removal: .identity))
                    } else {
                        grid(size: CGSize(width: window.size.width - gutter * 2, height: window.size.height), tall: tall)
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                StatusBar(status: model.status.text, running: model.running, droppedFrames: model.droppedFrames,
                          silentOutput: model.silentOutput, breaks: model.measurementBreaks,
                          missingSeconds: model.missingSeconds)
            }
            .padding(.horizontal, gutter)
            .padding(.top, tall ? 8 : 2)
            .padding(.bottom, 8)
        }
    }

    /// The full arrangement of the panels present. `size` is the window's width inside the gutters and its height.
    private func grid(size: CGSize, tall: Bool) -> some View {
        let total = max(1, size.width)
        let summary = Set([MeterPanel.loudness, .history, .vu].filter(placement.inGrid))
        let analyzersShown = placement.inGrid(.spectrum) || placement.inGrid(.waveform)
        let stageShown = placement.inGrid(.soundstage) || placement.inGrid(.levels)
        let below = analyzersShown || stageShown
        let stage = analyzersShown ? (stageShown ? ColumnLayout.stageWidth(CGFloat(stageWidth), total: total) : 0) : total
        let analyzers = stageShown ? max(1, total - PanelLayout.divider - stage) : total
        let hero = HeroLayout.height(CGFloat(heroHeight), tall: tall, window: size.height)
        return VStack(spacing: PanelLayout.divider) {
            if !summary.isEmpty {
                DashboardHero(model: model, readouts: model.readouts, panels: summary)
                    .frame(height: below ? hero : nil)
                    .frame(maxHeight: below ? nil : .infinity)
                    // Centred in the gap under the summary, so the gap keeps its width.
                    .overlay(alignment: .bottom) {
                        if below {
                            PanelDivider(axis: .vertical, leading: hero,
                                         onResize: { setHero($0, tall: tall, window: size.height) },
                                         onReset: { heroHeight = 0 })
                                .frame(height: PanelLayout.divider)
                                .offset(y: PanelLayout.divider)
                        }
                    }
                    .zIndex(1)
                    .transition(.opacity)
            }
            if below {
                HStack(spacing: 0) {
                    if analyzersShown {
                        analyzerPanels
                            .frame(width: analyzers)
                            .transition(.opacity)
                    }
                    if analyzersShown && stageShown {
                        PanelDivider(axis: .horizontal, leading: analyzers,
                                     onResize: { setStage(total - PanelLayout.divider - $0, total: total) },
                                     onReset: { setStage(ColumnLayout.defaultStage, total: total) })
                            .frame(width: PanelLayout.divider)
                    }
                    if stageShown {
                        stagePanels
                            .frame(width: stage)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private var analyzerPanels: some View {
        GeometryReader { proxy in
            let layout = PanelLayout(height: proxy.size.height, spectrum: CGFloat(spectrumFraction))
            let spectrum = placement.inGrid(.spectrum), waveform = placement.inGrid(.waveform)
            VStack(spacing: 0) {
                if spectrum {
                    PanelView(panel: .spectrum, model: model)
                        .frame(height: waveform ? layout.spectrum : proxy.size.height)
                }
                if spectrum && waveform {
                    PanelDivider(axis: .vertical, leading: layout.spectrum,
                                 onResize: { setSpectrum(layout.draggingSpectrum(to: $0)) },
                                 onReset: { setSpectrum(PanelLayout.defaultSpectrum) })
                        .frame(height: PanelLayout.divider)
                }
                if waveform {
                    PanelView(panel: .waveform, model: model)
                        .frame(height: spectrum ? layout.waveform : proxy.size.height)
                }
            }
        }
    }

    /// The right-hand column: the Soundstage room above Channel Levels, split by a divider.
    private var stagePanels: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            let spatial = model.format == .spatial
            let room = ColumnLayout.roomHeight(share: CGFloat(roomShare), total: total, spatial: spatial)
            let soundstage = placement.inGrid(.soundstage), levels = placement.inGrid(.levels)
            VStack(spacing: 0) {
                if soundstage {
                    PanelView(panel: .soundstage, model: model)
                        .frame(height: levels ? room : total)
                }
                if soundstage && levels {
                    PanelDivider(axis: .vertical, leading: room,
                                 onResize: { setRoom($0, total: total, spatial: spatial) },
                                 onReset: { roomShare = Double(ColumnLayout.defaultRoomShare) })
                        .frame(height: PanelLayout.divider)
                }
                if levels {
                    PanelView(panel: .levels, model: model)
                }
            }
        }
    }

    private func setRoom(_ height: CGFloat, total: CGFloat, spatial: Bool) {
        let share = Double(ColumnLayout.roomHeight(share: height / max(1, total), total: total, spatial: spatial) / max(1, total))
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
    @ObservedObject private var placement = PanelPlacement.shared
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
                Diagnostics.testDomeOrbitIfRequested(model: model)
                Diagnostics.testModeSwitchIfRequested(model: model)
                guard Diagnostics.showAbout else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openWindow(id: "about") }
            }
            .onChange(of: model.showSettings) { requested in
                guard requested else { return }
                model.showSettings = false
                openWindow(id: "settings")
            }
            .onChange(of: placement.windowRequest) { panel in
                guard let panel else { return }
                placement.windowRequest = nil
                openWindow(id: PanelWindow.sceneID, value: panel)
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
                    .help(L("Only digital silence has arrived so far. If an app is playing to this output, allow Auraliscope in Privacy & Security → Screen & System Audio Recording, then choose the output again."))
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
            Text("ITU-R BS.1770-5 · EBU R128")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 8)
    }
}
