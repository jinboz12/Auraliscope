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

/// Release essentials, what the app measures and bundled license notices, set as plain text: no icons or cards.
struct AboutView: View {
    @ObservedObject private var l10n = Localizer.shared

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return L("Third-party notices are included in the packaged app.")
        }
        return contents
    }

    private var features: [(title: String, detail: String)] {
        [(L("Loudness"), L("LUFS, loudness range and True Peak against your target.")),
         (L("Spectrogram & Spectrum"), L("Live spectrum beside its spectral history on one pitch axis, with the notes sounding together lit on its keyboard.")),
         (L("Waveform"), L("Real-time waveforms for each monitored channel.")),
         (L("Soundstage"), L("The channel map of Stereo and Immersive layouts up to 9.1.6 with each speaker's level, and where the frequency bands sit (full band, 3 or 5): a stereometer in Stereo, band markers in Immersive.")),
         (L("Channel Levels"), L("Peak, RMS and true-peak overs per channel, and correlation in 3 or 5 frequency bands in Stereo."))]
    }

    // Sized to its content, like a system About window: no empty space below a short page, and the window grows
    // when the third-party notices open.
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                AboutBanner()
                VStack(alignment: .leading, spacing: 20) {
                    AboutGroup(title: L("What it measures")) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                                if index > 0 { Divider().opacity(0.5) }
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(feature.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.ink)
                                        .frame(width: 170, alignment: .leading)
                                    Text(feature.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.secondary)
                                        .lineSpacing(Localizer.shared.paragraphSpacing)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 8)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    AboutGroup(title: L("Privacy")) {
                        paragraph(L("Audio stays on your Mac. It is analyzed in memory, never recorded or uploaded."))
                    }
                    AboutGroup(title: L("Acknowledgements")) {
                        VStack(alignment: .leading, spacing: 10) {
                            paragraph(L("Spectrogram inspired by AudioSpectrogram. MIT license included."))
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
                            .foregroundStyle(Theme.ink)
                        }
                    }
                    AboutFooter()
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 660, alignment: .top)
        .background(Theme.windowBottom)
        .background(UtilityWindowProbe(title: L("About Auraliscope"), capture: Diagnostics.showAbout))
        .tint(Theme.action)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(Localizer.shared.paragraphSpacing)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct AboutGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased(with: Localizer.shared.locale))
                .font(.eyebrow).tracking(Localizer.shared.tracking(Tracking.eyebrow))
                .foregroundStyle(Theme.tertiary)
            content
        }
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
            Button(L("Show Diagnostic Logs")) {
                NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.folder])
            }
            .glassButton()
            Button(L("Copy Version Info")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppVersion.summary, forType: .string)
            }
            .glassButton()
            .help(AppVersion.summary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.top, 4)
    }
}
