import AnalysisCore
import SwiftUI

/// The panels whose display choices live on the panel itself, behind a small button in its header.
enum PanelKind {
    case loudness, history, vu, spectrum, waveform, soundstage, levels, multiFFT
}

/// A panel's own settings: a small button in its header opening a popover of that panel's display choices. Every
/// choice takes effect at once and is kept (the model follows the stored values, as for every display option), so
/// what a control does shows right beside it, on the panel it changes.
struct PanelSettingsButton: View {
    /// The nebula's Analysis and motion section (the Spectrum's BOTH VIEWS, the Multi-FFT's bands), for scrolling to it.
    static let advancedID = "nebulaAdvanced"
    /// Every panel's popover is this wide, so their rows and notes line up alike (the nebula's scrolls, with a scroller
    /// that floats over its margin rather than narrowing it).
    static let popoverWidth: CGFloat = 372
    /// Titles, rows and notes in the popover share this inset, the cards' own.
    static let inset: CGFloat = 12
    let panel: PanelKind
    var model: MeterModel? = nil
    /// The panel's window button follows the settings button; off where the panel places it itself.
    var window = true
    @State private var open = false
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        HStack(spacing: 6) {
            settings
            if window { PanelWindowButton(panel: panel.meterPanel) }
        }
    }

    private var settings: some View {
        // A disc like the toolbar's buttons, lit while its popover is open.
        DiscButton(symbol: "slider.horizontal.3", help: L("Panel settings"), diameter: 22, on: open) { open.toggle() }
        .onAppear {
            // `--snapshot-panel-settings <panel>` (loudness, history, vu, spectrum, waveform, soundstage, levels, multiFFT).
            let wanted = Diagnostics.snapshotPanelSettingsPanel.isEmpty ? "spectrum" : Diagnostics.snapshotPanelSettingsPanel
            guard Diagnostics.snapshotPanelSettings, "\(panel)" == wanted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { open = true }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if panel == .soundstage || panel == .spectrum || panel == .multiFFT {
                // The nebula's settings are many: they scroll, so the popover fits a 720p screen.
                ScrollViewReader { proxy in
                    ScrollView {
                        PanelSettingsForm(panel: panel, model: model).padding(16)
                            .background(OverlayScrollers())
                    }
                    .onAppear {
                        // `--snapshot-panel-advanced`: scrolled to the Analysis and motion section, opened.
                        guard Diagnostics.snapshotPanelAdvanced else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo(Self.advancedID, anchor: .top) }
                    }
                }
                .frame(width: Self.popoverWidth, height: 500)
            } else {
                PanelSettingsForm(panel: panel, model: model)
                    .padding(16)
                    .frame(width: Self.popoverWidth)
            }
        }
    }
}

