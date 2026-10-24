import Foundation

/// From 2.0 beta (build 92) the app that had been Auraliscope LABS ships as Auraliscope itself, with the release
/// bundle ID. On its first launch it takes over every LABS setting that Auraliscope never stored (layouts, panel
/// settings, theme, standards…); whatever Auraliscope already had stays as it was. Runs once.
enum SettingsMigration {
    static let labsDomain = "com.jinboz.SoundMeterJBZ.Labs"
    static let doneKey = "settings.migratedFromLabs"
    /// Kept per app: the beta shows its own welcome, and the marker itself never travels.
    static let skipped: Set<String> = ["welcomeSeenBuild", doneKey]

    static func run(defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier,
                    from labsDomain: String = labsDomain, arguments: [String] = CommandLine.arguments) {
        // Diagnostic and snapshot runs (`--…` flags other than the plugin's launch request) leave settings alone.
        guard let bundleID, bundleID != labsDomain, !defaults.bool(forKey: doneKey),
              !arguments.dropFirst().contains(where: { $0.hasPrefix("--") && $0 != "--bridge-launch" }) else { return }
        var own = defaults.persistentDomain(forName: bundleID) ?? [:]
        let labs = defaults.persistentDomain(forName: labsDomain) ?? [:]
        let taken = labs.filter { own[$0.key] == nil && !skipped.contains($0.key) }
        own.merge(taken) { current, _ in current }
        own[doneKey] = true
        defaults.setPersistentDomain(own, forName: bundleID)
        if !taken.isEmpty { DiagnosticLog.event("Settings: \(taken.count) carried over from Auraliscope LABS") }
    }
}
