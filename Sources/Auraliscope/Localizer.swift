import Combine
import Foundation

// Language policy
//
// Everything a person reads is translated, the meter window included: panel titles (频谱, 파형, スペクトラム…),
// measurement names (瞬时, 트루 피크, pico real…), status and legends, the mode selector, AUTO, and theme names. What
// stays in English is what engineers read as symbols in every language: units (LUFS, dBFS, dBTP, RMS, VU, Hz), channel
// labels (L, R, C, LFE, Ls…), speaker layout names (5.1.2), note names, standards (EBU R128, ITU-R BS.1770-5),
// abbreviations (FFT) and product names. Terms with an established translation use it everywhere (Stereo →
// 立体声 / 立體聲 / ステレオ / 스테레오 / estéreo, True Peak → 真峰值 / トゥルーピーク / 트루 피크 / pico real…), so a
// tooltip quoting a meter label matches what the meter prints. Traditional Chinese follows Taiwan's usage and Spanish
// Spain's. `scripts/check-localization.py` holds the glossary and enforces all of this.

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"

    static let supported = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]
    var id: String { rawValue }

    /// Each language names itself, so the choice stays readable whatever is selected.
    var nativeName: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español (España)"
        }
    }
}

/// Runtime language switching over the standard `<lang>.lproj/Localizable.strings` tables in the app bundle.
/// English source text is the key, so a missing table or entry falls back to English. Switching only
/// republishes this object: views that read `L` observe it and redraw, and nothing in the audio path listens.
final class Localizer: ObservableObject {
    static let shared = Localizer()
    private static let defaultsKey = "appLanguage"
    /// Per-app language override macOS reads at launch for the menus and panels AppKit supplies itself.
    private static let systemLanguagesKey = "AppleLanguages"

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            Self.syncSystemLanguages(language)
            resolve()
        }
    }
    /// The resolved table: one of `AppLanguage.supported`.
    @Published private(set) var code = "en"
    private var table: Bundle?
    /// Typeset strings of the current language, by key.
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private init() {
        // The first preferences the app reads: put back any the Settings preview left behind (see `SettingsBackup`).
        SettingsBackup.restoreIfInterrupted()
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .system
        // A launch-argument override (`-appLanguage ko`) is for one run only and must not touch saved preferences.
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Self.defaultsKey] == nil {
            Self.syncSystemLanguages(language)
        }
        resolve()
    }

    var locale: Locale { Locale(identifier: code) }

    /// Chinese, Japanese and Korean set without Latin letter-spacing and with slightly more leading.
    var isCJK: Bool { ["zh-Hans", "zh-Hant", "ja", "ko"].contains(code) }

    /// Letter-spacing for a tracked heading: Latin capitals are spread, CJK glyphs are already evenly set.
    func tracking(_ latin: CGFloat) -> CGFloat { isCJK ? 0 : latin }

    /// Extra line spacing for wrapped paragraphs: CJK lines need a little more air than SF's default leading.
    var paragraphSpacing: CGFloat { isCJK ? 2.5 : 0 }

    /// The table a choice reads from: its own, or for System the first supported language in the Mac's list.
    func tableCode(for language: AppLanguage) -> String {
        language == .system
            ? Bundle.preferredLocalizations(from: AppLanguage.supported, forPreferences: Self.systemLanguages).first ?? "en"
            : language.rawValue
    }

    /// `language` is fully in effect: chosen, its table loaded and read from, and the menu bar's AppKit items
    /// retitled (Settings ▸ Apply checks this instead of asking for a restart).
    @MainActor
    func isApplied(_ language: AppLanguage) -> Bool {
        let wanted = tableCode(for: language)
        let loaded = lock.withLock { table?.bundlePath.hasSuffix("/\(wanted).lproj") ?? false }
        return self.language == language && code == wanted && loaded && SystemMenus.mismatches.isEmpty
    }

    private func resolve() {
        let resolved = tableCode(for: language)
        lock.withLock {
            table = Bundle.main.path(forResource: resolved, ofType: "lproj").flatMap(Bundle.init(path:))
            cache.removeAll()
        }
        if resolved != code { code = resolved }
        // SwiftUI rebuilds its own menus from the new tables; the AppKit items are retitled once it has.
        DispatchQueue.main.async { MainActor.assumeIsolated { SystemMenus.relocalize() } }
    }

    /// The user's macOS language list. `Locale.preferredLanguages` would return this app's own override.
    private static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[systemLanguagesKey] as? [String]
            ?? Locale.preferredLanguages
    }

    /// Everything Auraliscope draws switches at once, and `SystemMenus` retitles the menu items AppKit supplies.
    /// An explicit choice is also stored as this app's macOS language, so those items and the panels macOS
    /// draws itself (Open, Print, the About box) start in it next time too; "System" removes the override.
    private static func syncSystemLanguages(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        let wanted: [String]? = language == .system ? nil : [language.rawValue]
        let stored = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[systemLanguagesKey] as? [String]
        guard stored != wanted else { return }
        if let wanted { defaults.set(wanted, forKey: systemLanguagesKey) } else { defaults.removeObject(forKey: systemLanguagesKey) }
    }

    subscript(_ key: String) -> String {
        lock.withLock {
            if let text = cache[key] { return text }
            let text = Self.typeset(table?.localizedString(forKey: key, value: key, table: nil) ?? key)
            cache[key] = text
            return text
        }
    }

    /// Instrument terms of more than one word, which should never break across lines. CJK text may wrap after
    /// any character, so "Multi Channel" would otherwise split at its space inside a Chinese or Korean sentence.
    private static let unbreakable = ["True Peak", "TRUE PEAK", "Core Audio", "EBU R128", "EBU Tech 3342",
                                      "ITU-R BS.1770-5", "ATSC A/85", "Float32 PCM"]
    private static let unitAfterNumber = try! NSRegularExpression(
        pattern: #"(\d|%@|%d) (?=(?:dBFS|dBTP|dB|LUFS|LU|kHz|Hz|ms|s|ch|VU)(?![A-Za-z])|[秒个個路点點])"#)

    /// Joins multi-word terms, and a number with its unit or CJK measure word ("−60 dBFS", "150 ms", "8 秒"),
    /// by no-break spaces.
    static func typeset(_ text: String) -> String {
        var result = text
        for term in unbreakable where result.contains(term) {
            result = result.replacingOccurrences(of: term, with: term.replacingOccurrences(of: " ", with: "\u{00A0}"))
        }
        let range = NSRange(result.startIndex..., in: result)
        return unitAfterNumber.stringByReplacingMatches(in: result, range: range, withTemplate: "$1\u{00A0}")
    }
}

