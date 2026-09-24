import Combine
import Foundation

// Language policy
//
// The meter window keeps its English labels in every language: units (LUFS, dBFS, dBTP, RMS, VU), measurement
// names (MOMENTARY, TRUE PEAK, TARGET…), channel labels and groups (L, R, LFE, FRONT, SURROUND, HEIGHT), the
// mode selector (Mono | Stereo | Multi-Ch, AUTO) and panel titles (SPECTRUM, WAVEFORM, SOUNDSTAGE…). They match
// consoles, DAWs and hardware meters, so they are written as plain literals and never pass through `L`.
//
// Everything else is translated: menus, Settings, device and routing pickers, onboarding, About, tooltips,
// accessibility text, status and error messages. Terms with an established translation use it (Stereo → 立体声 /
// 스테레오, Integrated → 积分 / 통합, Soundstage → 声场 / 사운드스테이지…). True Peak, units, abbreviations,
// standards, product and theme names stay in English, and a tooltip may quote a meter label as printed (TARGET,
// TRUE PEAK). `scripts/check-localization.py` holds the glossary and enforces all of this.

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"

    static let supported = ["en", "zh-Hans", "ko"]
    var id: String { rawValue }

    /// Each language names itself, so the choice stays readable whatever is selected.
    var nativeName: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .korean: return "한국어"
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
    /// The resolved table: "en", "zh-Hans" or "ko".
    @Published private(set) var code = "en"
    private var table: Bundle?
    /// Typeset strings of the current language, by key.
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .system
        // A launch-argument override (`-appLanguage ko`) is for one run only and must not touch saved preferences.
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Self.defaultsKey] == nil {
            Self.syncSystemLanguages(language)
        }
        resolve()
    }

    var locale: Locale { Locale(identifier: code) }

    /// Chinese and Korean set without Latin letter-spacing and with slightly more leading.
    var isCJK: Bool { code != "en" }

    /// Letter-spacing for a tracked heading: Latin capitals are spread, CJK glyphs are already evenly set.
    func tracking(_ latin: CGFloat) -> CGFloat { isCJK ? 0 : latin }

    /// Extra line spacing for wrapped paragraphs: CJK lines need a little more air than SF's default leading.
    var paragraphSpacing: CGFloat { isCJK ? 2.5 : 0 }

    private func resolve() {
        let resolved: String
        if language == .system {
            resolved = Bundle.preferredLocalizations(from: AppLanguage.supported, forPreferences: Self.systemLanguages).first ?? "en"
        } else {
            resolved = language.rawValue
        }
        lock.withLock {
            table = Bundle.main.path(forResource: resolved, ofType: "lproj").flatMap(Bundle.init(path:))
            cache.removeAll()
        }
        if resolved != code { code = resolved }
    }

    /// The user's macOS language list. `Locale.preferredLanguages` would return this app's own override.
    private static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[systemLanguagesKey] as? [String]
            ?? Locale.preferredLanguages
    }

    /// Everything Auraliscope draws switches at once. Menu items AppKit supplies (Hide, Quit, Edit, Window) are
    /// localized by macOS when the app launches, so an explicit choice is also stored as this app's macOS
    /// language; "System" removes the override.
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
    private static let unbreakable = ["Multi Channel", "True Peak", "TRUE PEAK", "Core Audio", "EBU R128", "EBU Tech 3342",
                                      "ITU-R BS.1770-5", "ATSC A/85", "Dolby Atmos", "Apple Music", "Float32 PCM"]
    private static let unitAfterNumber = try! NSRegularExpression(
        pattern: #"(\d|%@|%d) (?=(?:dBFS|dBTP|dB|LUFS|LU|kHz|Hz|ms|s|ch|VU)(?![A-Za-z])|[秒个路点])"#)

    /// Joins multi-word terms, and a number with its unit or Chinese measure word ("−60 dBFS", "150 ms", "8 秒"),
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