/// The popover's content for one panel: titled groups of rows, each a name (its explanation on hover) and a control.
private struct PanelSettingsForm: View {
    let panel: PanelKind
    let model: MeterModel?
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(DisplayOptions.domeCentroidKey) private var domeCentroid = true
    @ObservedObject private var camera = DomeCamera.shared
    @AppStorage(NebulaSettings.Key.floor) private var nebulaFloor = NebulaSettings().floor
    @AppStorage(NebulaSettings.Key.lowest) private var nebulaLowest = NebulaSettings().lowest
    @AppStorage(NebulaSettings.Key.highest) private var nebulaHighest = NebulaSettings().highest
    @AppStorage(NebulaSettings.Key.smoothing) private var nebulaSmoothing = NebulaSettings().smoothing
    @AppStorage(NebulaSettings.Key.spread) private var nebulaSpread = NebulaSettings().spread
    @AppStorage(NebulaSettings.Key.coherence) private var nebulaCoherence = NebulaSettings().coherence
    @AppStorage(NebulaSettings.Key.opacity) private var nebulaOpacity = NebulaSettings().opacity
    @AppStorage(NebulaSettings.Key.colors) private var nebulaColors = NebulaSettings().colors.rawValue
    @AppStorage(NebulaSettings.Key.grain) private var nebulaGrain = NebulaSettings().grain
    @AppStorage(NebulaSettings.Key.attack) private var nebulaAttack = NebulaSettings().attack
    @AppStorage(NebulaSettings.Key.release) private var nebulaRelease = NebulaSettings().release
    @AppStorage(NebulaSettings.Key.persistence) private var nebulaPersistence = NebulaSettings().persistence
    @AppStorage(NebulaSettings.Key.speakers) private var nebulaSpeakers = true
    @AppStorage(NebulaSettings.Key.lfe) private var nebulaLFE = true
    @AppStorage(NebulaSettings.Key.listener) private var nebulaListener = true
    @AppStorage(NebulaSettings.Key.grid) private var nebulaGrid = true
    @AppStorage(NebulaSettings.Key.axes) private var nebulaAxes = false
    @AppStorage(NebulaSettings.Key.style) private var nebulaStyle = NebulaSettings().style.rawValue
    @AppStorage(NebulaSettings.Key.range) private var nebulaRange = NebulaSettings().range
    @AppStorage(NebulaSettings.Key.particles) private var nebulaParticles = NebulaSettings().particles
    @AppStorage(NebulaSettings.Key.particleSize) private var nebulaParticleSize = NebulaSettings().particleSize
    @AppStorage(NebulaSettings.Key.blur) private var nebulaBlur = NebulaSettings().blur
    @AppStorage(NebulaSettings.Key.points) private var nebulaPoints = NebulaSettings().points
    @AppStorage(NebulaSettings.Key.rawPoints) private var nebulaRawPoints = false
    @AppStorage(NebulaSettings.Key.window) private var nebulaWindow = SpatialWindowChoice.standard.rawValue
    @State private var nebulaAdvanced = Diagnostics.snapshotPanelAdvanced
    private var radiant: Bool { nebulaStyle != NebulaStyle.level.rawValue }
    @ObservedObject private var speakerLayouts = SpeakerLayoutStore.shared
    /// The layout the dome uses for the format shown: the user's, or the standard one.
    private var speakerLayoutName: String {
        let format = model?.shownLayout ?? .standard
        return speakerLayouts.configuration(for: format)?.name ?? L("Standard %@", format.name)
    }
    @AppStorage(LoudnessReading.key) private var headline = LoudnessReading.shortTerm.rawValue
    @AppStorage(VUScale.referenceKey) private var vuReference = 0.0
    @AppStorage(PeakHoldTime.key) private var levelsHold = PeakHoldTime.standard.rawValue
    @AppStorage(PeakRelease.key) private var levelsRelease = PeakRelease.normal.rawValue
    @AppStorage(LoudnessUnit.key) private var loudnessUnit = LoudnessUnit.lufs.rawValue
    @AppStorage(LoudnessScale.key) private var loudnessScale = LoudnessScale.full.rawValue
    @AppStorage(HistoryScale.momentaryKey) private var historyMomentary = true
    @AppStorage(HistoryScale.bandKey) private var historyBand = true
    @AppStorage(HistoryScale.key) private var historyScale = HistoryScale.full.rawValue
    @AppStorage(HistorySpan.key) private var historySpan = HistorySpan.fifteen.rawValue
    @AppStorage(SpectrogramView.key) private var view = SpectrogramView.flat.rawValue
    @AppStorage(SpectrogramAnalysis.key) private var analysis = SpectrogramAnalysis.classic.rawValue
    @AppStorage(SpectrogramSpan.key) private var span = SpectrogramSpan.auto.rawValue
    @AppStorage(SpectrogramRange.key) private var range = SpectrogramRange.standard.rawValue
    @AppStorage(SpectrogramColors.key) private var colors = SpectrogramColors.heat.rawValue
    @AppStorage(SpectrumSmoothing.key) private var smoothing = SpectrumSmoothing.sixth.rawValue
    @AppStorage(SpectrumResponse.key) private var response = SpectrumResponse.medium.rawValue
    @AppStorage(DisplayOptions.peakHoldsKey) private var peakHolds = true
    @AppStorage(DisplayOptions.averageSpectrumKey) private var average = true
    @AppStorage(SpectrumTilt.key) private var tilt = 0.0
    @AppStorage(FrequencyScale.key) private var frequencyScale = FrequencyScale.log.rawValue
    @AppStorage(MultiFFTPreferences.legacyKey) private var sharedSTFT = 4096
    @AppStorage(MultiFFTPreferences.key) private var multiFFTData: Data?
    @AppStorage(SpectrumTilt.multiFFTKey) private var multiFFTTilt = 0.0
    @AppStorage(FrequencyScale.multiFFTKey) private var multiFFTScale = FrequencyScale.log.rawValue
    @State private var multiFFTBands = Diagnostics.snapshotPanelAdvanced
    @AppStorage(SpectrumSide.key) private var side = SpectrumSide.right.rawValue
    @AppStorage(DisplayOptions.waveSecondsKey) private var waveSeconds = 4
    @AppStorage(WaveScale.key) private var waveScale = WaveScale.linear.rawValue
    @AppStorage(StageStyle.key) private var stageStyle = StageStyle.dots.rawValue
    @AppStorage(DisplayOptions.levelsBandsKey) private var levelBands = StereoBands.Resolution.five.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(panel.meterPanel.title, size: 15)
                .padding(.leading, PanelSettingsButton.inset)
            switch panel {
            case .loudness:
                group(L("READING")) {
                    row(L("Main reading"), note: L("The large reading, gauge and target difference follow this choice. The other two readings stay beside it. Momentary covers 400 ms; Short-term covers 3 s. Integrated measures the programme since the last reset, with loudness gating.")) {
                        segments(L("Main reading"), LoudnessReading.allCases, $headline) { $0.title }
                    }
                    line
                    row(L("Units"), note: L("LUFS writes loudness as it is; LU writes it relative to the target, 0 at the target, as an EBU-mode meter's relative scale does. Range and true peak keep their units.")) {
                        segments(L("Units"), LoudnessUnit.allCases, $loudnessUnit) { $0.title }
                    }
                    line
                    row(L("Gauge scale"), note: L("The gauge's range. Full spans −36 to 0 LUFS. EBU +9 spans −18 to +9 LU around the target and EBU +18 spans −36 to +18 LU, the two scales of EBU Tech 3341.")) {
                        segments(L("Gauge scale"), LoudnessScale.allCases, $loudnessScale) { $0.title }
                    }
                }
                if let model {
                    group(model.format == .spatial ? L("TARGET · IMMERSIVE") : L("TARGET · STEREO & MONO")) {
                        StandardSteppers(model: model)
                    }
                    caption(L("Type a value or use the arrows. The summary's TARGET and CEILING menus offer the published standards; Stereo and Immersive each keep their own."))
                }
            case .history:
                group(L("PLOT")) {
                    row(L("Span"), note: L("How much time the plot spans. Session shows the whole measurement since the last reset, the same readings a loudness report exports.")) {
                        segments(L("Span"), HistorySpan.allCases, $historySpan) { $0.title }
                    }
                    line
                    row(L("Scale"), note: L("The loudness the plot spans. Full reads −36 to 0 LUFS; Close zooms to 18 LU around the target, so small changes of level show.")) {
                        segments(L("Scale"), HistoryScale.allCases, $historyScale) { $0.title }
                    }
                }
                group(L("LINES")) {
                    row(L("Momentary"), note: L("The faint line: momentary loudness (400 ms) under the short-term line, to see the peaks a 3 s reading smooths away.")) {
                        toggle(L("Momentary"), $historyMomentary)
                    }
                    line
                    row(L("Target band"), note: L("The band of ±1 LU around the loudness target, with its value at the left.")) {
                        toggle(L("Target band"), $historyBand)
                    }
                }
            case .vu:
                group(L("CALIBRATION")) {
                    row(L("0 VU at"), note: L("The level the VU meter reads as 0 VU. Target follows the loudness target of the current mode; a fixed level calibrates it like a studio console, where −18 dBFS = 0 VU is common.")) {
                        GlassSegments(label: L("0 VU at"), options: VUScale.referenceChoices.map { ($0, $0 == 0 ? L("Target") : MeterScale.signedInteger(Float($0)),
                                                                                    $0 == 0 ? L("Target") : MeterScale.signedInteger(Float($0)) + " dBFS") },
                                      selection: VUScale.referenceChoices.contains(vuReference) ? vuReference : 0,
                                      select: { vuReference = $0 })
                    }
                }
            case .spectrum:
                group(L("SPECTROGRAM")) {
                    row(L("View"), note: L("2D scrolls a flat image in time. 3D lifts it into a landscape: time across, frequency into the distance, level as height.")) {
                        segments(L("View"), SpectrogramView.allCases, $view) { $0.title }
                    }
                    line
                    row(L("Analysis"), note: L("Classic shows every row at its calibrated level. Enhanced moves each component's energy to the time and frequency its phase points to (reassignment): tones become thin lines and onsets sharp, while noise breaks into fine grain.")) {
                        segments(L("Analysis"), SpectrogramAnalysis.allCases, $analysis) { $0.title }
                    }
                    if analysis == SpectrogramAnalysis.enhanced.rawValue, let model, model.sourceIsBridge,
                       model.lastSpectrogramMode != Float(SpectrogramMode.enhanced.rawValue) {
                        caption(L("This plugin sends Classic columns. Install the plugins of this build for Enhanced."))
                            .padding(.bottom, 6)
                    }
                    line
                    row(L("Spectrogram span"), note: L("How many seconds the spectrogram shows. Auto fits 3 to 8 s to the panel's width; 15 s shows a whole phrase.")) {
                        segments(L("Spectrogram span"), SpectrogramSpan.allCases, $span) { $0.title }
                    }
                    line
                    row(L("Shared STFT"), note: L("Shared Hann STFT serves both displays at the chosen size. Legacy keeps the multi-resolution analysis of build 113. Enhanced, Immersive and a plugin source keep their own analysis. Switching refills the FFT history.")) {
                        GlassSegments(label: L("Shared STFT"), options: [(0, L("Legacy"), L("Legacy (Build 113)"))] + [2048, 4096, 8192].map { ($0, "\($0)", "\($0)") },
                                      selection: [0, 2048, 4096, 8192].contains(sharedSTFT) ? sharedSTFT : 4096,
                                      select: { sharedSTFT = $0 })
                    }
                }
                group(L("SPECTROGRAM COLORS")) {
                    row(L("Color range"), note: L("The levels the spectrogram's colors span. Standard: −90 to −12 dBFS. Deep: −114 to −24 dBFS, for reverb tails, noise floors and hum. Hot: −72 to 0 dBFS, for loud masters.")) {
                        segments(L("Color range"), SpectrogramRange.allCases, $range) { $0.title }
                    }
                    line
                    row(L("Colors"), note: L("The spectrogram's color map. Theme follows the app's palette. Heat turns from indigo through crimson to amber as the level rises, so nearby levels are easier to tell apart. Gray is plain grayscale.")) {
                        segments(L("Colors"), SpectrogramColors.allCases, $colors) { $0.title }
                    }
                }
                group(L("SPECTRUM")) {
                    row(L("Smoothing"), note: L("Averages the curve, the peak holds and the average across frequency, in power. 1/6 octave reads like a mixing engineer's analyser; 1/3 octave shows the broad tonal balance; Off draws every band. Var keeps 1/48 octave detail up to 100 Hz and widens to 1/3 octave from 10 kHz, as room-measurement software does.")) {
                        segments(L("Smoothing"), SpectrumSmoothing.allCases, $smoothing) { $0.title }
                    }
                    line
                    row(L("Response"), note: L("How quickly the live spectrum follows the sound. Fast shows every attack; Slow steadies the curve so tonal balance is easy to read. Peak holds and the average are unaffected.")) {
                        segments(L("Response"), SpectrumResponse.allCases, $response) { $0.title }
                    }
                    line
                    row(L("Peak holds"), note: L("A faint line along each band's recent peak, held 1.2 s and then falling.")) {
                        toggle(L("Peak holds"), $peakHolds)
                    }
                    line
                    row(L("Average spectrum"), note: L("A second line averages received spectrum measurements in power, leaving out silence. Reset, a source or sample-rate change, or switching between Stereo and Immersive starts a new average.")) {
                        toggle(L("Average spectrum"), $average)
                    }
                }
                group(L("BOTH VIEWS")) {
                    row(L("Frequency scale"), note: L("Log gives every octave the same room from 20 Hz, as pitch is heard. Linear starts at 0 Hz and gives every hertz the same room, as an FFT spaces its bins: harmonics fall evenly apart and the treble opens out, while the bass narrows. The analysis is the same.")) {
                        segments(L("Frequency scale"), FrequencyScale.allCases, $frequencyScale) { $0.title }
                    }
                    line
                    row(L("Tilt"), note: L("A display slope around 1 kHz for the spectrum and the spectrogram, from 0 to 6 dB per octave. Music falls by about 3 to 4.5 dB per octave, so a tilt shows a balanced mix as level and the treble as clearly as the bass. Readings stay true.")) {
                        tiltSlider($tilt)
                    }
                    line
                    row(L("Orientation"), note: L("Standard: keyboard on the left, the spectrogram scrolling left from now, the spectrum on the right. Mirrored flips the panel: the spectrum on the left, the spectrogram scrolling right from now, the keyboard on the right.")) {
                        segments(L("Orientation"), SpectrumSide.allCases, $side) { $0.title }
                    }
                }
                .id(PanelSettingsButton.advancedID)
                caption(L("Hover over the spectrogram or the spectrum to read its pitch, frequency and level; pause to read a moment at leisure."))
            case .waveform:
                group(L("LANES")) {
                    row(L("Time span"), note: L("How much history the lanes show. A short span resolves single transients; a long one shows the shape of a phrase.")) {
                        GlassSegments(label: L("Time span"), options: DisplayOptions.waveChoices.map { ($0, L("%d s", $0), L("%d s", $0)) },
                                      selection: DisplayOptions.waveChoices.contains(waveSeconds) ? waveSeconds : 4,
                                      select: { waveSeconds = $0 })
                    }
                    line
                    row(L("Level scale"), note: L("Linear draws the amplitude as a DAW does. dB spreads the lanes by level, full scale at the edges and −48 dBFS at the centre line, so quiet passages and fades stay readable. Both draw the exact sample peaks.")) {
                        segments(L("Level scale"), WaveScale.allCases, $waveScale) { $0.title }
                    }
                }
                caption(L("Hover over the lanes to read the time and the sample peak there; pause to read a moment at leisure."))
                if let model { WaveformKey(format: model.format, layout: model.shownLayout) }
            case .soundstage:
                soundstage
            case .multiFFT:
                multiFFT
            case .levels:
                group(L("PEAK HOLD")) {
                    row(L("Hold"), note: L("How long each channel's peak mark stays at its highest reading before it falls. ∞ holds it until Reset.")) {
                        segments(L("Hold"), PeakHoldTime.allCases, $levelsHold) { $0.title }
                    }
                    line
                    row(L("Release"), note: L("How fast a mark falls once its hold has passed. Fast: 40 dB/s. Normal: 20 dB/s. PPM: 24 dB in 2.8 s, a peak programme meter's return (IEC 60268-10 Type II). The bars keep their own ballistics.")) {
                        segments(L("Release"), PeakRelease.allCases, $levelsRelease) { $0.title }
                    }
                }
                group(L("CORRELATION")) {
                    row(L("Bands"), note: L("How finely the correlation splits the spectrum: the full band, three bands or five.")) {
                        GlassSegments(label: L("Bands"), options: StereoBands.Resolution.allCases.map { ($0.rawValue, $0.title, $0.title) },
                                      selection: levelBands, select: { levelBands = $0; model?.levelsBands = StereoBands.Resolution(rawValue: $0) ?? .five })
                    }
                }
                // The key to each bar, drawn with the bars' own shapes and colours.
                MeterLegend()
                    .padding(.leading, PanelSettingsButton.inset)
            }
        }
    }

    /// The Soundstage's settings: Stereo's one choice, then the Immersive dome's in what each changes (the body, the
    /// camera, what else the dome shows), its finer analysis and motion folded away, then what the readings mean.
    @ViewBuilder private var soundstage: some View {
        group(L("STEREO")) {
            row(L("Stereometer style"), note: L("How the Stereo stereometer draws each band. Dots shows every sample; Outlines traces where each band's samples reach; Filled tints each outline, laying the smaller shapes over the larger so every edge stays visible.")) {
                segments(L("Stereometer style"), StageStyle.allCases, $stageStyle) { $0.title }
            }
        }
        group(L("IMMERSIVE")) {
            row(L("Style"), note: L("Radiant body draws each band where its frequencies are heard, at the centre of gravity of the speakers that carry them weighted by their level in each, as one glowing body: a centred phantom gathers between L and R, a wide stereo programme stretches along the line between them, and sound all round gathers toward the listener. It glows in the frequencies' hues, burns toward white where it is dense and loud, and swells into haze as it ages. Point lights over it mark exactly where each band's frequencies sit. Level body draws the level heard from each direction as the radius of one body, read on the floor's dBFS rings.")) {
                segments(L("Style"), NebulaStyle.allCases, $nebulaStyle) { $0.title }
            }
            line
            row(L("Colors"), note: radiant ? L("Frequency colors the body by the frequencies heard at each place, warm bass through cool treble: where many bands meet it burns toward a cream-white core, and its fringes show what dominates there. Theme draws it in the palette's color. A split into 3 or 5 bands always shows each band in its own color.") : L("Frequency colors the full band by the bands heard from each direction, warm bass through cool treble: near the listener every audible band mixes, toward white for broadband sound, and toward the edge only the loudest bands remain. Theme draws it in the palette's color. A split into 3 or 5 bands always shows each band in its own color.")) {
                segments(L("Colors"), NebulaColors.allCases, $nebulaColors) { $0.title }
            }
            line
            row(L("Speaker layout"), note: L("Where each speaker sits around the listening position (azimuth, elevation and, if known, distance), for the dome and its analysis, here and in a DAW plugin of this build. The standard layout places the ear layer at 0° and every height at 45°.")) {
                Button {
                    SpeakerLayoutStore.shared.openEditor(for: model?.shownLayout ?? .standard)
                } label: {
                    Label { Text(verbatim: speakerLayoutName).lineLimit(1) } icon: { Image(systemName: "hifispeaker.2") }
                }
                .glassButton()
            }
        }
        group(radiant ? L("RADIANT BODY") : L("LEVEL BODY")) {
            row(L("Opacity"), note: radiant ? L("How bright and dense the body glows.") : L("How much the body covers what lies behind it.")) {
                slider($nebulaOpacity, NebulaSettings.ranges.opacity) { String(format: "%.2f", $0) }
            }
            if radiant {
                line
                row(L("Glow range"), note: L("How far below the loudest band frequencies still add to the body, in dB: the loudest burn white, quieter ones fade out over this range. How loud the loudest band is sets how dense the whole body is. Hover over the body to read a band's level.")) {
                    slider($nebulaRange, NebulaSettings.ranges.range) { "\(Int($0.rounded())) dB" }
                }
                line
                row(L("Particles"), note: L("How many particles a band keeps per analysis frame (30 a second) on average: the analysis gathers a band's frequencies that sit at one place into one particle, keeps every place that carries a good share of the band's energy, and gathers the weakest rest; bands with more detail (the treble's) get what simpler ones leave. Fewer particles never dim the picture or move a band's centre: its light and its centre of gravity stay the same.")) {
                    slider($nebulaParticles, NebulaSettings.ranges.particles) { "\(Int($0.rounded()))" }
                }
                line
                row(L("Particle size"), note: L("How large each new particle's light is in the body: larger merges neighbouring places into one mass, smaller keeps them apart.")) {
                    slider($nebulaParticleSize, NebulaSettings.ranges.particleSize) { String(format: "%.1f×", $0) }
                }
                line
                row(L("Blur"), note: L("How much light swells as it ages, so older light turns to haze while new light stays compact. 0 keeps it as compact as when it was heard.")) {
                    slider($nebulaBlur, NebulaSettings.ranges.blur) { String(format: "%.1f×", $0) }
                }
                if !nebulaRawPoints {
                    line
                    row(L("Points"), note: L("How bright the point lights over the body are: each is one place where a band's frequencies are heard, crisp when new and smearing as it ages, so where every band sits can be read exactly. The body dims a little under them, so they carry the brightest light. 0 shows the body alone.")) {
                        slider($nebulaPoints, NebulaSettings.ranges.points) { String(format: "%.1f×", $0) }
                    }
                }
            } else {
                line
                row(L("Smoothing"), note: L("How much every lobe is widened beyond the width it is predicted to be heard at, so the body reads as one mass (degrees at half maximum). At 30°, two uncorrelated speakers 60° apart still show as two lobes, while one coherent image between them shows as one.")) {
                    slider($nebulaSmoothing, NebulaSettings.ranges.smoothing) { "\(Int($0.rounded()))°" }
                }
                line
                // Radiant places every particle where its frequency's amplitudes put it: nothing is spread.
                row(L("Spatial spread"), note: L("How much of each image's predicted width is drawn: 1 as wide as it is heard, from its energy vector after Frank 2013 (an in-phase phantom between speakers 60° apart about 36°, one speaker 10.7°), 0 every image as compact as one speaker, 2 twice as wide. Energy that cancels between speakers spreads wider still.")) {
                    slider($nebulaSpread, NebulaSettings.ranges.spread) { String(format: "%.2f", $0) }
                }
            }
            line
            row(L("Grain"), note: L("A fine, still grain in the glow, like the window's film grain. It moves only with the body.")) {
                toggle(L("Grain"), $nebulaGrain)
            }
        }
        group(L("CAMERA")) {
            row(L("View"), note: L("Dome orbits: drag across to turn it, up or down to raise or lower the camera. Front looks ahead from behind the listener, Top from above, Side from the right, Iso from an isometric corner; dragging in Front, Top or Iso carries on from there. Scroll or pinch to zoom; double-click to return to the default view.")) {
                GlassSegments(label: L("View"), options: DomeView.allCases.map { ($0, $0.short, $0.title) },
                              selection: camera.settings.view, select: { camera.select($0) })
            }
            line
            row(L("Zoom"), note: L("How close the camera is to the listener. Also with the scroll wheel or a pinch over the dome.")) {
                slider(Binding(get: { camera.settings.zoom }, set: { camera.setZoom($0) }), DomeGeometry.zoomRange) {
                    String(format: "%.1f×", $0)
                }
            }
            line
            row(L("Reset view"), note: L("Back to the default view, as a double-click on the dome does.")) {
                Button { camera.reset() } label: { Label(L("Reset view"), systemImage: "scope").labelStyle(.iconOnly) }
                    .glassButton()
                    .help(L("Reset view"))
            }
        }
        group(L("SHOW")) {
            row(L("Speakers"), note: L("The speakers' positions and names.")) {
                toggle(L("Speakers"), $nebulaSpeakers)
            }
            line
            row(L("Listener"), note: L("A head at the listening position, its nose to the front and its ears to the sides, so the dome's front, sides and back read at a glance. Its size is schematic.")) {
                toggle(L("Listener"), $nebulaListener)
            }
            line
            row("LFE", note: L("The LFE channel's level as the arc around the listener, on the body's scale: it has no direction, so it never shapes the body. Low frequencies in the full-range channels stay where those channels are.")) {
                toggle(L("Show LFE"), $nebulaLFE)
            }
            line
            row(L("Grid"), note: radiant ? L("The hemisphere's grid.") : L("The hemisphere's grid and the level rings on the floor, every 20 dB, labelled in dBFS.")) {
                toggle(L("Grid"), $nebulaGrid)
            }
            line
            row(L("Axes"), note: L("x to the right, y to the front, z up, from the listener.")) {
                toggle(L("Axes"), $nebulaAxes)
            }
            line
            row(L("Energy centroid"), note: L("A power-weighted balance point, not a sound source or a measure of diffuseness.")) {
                toggle(L("Energy centroid"), $domeCentroid)
            }
        }
        DisclosureGroup(isExpanded: $nebulaAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                group(L("ANALYSIS")) {
                    row(L("Coherence sensitivity"), note: radiant ? L("How readily speakers that share coherent energy count as one image. In Radiant body it decides what reads as a phantom image or out of phase (the ochre tint and the pointer's reading), not where the body sits: its frequencies' amplitudes decide that. Coherence is measured from the speakers' smoothed cross-spectra and corrected for chance. The analysis uses it (in the plugin, too).") : L("How readily speakers that share coherent energy form one image between them. Coherence is measured from the speakers' smoothed cross-spectra and corrected for chance; higher sensitivity lets weaker coherence form images, lower keeps only strongly shared signals together. The analysis uses it (in the plugin, too).")) {
                        slider($nebulaCoherence, NebulaSettings.ranges.coherence) { String(format: "%.0f%%", $0 * 100) }
                    }
                    if radiant {
                        line
                        row(L("Raw observations"), note: L("Draws the analysis' observations as points instead of the body, for checking where sound is placed: the newest frame only, every point the same small size, without smear, glow or depth shading.")) {
                            toggle(L("Raw observations"), $nebulaRawPoints)
                        }
                        line
                        row(L("Spatial window"), note: L("How long a stretch of sound places the particles. Standard measures every band over the full analysis window: the steadiest placement. Fast measures the bands from 1 kHz up over a quarter of it and those from 4 kHz up over an eighth (about 43 and 21 ms at 48 kHz), so their particles follow moves and onsets sooner, with coarser frequency detail. The analysis uses it (in the plugin, too).")) {
                            segments(L("Spatial window"), SpatialWindowChoice.allCases, $nebulaWindow) { $0.title }
                        }
                    }
                }
                group(L("DRAWN LEVELS AND FREQUENCIES")) {
                    row(L("Level floor"), note: radiant ? L("The quietest band drawn: a band below it adds nothing to the body, whatever the glow range.") : L("The level at the listener, where the body's radius starts: quieter energy reaches no radius. The speakers' shell is 0 dBFS.")) {
                        slider($nebulaFloor, NebulaSettings.ranges.floor) { "\(Int($0.rounded())) dBFS" }
                    }
                    line
                    row(L("Lowest frequency"), note: L("Frequencies below are not drawn.")) {
                        logSlider($nebulaLowest, 20...10_000) { Self.hertz($0) }
                    }
                    line
                    row(L("Highest frequency"), note: L("Frequencies above are not drawn.")) {
                        logSlider($nebulaHighest, 100...20_000) { Self.hertz($0) }
                    }
                }
                group(L("MOTION")) {
                    if !radiant {
                        row(L("Attack"), note: L("How quickly the body grows toward a new level.")) {
                            logSlider($nebulaAttack, NebulaSettings.ranges.attack) { "\(Int($0.rounded())) ms" }
                        }
                        line
                        row(L("Release"), note: L("How quickly the body shrinks when the level drops.")) {
                            logSlider($nebulaRelease, NebulaSettings.ranges.release) { "\(Int($0.rounded())) ms" }
                        }
                        line
                    }
                    row(L("Persistence"), note: radiant ? L("How long light stays in the body, fading and swelling as it goes; the longer, the more it builds up into a trail of where sound has been.") : L("How long a faint afterglow of recent energy lingers after the release; 0 turns it off.")) {
                        slider($nebulaPersistence, NebulaSettings.ranges.persistence) { "\(Int($0.rounded())) ms" }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("Analysis and motion")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .id(PanelSettingsButton.advancedID)
        Button { NebulaSettings.restoreDefaults() } label: { Label(L("Restore defaults"), systemImage: "arrow.counterclockwise") }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .padding(.leading, PanelSettingsButton.inset)
        if radiant {
            caption(L("Each particle is a place where a band's frequencies sit in the newest analysis: at the centre of gravity of the speakers, weighted by each frequency's amplitude in each (for one sound panned with gains, the direction of its velocity vector). A sound only one speaker carries sits at that speaker; one panned between speakers sits on the line between them where its gains put it, at every frequency; two sounds sharing a band each keep their own place; sound the speakers carry independently scatters along the lines between them. Neighbouring frequencies at one place share a particle. Energy that cancels between speakers is tinted ochre where it sits. A description of how the feeds share the signal, not a measured sound field or source distance; speakers stand where the speaker layout puts them (the standard one puts every height at 45 degrees). Hover over a particle to read its frequency, level and what places it there."))
        } else {
            caption(L("Colored by frequency, a point of the body wears the hues of the bands that are at least that loud in its direction: the edge shows what dominates each direction, the core what all of them share."))
            caption(L("The body shows how loud the speaker feeds are heard from each direction: its radius is the level in dBFS (the rings on the floor), not a distance. Energy only one speaker carries points at that speaker. Energy several speakers carry coherently points between them, where its phantom image is heard: along their velocity vector below about 700 Hz and their energy vector above (Gerzon), as wide as the energy vector predicts it is heard (Frank). Energy that cancels between speakers has no stable direction: it spreads wide and is tinted ochre. An estimate from the feeds, not a measured sound field; speakers stand where the speaker layout puts them (the standard one puts every height at 45 degrees). Hover over the body to read a direction's level and what forms it."))
        }
        if radiant, let model, model.sourceIsBridge, model.lastSpatialFieldStatus == 1, model.lastObservations.status != 1 {
            caption(L("This plugin sends no frequencies of its own (before build 87), so Radiant body draws from the spatial field's statistics. Install the plugins of this build to see each frequency where it is heard."))
        }
        switch model?.geometryNotice {
        case .pluginTooOld?:
            caption(L("This plugin places sound with the standard speaker layout (it is older than build 98), so the dome shows the standard layout. Install the plugins of this build to use your speaker layout."))
        case .pluginRefused?:
            caption(L("This plugin could not use your speaker layout, so the dome shows the standard layout."))
        case .applying?:
            caption(L("Applying the speaker layout: what was analysed with the previous one is not drawn."))
        case nil:
            EmptyView()
        }
        if let model, model.sourceIsBridge, model.lastSpatialFieldStatus == SpatialFieldWire.unsupported {
            caption(L("This plugin sends no spatial field, so the nebula shows each channel's band energy at its speaker only. Install the plugins of this build for coherent images."))
        }
    }

    /// A display slope in half-dB steps, its value beside it ("Flat", "3 dB/oct").
    private func tiltSlider(_ value: Binding<Double>) -> some View {
        slider(Binding(get: { value.wrappedValue }, set: { value.wrappedValue = Double(SpectrumTilt(stored: $0).decibelsPerOctave) }),
               SpectrumTilt.range) { SpectrumTilt(stored: $0).title }
    }

    // MARK: Multi-FFT

    private var multiFFTRate: Double { max(8_000, model?.sampleRate ?? 48_000) }
    private var multiFFTConfiguration: MultiFFTConfiguration {
        MultiFFTPreferences.decode(multiFFTData).validated(sampleRate: multiFFTRate)
    }
    private func saveMultiFFT(_ configuration: MultiFFTConfiguration) {
        let valid = configuration.validated(sampleRate: multiFFTRate)
        if valid != multiFFTConfiguration { MultiFFTPreferences.save(valid) }
    }
    /// An advanced value: changing it makes the configuration Custom.
    private func multiFFT<T: Equatable>(_ key: WritableKeyPath<MultiFFTConfiguration, T>, custom: Bool = true) -> Binding<T> {
        Binding(get: { multiFFTConfiguration[keyPath: key] }, set: {
            var c = multiFFTConfiguration
            guard $0 != c[keyPath: key] else { return }
            c[keyPath: key] = $0
            if custom { c.preset = .custom }
            saveMultiFFT(c)
        })
    }
    private func multiFFTBand<T: Equatable>(_ index: Int, _ key: WritableKeyPath<MultiFFTConfiguration.Band, T>) -> Binding<T> {
        Binding(get: { multiFFTConfiguration.bands[index][keyPath: key] }, set: {
            var c = multiFFTConfiguration
            guard $0 != c.bands[index][keyPath: key] else { return }
            c.bands[index][keyPath: key] = $0
            c.preset = .custom
            saveMultiFFT(c)
        })
    }

    /// The Multi-FFT Spectrum's settings, grouped as the other panels' are: what the plot shows, how much analysis it
    /// costs, the analysis itself, then the three bands folded away.
    @ViewBuilder private var multiFFT: some View {
        let c = multiFFTConfiguration
        group(L("DISPLAY")) {
            row(L("Frequency scale"), note: L("Log gives every octave the same room from 20 Hz, as pitch is heard. Linear starts at 0 Hz and gives every hertz the same room, as an FFT spaces its bins: harmonics fall evenly apart and the treble opens out, while the bass narrows. The analysis is the same.")) {
                segments(L("Frequency scale"), FrequencyScale.allCases, $multiFFTScale) { $0.title }
            }
            line
            row(L("Tilt"), note: L("A display slope around 1 kHz for every curve, from 0 to 6 dB per octave. Music falls by about 3 to 4.5 dB per octave, so a tilt shows a balanced mix as level and the treble as clearly as the bass. The hover reading stays true.")) {
                tiltSlider($multiFFTTilt)
            }
            line
            row(L("Mid and Side"), note: L("Adds the Mid and Side curves to Left and Right: M = (L+R)/2, S = (L−R)/2.")) {
                toggle(L("Mid and Side"), multiFFT(\.midSide, custom: false))
            }
        }
        group(L("PERFORMANCE")) {
            row(L("Preset"), note: L("How much analysis the panel does: Economy is the lightest, Ultra resolves the most. Any change to the bands or the fusion below makes it Custom.")) {
                choiceMenu(MultiFFTConfiguration.Preset.allCases.filter { $0 != .custom || c.preset == .custom }, selection: c.preset, title: \.title) {
                    guard $0 != .custom else { return }
                    saveMultiFFT(.make($0, priority: c.priority))
                }
            }
            line
            row(L("Priority"), note: L("Tunes the preset's window sizes and update rates: Precision favours frequency detail, Responsive favours time. All three bands use the slowest requested cadence to keep their analysis centres aligned.")) {
                GlassSegments(label: L("Priority"), options: MultiFFTConfiguration.Priority.allCases.map { ($0, $0.title, $0.title) },
                              selection: c.priority, select: { priority in
                                  if c.preset == .custom { var next = c; next.priority = priority; saveMultiFFT(next) }
                                  else { saveMultiFFT(.make(c.preset, priority: priority)) }
                              })
            }
            line
            row(L("Analysis rate"), note: L("How often a new frame is analysed, and the common delay of the three bands' centres behind the newest audio.")) {
                Text(verbatim: String(format: "%.1f Hz · %.0f ms", multiFFTRate / Double(c.hop(sampleRate: multiFFTRate)),
                                      Double(c.bands.map(\.size).max() ?? 0) / 2 / multiFFTRate * 1000))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
        group(L("ANALYSIS")) {
            row(L("Window"), note: L("Hann resolves close tones best; Blackman–Harris keeps a loud tone's skirts out of quiet neighbours.")) {
                GlassSegments(label: L("Window"), options: [(MultiFFTConfiguration.Window.hann, "Hann", "Hann"),
                                                            (.blackmanHarris, "Blackman–Harris", "Blackman–Harris")],
                              selection: c.window, select: { multiFFT(\.window).wrappedValue = $0 })
            }
            line
            row(L("Calibration"), note: L("Tone keeps a sine's peak at its level in dBFS in every band. PSD reads noise as density (dBFS/Hz), comparable across window sizes.")) {
                GlassSegments(label: L("Calibration"), options: [(MultiFFTConfiguration.Scale.amplitude, L("Tone"), L("Tone amplitude · dBFS")),
                                                                 (.psd, "PSD", "PSD · dBFS/Hz")],
                              selection: c.scale, select: { multiFFT(\.scale).wrappedValue = $0 })
            }
            line
            row(L("Time smoothing"), note: L("How long each curve averages in time; 0 shows every frame.")) {
                slider(multiFFT(\.smoothingSeconds), 0...2) { String(format: "%.2f s", $0) }
            }
            line
            row(L("Frequency smoothing"), note: L("Averages each curve across frequency, in octaves; narrow peaks read lower as it widens.")) {
                slider(multiFFT(\.smoothingOctaves), 0...1) { $0 == 0 ? L("Off") : String(format: "%.2f oct", $0) }
            }
        }
        DisclosureGroup(isExpanded: $multiFFTBands) {
            VStack(alignment: .leading, spacing: 14) {
                group(L("FUSION")) {
                    row(L("Low/Mid crossover"), note: L("Where the low band hands over to the mid band.")) {
                        logSlider(multiFFT(\.lowCrossover), 40...max(41, MeterScale.upperFrequency(sampleRate: multiFFTRate) / 4)) { Self.hertz($0) }
                    }
                    line
                    row(L("Mid/High crossover"), note: L("Where the mid band hands over to the high band.")) {
                        logSlider(multiFFT(\.highCrossover), max(80, c.lowCrossover * 2)...max(c.lowCrossover * 2 + 1, MeterScale.upperFrequency(sampleRate: multiFFTRate) * 0.9)) { Self.hertz($0) }
                    }
                    line
                    row(L("Fusion width"), note: L("How many octaves two neighbouring bands are blended across at each crossover.")) {
                        slider(multiFFT(\.blendOctaves), 0.125...2) { String(format: "%.2f oct", $0) }
                    }
                }
                ForEach(0..<3, id: \.self) { i in
                    group([L("LOW BAND"), L("MID BAND"), L("HIGH BAND")][i]) {
                        row(L("FFT size"), note: L("The band's window length in samples: longer resolves finer frequency detail, shorter follows time more closely.")) {
                            choiceMenu(MultiFFTConfiguration.sizes, selection: c.bands[i].size, title: { "\($0)" }) { multiFFTBand(i, \.size).wrappedValue = $0 }
                        }
                        line
                        row(L("Update ceiling"), note: L("The most frames a second this band asks for.")) {
                            slider(multiFFTBand(i, \.rate), 1...60) { "\(Int($0.rounded())) Hz" }
                        }
                        line
                        row(L("Overlap ceiling"), note: L("The most consecutive windows may overlap; more overlap allows a faster update.")) {
                            choiceMenu([0.0, 0.5, 0.75, 0.875, 0.9375, 0.96875], selection: c.bands[i].overlap,
                                       title: { String(format: "%.3g%%", $0 * 100) }) { multiFFTBand(i, \.overlap).wrappedValue = $0 }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("Bands and fusion")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .id(PanelSettingsButton.advancedID)
        Button { saveMultiFFT(MultiFFTConfiguration()); multiFFTTilt = 0; multiFFTScale = FrequencyScale.log.rawValue } label: {
            Label(L("Restore defaults"), systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .padding(.leading, PanelSettingsButton.inset)
        if let model, model.sourceIsBridge {
            caption(L("Bridge keeps its original analysis. Multi-FFT requires local PCM in this Beta."))
        }
        caption(L("Three FFTs of different lengths analyse the low, mid and high frequencies, centred on the same instant, and are fused into one curve per channel. Hover over the plot to read a frequency's pitch and each curve's level."))
    }

    /// A pop-up of `options`, its title the current choice, on the quiet capsule the summary's menus use
    /// (`SummaryMenu`), so it sits with the panel's segments and switches.
    private func choiceMenu<T: Hashable>(_ options: [T], selection: T, title: @escaping (T) -> String,
                                         select: @escaping (T) -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        return Menu {
            ForEach(options, id: \.self) { option in
                Button { select(option) } label: {
                    if option == selection { Label(title(option), systemImage: "checkmark") } else { Text(title(option)) }
                }
            }
        } label: {
            (Text(verbatim: title(selection)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundColor(Theme.ink)
                + Text(verbatim: "  ")
                + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 7, weight: .bold)).foregroundColor(Theme.tertiary))
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background {
                    shape.fill(Theme.controlFill).overlay { shape.gradientBorder(Theme.controlRim, lineWidth: 0.5) }
                }
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A titled group: its name in the heading voice, then its rows on one quiet card, set off from each other by
    /// hairlines (`line`), like a Settings section.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        PanelSettingsGroup(title: title, content: content)
    }

    /// The hairline between two rows of a group.
    private var line: some View { SettingsDivider() }

    /// A name (its explanation on hover) and its control on one line; where the two do not fit side by side (a long
    /// translation), the control moves under the name.
    private func row<Control: View>(_ title: String, note: String, @ViewBuilder control: () -> Control) -> some View {
        let control = control()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                rowTitle(title).fixedSize()
                Spacer(minLength: 8)
                control
            }
            VStack(alignment: .leading, spacing: 6) {
                rowTitle(title)
                control.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 6)
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .help(note)
    }

    private func rowTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
    }

    /// A compact slider with its value beside it.
    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>, text: @escaping (Double) -> String) -> some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range).controlSize(.mini).frame(width: 120)
            Text(verbatim: text(value.wrappedValue)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    /// The same along a log scale (frequencies, times).
    private func logSlider(_ value: Binding<Double>, _ range: ClosedRange<Double>, text: @escaping (Double) -> String) -> some View {
        let low = log(range.lowerBound), high = log(range.upperBound)
        let position = Binding<Double>(get: { (log(min(range.upperBound, max(range.lowerBound, value.wrappedValue))) - low) / (high - low) },
                                       set: { value.wrappedValue = exp(low + $0 * (high - low)) })
        return HStack(spacing: 6) {
            Slider(value: position, in: 0...1).controlSize(.mini).frame(width: 120)
            Text(verbatim: text(value.wrappedValue)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private static func hertz(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1f kHz", value / 1_000) : "\(Int(value.rounded())) Hz"
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            .lineSpacing(l10n.paragraphSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PanelSettingsButton.inset)
    }

    /// A stored choice of `T`, shown by `title`.
    private func segments<T: RawRepresentable & Hashable>(_ label: String, _ cases: [T], _ stored: Binding<String>,
                                                       title: @escaping (T) -> String) -> some View where T.RawValue == String {
        let selection = T(rawValue: stored.wrappedValue) ?? cases[0]
        return GlassSegments(label: label, options: cases.map { ($0, title($0), title($0)) }, selection: selection,
                             select: { stored.wrappedValue = $0.rawValue })
    }
}

/// A titled group of a panel's settings: its name in the heading voice on the rows' text edge, then the rows on one
/// quiet card, a shade off the popover, so each group reads as one block.
struct PanelSettingsGroup<Content: View>: View {
    /// Rows, notes and titles share this inset from the card's edge.
    static var inset: CGFloat { PanelSettingsButton.inset }
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold).width(.expanded))
                .tracking(Localizer.shared.tracking(0.9))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .padding(.leading, Self.inset)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape.fill(Theme.ink.opacity(Theme.dark ? 0.05 : 0.035))
                        .overlay { shape.strokeBorder(Theme.hairline.opacity(Theme.dark ? 0.08 : 0.10), lineWidth: 0.5) }
                }
        }
    }
}

/// Any loudness target and true-peak ceiling for the mode in use, beyond the summary menu's published standards (a
/// broadcaster's own −20 LUFS, a client's −12…): typed, or stepped with the arrows.
private struct StandardSteppers: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let spatial = model.format == .spatial
        let mode = spatial ? L("Immersive") : L("Stereo & Mono")
        HStack(spacing: 10) {
            Text(L("Target")).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 6)
            NumberEntry(label: L("Target"), value: model.loudnessTarget, range: -40 ... -5, step: 0.5, unit: "LUFS") {
                model.setTarget($0, spatial: spatial)
            }
        }
        .frame(minHeight: 32)
        .help(L("The loudness target of %@: type a value (to a tenth, the minus sign may be left out) or step it by 0.5 LU. The summary's TARGET menu offers the published standards.", mode))
        SettingsDivider()
        HStack(spacing: 10) {
            Text(L("True Peak ceiling")).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 6)
            NumberEntry(label: L("True Peak ceiling"), value: model.truePeakCeiling, range: -6 ... 0, step: 0.1, unit: "dBTP") {
                model.setCeiling($0, spatial: spatial)
            }
        }
        .frame(minHeight: 32)
        .help(L("The True Peak limit of %@: type a value or step it by 0.1 dB. TRUE PEAK turns amber above it.", mode))
    }
}

/// A level typed or stepped: a small field that takes what is typed on Return or when it loses focus, read to a tenth
/// and kept inside `range`, with the stepper's arrows beside it. Every value it takes is negative or zero, so a minus
/// sign left out ("14") still means −14, and "−", "-" and a decimal comma all read; anything else puts the value back.
struct NumberEntry: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 4) {
            TextField(label, text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .frame(width: 48)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background {
                    shape.fill(Theme.controlFill)
                        .overlay { shape.strokeBorder(focused ? Theme.action.opacity(0.8) : Theme.hairline.opacity(0.6), lineWidth: focused ? 1 : 0.5) }
                }
                .onSubmit(commit)
                .onAppear { text = Self.format(value) }
                .onChange(of: focused) { now in if !now { commit() } }
                .onChange(of: value) { now in if !focused { text = Self.format(now) } }
            Text(verbatim: unit).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .frame(width: 30, alignment: .leading)
            Stepper(label, value: Binding(get: { value }, set: { take(($0 / step).rounded() * step) }), in: range, step: step)
                .labelsHidden().controlSize(.small)
        }
    }

    private func commit() {
        guard let typed = Self.parse(text) else { return text = Self.format(value) }
        take(typed)
    }

    private func take(_ number: Double) {
        let clamped = min(range.upperBound, max(range.lowerBound, (number * 10).rounded() / 10))
        if clamped != value { set(clamped) }
        text = Self.format(clamped)
    }

    /// "−14", "-14.5", "14,5", "−14 LUFS" read as −14 / −14.5; nil for anything else.
    static func parse(_ text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: ",", with: ".")
        while let last = cleaned.last, last.isLetter || last == " " { cleaned.removeLast() }
        guard let number = Double(cleaned), number.isFinite else { return nil }
        return -abs(number)
    }

    static func format(_ value: Double) -> String { MeterScale.signedTenths(Float(value)) }
}
