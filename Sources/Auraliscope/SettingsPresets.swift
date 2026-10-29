import AppKit
import SwiftUI

/// Saved sets of the user's preferences, under a name: language, appearance and theme, the monitoring format and mode,
/// loudness targets, every panel's display settings, speaker layouts and the window's layout. Saving takes every
/// stored preference but what belongs to this Mac or this moment (the source and its routing, window positions,
/// migration marks); loading writes them back, sends every other preference to its default, and brings the app's own
/// copies up to date, so a preset takes effect at once without a restart.
///
/// Each preset is a property list of its own in Application Support/Auraliscope/Settings Presets, named after the
/// preset, so it can be shown in the Finder, copied to another Mac or backed up. The folder is watched: a preset
/// renamed, copied in or removed in the Finder shows at once.
@MainActor
final class SettingsPresets: ObservableObject {
    static let shared = SettingsPresets()
    /// Where build 110 kept presets, before they became files; moved into the folder on first launch.
    private static let legacyKey = "settings.presets"
    static let fileExtension = "plist"

    struct Preset: Identifiable, Equatable {
        let name: String
        let saved: Date
        let values: [String: Any]
        let url: URL
        var id: String { url.path }
        static func == (a: Preset, b: Preset) -> Bool { a.url == b.url && a.saved == b.saved }
    }

    @Published private(set) var saved: [Preset] = []
    /// Preset files in the folder that could not be read (damaged, or not a preset), by name: listed, never loaded.
    @Published private(set) var unreadable: [String] = []
    private var watcher: DispatchSourceFileSystemObject?

    static var folder: URL {
        // A QA bundle (self-tests, `--test-settings-presets`) saves and deletes presets: never in the user's folder.
        if Bundle.main.bundleIdentifier?.hasSuffix(".QA") == true {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Auraliscope-QA-Presets", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Auraliscope", isDirectory: true)
            .appendingPathComponent("Settings Presets", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        migrateLegacy()
        reload()
        watch()
    }

    /// Reads every preset file in the folder, sorted by name as the Finder sorts.
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let presetFiles = files.filter { $0.pathExtension == Self.fileExtension }
        saved = presetFiles.compactMap(Self.read)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let names = presetFiles.filter { Self.read($0) == nil }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        if names != unreadable {
            if !names.isEmpty { DiagnosticLog.event("Settings presets: \(names.count) file(s) could not be read") }
            unreadable = names
        }
    }

