import AppKit
import SwiftUI

/// Saved arrangements of the main window: which panels show, every divider's position and the strip's panels. A few
/// come built in; the user saves their own under a name (Layout ▸ Save Layout…). Applying one animates the window
/// into it. Panel display settings (scales, colours, bands) are not part of a layout: they belong to the panel.
@MainActor
final class LayoutPresets: ObservableObject {
    static let shared = LayoutPresets()
    private static let storeKey = "layout.presets"

    struct Preset: Identifiable, Equatable {
        let name: String
        /// Stored keys and their values; keys missing here go back to their defaults.
        let values: [String: Any]
        var id: String { name }
        static func == (a: Preset, b: Preset) -> Bool { a.name == b.name }
    }

    /// Built in: the full window, the analyzers large, and loudness with levels.
    struct BuiltIn: Identifiable {
        let title: String
        let hidden: Set<MeterPanel>
        let values: [String: Any]
        var id: String { title }
    }

    static var builtIns: [BuiltIn] {
        [BuiltIn(title: L("Full Meter"), hidden: [], values: [:]),
         BuiltIn(title: L("Analysis"), hidden: [.history, .vu, .levels],
                 values: ["layout.analyzerShare": 0.7, "layout.stageWidth": 460.0]),
         BuiltIn(title: L("Loudness & Levels"), hidden: [.spectrum, .waveform, .soundstage],
                 values: ["layout.heroHeight": 300.0]),
         BuiltIn(title: L("Spectrum Only"), hidden: [.loudness, .history, .vu, .waveform, .soundstage, .levels], values: [:])]
    }

