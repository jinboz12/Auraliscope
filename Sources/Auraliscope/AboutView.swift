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

/// Release essentials, main features and bundled license notices.
struct AboutView: View {
    @ObservedObject private var l10n = Localizer.shared

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return L("Third-party notices are included in the packaged app.")
        }
        return contents
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AboutBanner()
                VStack(alignment: .leading, spacing: 18) {
                    AboutGroup(title: L("What it measures")) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            AboutFeature(symbol: "waveform.path.ecg", color: Theme.sage, title: L("Spectrum & Spectrogram"),
                                         detail: L("Live frequency analysis, pitch detection and spectral history."))
                            AboutFeature(symbol: "chart.xyaxis.line", color: Theme.ochre, title: L("Loudness"),
                                         detail: L("LUFS, loudness range and True Peak against your target."))
                            AboutFeature(symbol: "waveform", color: Theme.sand, title: L("Waveform"),
                                         detail: L("Real-time waveforms for each monitored channel."))
                            AboutFeature(symbol: "hifispeaker.2", color: Theme.heather, title: L("Soundstage"),
                                         detail: L("Channel levels, clipping and correlation, from Mono to 9.1.6."))
                        }
                    }
                    AboutGroup(title: L("Privacy")) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.sage)
                                .frame(width: 26)
                            Text(L("Audio stays on your Mac. It is analyzed in memory, never recorded or uploaded."))
                                .font(.system(size: 12))
                                .lineSpacing(Localizer.shared.paragraphSpacing)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { CardSurface(radius: 14) }
                    }
                    AboutGroup(title: L("Acknowledgements")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("Spectrogram inspired by AudioSpectrogram. MIT license included."))
                                .font(.system(size: 12))
                                .lineSpacing(Localizer.shared.paragraphSpacing)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 620, minHeight: 580)
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
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    BrandMark(size: 22, color: Theme.ink)
                    Text(L("Native audio metering for macOS"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink.opacity(0.86))
                    HStack(spacing: 8) {
                        Text(L("Version %@", AppVersion.label))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .glassSurface(Capsule(), tint: Theme.sage.opacity(0.08), fallback: Theme.chipFill)
                        Text(L("Build %@", AppVersion.build))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.ink.opacity(0.78))
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .frame(minHeight: 138)
    }
}

private struct AboutGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased(with: Localizer.shared.locale))
                .font(.eyebrow).tracking(Localizer.shared.tracking(Tracking.eyebrow))
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 2)
            content
        }
    }
}

private struct AboutFeature: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(Localizer.shared.paragraphSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background { CardSurface(radius: 12) }
        .accessibilityElement(children: .combine)
    }
}

private struct AboutFooter: View {
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "© 2026 JINBOZ")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppVersion.summary, forType: .string)
            } label: {
                Label(L("Copy Version Info"), systemImage: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .glassButton()
            .help(AppVersion.summary)
        }
        .padding(.top, 4)
    }
}
