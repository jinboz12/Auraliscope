import SwiftUI
import AVFoundation

private final class WelcomeOutputSelection: ObservableObject {
    @Published var outputID = SourceID.noOutput
    @Published var requested = false
}

/// A short first-run introduction. The preference is shared with Settings → General → Startup.
struct WelcomeSheet: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage("showWelcomeOnLaunch") private var showWelcomeOnLaunch = true
    @ObservedObject private var permission = AudioPermission.shared
    @StateObject private var outputSelection = WelcomeOutputSelection()

    private var outputs: [InputDevice] { model.devices.filter(\.output) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Theme.bannerAccent.opacity(0.8), Theme.bannerAccent.opacity(0.45), Theme.windowBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 10) {
                    BrandMark(size: 13, color: Theme.ink)
                    Text(L("See your sound in real time"))
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(L("Live analysis of any input or output, from Mono to 9.1.6."))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(26)
            }
            .frame(height: 168)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                WelcomeFeature(symbol: "waveform.path", title: L("Spectrogram & Spectrum"),
                               detail: L("Frequency content and pitch, live and over the last 8 seconds."), color: Theme.sage)
                WelcomeFeature(symbol: "chart.xyaxis.line", title: L("Loudness"),
                               detail: L("LUFS, Range and True Peak against a delivery target."), color: Theme.ochre)
                WelcomeFeature(symbol: "waveform", title: L("Waveform"),
                               detail: L("Every channel over the last 2, 4 or 8 seconds."), color: Theme.sand)
                WelcomeFeature(symbol: "speaker.wave.3", title: L("Soundstage"),
                               detail: L("Formats up to 9.1.6, with up to 64 inputs to route."), color: Theme.heather)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 18)

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
                            Button(L("Request System Audio Access")) {
                                let outputID = outputSelection.outputID
                                guard outputs.contains(where: { $0.id == outputID }) else { return }
                                outputSelection.requested = true
                                if model.selectedID == outputID { model.resume() }
                                else { model.select(outputID) }
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
            .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
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
                // The native prominent button: tinted Liquid Glass on macOS 26, a filled accent button before it.
                Button { dismiss() } label: {
                    Text(L("Start Metering"))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .disabled(!permission.granted && model.selectedDevice?.output != true && !Diagnostics.demo)
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
        }
    }
}

private struct WelcomeFeature: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24, height: 25)
            VStack(alignment: .leading, spacing: 5) {
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
        .frame(maxWidth: .infinity, minHeight: 75, alignment: .topLeading)
        .padding(13)
        .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