    private static func read(_ url: URL) -> Preset? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let values = plist["values"] as? [String: Any] else { return nil }
        // The file's name is the preset's: renaming it in the Finder renames the preset.
        return Preset(name: url.deletingPathExtension().lastPathComponent, saved: plist["saved"] as? Date ?? .distantPast,
                      values: values, url: url)
    }

    @discardableResult
    private static func write(name: String, saved: Date, values: [String: Any], to url: URL) -> Bool {
        let plist: [String: Any] = ["name": name, "saved": saved, "values": values,
                                    "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// The file for a preset called `name`: characters a file name cannot hold become dashes.
    private static func url(for name: String) -> URL {
        let file = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent(file.hasPrefix(".") ? "-" + file.dropFirst() : file)
            .appendingPathExtension(fileExtension)
    }

    /// Follows changes made to the folder outside the app (the Finder, a copy from another Mac).
    private func watch() {
        let descriptor = open(Self.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func migrateLegacy() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.array(forKey: Self.legacyKey) as? [[String: Any]] else { return }
        for entry in stored {
            guard let name = entry["name"] as? String, let values = entry["values"] as? [String: Any] else { continue }
            let url = Self.url(for: name)
            if !FileManager.default.fileExists(atPath: url.path) {
                Self.write(name: name, saved: entry["saved"] as? Date ?? Date(), values: values, to: url)
            }
        }
        defaults.removeObject(forKey: Self.legacyKey)
    }

    /// Kept out of presets: the source and routing (they belong to the devices connected), window positions, the
    /// stores of layouts and the old presets, and the app's own bookkeeping.
    private static let excludedKeys: Set<String> = [
        legacyKey, "layout.presets", SettingsBackup.key, "settingsPane", "welcomeSeenBuild",
        MeterModel.inputDeviceUIDKey, MeterModel.inputDeviceIsOutputKey, "lastAudioDeviceUID", "lastAudioDeviceIsOutput",
        "bridgeSelection", "bridgeSourceName", PanelPlacement.stripFrameName,
        SpeakerLayoutStore.revisionKey, "labsIndigoDefaultAdopted", "settings.migratedFromLabs",
    ]
    private static let excludedPrefixes = ["NS", "Apple", "com.apple.", "assign.", "experiment"]

    private static func included(_ key: String) -> Bool {
        !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The saved preferences only (not launch arguments or registered defaults).
    private static var current: [String: Any] {
        let defaults = UserDefaults.standard
        // An unbundled build (`swift build`) keeps its preferences under the process name.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return (defaults.persistentDomain(forName: domain) ?? [:]).filter { included($0.key) }
    }

    /// Asks for a name: nil when cancelled or left empty.
    private func askName(title: String, message: String? = nil, button: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("Preset name")
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A name no preset has yet: `base`, else "base 2", "base 3"…
    private func unusedName(_ base: String) -> String {
        let taken = Set(saved.map(\.name))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }

    /// Asks for a name and saves the current settings under it (replacing a preset of the same name).
    func saveCurrent() {
        guard let name = askName(title: L("Save Settings Preset"),
                                 message: L("Keeps your language, appearance, monitoring and loudness choices, every panel's settings and the layout. The source and its routing stay with your devices."),
                                 button: L("Save"), initial: unusedName(L("My Settings %d", saved.count + 1))) else { return }
        if saved.contains(where: { $0.name == name }) {
            let replace = NSAlert()
            replace.messageText = L("Replace the preset “%@”?", name)
            replace.informativeText = L("A preset with this name already exists. Replacing it keeps only the current settings.")
            replace.addButton(withTitle: L("Replace"))
            replace.addButton(withTitle: L("Cancel"))
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }
        save(as: name)
    }

    /// Saves the current settings under `name`, replacing a preset of that name.
    func save(as name: String) {
        let values = Self.current
        guard Self.write(name: name, saved: Date(), values: values, to: Self.url(for: name)) else {
            DiagnosticLog.event("Settings preset could not be saved")
            let alert = NSAlert()
            alert.messageText = L("The preset “%@” could not be saved.", name)
            alert.informativeText = L("Check that the presets folder can be written to (Show Presets in Finder), then try again.")
            alert.runModal()
            return
        }
        reload()
        DiagnosticLog.event("Settings preset saved (\(values.count) settings)")
    }

    /// Asks before replacing the current settings with `preset`'s.
    func confirmLoad(_ preset: Preset, model: MeterModel) {
        let alert = NSAlert()
        alert.messageText = L("Load “%@”?", preset.name)
        alert.informativeText = L("Your current settings are replaced by the preset's. Save them as a preset first to keep them.")
        alert.addButton(withTitle: L("Load"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        load(preset, model: model)
    }

    func load(_ preset: Preset, model: MeterModel) {
        // Pending edits in Settings belong to the settings being replaced.
        SettingsDraft.shared.revert()
        let defaults = UserDefaults.standard
        let revision = defaults.integer(forKey: SpeakerLayoutStore.revisionKey)
        withAnimation(.panelMove) {
            for key in Self.current.keys where preset.values[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in preset.values where Self.included(key) { defaults.set(value, forKey: key) }
            // The analysis notices a changed speaker geometry by its revision, which only ever counts up.
            defaults.set(revision + 1, forKey: SpeakerLayoutStore.revisionKey)
            SpeakerLayoutStore.shared.reload()
            Localizer.shared.language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
            ThemeSettings.shared.reloadStored()
            model.reloadStoredSettings()
            PanelPlacement.shared.reloadStored()
        }
        CanvasDriver.shared.restart()
        SystemMenus.relocalize()
        DiagnosticLog.event("Settings preset loaded (\(preset.values.count) settings)")
    }

    /// A copy of `preset` under "<name> Copy" (numbered if that is taken), dated now.
    @discardableResult
    func duplicate(_ preset: Preset) -> Preset? {
        let name = unusedName(L("%@ Copy", preset.name))
        let url = Self.url(for: name)
        guard Self.write(name: name, saved: Date(), values: preset.values, to: url) else { return nil }
        reload()
        // By path, links resolved: a folder reached through a link (/var → /private/var) is listed by its real path.
        return saved.first { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }
    }

    func rename(_ preset: Preset) {
        guard let name = askName(title: L("Rename Preset"), button: L("Rename"), initial: preset.name),
              name != preset.name else { return }
        // A preset already under the new name gives way to the renamed one.
        let target = Self.url(for: name)
        if target != preset.url { try? FileManager.default.removeItem(at: target) }
        try? FileManager.default.moveItem(at: preset.url, to: target)
        Self.write(name: name, saved: preset.saved, values: preset.values, to: target)
        reload()
    }

    /// Moves the preset's file to the Trash, so a deletion can be undone from the Finder (`permanently`: removes it,
    /// for diagnostics that clean up after themselves).
    func delete(_ preset: Preset, permanently: Bool = false) {
        if permanently { try? FileManager.default.removeItem(at: preset.url) }
        else { try? FileManager.default.trashItem(at: preset.url, resultingItemURL: nil) }
        reload()
    }

    func showInFinder(_ preset: Preset) {
        NSWorkspace.shared.activateFileViewerSelecting([preset.url])
    }

    func showFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }
}

/// Settings ▸ General ▸ Presets: Save Current Settings, then the saved presets, each with Load and a menu to update,
/// duplicate, rename, show in the Finder or move to the Trash.
struct SettingsPresetsSection: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var presets = SettingsPresets.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        SettingsRow(title: L("Settings Presets")) {
            HStack(spacing: 8) {
                Button { presets.showFolder() } label: { Image(systemName: "folder") }
                    .glassIconButton()
                    .help(L("Show Presets in Finder"))
                    .accessibilityLabel(L("Show Presets in Finder"))
                Button { presets.saveCurrent() } label: {
                    Label(L("Save Current Settings…"), systemImage: "square.and.arrow.down")
                }
                .glassButton()
            }
        }
        if !presets.unreadable.isEmpty {
            SettingsNote(L("Not listed, because the file could not be read (damaged, or not a settings preset): %@. Your current settings are unchanged.",
                           presets.unreadable.joined(separator: ", ")))
        }
        ForEach(presets.saved) { preset in
            SettingsDivider()
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: preset.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if preset.saved > .distantPast {
                        Text(preset.saved.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(l10n.locale)))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Button(L("Load")) { presets.confirmLoad(preset, model: model) }
                    .glassButton()
                Menu {
                    Button(L("Update with Current Settings")) { presets.save(as: preset.name) }
                    Button(L("Duplicate")) { presets.duplicate(preset) }
                    Button(L("Rename…")) { presets.rename(preset) }
                    Button(L("Show in Finder")) { presets.showInFinder(preset) }
                    Divider()
                    Button(L("Move to Trash"), role: .destructive) { presets.delete(preset) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L("More"))
            }
            .frame(minHeight: SettingsMetrics.row)
        }
    }
}

/// The app menu's Settings Presets submenu: load a saved preset, or save the current settings as one.
struct SettingsPresetsMenu: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var presets = SettingsPresets.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Menu(L("Settings Presets")) {
            ForEach(presets.saved) { preset in
                Button(preset.name) { presets.confirmLoad(preset, model: model) }
            }
            if !presets.saved.isEmpty { Divider() }
            Button(L("Save Current Settings…")) { presets.saveCurrent() }
            Button(L("Show Presets in Finder")) { presets.showFolder() }
        }
    }
}
