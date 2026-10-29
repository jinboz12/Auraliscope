import SwiftUI

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
            case .idle: Text(L("Checks public GitHub releases each time Auraliscope opens, and when you ask. Nothing is downloaded or installed until you choose to.")).font(.caption).foregroundStyle(Theme.secondary)
            case .checking: Text(L("Checking GitHub…")).font(.caption).foregroundStyle(Theme.secondary)
            case .failed(let failure): Text(L(Self.message(failure))).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
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

    static func message(_ failure: GitHubUpdateChecker.Failure) -> String {
        switch failure {
        case .unavailable: return LKey("GitHub release unavailable. The repository may be private or have no public release.")
        case .rateLimited: return LKey("GitHub rate limit reached. Try again later.")
        case .invalidResponse: return LKey("GitHub returned release information that could not be verified.")
        case .connection: return LKey("Could not check GitHub for updates. Check your connection and try again.")
        }
    }
}

/// The launch check's offer, at the foot of the meter window: what is available and the two ways to get it, both
/// left to the person (the release page, or the installer download in the browser). Never shown when up to date or
/// when the check failed; Later hides it until the next launch.
struct UpdateBanner: View {
    @ObservedObject private var checker = GitHubUpdateChecker.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        ZStack {
            if let release = checker.notice { banner(release) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: checker.notice)
    }

    private func banner(_ release: GitHubReleaseUpdate) -> some View {
        HStack(spacing: 10) {
            Label(release.prerelease ? L("Pre-release available: %@", release.title) : L("Update available: %@", release.title),
                  systemImage: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Link(destination: release.releaseURL) { Label(L("View Release"), systemImage: "safari") }
                .glassButton(prominent: release.installerURL == nil)
                .controlSize(.small)
            if let installer = release.installerURL {
                Link(destination: installer) { Label(L("Download Installer"), systemImage: "arrow.down") }
                    .glassButton(prominent: true)
                    .controlSize(.small)
            }
            Button(L("Later")) { checker.dismissNotice() }
                .glassButton()
                .controlSize(.small)
                .help(L("Hides this until Auraliscope opens again."))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.controlRadius + 4, style: .continuous),
                      tint: Theme.sage.opacity(Theme.dark ? 0.16 : 0.10))
        .frame(maxWidth: 680)
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
