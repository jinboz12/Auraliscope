import AppKit
import CoreAudio
import SwiftUI

/// Sections of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, audio, channels, appearance

    static let defaultsKey = "settingsPane"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .audio: return L("Audio")
        case .channels: return L("Channels")
        case .appearance: return L("Appearance")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "mic"
        case .channels: return "hifispeaker.2"
        case .appearance: return "paintpalette"
        }
    }
}

extension MeterModel {
    /// Opens the Settings window, optionally on a given pane.
    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.defaultsKey) }
        SettingsDraft.shared.follow()
        SettingsDraft.shared.attach(self)
        showSettings = true
    }
}

/// Changes made in Settings wait here until Apply. A field holds a value only while it differs from what the app
/// is using; every other field reads through to the live value, so a change made elsewhere meanwhile (the
/// toolbar's mode switch, the appearance button) still shows. Apply writes the pending values in dependency
/// order, then checks each one is really in effect (the language down to the menu bar's items) and reports
/// what could not be applied, which stays pending. Actions (Reset, Toggle Full Screen, Refresh, Open System
/// Settings) are not settings and act at once.
///
/// Preview puts the pending values into effect for a look without keeping them: the app's values are noted
/// first, every change made while previewing shows at once, and Revert, closing Settings or
/// quitting puts the noted values back. Apply keeps them. The source and routing restart the audio, so they wait
/// for Apply.
@MainActor
final class SettingsDraft: ObservableObject {
    static let shared = SettingsDraft()

    @Published var language: AppLanguage?
    @Published var welcome: Bool?
    @Published var source: SourceID?
    @Published var layout: SpeakerLayout?
    @Published var mono: Bool?
    @Published var mode: FormatMode?
    @Published var routing: [Int32]?
    @Published var appearance: AppearanceMode?
    @Published var palette: Theme.Palette?

    enum Outcome: Equatable { case checking, applied, failed([String]) }
    @Published private(set) var outcome: Outcome?
    @Published private(set) var previewing = false
    // A delayed verification belongs to one Apply, never to a later visit or a newer edit.
    private var applyGeneration = 0

    /// The model Settings edits, attached by the Settings view.
    private(set) weak var model: MeterModel?
    func attach(_ model: MeterModel) { self.model = model }

    /// One setting: its pending value in the draft, the value in effect, how to put a value into effect, and
    /// whether it can be previewed. Listed in dependency order: language and theme first, the source before the
    /// format, the format before the mode, the routing last.
    private struct Field {
        let key: AnyKeyPath
        let name: () -> String
        let previewable: Bool
        let pending: (SettingsDraft) -> Any?
        let setPending: (SettingsDraft, Any?) -> Void
        let live: (MeterModel) -> Any
        let write: (Any, MeterModel) -> Void
        let applied: (Any, MeterModel) -> Bool
    }

    private static func field<T: Equatable>(_ key: ReferenceWritableKeyPath<SettingsDraft, T?>, _ name: @escaping () -> String,
                                            previewable: Bool = true, live: @escaping (MeterModel) -> T,
                                            write: @escaping (T, MeterModel) -> Void,
                                            applied: ((T, MeterModel) -> Bool)? = nil) -> Field {
        Field(key: key, name: name, previewable: previewable,
              pending: { $0[keyPath: key] },
              setPending: { $0[keyPath: key] = $1 as? T },
              live: { live($0) },
              write: { value, model in if let value = value as? T { write(value, model) } },
              applied: { value, model in
                  guard let value = value as? T else { return false }
                  return applied?(value, model) ?? (live(model) == value)
              })
    }

