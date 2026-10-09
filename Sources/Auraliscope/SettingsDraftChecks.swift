import AnalysisCore
import AppKit

extension SettingsDraft {
    /// Run with --demo --show-settings --test-settings-draft in an isolated QA bundle. Exercises the same
    /// bindings as the controls, including delayed Apply verification; never opens an audio device.
    func checkRegression(model: MeterModel) {
        guard !Self.checksStarted else { return }
        Self.checksStarted = true
        guard Diagnostics.demo,
              Bundle.main.bundleIdentifier?.hasSuffix(".QA") == true else {
            fputs("Settings checks require --demo and a separate .QA bundle identifier.\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            let defaults = UserDefaults.standard
            let domain = Bundle.main.bundleIdentifier!
            let saved = defaults.persistentDomain(forName: domain) ?? [:]
            func check(_ condition: Bool, _ name: String) {
                guard condition else {
                    defaults.setPersistentDomain(saved, forName: domain)
                    fputs("FAIL: \(name)\n", stderr)
                    exit(1)
                }
                print("PASS: \(name)")
                fflush(stdout)
            }
            func settle() async { try? await Task.sleep(nanoseconds: 650_000_000) }
            let theme = ThemeSettings.shared
            let original = theme.mode
            let next: AppearanceMode = original == .dark ? .light : .dark
            let appearance = binding(\.appearance, live: { theme.mode })

            appearance.wrappedValue = original
            check(!dirty && !previewing, "unchanged selection does not start a preview")
            appearance.wrappedValue = next
            check(dirty && previewing && theme.mode == next, "edits preview immediately")
            appearance.wrappedValue = original
            check(!dirty && !previewing && theme.mode == original, "original choice ends preview")
            check(defaults.object(forKey: SettingsBackup.key) == nil, "completed preview clears recovery backup")

            appearance.wrappedValue = next
            apply(model: model)
            appearance.wrappedValue = original
            check(outcome == .checking && theme.mode == next, "edits wait for Apply verification")
            await settle()
            check(outcome == .applied && !dirty && !previewing, "Apply verifies and clears pending changes")
            appearance.wrappedValue = original
            revert()
            check(theme.mode == next, "Revert after Apply uses the newly committed value")

            appearance.wrappedValue = original
            apply(model: model)
            // Closing Settings calls Revert. Its obsolete verification must not appear in the next visit.
            revert()
            appearance.wrappedValue = next
            await settle()
            check(outcome == nil && dirty && previewing, "a closed visit cannot finish over a new preview")
            revert()
            check(theme.mode == original, "new preview still reverts to its baseline")

            routing = [Int32](repeating: -1, count: Role.count)
            let otherLayout: SpeakerLayout = model.speakerLayout == .s916 ? .standard : .s916
            binding(\.layout, live: { model.speakerLayout }).wrappedValue = otherLayout
            check(routing == nil, "changing format drops routing for the old format")
            revert()
            routing = [Int32](repeating: -1, count: Role.count)
            binding(\.source, live: { model.selectedID }).wrappedValue = model.selectedID == .none ? .noOutput : .none
            check(routing == nil, "changing source drops routing for the old device")
            revert()

            binding(\.mono, live: { model.monoEnabled }).wrappedValue = true
            binding(\.mode, live: { model.formatMode }).wrappedValue = .mono
            binding(\.mono, live: { model.monoEnabled }).wrappedValue = false
            check(mode != .mono && model.formatMode != .mono, "hiding Mono clears a pending Mono selection")
            apply(model: model)
            await settle()
            check(!dirty && outcome != .checking, "dependent mode changes finish applying")
            revert()
            defaults.setPersistentDomain(saved, forName: domain)
            print("All settings draft regression checks passed.")
            fflush(stdout)
            exit(0)
        }
    }

    private static var checksStarted = false
}