/// Localized text for the current app language.
func L(_ key: String) -> String { Localizer.shared[key] }

/// Localized format string, e.g. `L("Input %d", 3)`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localizer.shared[key], locale: Localizer.shared.locale, arguments: arguments)
}

/// Marks a table key that is stored now and translated later with `L(key)`, so the localization check can see
/// it (loudness standards, capture steps named in error messages).
func LKey(_ key: String) -> String { key }

/// Settings previewed live are written where the app keeps them. What they replaced is saved here when a preview
/// starts and dropped when it ends (Apply, Revert, closing Settings, quitting), so a preview cut short by a crash
/// or a force quit is undone at the next launch, before anything reads its preferences.
enum SettingsBackup {
    static let key = "settings.previewBackup"
    /// Every preference a preview can change.
    static let keys = ["appLanguage", "AppleLanguages", "appearanceMode", "colorTheme", "speakerLayout", "showMonoMode",
                       "formatMode", "soundstage.style", "spectrum.side", "spectrum.peakHolds", "waveform.seconds",
                       "loudness.headline"]

    /// Saved values only, not launch arguments or registered defaults.
    private static var saved: [String: Any] {
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier { return defaults.persistentDomain(forName: domain) ?? [:] }
        return defaults.dictionaryRepresentation()
    }

    static func save() {
        let current = saved
        var values: [String: Any] = [:]
        for key in keys { if let value = current[key] { values[key] = value } }
        UserDefaults.standard.set(["keys": keys, "values": values], forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func restoreIfInterrupted() {
        let defaults = UserDefaults.standard
        guard let backup = saved[key] as? [String: Any] else { return }
        let values = backup["values"] as? [String: Any] ?? [:]
        for name in backup["keys"] as? [String] ?? keys {
            if let value = values[name] { defaults.set(value, forKey: name) } else { defaults.removeObject(forKey: name) }
        }
        clear()
    }
}
