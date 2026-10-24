import SwiftUI

/// Release identity read from Info.plist: the public label and the build number.
enum AppVersion {
    static var label: String {
        Bundle.main.infoDictionary?["AuraliscopeVersionLabel"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "—" }
    /// One line for bug reports: name, version, build and the macOS release.
    static var summary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Auraliscope \(label) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

/// Release identity and useful links, with the full license notices available on demand.
struct AboutView: View {
    @ObservedObject private var l10n = Localizer.shared

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return L("Third-party notices are included in the packaged app.")
        }
        return contents
    }

    private var license: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return "GPL-3.0-only" }
        return contents
    }

    // Sized to its content, like a system About window: no empty space below a short page, and the window grows
    // when the third-party notices open.
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                AboutBanner()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(verbatim: "GPL-3.0-only")
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Link("GitHub", destination: URL(string: "https://github.com/jinboz12/Auraliscope")!)
                    }
                    .font(.system(size: 12))
                    GitHubUpdateView()
                    DisclosureGroup("GNU GPL v3") {
                        ScrollView {
                            Text(verbatim: license)
                                .font(.system(size: 10).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 200)
                        .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))
                    DisclosureGroup(L("Third-party notices")) {
                        ScrollView {
                            Text(verbatim: notices)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 200)
                        .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))
                    Divider().padding(.vertical, 4)
                    AboutFooter()
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580, alignment: .top)
        .background(Theme.windowBottom)
        .background(UtilityWindowProbe(title: L("About Auraliscope"), capture: Diagnostics.showAbout))
        .tint(Theme.action)
    }

}

private struct AboutBanner: View {
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Theme.bannerAccent.opacity(0.85), Theme.bannerAccent.opacity(0.45), Theme.windowBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 6) {
                BrandMark(size: 22, color: Theme.ink)
                Text(L("Native audio metering for macOS"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink.opacity(0.86))
                Text(verbatim: L("Version %@", AppVersion.label) + "  ·  " + L("Build %@", AppVersion.build))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink.opacity(0.78))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .frame(minHeight: 132)
    }
}

private struct AboutFooter: View {
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(verbatim: "© 2026 JINBOZ")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.folder])
            } label: {
                Label(L("Diagnostic logs"), systemImage: "doc.text.magnifyingglass")
            }
            .glassButton()
            .help(L("Show Diagnostic Logs"))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppVersion.summary, forType: .string)
            } label: {
                Label(L("Copy version"), systemImage: "doc.on.doc")
            }
            .glassButton()
            .help(AppVersion.summary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.top, 4)
    }
}
