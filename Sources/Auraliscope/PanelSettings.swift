import AnalysisCore
import SwiftUI

/// The panels whose display choices live on the panel itself, behind a small button in its header.
enum PanelKind {
    case loudness, spectrum, waveform, soundstage, levels
}

/// A panel's own settings: a small button in its header opening a popover of that panel's display choices. Every
/// choice takes effect at once and is kept (the model follows the stored values, as for every display option), so
/// what a control does shows right beside it, on the panel it changes.
struct PanelSettingsButton: View {
    let panel: PanelKind
    var model: MeterModel? = nil
    @State private var open = false
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(open ? Theme.ink : Theme.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Theme.ink.opacity(open ? 0.12 : 0.06)))
        .help(L("Panel settings"))
        .accessibilityLabel(L("Panel settings"))
        .onAppear {
            guard Diagnostics.snapshotPanelSettings, panel == .spectrum else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { open = true }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PanelSettingsForm(panel: panel, model: model)
                .padding(14)
                .frame(width: 340)
        }
    }
}

/// The popover's content for one panel: titled groups of rows, each a name (its explanation on hover) and a control.
private struct PanelSettingsForm: View {
    let panel: PanelKind
    let model: MeterModel?
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(LoudnessReading.key) private var headline = LoudnessReading.shortTerm.rawValue
    @AppStorage(SpectrogramView.key) private var view = SpectrogramView.flat.rawValue
    @AppStorage(SpectrogramAnalysis.key) private var analysis = SpectrogramAnalysis.classic.rawValue
    @AppStorage(SpectrogramSpan.key) private var span = SpectrogramSpan.auto.rawValue
    @AppStorage(SpectrogramRange.key) private var range = SpectrogramRange.standard.rawValue
    @AppStorage(SpectrogramColors.key) private var colors = SpectrogramColors.heat.rawValue
    @AppStorage(SpectrumSmoothing.key) private var smoothing = SpectrumSmoothing.sixth.rawValue
    @AppStorage(SpectrumResponse.key) private var response = SpectrumResponse.medium.rawValue
    @AppStorage(DisplayOptions.peakHoldsKey) private var peakHolds = true
    @AppStorage(DisplayOptions.averageSpectrumKey) private var average = true
    @AppStorage(SpectrumTilt.key) private var tilt = SpectrumTilt.flat.rawValue
    @AppStorage(SpectrumSide.key) private var side = SpectrumSide.right.rawValue
    @AppStorage(DisplayOptions.waveSecondsKey) private var waveSeconds = 4
    @AppStorage(StageStyle.key) private var stageStyle = StageStyle.dots.rawValue
    @AppStorage("levels.bands") private var levelBands = StereoBands.Resolution.five.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch panel {
            case .loudness:
                group(L("LOUDNESS")) {
                    row(L("Main reading"), note: L("The large reading, gauge and target difference follow this choice. The other two readings stay beside it. Momentary covers 400 ms; Short-term covers 3 s. Integrated measures the programme since the last reset, with loudness gating.")) {
                        segments(L("Main reading"), LoudnessReading.allCases, $headline) { $0.title }
                    }
                }
            case .spectrum:
                group(L("SPECTROGRAM")) {
                    row(L("View"), note: L("2D scrolls a flat image in time. 3D lifts it into a landscape: time across, frequency into the distance, level as height.")) {
                        segments(L("View"), SpectrogramView.allCases, $view) { $0.title }
                    }
                    row(L("Analysis"), note: L("Classic shows every row at its calibrated level. Enhanced moves each component's energy to the time and frequency its phase points to (reassignment): tones become thin lines and onsets sharp, while noise breaks into fine grain.")) {
                        segments(L("Analysis"), SpectrogramAnalysis.allCases, $analysis) { $0.title }
                    }
                    if analysis == SpectrogramAnalysis.enhanced.rawValue, let model, model.sourceIsBridge,
                       model.lastSpectrogramMode != Float(SpectrogramMode.enhanced.rawValue) {
                        caption(L("This plugin sends Classic columns. Install the plugins of this build for Enhanced."))
                    }
                    row(L("Spectrogram span"), note: L("How many seconds the spectrogram shows. Auto fits 3 to 8 s to the panel's width; 15 s shows a whole phrase.")) {
                        segments(L("Spectrogram span"), SpectrogramSpan.allCases, $span) { $0.title }
                    }
                    row(L("Color range"), note: L("The levels the spectrogram's colors span. Standard: −90 to −12 dBFS. Deep: −114 to −24 dBFS, for reverb tails, noise floors and hum. Hot: −72 to 0 dBFS, for loud masters.")) {
                        segments(L("Color range"), SpectrogramRange.allCases, $range) { $0.title }
                    }
                    row(L("Colors"), note: L("The spectrogram's color map. Theme follows the app's palette. Heat turns from indigo through crimson to amber as the level rises, so nearby levels are easier to tell apart. Gray is plain grayscale.")) {
                        segments(L("Colors"), SpectrogramColors.allCases, $colors) { $0.title }
                    }
                }
                group(L("SPECTRUM")) {
                    row(L("Smoothing"), note: L("Averages the curve, the peak holds and the average across frequency, in power. 1/6 octave reads like a mixing engineer's analyser; 1/3 octave shows the broad tonal balance; Off draws every band.")) {
                        segments(L("Smoothing"), SpectrumSmoothing.allCases, $smoothing) { $0.title }
                    }
                    row(L("Response"), note: L("How quickly the live spectrum follows the sound. Fast shows every attack; Slow steadies the curve so tonal balance is easy to read. Peak holds and the average are unaffected.")) {
                        segments(L("Response"), SpectrumResponse.allCases, $response) { $0.title }
                    }
                    row(L("Peak holds"), note: L("A faint line along each band's recent peak, held 1.2 s and then falling.")) {
                        Toggle(L("Peak holds"), isOn: $peakHolds).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row(L("Average spectrum"), note: L("A second line averages received spectrum measurements in power, leaving out silence. Reset, a source or sample-rate change, or switching between Stereo and Immersive starts a new average.")) {
                        Toggle(L("Average spectrum"), isOn: $average).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }
                group(L("BOTH")) {
                    row(L("Tilt"), note: L("A display slope around 1 kHz for the spectrum and the spectrogram. Music falls by about 3 to 4.5 dB per octave, so a tilt shows a balanced mix as level and the treble as clearly as the bass. Readings stay true.")) {
                        segments(L("Tilt"), SpectrumTilt.allCases, $tilt) { $0.title }
                    }
                    row(L("Orientation"), note: L("Standard: keyboard on the left, the spectrogram scrolling left from now, the spectrum on the right. Mirrored flips the panel: the spectrum on the left, the spectrogram scrolling right from now, the keyboard on the right.")) {
                        segments(L("Orientation"), SpectrumSide.allCases, $side) { $0.title }
                    }
                }
                caption(L("Hover over the spectrogram or the spectrum to read its pitch, frequency and level; pause to read a moment at leisure."))
            case .waveform:
                group(L("WAVEFORM")) {
                    row(L("Time span"), note: L("How much history the lanes show. A short span resolves single transients; a long one shows the shape of a phrase.")) {
                        GlassSegments(label: L("Time span"), options: DisplayOptions.waveChoices.map { ($0, L("%d s", $0), L("%d s", $0)) },
                                      selection: DisplayOptions.waveChoices.contains(waveSeconds) ? waveSeconds : 4,
                                      select: { waveSeconds = $0 })
                    }
                }
                if let model { WaveformKey(format: model.format, layout: model.speakerLayout) }
            case .soundstage:
                group(L("SOUNDSTAGE")) {
                    row(L("Stereometer style"), note: L("How the Stereo stereometer draws each band. Dots shows every sample; Outlines traces where each band's samples reach; Filled tints each outline, laying the smaller shapes over the larger so every edge stays visible.")) {
                        segments(L("Stereometer style"), StageStyle.allCases, $stageStyle) { $0.title }
                    }
                }
            case .levels:
                group(L("CHANNEL LEVELS")) {
                    row(L("BANDS"), note: L("How finely the correlation splits the spectrum: the full band, three bands or five.")) {
                        GlassSegments(label: L("BANDS"), options: StereoBands.Resolution.allCases.map { ($0.rawValue, $0.title, $0.title) },
                                      selection: levelBands, select: { levelBands = $0; model?.levelsBands = StereoBands.Resolution(rawValue: $0) ?? .five })
                    }
                }
                // The key to each bar, drawn with the bars' own shapes and colours.
                MeterLegend()
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(l10n.tracking(0.6))
                .foregroundStyle(Theme.tertiary)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    private func row<Control: View>(_ title: String, note: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 6)
            control()
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .help(note)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A stored choice of `T`, shown by `title`.
    private func segments<T: RawRepresentable & Hashable>(_ label: String, _ cases: [T], _ stored: Binding<String>,
                                                       title: @escaping (T) -> String) -> some View where T.RawValue == String {
        let selection = T(rawValue: stored.wrappedValue) ?? cases[0]
        return GlassSegments(label: label, options: cases.map { ($0, title($0), title($0)) }, selection: selection,
                             select: { stored.wrappedValue = $0.rawValue })
    }
}