    @Published private(set) var saved: [Preset] = []

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.storeKey) as? [[String: Any]] ?? []
        saved = stored.compactMap { entry in
            guard let name = entry["name"] as? String, let values = entry["values"] as? [String: Any] else { return nil }
            return Preset(name: name, values: values)
        }
    }

    /// Every stored key a layout covers: the dividers (`layout.*`, the hidden panels among them) and the strip's panels.
    private static func layoutKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { ($0.hasPrefix("layout.") && $0 != storeKey) || $0 == PanelPlacement.stripKey }
            .sorted()
    }

    private static var current: [String: Any] {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in layoutKeys() { values[key] = defaults.object(forKey: key) }
        return values
    }

    func apply(_ preset: Preset) { apply(values: preset.values) }

    func apply(_ builtIn: BuiltIn) {
        var values = builtIn.values
        values[PanelPlacement.hiddenKey] = MeterPanel.allCases.filter(builtIn.hidden.contains).map(\.rawValue).joined(separator: ",")
        if let strip = UserDefaults.standard.string(forKey: PanelPlacement.stripKey) { values[PanelPlacement.stripKey] = strip }
        apply(values: values)
    }

    private func apply(values: [String: Any]) {
        let defaults = UserDefaults.standard
        withAnimation(.panelMove) {
            for key in Self.layoutKeys() where values[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in values { defaults.set(value, forKey: key) }
            let placement = PanelPlacement.shared
            placement.setHidden(Set((values[PanelPlacement.hiddenKey] as? String ?? "").split(separator: ",")
                .compactMap { MeterPanel(rawValue: String($0)) }))
            placement.setStripPanels(PanelPlacement.decode(values[PanelPlacement.stripKey] as? String) ?? PanelPlacement.defaultStrip)
            placement.restore()
        }
        DiagnosticLog.event("Layout applied")
    }

    /// Asks for a name and saves the current arrangement under it (replacing one of the same name).
    func saveCurrent() {
        let alert = NSAlert()
        alert.messageText = L("Save Layout")
        alert.informativeText = L("Saves which panels show, the dividers' positions and the dock's panels.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("Layout name")
        field.stringValue = L("My Layout %d", saved.count + 1)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if saved.contains(where: { $0.name == name }) {
            let replace = NSAlert()
            replace.messageText = L("Replace the layout “%@”?", name)
            replace.informativeText = L("A layout with this name already exists. Replacing it keeps only the current arrangement.")
            replace.addButton(withTitle: L("Replace"))
            replace.addButton(withTitle: L("Cancel"))
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }
        let preset = Preset(name: name, values: Self.current)
        if let index = saved.firstIndex(where: { $0.name == name }) { saved[index] = preset } else { saved.append(preset) }
        store()
    }

    func delete(_ preset: Preset) {
        saved.removeAll { $0.name == preset.name }
        store()
    }

    private func store() {
        UserDefaults.standard.set(saved.map { ["name": $0.name, "values": $0.values] as [String: Any] }, forKey: Self.storeKey)
    }
}

/// The Layout menu: the horizontal strip, enlarging a panel, which panels show, panels in windows of their own, and
/// saved layouts.
struct LayoutCommands: Commands {
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var presets = LayoutPresets.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some Commands {
        CommandMenu(L("Layout")) {
            Button(placement.strip ? L("Leave Dock Mode") : L("Dock Mode")) { placement.toggleStrip() }
                .keyboardShortcut("s", modifiers: [.option, .command])
            Button(L("Move to Bottom of Screen")) { placement.dockStrip() }
                .disabled(!placement.strip)
            Menu(L("Dock Panels")) {
                ForEach(placement.dockMenuPanels) { panel in
                    Toggle(panel.title, isOn: Binding(get: { placement.stripIncludes(panel) },
                                                      set: { _ in placement.toggleStripPanel(panel) }))
                }
            }
            Divider()
            Menu(L("Enlarge Panel")) {
                ForEach(MeterPanel.allCases) { panel in
                    Button(panel.title) { placement.toggleEnlarged(panel) }
                        .keyboardShortcut(panel.shortcut, modifiers: .command)
                        .disabled(placement.strip || !placement.isShown(panel))
                }
            }
            Button(L("Restore Full Window")) { placement.restore() }
                .disabled(placement.enlarged == nil)
            Menu(L("Open Panel in New Window")) {
                ForEach(MeterPanel.allCases) { panel in
                    Button(panel.title) { placement.requestWindow(panel) }
                        .disabled(placement.detached.contains(panel))
                }
            }
            Divider()
            Menu(L("Show Panels")) {
                ForEach(MeterPanel.allCases) { panel in
                    Toggle(panel.title, isOn: Binding(get: { placement.isShown(panel) },
                                                      set: { placement.setShown(panel, $0) }))
                }
                Divider()
                Button(L("Show All Panels")) { placement.showAll() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            Divider()
            ForEach(LayoutPresets.builtIns) { builtIn in
                Button(builtIn.title) { presets.apply(builtIn) }
            }
            if !presets.saved.isEmpty {
                Divider()
                ForEach(presets.saved) { preset in
                    Button(preset.name) { presets.apply(preset) }
                }
            }
            Divider()
            Button(L("Save Layout…")) { presets.saveCurrent() }
            Menu(L("Delete Layout")) {
                ForEach(presets.saved) { preset in
                    Button(preset.name) { presets.delete(preset) }
                }
            }
            .disabled(presets.saved.isEmpty)
        }
    }
}

/// The toolbar's layout control: the horizontal strip, the panels shown, and the layouts.
struct LayoutMenuButton: View {
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var presets = LayoutPresets.shared
    @ObservedObject private var l10n = Localizer.shared
    @State private var hovering = false

    var body: some View {
        Menu {
            Button { placement.toggleStrip() } label: {
                Label(placement.strip ? L("Leave Dock Mode") : L("Dock Mode"),
                      systemImage: placement.strip ? "dock.arrow.up.rectangle" : "dock.rectangle")
            }
            Divider()
            Section(L("Show Panels")) {
                ForEach(MeterPanel.allCases) { panel in
                    Toggle(panel.title, isOn: Binding(get: { placement.isShown(panel) },
                                                      set: { placement.setShown(panel, $0) }))
                }
            }
            Divider()
            Section(L("Layout")) {
                ForEach(LayoutPresets.builtIns) { builtIn in
                    Button(builtIn.title) { presets.apply(builtIn) }
                }
                ForEach(presets.saved) { preset in
                    Button(preset.name) { presets.apply(preset) }
                }
                Button { presets.saveCurrent() } label: { Label(L("Save Layout…"), systemImage: "square.and.arrow.down") }
            }
        } label: {
            DiscFace(symbol: "dock.rectangle", diameter: Theme.dockButton, hovering: hovering)
        } primaryAction: {
            placement.toggleStrip()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .help(L("Dock mode (click, ⌥⌘S); panels and layouts (hold)"))
        .accessibilityLabel(L("Layout"))
    }
}

/// The main window's panels in a popover from the toolbar, as the strip has its own (`StripPanelsMenu`): a checkbox
/// per panel shows or hides it, the same setting as the Meter menu's Show Panels.
struct WindowPanelsMenu: View {
    @ObservedObject private var l10n = Localizer.shared
    @State private var open = false

    var body: some View {
        DiscButton(symbol: "rectangle.split.2x2", help: L("Show or hide the main window's panels"), on: open) { open.toggle() }
            .onAppear {
                guard Diagnostics.snapshotWindowPanels else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { open = true }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                WindowPanelsForm().padding(14).frame(width: 280)
            }
    }
}

struct WindowPanelsForm: View {
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        // The last panel shown stays: unchecking it would leave the window empty.
        let lastShown = MeterPanel.allCases.filter(placement.isShown).count == 1
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(L("WINDOW PANELS"), color: Theme.title)
            VStack(spacing: 2) {
                ForEach(MeterPanel.allCases) { panel in
                    let shown = placement.isShown(panel)
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { shown }, set: { placement.setShown(panel, $0) })) {
                            Label(panel.title, systemImage: panel.symbol)
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        .disabled(shown && lastShown)
                        Spacer(minLength: 4)
                        // A panel in a window of its own shows there; this brings it back into the arrangement.
                        if shown && placement.detached.contains(panel) {
                            Button { placement.closeWindow(panel) } label: { Image(systemName: "macwindow") }
                                .help(L("Return this panel to the main window"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(height: 24)
                }
            }
            Divider()
            HStack {
                Button { placement.showAll() } label: { Label(L("Show All Panels"), systemImage: "eye") }
                    .disabled(MeterPanel.allCases.allSatisfy(placement.isShown))
                Spacer()
            }
            .controlSize(.small)
            Text(L("Hidden panels stop drawing. Measurements continue; the optional Multi-FFT engine stops when its panel closes."))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