    private static func store<T>(_ value: T, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    private static let fields: [Field] = [
        field(\.language, { L("Language") }, live: { _ in Localizer.shared.language },
              write: { value, _ in Localizer.shared.language = value }, applied: { value, _ in Localizer.shared.isApplied(value) }),
        field(\.appearance, { L("Appearance") }, live: { _ in ThemeSettings.shared.mode },
              write: { value, _ in ThemeSettings.shared.mode = value }),
        field(\.palette, { L("Color theme") }, live: { _ in ThemeSettings.shared.palette },
              write: { value, _ in ThemeSettings.shared.palette = value }),
        field(\.welcome, { L("Show welcome at launch") }, previewable: false,
              live: { _ in UserDefaults.standard.object(forKey: WelcomeSheet.showOnLaunchKey) as? Bool ?? true },
              write: { value, _ in store(value, WelcomeSheet.showOnLaunchKey) }),
        field(\.source, { L("Source") }, previewable: false, live: { $0.selectedID }, write: { value, model in model.select(value) }),
        field(\.layout, { L("Immersive format") }, live: { $0.speakerLayout }, write: { value, model in model.speakerLayout = value }),
        field(\.mono, { L("Show Mono mode") }, live: { $0.monoEnabled }, write: { value, model in model.monoEnabled = value }),
        field(\.mode, { L("Monitoring mode") }, live: { $0.formatMode },
              write: { value, model in if model.availableModes.contains(value) { model.formatMode = value } }),
        field(\.routing, { L("Routing") }, previewable: false, live: { $0.sourceForRole },
              write: { value, model in model.assign(routing: value) },
              applied: { routing, model in model.speakerLayout.roles.allSatisfy { model.sourceForRole[$0] == routing[$0] } }),
    ]

    private static func field(for key: AnyKeyPath) -> Field? { fields.first { $0.key == key } }

    var dirty: Bool { Self.fields.contains { $0.pending(self) != nil } }
    /// Routing is edited for the device and format in use, so it waits while either of them is pending.
    var routingLocked: Bool { source != nil || layout != nil }
    /// Pending changes that Preview cannot show (the source and routing restart the audio).
    var unpreviewable: Bool { Self.fields.contains { !$0.previewable && $0.pending(self) != nil } }
    private var previewablePending: Bool { Self.fields.contains { $0.previewable && $0.pending(self) != nil } }

    /// The app's own values, noted when Preview began, by field.
    private var kept: [AnyKeyPath: Any] = [:]

    /// A control's binding: shows the pending value, or the one in effect (while previewing, the one the app
    /// had before); choosing that value clears it. While previewing, a previewable change shows at once.
    func binding<T: Equatable>(_ key: ReferenceWritableKeyPath<SettingsDraft, T?>, live: @escaping () -> T) -> Binding<T> {
        Binding(get: { self[keyPath: key] ?? (self.kept[key] as? T) ?? live() }, set: { value in
            guard self.outcome != .checking else { return }
            let base = (self.kept[key] as? T) ?? live()
            self[keyPath: key] = value == base ? nil : value
            self.outcome = nil
            // A routing draft belongs to its source and format. Never apply it to a newly chosen one.
            if key == \SettingsDraft.source || key == \SettingsDraft.layout { self.routing = nil }
            // Every previewable change shows in the app at once: the first starts the preview (noting what the
            // app had), later ones join it, and it ends once nothing previewable is pending.
            guard let model = self.model, let field = Self.field(for: key), field.previewable else { return }
            if !self.previewing {
                if self.previewablePending { self.setPreview(true) }
            } else {
                field.write(value, model)
                if !self.previewablePending { self.endPreview() }
            }
            // Disabling Mono also removes a pending Mono selection, matching the model's Stereo fallback.
            if key == \SettingsDraft.mono, !model.monoEnabled, self.mode == .mono {
                self.mode = (self.kept[\SettingsDraft.mode] as? FormatMode) == .stereo ? nil : .stereo
            }
        })
    }

    /// Starts the preview (notes the app's values, then shows the pending ones) or ends it (puts the noted values
    /// back).
    private func setPreview(_ on: Bool) {
        guard on != previewing, let model else { return }
        if on {
            SettingsBackup.save()
            kept = [:]
            for field in Self.fields where field.previewable { kept[field.key] = field.live(model) }
            previewing = true
            for field in Self.fields where field.previewable {
                if let value = field.pending(self) { field.write(value, model) }
            }
            SystemMenus.relocalize()
            DiagnosticLog.event("Settings preview on")
        } else {
            endPreview()
        }
    }

    /// Puts back the values noted when Preview began.
    private func endPreview() {
        guard previewing else { return }
        previewing = false
        if let model {
            for field in Self.fields where field.previewable {
                if let value = kept[field.key], !field.applied(value, model) { field.write(value, model) }
            }
        }
        kept = [:]
        SettingsBackup.clear()
        SystemMenus.relocalize()
        DiagnosticLog.event("Settings preview off")
    }

    private var closing: NSObjectProtocol?
    private var rehearsed = false

    /// Pending changes belong to one visit: closing the Settings window drops them (and ends a preview), so it
    /// always reopens on what the app is using. (Not on the view disappearing: a new appearance rebuilds the
    /// view mid-visit.)
    func follow() {
        guard closing == nil else { return }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let id = (note.object as? NSWindow)?.identifier?.rawValue ?? ""
            guard id.hasPrefix("settings") else { return }
            MainActor.assumeIsolated { SettingsDraft.shared.revert() }
        }
    }

    func revert() {
        applyGeneration += 1
        endPreview()
        for field in Self.fields { field.setPending(self, nil) }
        outcome = nil
    }

