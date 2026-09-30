import AppKit

/// Keeps the menu bar and window titles in the app's current language, so a language change applies at once,
/// without a relaunch. Neither source follows on its own: the items AppKit adds (Hide, Quit, Undo, Copy,
/// Minimize…) are localized by macOS in the language the app launched with, and SwiftUI builds the commands and
/// window titles once and keeps them. So every title is looked up in all of the app's tables, whatever language
/// it currently reads in, and set to the current language's; AppKit's items, whose macOS wording may not be in
/// the tables, are found by the action they send, and the Edit, Window and Help menus by their role.
@MainActor
enum SystemMenus {
    /// AppKit's items by the action they send, with their title's table key.
    private static let actions: [(Selector, String)] = [
        (#selector(NSApplication.hide(_:)), LKey("Hide Auraliscope LABS")),
        (#selector(NSApplication.hideOtherApplications(_:)), LKey("Hide Others")),
        (#selector(NSApplication.unhideAllApplications(_:)), LKey("Show All")),
        (#selector(NSApplication.terminate(_:)), LKey("Quit Auraliscope LABS")),
        (Selector(("undo:")), LKey("Undo")),
        (Selector(("redo:")), LKey("Redo")),
        (#selector(NSText.cut(_:)), LKey("Cut")),
        (#selector(NSText.copy(_:)), LKey("Copy")),
        (#selector(NSText.paste(_:)), LKey("Paste")),
        (#selector(NSTextView.pasteAsPlainText(_:)), LKey("Paste and Match Style")),
        (#selector(NSText.delete(_:)), LKey("Delete")),
        (#selector(NSText.selectAll(_:)), LKey("Select All")),
        (#selector(NSApplication.orderFrontCharacterPalette(_:)), LKey("Emoji & Symbols")),
        (Selector(("startDictation:")), LKey("Start Dictation…")),
        (#selector(NSWindow.performMiniaturize(_:)), LKey("Minimize")),
        (#selector(NSWindow.performZoom(_:)), LKey("Zoom")),
        (#selector(NSApplication.arrangeInFront(_:)), LKey("Bring All to Front")),
    ]

    /// macOS titles with no action of their own, matched through the tables by their macOS wording.
    private static let macOSTitles = [LKey("View"), LKey("AutoFill")]

    /// Every translation in every table, back to its keys: a title in any of the app's languages finds its key.
    private static let keys: [String: [String]] = {
        _ = macOSTitles
        var result: [String: [String]] = [:]
        for code in AppLanguage.supported {
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let table = NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String] else { continue }
            for (key, value) in table {
                for form in Set([value, Localizer.typeset(value)]) where !(result[form]?.contains(key) ?? false) {
                    result[form, default: []].append(key)
                }
            }
        }
        return result
    }()

    /// The key a title was found under, remembered per item: a translation two keys share ("Monitoring Mode" in
    /// the menu, "Monitoring mode" in Settings, one wording in Chinese and Korean) then keeps its own.
    private static var found: [ObjectIdentifier: String] = [:]

    /// The key of `title`: the one it is spelled as, else a title-case key (menu and window titles are), else any.
    private static func key(for title: String, of object: AnyObject) -> String? {
        let id = ObjectIdentifier(object)
        if let known = found[id], L(known) == title || keys[title]?.contains(known) == true { return known }
        guard let candidates = keys[title] else { return nil }
        func titleCase(_ key: String) -> Int { key.split(separator: " ").filter { $0.first?.isUppercase == true }.count }
        let key = candidates.first { $0 == title } ?? candidates.max { titleCase($0) < titleCase($1) }!
        found[id] = key
        return key
    }

    /// Every title that can be put in the current language, with the one it should read.
    private static func expected() -> [(title: String, wanted: String, set: (String) -> Void)] {
        var result: [(String, String, (String) -> Void)] = []
        func add(_ item: NSMenuItem, key: String) {
            result.append((item.title, L(key), { item.title = $0; item.submenu?.title = $0 }))
        }
        func walk(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                if let action = item.action, let key = actions.first(where: { $0.0 == action })?.1 {
                    add(item, key: key)
                } else if let key = key(for: item.title, of: item) {
                    add(item, key: key)
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        guard let main = NSApp.mainMenu else { return [] }
        walk(main)
        // Menus whose title macOS supplies, by their role.
        for item in main.items {
            guard let submenu = item.submenu else { continue }
            if submenu === NSApp.windowsMenu {
                add(item, key: LKey("Window"))
            } else if submenu === NSApp.helpMenu {
                add(item, key: LKey("Help"))
            } else if submenu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) {
                add(item, key: LKey("Edit"))
            }
        }
        if let services = NSApp.servicesMenu, let item = main.items.first?.submenu?.items.first(where: { $0.submenu === services }) {
            add(item, key: LKey("Services"))
        }
        // Window titles, which the Window menu lists.
        for window in NSApp.windows where !window.title.isEmpty {
            if let key = key(for: window.title, of: window) { result.append((window.title, L(key), { window.title = $0 })) }
        }
        return result
    }

    /// Puts every title in the current language.
    static func relocalize() {
        for entry in expected() where entry.title != entry.wanted { entry.set(entry.wanted) }
    }

    /// Titles that still read in another language (none once `relocalize` has run).
    static var mismatches: [String] { expected().filter { $0.title != $0.wanted }.map(\.wanted) }

    private static var tracking: NSObjectProtocol?

    /// Relocalizes now, and whenever the menu bar opens, so anything SwiftUI or AppKit rebuilds is caught too.
    static func follow() {
        relocalize()
        guard tracking == nil else { return }
        tracking = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { relocalize() }
        }
    }
}
