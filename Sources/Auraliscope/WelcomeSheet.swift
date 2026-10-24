import SwiftUI
import AVFoundation

private final class WelcomeOutputSelection: ObservableObject {
    @Published var outputID = SourceID.noOutput
    @Published var requested = false
}

/// A short first-run tutorial in three pages: what the app does, the panels, then the access it needs. The
/// preference is shared with Settings → General → Startup.
struct WelcomeSheet: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage("showWelcomeOnLaunch") private var showWelcomeOnLaunch = true
    @ObservedObject private var permission = AudioPermission.shared
    @StateObject private var outputSelection = WelcomeOutputSelection()
    @State private var page = 0

    private static let pages = 3
    private var outputs: [InputDevice] { model.devices.filter(\.output) }
    private var lastPage: Bool { page == Self.pages - 1 }

    private var heading: (title: String, detail: String) {
        switch page {
        case 0: return (L("See your sound in real time"), L("Live analysis of any input or output, from Mono to 9.1.6."))
        case 1: return (L("Seven panels, one window"), L("Each panel answers one question about your sound."))
        default: return (L("Allow access to audio"), L("Auraliscope only listens to the audio you choose."))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Theme.bannerAccent.opacity(0.8), Theme.bannerAccent.opacity(0.45), Theme.windowBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 10) {
                    BrandMark(size: 13, color: Theme.ink)
                    Text(heading.title)
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(heading.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(26)
                .id(page)
                .transition(.opacity)
            }
            .frame(height: 168)
            .clipped()

            // Every page is laid out at once, so the sheet keeps the tallest page's height and never jumps.
            ZStack(alignment: .top) {
                overview.page(0, of: page)
                panels.page(1, of: page)
                access.page(2, of: page)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(spacing: 14) {
                Toggle(L("Don't show this again"), isOn: Binding(
                    get: { !showWelcomeOnLaunch },
                    set: { showWelcomeOnLaunch = !$0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                Spacer()
                PageDots(count: Self.pages, current: page)
                Spacer()
                if page > 0 {
                    Button(L("Back")) { turn(to: page - 1) }
                        .glassButton()
                        .controlSize(.large)
                }
                // The native prominent button: tinted Liquid Glass on macOS 26, a filled accent button before it.
                Button { lastPage ? dismiss() : turn(to: page + 1) } label: {
                    Text(lastPage ? L("Start Metering") : L("Next"))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .disabled(lastPage && !permission.granted && model.selectedDevice?.output != true
                          && model.selectedDevice?.isBridge != true && !Diagnostics.demo)
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .controlSize(.large)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 610)
        .background(Theme.windowTop)
        .tint(Theme.action)
        .onAppear {
            permission.refresh()
            outputSelection.outputID = (model.selectedDevice?.output == true ? model.selectedID : outputs.first?.id) ?? .noOutput
            if let shown = Diagnostics.welcomePage { page = max(0, min(Self.pages - 1, shown)) }
        }
    }

    private func turn(to next: Int) {
        withAnimation(.smooth(duration: 0.32)) { page = max(0, min(Self.pages - 1, next)) }
    }

    /// Page 1: the whole program in three steps.
    private var overview: some View {
        VStack(spacing: 10) {
            WelcomeStep(number: 1, symbol: "mic", title: L("Choose a source"),
                        detail: L("Pick an input or an output in the toolbar, or a DAW track through the Auraliscope Bridge plugin."),
                        color: Theme.sage)
            WelcomeStep(number: 2, symbol: "hifispeaker.2", title: L("Pick a mode"),
                        detail: L("Mono, Stereo or Immersive up to 9.1.6. Auto follows what is playing."),
                        color: Theme.heather)
            WelcomeStep(number: 3, symbol: "doc.text.magnifyingglass", title: L("Read, then report"),
                        detail: L("Meter against a loudness target, export a report (⌘E) or analyze a file (⌘O)."),
                        color: Theme.ochre)
        }
    }

    /// Page 2: each panel in a line, then how to arrange them.
    private var panels: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                WelcomePanel(panel: .loudness, detail: L("Momentary, Short-term and Integrated LUFS against your target."))
                WelcomePanel(panel: .history, detail: L("How the loudness has moved over time."))
                WelcomePanel(panel: .vu, detail: L("A classic needle for the average level."))
                WelcomePanel(panel: .spectrum, detail: L("Frequency content and pitch, live and over the last 8 seconds."))
                WelcomePanel(panel: .waveform, detail: L("Every channel over the last 2, 4 or 8 seconds."))
                WelcomePanel(panel: .soundstage, detail: L("Where the sound sits, from stereo width to a 9.1.6 dome."))
                WelcomePanel(panel: .levels, detail: L("Every channel's level, side by side."))
            }
            VStack(alignment: .leading, spacing: 7) {
                WelcomeTip(symbol: "arrow.up.left.and.arrow.down.right",
                           text: L("Click a panel's corner button (⌘1–⌘7) to enlarge it; hold it to open the panel in its own window."))
                WelcomeTip(symbol: "dock.rectangle",
                           text: L("Dock mode (⌥⌘S) lays every panel in one row along the bottom of the screen."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Page 3: the access the meter needs.
    private var access: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: permission.granted ? "checkmark.shield.fill" : "mic.fill")
                    .foregroundStyle(permission.granted ? Theme.sage : Theme.ochre)
                Text(L("Microphone access"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(permission.statusText).foregroundStyle(Theme.secondary)
                Button { permission.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .glassIconButton().help(L("Check again"))
            }
            Text(L("Needed to read the input you select. Audio stays on this Mac and is never recorded."))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .lineSpacing(Localizer.shared.paragraphSpacing)
                .fixedSize(horizontal: false, vertical: true)
            if !permission.granted && !Diagnostics.demo {
                Button(permission.status == .notDetermined ? L("Allow Microphone Access") : L("Open Microphone Settings")) {
                    permission.request()
                }
                .glassButton(prominent: true)
            }
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(Theme.heather)
                Text(L("System audio recording"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if outputSelection.requested {
                    Text(model.status.text)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Text(L("Only needed to monitor what apps play to an output. macOS requests access when that output starts; permission can later be changed in System Settings."))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .lineSpacing(Localizer.shared.paragraphSpacing)
                .fixedSize(horizontal: false, vertical: true)
            if #available(macOS 14.2, *) {
                if outputs.isEmpty {
                    Text(L("Connect an output device to request access."))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                } else if !Diagnostics.demo {
                    HStack(spacing: 10) {
                        Picker(L("Output device"), selection: $outputSelection.outputID) {
                            ForEach(outputs) { device in Text(verbatim: device.name).tag(device.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 270)
                        Button {
                            let outputID = outputSelection.outputID
                            guard outputs.contains(where: { $0.id == outputID }) else { return }
                            outputSelection.requested = true
                            if model.selectedID == outputID { model.resume() }
                            else { model.select(outputID) }
                        } label: {
                            Label(L("Request System Audio Access"), systemImage: "hand.raised")
                        }
                        .glassButton()
                    }
                }
            } else {
                Text(L("Output monitoring requires macOS 14.2 or later."))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: Theme.cardRadius - 4, style: .continuous))
    }
}

private extension View {
    /// One page of the welcome: shown at `index`, faded and slid a little toward the side it came from otherwise.
    func page(_ index: Int, of current: Int) -> some View {
        opacity(index == current ? 1 : 0)
            .offset(x: CGFloat(index - current) * 28)
            .allowsHitTesting(index == current)
            .accessibilityHidden(index != current)
    }
}

/// Which page of the welcome is showing.
private struct PageDots: View {
    let count: Int
    let current: Int
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.ink.opacity(0.8) : Theme.ink.opacity(0.2))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Page %d of %d", current + 1, count))
    }
}

/// A numbered step of the first page.
private struct WelcomeStep: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(verbatim: "\(number)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.22), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(Localizer.shared.paragraphSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: Theme.cardRadius - 4, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One panel of the second page: its toolbar symbol, title and what it shows.
private struct WelcomePanel: View {
    let panel: MeterPanel
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: panel.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.action)
                .frame(width: 20, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(panel.title)
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
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: Theme.cardRadius - 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A one-line hint under the panels.
private struct WelcomeTip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(Localizer.shared.paragraphSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