    func apply(model: MeterModel) {
        guard dirty, outcome != .checking else { return }
        applyGeneration += 1
        let generation = applyGeneration
        let staged = Self.fields.compactMap { field in field.pending(self).map { (field, $0) } }
        outcome = .checking
        // Preview already shows the previewable values; Apply keeps them instead of putting the old ones back.
        previewing = false
        kept = [:]
        for (field, value) in staged where !field.applied(value, model) { field.write(value, model) }
        SettingsBackup.clear()
        // Checked once SwiftUI and AppKit have rebuilt the menus and views for the new values.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            MainActor.assumeIsolated {
                guard self.applyGeneration == generation else { return }
                self.verify(staged, model: model, generation: generation)
            }
        }
    }

    /// Diagnostics (`--settings-apply`): stages a language and Light, applies, and prints what came of it.
    func rehearse(language: AppLanguage, model: MeterModel) {
        guard !rehearsed else { return }
        rehearsed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            MainActor.assumeIsolated {
                self.language = language
                self.appearance = .light
                print("settings staged: dirty \(self.dirty)")
                guard !Diagnostics.settingsStageOnly else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated {
                        self.apply(model: model)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            MainActor.assumeIsolated {
                                print("settings outcome: \(String(describing: self.outcome)) dirty: \(self.dirty) language: \(Localizer.shared.language.rawValue) code: \(Localizer.shared.code) theme: \(ThemeSettings.shared.mode.rawValue)")
                                if let menu = NSApp.mainMenu {
                                    for item in menu.items { print("menu: \(item.title) → \(item.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [])") }
                                }
                                print("windows: \(NSApp.windows.compactMap { $0.identifier?.rawValue })")
                                fflush(stdout)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Diagnostics (`--settings-preview`): previews the other appearance, changes the palette and Mono while
    /// previewing, then reverts, and prints what the app uses at each step.
    func rehearsePreview(model: MeterModel) {
        guard !rehearsed else { return }
        rehearsed = true
        func report(_ step: String) {
            print("preview \(step): previewing \(previewing) dirty \(dirty) theme \(ThemeSettings.shared.mode.rawValue) palette \(ThemeSettings.shared.palette.rawValue) mono \(model.monoEnabled)")
            fflush(stdout)
        }
        func later(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
        }
        later(1) {
            report("before")
            // The opposite of what is in use, so every step changes something whatever was stored.
            let appearance: AppearanceMode = ThemeSettings.shared.mode == .light ? .dark : .light
            let palette = Theme.Palette.allCases.first { $0 != ThemeSettings.shared.palette } ?? ThemeSettings.shared.palette
            self.binding(\.appearance, live: { ThemeSettings.shared.mode }).wrappedValue = appearance
            report("staged, previewing at once")
            self.binding(\.palette, live: { ThemeSettings.shared.palette }).wrappedValue = palette
            self.binding(\.mono, live: { model.monoEnabled }).wrappedValue = !model.monoEnabled
            report("changed while on")
            guard !Diagnostics.settingsPreviewHold else { return }
            later(1) {
                self.setPreview(false)
                report("off")
                self.setPreview(true)
                report("on again")
                self.revert()
                report("reverted")
            }
        }
    }

    /// A value in effect leaves the draft; one that is not stays pending, so Apply can be tried again. Checked
    /// against the values as Apply found them, whatever happened to the draft meanwhile (a new appearance
    /// rebuilds the Settings view).
    private func verify(_ staged: [(Field, Any)], model: MeterModel, generation: Int) {
        SystemMenus.relocalize()
        var failed: [String] = []
        for (field, value) in staged {
            if field.applied(value, model) {
                if let pending = field.pending(self), field.applied(pending, model) { field.setPending(self, nil) }
            } else {
                failed.append(field.name())
                field.setPending(self, value)
            }
        }
        outcome = failed.isEmpty ? .applied : .failed(failed)
        // The confirmation shows for a moment, then the bar leaves with it (a failure stays until acted on).
        if failed.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                MainActor.assumeIsolated {
                    if self.applyGeneration == generation, self.outcome == .applied { self.outcome = nil }
                }
            }
        }
        DiagnosticLog.event(failed.isEmpty ? "Settings applied" : "Settings not applied: \(failed.joined(separator: ", "))")
    }
}

/// One set of measures for every Settings page, so each starts its title, sections, rows and notes at the same
/// places: one text column from the page title down to the last note, whichever page is shown and whether or not
/// it scrolls.
enum SettingsMetrics {
    /// The page's margin either side of its column, and the widest the column grows.
    static let gutter: CGFloat = 28
    static let column: CGFloat = 640
    /// Inside a card: every row's and note's inset from its edge, and a row's height.
    static let inset: CGFloat = 16
    static let row: CGFloat = 40
    /// Between sections, and from a section's title to its card.
    static let sectionGap: CGFloat = 24
    static let titleGap: CGFloat = 8
    static let radius: CGFloat = 16
}

/// Settings as a page of its own: a sidebar of five panes and a scrolling detail column of grouped cards, with
/// Revert and Apply along its foot. The window's night sky (`WindowBackdrop`) runs under the title bar, the sidebar and
/// the cards, which are the meter's glass panels.
struct SettingsView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var draft = SettingsDraft.shared
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsPane.defaultsKey) private var paneName = SettingsPane.general.rawValue
    @Namespace private var selection

    private var pane: SettingsPane { SettingsPane(rawValue: paneName) ?? .general }
    /// The top of the page, scrolled to when the pane changes.
    private static let top = "settingsTop"

    /// Another pane: the sidebar's selection glides to it and its page rises into place.
    private func show(_ item: SettingsPane) {
        guard item != pane else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.page) { paneName = item.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .layoutPriority(1)
                .frame(maxHeight: .infinity)
                .background { Theme.sidebarTint.ignoresSafeArea() }
            Rectangle().fill(Theme.hairline.opacity(Theme.dark ? 0.09 : 0.11)).frame(width: 0.5).ignoresSafeArea()
            ScrollViewReader { scroller in
                ScrollView {
                    // The page takes the width the scroll view offers, and its scroller floats over the gutter
                    // (`OverlayScrollers`), so the column has the same margins on every page, scrolling or not. A width
                    // of its own made a page that scrolls sit half a scroller to the left of one that does not.
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(height: 0).id(Self.top)
                        page(pane)
                            .id(pane)
                            .transition(reduceMotion ? .opacity
                                        : .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
                    }
                    .disabled(draft.outcome == .checking)
                    .frame(maxWidth: SettingsMetrics.column, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.gutter)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OverlayScrollers())
                }
                // Another page opens at its top, not at the previous page's scroll position.
                .onChange(of: paneName) { _ in scroller.scrollTo(Self.top, anchor: .top) }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            // Revert and Apply appear only while there are changes to apply (and briefly with the result).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if draft.dirty || draft.outcome != nil {
                    ApplyBar(model: model, draft: draft)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.page, value: draft.dirty || draft.outcome != nil)
        }
        .background { WindowBackdrop() }
        .onAppear {
            draft.attach(model)
            if Diagnostics.testSettingsDraft { draft.checkRegression(model: model) }
            if let language = Diagnostics.settingsApply { draft.rehearse(language: language, model: model) }
            if Diagnostics.settingsPreview { draft.rehearsePreview(model: model) }
        }
        .frame(minWidth: 740, minHeight: 520)
        .background(UtilityWindowProbe(title: L("Settings"), capture: Diagnostics.showSettings))
        .tint(Theme.action)
    }

    /// A pane's page: its title on the column's text edge, then its sections.
    private func page(_ pane: SettingsPane) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            PageTitle(pane.title)
                .padding(.leading, SettingsMetrics.inset)
                .padding(.bottom, -6)
            switch pane {
            case .general: GeneralPane(model: model)
            case .audio: AudioPane(model: model)
            case .channels: ChannelsPane(model: model)
            case .appearance: AppearancePane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            BrandMark(size: 10)
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                StatusDot(running: model.running, pulse: true)
                Text(model.captureStateTitle.uppercased(with: l10n.locale))
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
            // Rows of our own rather than the system list: its selection turns the macOS grey whenever Settings is
            // not the key window (and after an appearance change), so here the selection is always the colour
            // theme's accent. The arrow keys still move between panes.
            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    SidebarRow(item: item, selected: item == pane, selection: selection) { show(item) }
                }
            }
            .modifier(QuietFocus())
            .onMoveCommand { direction in
                let all = SettingsPane.allCases, index = all.firstIndex(of: pane) ?? 0
                switch direction {
                case .up: show(all[max(0, index - 1)])
                case .down: show(all[min(all.count - 1, index + 1)])
                default: break
                }
            }
            Spacer(minLength: 12)
            // Actions, not settings: they act at once.
            Button { model.resetMeasurements() } label: {
                Label(L("Reset measurements"), systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            // Red here, where it sits among settings: it clears the session. The meter window's own Reset keeps
            // its quiet style.
            .glassButton(prominent: true)
            .tint(Theme.ember)
            .help(L("Start every measurement over: Integrated loudness, Range, peaks and the loudness history"))
            .padding(.horizontal, 2)
            Button { openWindow(id: "about") } label: {
                Label(L("About Auraliscope"), systemImage: "info.circle")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .glassButton()
            .padding(.horizontal, 2)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
    }
}

/// Gives the enclosing scroll view overlay scrollers, which float over the content and show while it scrolls, even
/// when System Settings shows scroll bars always (a mouse is attached): a legacy scroller takes room from the page, so
/// a page that scrolls would be narrower than one that does not. AppKit puts the system's style back when that
/// preference changes, so it is set again then.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        private var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                // After the scroll view has taken the new system style.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
            }
        }

        func apply() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Takes keyboard focus for the arrow keys without drawing a focus ring (the selection already shows where it is).
