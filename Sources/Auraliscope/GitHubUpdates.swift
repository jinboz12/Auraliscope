import SwiftUI

@MainActor
final class GitHubUpdateChecker: ObservableObject {
    static let shared = GitHubUpdateChecker()
    enum State { case idle, checking, finished(GitHubUpdateResult), failed(String) }
    @Published private(set) var state = State.idle
    private var task: Task<Void, Never>?
    var checking: Bool { if case .checking = state { return true }; return false }
    /// A result from the other channel no longer answers; the next check uses the new one.
    func channelChanged() {
        task?.cancel(); task = nil
        state = .idle
    }

    func check() {
        guard !checking else { return }
        state = .checking
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let build = Int(AppVersion.build) ?? 0
        let prereleases = UserDefaults.standard.bool(forKey: GitHubUpdateCatalog.prereleaseKey)
        task = Task { [weak self] in
            do {
                let result = try await GitHubUpdateClient().check(version: version, build: build, includePrereleases: prereleases)
                guard !Task.isCancelled else { return }
                self?.state = .finished(result)
            } catch {
                guard !Task.isCancelled else { return }
                let message: String
                switch error {
                case GitHubUpdateError.unavailable: message = LKey("GitHub release unavailable. The repository may be private or have no public release.")
                case GitHubUpdateError.rateLimited: message = LKey("GitHub rate limit reached. Try again later.")
                case GitHubUpdateError.invalidResponse: message = LKey("GitHub returned release information that could not be verified.")
                default: message = LKey("Could not check GitHub for updates. Check your connection and try again.")
                }
                self?.state = .failed(message)
            }
        }
    }
}

struct GitHubUpdateView: View {
    @ObservedObject private var checker = GitHubUpdateChecker.shared
    @ObservedObject private var l10n = Localizer.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { checker.check() } label: {
                    Label(L("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                }.glassButton().disabled(checker.checking)
                if checker.checking { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            switch checker.state {
            case .idle: Text(L("Checks public GitHub releases. Opens the release page or installer download when an update is available.")).font(.caption).foregroundStyle(Theme.secondary)
            case .checking: Text(L("Checking GitHub…")).font(.caption).foregroundStyle(Theme.secondary)
            case .failed(let key): Text(L(key)).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
            case .finished(.noNewerRelease(let release)):
                Text(L("No newer published release found. Latest: %@", release.title)).font(.caption).foregroundStyle(Theme.secondary)
            case .finished(.available(let release)):
                Text(release.prerelease ? L("Pre-release available: %@", release.title) : L("Update available: %@", release.title))
                    .font(.caption).foregroundStyle(Theme.ink)
                HStack(spacing: 12) {
                    Link(L("View Release"), destination: release.releaseURL)
                    if let installer = release.installerURL { Link(L("Download Installer"), destination: installer) }
                }.font(.caption)
            }
        }
    }
}

/// Settings ▸ Updates: opts into GitHub pre-releases (betas and release candidates). Off by default.
struct PrereleaseUpdatesRow: View {
    @AppStorage(GitHubUpdateCatalog.prereleaseKey) private var prereleases = false
    @ObservedObject private var l10n = Localizer.shared
    var body: some View {
        SettingsRow(title: L("Include pre-releases")) {
            Toggle(L("Include pre-releases"), isOn: Binding(get: { prereleases }, set: {
                prereleases = $0
                GitHubUpdateChecker.shared.channelChanged()
                DiagnosticLog.event("Pre-release updates: \($0 ? "on" : "off")")
            }))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        SettingsNote(L("Also offers beta and release-candidate builds published on GitHub. They are tested less than final releases. Turn off to return to final releases only; an installed pre-release stays until a newer final release."))
    }
}