private struct QuietFocus: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.focusable().focusEffectDisabled()
        } else {
            content.focusable()
        }
    }
}

/// A pane in the Settings sidebar: its symbol and name, on the accent when selected. The selection is one plate that
/// glides from row to row; the symbol bounces as its pane is chosen.
private struct SidebarRow: View {
    let item: SettingsPane
    let selected: Bool
    let selection: Namespace.ID
    let select: () -> Void
    @ObservedObject private var theme = ThemeSettings.shared
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            select()
        } label: {
            // Symbols in a fixed column, so every name starts at the same x.
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14))
                    .symbolVariant(selected ? .fill : .none)
                    .modifier(SymbolMotion(bounce: taps))
                    .frame(width: 20)
                Text(item.title)
            }
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onAction : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                    if selected {
                        shape.fill(Theme.action)
                            .shadow(color: Theme.glow(Theme.action, 0.45), radius: 8, y: 2)
                            .matchedGeometryEffect(id: "pane", in: selection)
                    } else if hovering {
                        shape.fill(Theme.controlHover)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var draft = SettingsDraft.shared
    @AppStorage(CanvasDriver.frameRateKey) private var frameRate = 0

    var body: some View {
        SettingsSection(title: L("PRESETS")) {
            SettingsPresetsSection(model: model)
            SettingsNote(L("A preset keeps your language, appearance, monitoring and loudness choices, every panel's settings and the layout, to load again later. The source and its routing stay with your devices."))
        }
        SettingsSection(title: L("LANGUAGE")) {
            SettingsRow(title: L("Language")) {
                Picker(L("Language"), selection: draft.binding(\.language, live: { l10n.language })) {
                    ForEach(AppLanguage.allCases) { language in Text(verbatim: language.nativeName).tag(language) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: l10n.language) { DiagnosticLog.event("Language: \($0.rawValue)") }
            }
            SettingsNote(L("Language previews immediately, including the menu bar, while metering carries on. Apply keeps it; Revert restores your previous language. Units, channel labels and standards keep their console and DAW notation."))
        }
        SettingsSection(title: L("WINDOW")) {
            SettingsRow(title: L("Always on top")) {
                Toggle(L("Always on top"), isOn: $model.floating)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            SettingsNote(L("Keeps the meter window, and any panel in a window of its own, above other apps' windows. Off until you turn it on, here or with the pin in the toolbar; it pauses in full screen."))
            SettingsDivider()
            SettingsRow(title: L("Full screen")) {
                Button { MainWindow.toggleFullScreen() } label: {
                    Label(L("Toggle Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .glassButton()
            }
            SettingsNote(L("Or use the green window button, or View ▸ Enter Full Screen (⌃⌘F)."))
            SettingsDivider()
            SettingsRow(title: L("Dock mode")) {
                Button { PanelPlacement.shared.toggleStrip() } label: {
                    Label(L("Dock Mode"), systemImage: "dock.rectangle")
                }
                .glassButton()
            }
            SettingsNote(L("Dock mode lays the panels in one row along the bottom of the screen (⌥⌘S)."))
            SettingsDivider()
            SettingsRow(title: L("Layout")) {
                Button { LayoutPresets.shared.apply(LayoutPresets.builtIns[0]) } label: {
                    Label(L("Reset Layout"), systemImage: "rectangle.split.2x2")
                }
                .glassButton()
            }
            SettingsNote(L("Layout ▸ Save Layout… keeps an arrangement of panels and dividers; each panel's title row can enlarge it (⌘1…⌘7) or open it in a window of its own."))
        }
        SettingsSection(title: L("PERFORMANCE")) {
            SettingsRow(title: L("Display frame rate")) {
                Picker(L("Display frame rate"), selection: Binding(get: { frameRate }, set: { rate in
                    frameRate = rate
                    CanvasDriver.shared.restart()
                    DiagnosticLog.event("Frame rate: \(rate)")
                })) {
                    Text(L("Automatic")).tag(0)
                    Text(verbatim: "120 fps").tag(120)
                    Text(verbatim: "60 fps").tag(60)
                    Text(verbatim: "30 fps").tag(30)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsNote(L("How often the meters redraw. Automatic follows the display: 120 fps on a ProMotion display, 60 on others, 30 in Low Power Mode. 30 fps about halves the drawing work, for a laptop on battery or a busy session; the measurement itself is the same. Takes effect at once."))
        }
        SettingsNote(L("Hidden panels stop drawing. Measurements continue; the optional Multi-FFT engine stops when its panel closes."))
        SettingsSection(title: L("STARTUP")) {
            SettingsRow(title: L("Show welcome at launch")) {
                Toggle(L("Show welcome at launch"), isOn: draft.binding(\.welcome, live: {
                    UserDefaults.standard.object(forKey: WelcomeSheet.showOnLaunchKey) as? Bool ?? true
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
        SettingsSection(title: L("UPDATES")) {
            PrereleaseUpdatesRow()
            GitHubUpdateView()
        }
        SettingsSection(title: L("FEEDBACK")) {
            SettingsRow(title: L("Website")) {
                Link(destination: URL(string: "https://jinbozmusic.com")!) {
                    Label { Text(verbatim: "jinbozmusic.com") } icon: { Image(systemName: "globe") }
                }
                .glassButton()
            }
            SettingsDivider()
            SettingsRow(title: "Discord") {
                Link(destination: URL(string: "https://discord.gg/J5sd8qbtNW")!) {
                    Label(L("Join the Discord"), systemImage: "bubble.left.and.bubble.right")
                }
                .glassButton()
            }
            SettingsNote(L("Questions, bug reports and ideas are welcome. Diagnostic logs (Help ▸ Show Diagnostic Logs) help with a bug report."))
        }
    }
}

private struct AudioPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var draft = SettingsDraft.shared

    /// The two kinds of source: the Mac's own audio devices (inputs, and what apps play to outputs), analysed
    /// here; or the Auraliscope Bridge inserts in a DAW, which analyse their audio themselves.
    private enum SourceKind: Hashable { case devices, plugins }

    var body: some View {
        let source = draft.binding(\.source, live: { model.selectedID })
        let kind = source.wrappedValue.bridge != nil ? SourceKind.plugins : .devices
        SettingsSection(title: L("DEVICE")) {
            SettingsRow(title: L("Source type")) {
                Picker(L("Source type"), selection: Binding(get: { kind }, set: { wanted in
                    guard wanted != kind else { return }
                    // Back to the kind in use: what is in use. Otherwise the kind's own choice (see the model).
                    let live = model.selectedID
                    if wanted == .plugins {
                        source.wrappedValue = live.bridge != nil ? live : model.preferredPluginSource()
                    } else {
                        source.wrappedValue = live.bridge == nil ? live : model.preferredDeviceSource()
                    }
                })) {
                    Text(L("Audio devices")).tag(SourceKind.devices)
                    Text(L("Host plugins")).tag(SourceKind.plugins)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            SettingsDivider()
            SettingsRow(title: L("Source")) {
                HStack(spacing: 6) {
                    Picker(L("Source"), selection: source) {
                        if kind == .devices {
                            let hardware = model.devices.filter { !$0.isBridge }
                            let inputs = hardware.filter { !$0.output }, outputs = hardware.filter(\.output)
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
                        } else {
                            let plugins = model.devices.filter(\.isBridge)
                            let waiting = model.selectedID.bridge != nil && model.selectedID != .anyPlugin
                                && !plugins.contains { $0.id == model.selectedID }
                            Section(L("DAW plugins · Auraliscope Bridge")) {
                                Text(plugins.isEmpty ? L("No DAW plugin connected") : L("Choose a DAW plugin"))
                                    .tag(SourceID.anyPlugin)
                                ForEach(plugins) { device in
                                    // Inserts that could be the saved one, while that is ambiguous, are marked.
                                    let candidate = device.bridgeSession.map(model.bridgeCandidates.contains) ?? false
                                    Text(verbatim: "\(candidate ? "◆ " : "")\(device.detail) · \(device.channels) ch").tag(device.id)
                                }
                                if waiting {
                                    let name = model.selectedDevice?.name
                                        ?? UserDefaults.standard.string(forKey: "bridgeSourceName") ?? L("DAW plugin")
                                    Text(model.bridgeCandidates.isEmpty ? L("%@ (waiting)", name)
                                         : L("%@ (choose one of the ◆ inserts)", name))
                                        .tag(model.selectedID)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Button(action: model.refreshDevices) { Image(systemName: "arrow.clockwise") }
                        .glassIconButton()
                        .help(L("Refresh devices"))
                }
            }
            SettingsDivider()
            SettingsRow(title: L("Status")) {
                Text(model.status.text)
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.status.text)
            }
            if model.silentOutput {
                Label(L("Only digital silence has arrived so far. If an app is playing to this output, allow Auraliscope in Privacy & Security → Screen & System Audio Recording, then choose the output again."),
                      systemImage: "speaker.slash")
                    .font(.system(size: 11)).foregroundStyle(Theme.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.incompatibleBridgePlugins.isEmpty {
                Label(L("An Auraliscope Bridge of another version is connected (%@). Install the Bridge that comes with this Auraliscope, then reopen the project.",
                        model.incompatibleBridgePlugins.map { $0.hostName }.joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if kind == .devices {
                SettingsNote(L("Inputs are read directly. An output (macOS 14.2 or later) is read through a Core Audio tap: Auraliscope meters what every app plays to it, such as your DAW's monitor or headphone bus, without changing or delaying the signal."))
                SettingsNote(L("At launch, Auraliscope meters the current macOS default output, what your Mac is playing (the default input before macOS 14.2)."))
            } else {
                SettingsNote(model.bridgeError.map { L("DAW plugin receiver unavailable: %@", $0) }
                    ?? L("DAW plugins: insert Auraliscope Bridge (VST3 or AU) on a track, bus or master in your DAW; each instance appears here under its name. Mono and stereo inserts are supported, and in VST3 immersive buses up to 9.1.6."))
                SettingsNote(L("Each insert measures its own audio inside the DAW; Auraliscope shows its results. The plugin window's button also chooses its insert here."))
            }
        }
        SettingsSection(title: L("PRIVACY")) {
            SettingsRow(title: L("Microphone access")) { PermissionControl() }
            SettingsNote(L("Needed to meter any input. After changing it in System Settings, click the arrow to check again."))
            SettingsDivider()
            SettingsRow(title: L("System audio recording")) {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                } label: {
                    Label(L("Open System Settings"), systemImage: "gear")
                }
                .glassButton()
            }
            SettingsNote(L("Needed to meter an output. macOS asks when output capture starts. If the meters stay silent, allow Auraliscope in Privacy & Security → Screen & System Audio Recording, then choose the output again."))
        }
        // The pane never shows a state from before a change made in System Settings.
        .onAppear { AudioPermission.shared.refresh() }
    }
}

private struct ChannelsPane: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var draft = SettingsDraft.shared

    var body: some View {
        SettingsSection(title: L("FORMAT")) {
            // The four-segment mode picker gets a full-width row of its own: beside the diagram it made the
            // pane wider than the window's default size.
            HStack(alignment: .center, spacing: 16) {
                LayoutDiagram(layout: model.layoutFromPlugin ? model.shownLayout : draft.layout ?? model.speakerLayout)
                    .frame(width: 96, height: 96)
                SettingsRow(title: L("Immersive format")) {
                    if model.layoutFromPlugin {
                        // A DAW plugin's immersive bus: its own format, not a choice.
                        Text(verbatim: L("%@ · %d channels", model.shownLayoutName, Int(model.selectedDevice?.channels ?? 0)))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .frame(width: 170, alignment: .leading)
                    } else {
                        Picker(L("Immersive format"), selection: draft.binding(\.layout, live: { model.speakerLayout })) {
                            ForEach(SpeakerLayout.allCases) { layout in
                                Text(L("%@ · %d channels", layout.name, layout.channelCount)).tag(layout)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }
            .padding(.vertical, SettingsMetrics.inset - 4)
            if model.layoutFromPlugin {
                SettingsNote(L("The DAW plugin's bus sets the format and the routing: each of its channels feeds its own speaker. The format chosen here returns with audio devices."))
            }
            SettingsDivider()
            SettingsRow(title: L("Show Mono mode")) {
                Toggle(L("Show Mono mode"), isOn: draft.binding(\.mono, live: { model.monoEnabled }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            SettingsNote(L("Mono reads only the input routed to L and is rarely needed, so it stays out of the mode selector, the Meter menu and Auto until you turn it on."))
            SettingsDivider()
            // The panels' glass switch, trailing like every other row's control.
            SettingsRow(title: L("Monitoring mode")) {
                let showsMono = draft.mono ?? model.monoEnabled
                let modes = FormatMode.allCases.filter { showsMono || $0 != .mono }
                let chosen = draft.mode ?? model.formatMode
                GlassSegments(label: L("Monitoring mode"), options: modes.map { ($0, $0.title, $0.title) },
                              selection: modes.contains(chosen) ? chosen : .stereo,
                              select: { draft.binding(\.mode, live: { model.formatMode }).wrappedValue = $0 })
            }
            SettingsNote(L("Immersive shows every channel of this format in Soundstage, Channel Levels and Waveform; Stereo shows L and R with their correlation; Mono reads only the input routed to L. Auto follows the programme between Stereo and Immersive, and picks Mono for a single routed input when Mono is shown."))
        }
        SettingsSection(title: L("ROUTING")) {
            HStack {
                Text(verbatim: model.selectedDevice.map { "\($0.output ? L("%@ (output)", $0.name) : $0.name) · \($0.channels) ch" } ?? L("No audio device"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                ChannelOrderMenu(model: model)
                    .disabled(draft.routingLocked || model.layoutFromPlugin)
            }
            .frame(minHeight: SettingsMetrics.row)
            if model.selectedDevice != nil && !model.layoutFromPlugin {
                DeviceSpeakersNote(model: model)
            }
            if model.selectedDevice?.name.localizedCaseInsensitiveContains("Pro Tools") == true && !model.layoutFromPlugin {
                SettingsNote(L("Pro Tools sends surround in film order (L C R Ls Rs LFE…), not in SMPTE order (L R C LFE Ls Rs…): with SMPTE order its surrounds are shown at the front. Set its speakers up in Audio MIDI Setup or choose Channel Order ▸ Film Order, unless its I/O Setup is remapped, and the format that matches its output bus."))
            }
            ForEach(model.shownLayout.groups, id: \.self) { group in
                SettingsDivider()
                HStack(spacing: 6) {
                    Capsule().fill(Theme.groupColor(group)).frame(width: 8, height: 3)
                    Text(group.localizedName.uppercased(with: l10n.locale))
                        .font(.system(size: 9, weight: .semibold).width(.expanded)).tracking(l10n.tracking(1))
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.bottom, 2)
                ForEach(model.shownLayout.speakers.filter { $0.group == group }, id: \.role) { speaker in
                    RoutingRow(model: model, speaker: speaker)
                        .disabled(draft.routingLocked || model.layoutFromPlugin)
                }
            }
            if draft.routingLocked {
                SettingsNote(L("Apply the source and format first, then route their channels."))
            }
            SettingsNote(L("Routing is saved per device and format. A change restarts capture and resets Integrated LUFS. LFE shows Peak and RMS but is excluded from LUFS, per BS.1770."))
        }
    }
}

/// Routes every channel of the format in one go (staged, applied with the rest): as the device's speakers are set up
/// in Audio MIDI Setup, or in a host's channel order.
private struct ChannelOrderMenu: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var draft = SettingsDraft.shared

    var body: some View {
        let speakers = model.deviceSpeakers
        Menu {
            Button(speakers.map { L("Audio MIDI Setup (%@)", $0.name) } ?? L("Audio MIDI Setup")) { stage(model.deviceAssignment) }
                .disabled(speakers == nil)
            Divider()
            Button(L("SMPTE / ITU: L R C LFE Ls Rs…")) { stage(model.smpteAssignment) }
            Button(L("Film (Pro Tools): L C R Ls Rs LFE…")) { stage(model.filmAssignment) }
            Button(L("VST3 (Nuendo, Cubase): L R C LFE Lrs Rrs Lss Rss…")) { stage(model.vst3Assignment) }
        } label: {
            Label(L("Channel Order"), systemImage: "list.number")
        }
        .menuStyle(.button)
        .glassButton()
        .fixedSize()
        .help(L("Routes every channel of this format at once: as the device's speakers are set up in Audio MIDI Setup, or in a host's channel order"))
    }

    private func stage(_ routing: [Int32]?) {
        guard let routing else { return }
        draft.binding(\.routing, live: { model.sourceForRole }).wrappedValue = routing
    }
}

/// Where the device's default routing comes from: its speaker configuration in Audio MIDI Setup, or SMPTE order.
private struct DeviceSpeakersNote: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var draft = SettingsDraft.shared

    var body: some View {
        let speakers = model.deviceSpeakers
        let format = draft.layout ?? model.speakerLayout
        if let speakers {
            SettingsNote(L("Audio MIDI Setup sets this device's speakers up as %@: unless you route them here, its channels feed those speakers.", speakers.name))
            if let layout = speakers.layout, layout != format {
                HStack(alignment: .firstTextBaseline) {
                    SettingsNote(L("The format chosen above is %@: speakers it has that Audio MIDI Setup does not describe stay unrouted.", format.name))
                    Button {
                        draft.binding(\.layout, live: { model.speakerLayout }).wrappedValue = layout
                    } label: {
                        Label(L("Use %@", layout.name), systemImage: "hifispeaker.2")
                    }
                    .glassButton()
                    .fixedSize()
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                SettingsNote(L("No speakers are set up for this device in Audio MIDI Setup, so input 1 feeds the first channel in SMPTE order, input 2 the second, and so on. Set them up there (Configure Speakers), or choose a Channel Order."))
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                } label: {
                    Label(L("Audio MIDI Setup…"), systemImage: "pianokeys")
                }
                .glassButton()
                .fixedSize()
            }
        }
    }
}

private struct RoutingRow: View {
    @ObservedObject var model: MeterModel
    let speaker: Speaker
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var draft = SettingsDraft.shared

    var body: some View {
        SettingsRow(title: speaker.name, monospaced: true) {
            Picker(selection: Binding(get: { (draft.routing ?? model.sourceForRole)[speaker.role] }, set: { source in
                var routing = draft.routing ?? model.sourceForRole
                routing[speaker.role] = source
                draft.binding(\.routing, live: { model.sourceForRole }).wrappedValue = routing
            })) {
                Text(L("Off")).tag(Int32(-1))
                ForEach(0..<Int(min(model.selectedDevice?.channels ?? 0, 64)), id: \.self) { source in
                    Text(model.selectedDevice?.isBridge == true ? L("Channel %d", source + 1)
                         : model.selectedDevice?.output == true ? L("Output %d", source + 1) : L("Input %d", source + 1)).tag(Int32(source))
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

private struct AppearancePane: View {
    @ObservedObject private var l10n = Localizer.shared
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var draft = SettingsDraft.shared

    var body: some View {
        let mode = draft.binding(\.appearance, live: { theme.mode })
        let palette = draft.binding(\.palette, live: { theme.palette })
        SettingsSection(title: L("INTERFACE")) {
            HStack(spacing: 18) {
                ForEach(AppearanceMode.allCases) { option in
                    AppearanceOption(mode: option, palette: palette.wrappedValue, selected: mode.wrappedValue == option) {
                        mode.wrappedValue = option
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, SettingsMetrics.inset - 4)
            SettingsNote(L("Auto follows macOS. The sun and moon button in the toolbar, or View ▸ Appearance, switches between Light and Dark at any time."))
        }
        SettingsSection(title: L("COLOR")) {
            SettingsRow(title: L("Color theme")) {
                ThemePicker(selection: Binding(get: { palette.wrappedValue.rawValue },
                                               set: { palette.wrappedValue = Theme.Palette(rawValue: $0) ?? .standard }))
                    .frame(width: 205, height: 26)
                    .background {
                        if #available(macOS 26, *) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.ink.opacity(Theme.dark ? 0.10 : 0.06))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.14 : 0.12), lineWidth: 0.5)
                                }
                        }
                    }
            }
            SettingsNote(L("The theme's accent colors the controls, traces and level meters in both appearances. In Light it is deepened just enough to stay legible on white."))
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
    /// Group name in Settings, in the current language; the Soundstage on the meter prints `groupTitle`.
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
        .background(Theme.display, in: RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
        .accessibilityLabel(Text(verbatim: layout.name))
    }
}

/// The foot of the Settings detail column while there are changes: their state, then Revert and Apply (Return);
/// after Apply, the result for a moment.
private struct ApplyBar: View {
    let model: MeterModel
    @ObservedObject var draft: SettingsDraft
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 10) {
            status
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if draft.dirty {
                Button { draft.revert() } label: { Label(L("Revert"), systemImage: "arrow.uturn.backward") }
                    .glassButton()
                    .disabled(draft.outcome == .checking)
                Button { draft.apply(model: model) } label: { Label(L("Apply"), systemImage: "checkmark") }
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.outcome == .checking)
            }
        }
        .padding(.horizontal, SettingsMetrics.gutter + SettingsMetrics.inset)
        .padding(.vertical, 12)
        .background {
            // Frosted over the page that scrolls under it.
            Rectangle().fill(.ultraThinMaterial)
                .overlay { Theme.sidebarTint }
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline.opacity(Theme.dark ? 0.09 : 0.11)).frame(height: 0.5) }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch draft.outcome {
        case .checking:
            Label(L("Applying…"), systemImage: "hourglass").foregroundStyle(Theme.secondary)
        case .failed(let names):
            Label(L("Could not apply: %@", names.joined(separator: ", ")), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.ember)
        case .applied where !draft.dirty:
            Label(L("All changes applied."), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.sage)
        default:
            if draft.previewing {
                Label(draft.unpreviewable ? L("Previewing. Source and routing change on Apply.") : L("Previewing in the main window. Apply to keep, or Revert."),
                      systemImage: "eye.fill")
                    .foregroundStyle(Theme.sage)
            } else {
                Label(L("Changes are not applied yet."), systemImage: "circle.fill").foregroundStyle(Theme.ochre)
            }
        }
    }
}

/// On the meter window while Settings previews changes: says so, with Revert and Apply at hand.
struct PreviewBanner: View {
    let model: MeterModel
    @ObservedObject private var draft = SettingsDraft.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        ZStack {
            if draft.previewing { banner }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: draft.previewing)
    }

    private var banner: some View {
            HStack(spacing: 10) {
                Label(L("Previewing settings"), systemImage: "eye.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Button { draft.revert() } label: { Label(L("Revert"), systemImage: "arrow.uturn.backward") }
                    .glassButton()
                    .controlSize(.small)
                Button { draft.apply(model: model) } label: { Label(L("Apply"), systemImage: "checkmark") }
                    .glassButton(prominent: true)
                    .controlSize(.small)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassSurface(RoundedRectangle(cornerRadius: Theme.controlRadius + 4, style: .continuous),
                          tint: Theme.sage.opacity(Theme.dark ? 0.16 : 0.10))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A titled group of settings: its title on the column's text edge, then one glass card (the meter's panel surface)
/// whose rows and notes all sit at `SettingsMetrics.inset` from its edge. Row groups (a row and its note) are parted by
/// `SettingsDivider`.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.titleGap) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(Localizer.shared.tracking(0.6))
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, SettingsMetrics.inset)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, SettingsMetrics.inset)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { CardSurface(radius: SettingsMetrics.radius) }
        }
    }
}

/// The hairline between two row groups of a card, the same in every pane.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline.opacity(Theme.dark ? 0.10 : 0.12)).frame(height: 0.5)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var monospaced = false
    @ViewBuilder var control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label.fixedSize()
                Spacer(minLength: 8)
                control
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                control.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 8)
        }
        .frame(minHeight: SettingsMetrics.row)
    }

    private var label: some View {
        Text(title)
            .font(monospaced ? .system(size: 13, weight: .medium).monospaced() : .system(size: 13))
    }
}

/// The explanation under a row: as wide as the card's text column, with the same space below it in every pane.
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .lineSpacing(Localizer.shared.paragraphSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
    }
}
