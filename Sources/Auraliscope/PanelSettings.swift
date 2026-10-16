import AnalysisCore
import SwiftUI

/// The panels whose display choices live on the panel itself, behind a small button in its header.
enum PanelKind {
    case loudness, history, vu, spectrum, waveform, soundstage, levels
}

/// A panel's own settings: a small button in its header opening a popover of that panel's display choices. Every
/// choice takes effect at once and is kept (the model follows the stored values, as for every display option), so
/// what a control does shows right beside it, on the panel it changes.
struct PanelSettingsButton: View {
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
            // `--snapshot-panel-settings <panel>` (loudness, history, vu, spectrum, waveform, soundstage, levels).
            let wanted = Diagnostics.snapshotPanelSettingsPanel.isEmpty ? "spectrum" : Diagnostics.snapshotPanelSettingsPanel
            guard Diagnostics.snapshotPanelSettings, "\(panel)" == wanted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { open = true }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if panel == .soundstage {
                // The nebula's settings are many: they scroll, so the popover fits a 720p screen.
                ScrollView {
                    PanelSettingsForm(panel: panel, model: model).padding(14)
                }
                .frame(width: 360, height: 480)
            } else {
                PanelSettingsForm(panel: panel, model: model)
                    .padding(14)
                    .frame(width: 340)
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
    @AppStorage(NebulaSettings.Key.grid) private var nebulaGrid = true
    @AppStorage(NebulaSettings.Key.axes) private var nebulaAxes = false
    @AppStorage(NebulaSettings.Key.style) private var nebulaStyle = NebulaSettings().style.rawValue
    @AppStorage(NebulaSettings.Key.range) private var nebulaRange = NebulaSettings().range
    @AppStorage(NebulaSettings.Key.particles) private var nebulaParticles = NebulaSettings().particles
    @AppStorage(NebulaSettings.Key.particleSize) private var nebulaParticleSize = NebulaSettings().particleSize
    @AppStorage(NebulaSettings.Key.blur) private var nebulaBlur = NebulaSettings().blur
    @AppStorage(NebulaSettings.Key.sparkle) private var nebulaSparkle = NebulaSettings().sparkle
    @State private var nebulaAdvanced = false
    private var radiant: Bool { nebulaStyle != NebulaStyle.level.rawValue }
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
    @AppStorage(SpectrumTilt.key) private var tilt = SpectrumTilt.flat.rawValue
    @AppStorage(SpectrumSide.key) private var side = SpectrumSide.right.rawValue
    @AppStorage(DisplayOptions.waveSecondsKey) private var waveSeconds = 4
    @AppStorage(WaveScale.key) private var waveScale = WaveScale.linear.rawValue
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
                    row(L("Units"), note: L("LUFS writes loudness as it is; LU writes it relative to the target, 0 at the target, as an EBU-mode meter's relative scale does. Range and true peak keep their units.")) {
                        segments(L("Units"), LoudnessUnit.allCases, $loudnessUnit) { $0.title }
                    }
                    row(L("Gauge scale"), note: L("The gauge's range. Full spans −36 to 0 LUFS. EBU +9 spans −18 to +9 LU around the target and EBU +18 spans −36 to +18 LU, the two scales of EBU Tech 3341.")) {
                        segments(L("Gauge scale"), LoudnessScale.allCases, $loudnessScale) { $0.title }
                    }
                    if let model { StandardSteppers(model: model) }
                }
            case .history:
                group(L("LOUDNESS HISTORY")) {
                    row(L("Span"), note: L("How much time the plot spans. Session shows the whole measurement since the last reset, the same readings a loudness report exports.")) {
                        segments(L("Span"), HistorySpan.allCases, $historySpan) { $0.title }
                    }
                    row(L("Momentary"), note: L("The faint line: momentary loudness (400 ms) under the short-term line, to see the peaks a 3 s reading smooths away.")) {
                        Toggle(L("Momentary"), isOn: $historyMomentary).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row(L("Target band"), note: L("The band of ±1 LU around the loudness target, with its value at the left.")) {
                        Toggle(L("Target band"), isOn: $historyBand).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row(L("Scale"), note: L("The loudness the plot spans. Full reads −36 to 0 LUFS; Close zooms to 18 LU around the target, so small changes of level show.")) {
                        segments(L("Scale"), HistoryScale.allCases, $historyScale) { $0.title }
                    }
                }
            case .vu:
                group("VU") {
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
                    row(L("Smoothing"), note: L("Averages the curve, the peak holds and the average across frequency, in power. 1/6 octave reads like a mixing engineer's analyser; 1/3 octave shows the broad tonal balance; Off draws every band. Var keeps 1/48 octave detail up to 100 Hz and widens to 1/3 octave from 10 kHz, as room-measurement software does.")) {
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
                    row(L("Level scale"), note: L("Linear draws the amplitude as a DAW does. dB spreads the lanes by level, full scale at the edges and −48 dBFS at the centre line, so quiet passages and fades stay readable. Both draw the exact sample peaks.")) {
                        segments(L("Level scale"), WaveScale.allCases, $waveScale) { $0.title }
                    }
                }
                caption(L("Hover over the lanes to read the time and the sample peak there; pause to read a moment at leisure."))
                if let model { WaveformKey(format: model.format, layout: model.shownLayout) }
            case .soundstage:
                group(L("SOUNDSTAGE")) {
                    row(L("Stereometer style"), note: L("How the Stereo stereometer draws each band. Dots shows every sample; Outlines traces where each band's samples reach; Filled tints each outline, laying the smaller shapes over the larger so every edge stays visible.")) {
                        segments(L("Stereometer style"), StageStyle.allCases, $stageStyle) { $0.title }
                    }
                }
                group(L("IMMERSIVE NEBULA")) {
                    row(L("Style"), note: L("Radiant draws each band as particles where its frequencies are heard: at the centre of gravity of the speakers that carry them, weighted by their level in each, so a centred phantom is a bright point between L and R and a wide stereo programme a streak along the line between them. The particles glow in their frequency's hue, as bright as they are loud, then fade and smear as they age. Level body draws the level heard from each direction as the radius of one body, read on the floor's dBFS rings.")) {
                        segments(L("Style"), NebulaStyle.allCases, $nebulaStyle) { $0.title }
                    }
                    row(L("View"), note: L("Dome orbits: drag across to turn it, up or down to raise or lower the camera. Front looks ahead from behind the listener, Top from above, Side from the right, Iso from an isometric corner; dragging in Front, Top or Iso carries on from there. Scroll or pinch to zoom; double-click to return to the default view.")) {
                        GlassSegments(label: L("View"), options: DomeView.allCases.map { ($0, $0.short, $0.title) },
                                      selection: camera.settings.view, select: { camera.select($0) })
                    }
                    row(L("Zoom"), note: L("How close the camera is to the listener. Also with the scroll wheel or a pinch over the dome.")) {
                        slider(Binding(get: { camera.settings.zoom }, set: { camera.setZoom($0) }), DomeGeometry.zoomRange) {
                            String(format: "%.1f×", $0)
                        }
                    }
                    row(L("Opacity"), note: radiant ? L("How bright the particles' light is.") : L("How much the body covers what lies behind it.")) {
                        slider($nebulaOpacity, NebulaSettings.ranges.opacity) { String(format: "%.2f", $0) }
                    }
                    if radiant {
                        row(L("Glow range"), note: L("How far below the loudest band particles still glow, in dB: the loudest burn white, quieter ones fade out over this range. How loud the loudest band is sets how bright the whole glow is. Hover over a particle to read its band's level.")) {
                            slider($nebulaRange, NebulaSettings.ranges.range) { "\(Int($0.rounded())) dB" }
                        }
                        row(L("Particles"), note: L("How many particles each band sends per analysis frame (30 a second), drawn from its frequencies in proportion to their energy, so a strong one gathers several into one bright bead. More fill the streaks and clouds; fewer leave single beads.")) {
                            slider($nebulaParticles, NebulaSettings.ranges.particles) { "\(Int($0.rounded()))" }
                        }
                        row(L("Particle size"), note: L("How large a new particle is.")) {
                            slider($nebulaParticleSize, NebulaSettings.ranges.particleSize) { String(format: "%.1f×", $0) }
                        }
                        row(L("Blur"), note: L("How much particles smear as they age, so older light turns to haze while new particles stay crisp. 0 keeps them sharp.")) {
                            slider($nebulaBlur, NebulaSettings.ranges.blur) { String(format: "%.1f×", $0) }
                        }
                        row(L("Sparkle"), note: L("How brightly new particles glint before they smoke into glow. 0 leaves only the glow.")) {
                            slider($nebulaSparkle, NebulaSettings.ranges.sparkle) { String(format: "%.1f×", $0) }
                        }
                    }
                    row(L("Colors"), note: radiant ? L("Frequency colors each band's particles by its frequency, warm bass through cool treble; where many bands meet, their light adds up toward white. Theme draws them in the palette's color. A split into 3 or 5 bands always shows each band in its own color.") : L("Frequency colors the full band by the bands heard from each direction, warm bass through cool treble: near the listener every audible band mixes, toward white for broadband sound, and toward the edge only the loudest bands remain. Theme draws it in the palette's color. A split into 3 or 5 bands always shows each band in its own color.")) {
                        segments(L("Colors"), NebulaColors.allCases, $nebulaColors) { $0.title }
                    }
                    if !radiant {
                        row(L("Grain"), note: L("A fine, still grain in the glow, like the window's film grain. It moves only with the body.")) {
                            Toggle(L("Grain"), isOn: $nebulaGrain).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        row(L("Smoothing"), note: L("How much every lobe is widened beyond the width it is predicted to be heard at, so the body reads as one mass (degrees at half maximum). At 30°, two uncorrelated speakers 60° apart still show as two lobes, while one coherent image between them shows as one.")) {
                            slider($nebulaSmoothing, NebulaSettings.ranges.smoothing) { "\(Int($0.rounded()))°" }
                        }
                        // Radiant places every particle where its frequency's amplitudes put it: nothing is spread.
                        row(L("Spatial spread"), note: L("How much of each image's predicted width is drawn: 1 as wide as it is heard, from its energy vector after Frank 2013 (an in-phase phantom between speakers 60° apart about 36°, one speaker 10.7°), 0 every image as compact as one speaker, 2 twice as wide. Energy that cancels between speakers spreads wider still.")) {
                            slider($nebulaSpread, NebulaSettings.ranges.spread) { String(format: "%.2f", $0) }
                        }
                    }
                    row(L("Speakers"), note: L("The speakers' positions and names.")) {
                        Toggle(L("Speakers"), isOn: $nebulaSpeakers).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row("LFE", note: L("The LFE channel's level as the arc around the listener, on the body's scale: it has no direction, so it never shapes the body. Low frequencies in the full-range channels stay where those channels are.")) {
                        Toggle(L("Show LFE"), isOn: $nebulaLFE).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row(L("Grid"), note: radiant ? L("The hemisphere's grid.") : L("The hemisphere's grid and the level rings on the floor, every 20 dB, labelled in dBFS.")) {
                        Toggle(L("Grid"), isOn: $nebulaGrid).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row(L("Axes"), note: L("x to the right, y to the front, z up, from the listener.")) {
                        Toggle(L("Axes"), isOn: $nebulaAxes).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    row(L("Energy centroid"), note: L("A power-weighted balance point, not a sound source or a measure of diffuseness.")) {
                        Toggle(L("Energy centroid"), isOn: $domeCentroid).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    HStack(spacing: 14) {
                        Button(L("Reset view")) { camera.reset() }
                        Button(L("Restore defaults")) { NebulaSettings.restoreDefaults() }
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                DisclosureGroup(isExpanded: $nebulaAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        group(L("ANALYSIS")) {
                            row(L("Coherence sensitivity"), note: radiant ? L("How readily speakers that share coherent energy count as one image. In Radiant it decides what reads as a phantom image or out of phase (the ochre tint and the pointer's reading), not where particles sit: their frequencies' amplitudes decide that. Coherence is measured from the speakers' smoothed cross-spectra and corrected for chance. The analysis uses it (in the plugin, too).") : L("How readily speakers that share coherent energy form one image between them. Coherence is measured from the speakers' smoothed cross-spectra and corrected for chance; higher sensitivity lets weaker coherence form images, lower keeps only strongly shared signals together. The analysis uses it (in the plugin, too).")) {
                                slider($nebulaCoherence, NebulaSettings.ranges.coherence) { String(format: "%.0f%%", $0 * 100) }
                            }
                            row(L("Level floor"), note: radiant ? L("The quietest band drawn: a band below it sends no particles, whatever the glow range.") : L("The level at the listener, where the body's radius starts: quieter energy reaches no radius. The speakers' shell is 0 dBFS.")) {
                                slider($nebulaFloor, NebulaSettings.ranges.floor) { "\(Int($0.rounded())) dBFS" }
                            }
                            row(L("Lowest frequency"), note: L("Frequencies below are not drawn.")) {
                                logSlider($nebulaLowest, 20...10_000) { Self.hertz($0) }
                            }
                            row(L("Highest frequency"), note: L("Frequencies above are not drawn.")) {
                                logSlider($nebulaHighest, 100...20_000) { Self.hertz($0) }
                            }
                        }
                        group(L("MOTION")) {
                            if !radiant {
                                row(L("Attack"), note: L("How quickly the body grows toward a new level.")) {
                                    logSlider($nebulaAttack, NebulaSettings.ranges.attack) { "\(Int($0.rounded())) ms" }
                                }
                                row(L("Release"), note: L("How quickly the body shrinks when the level drops.")) {
                                    logSlider($nebulaRelease, NebulaSettings.ranges.release) { "\(Int($0.rounded())) ms" }
                                }
                            }
                            row(L("Persistence"), note: radiant ? L("How long particles stay, fading as they go; the longer, the more they build up into streaks and clouds.") : L("How long a faint afterglow of recent energy lingers after the release; 0 turns it off.")) {
                                slider($nebulaPersistence, NebulaSettings.ranges.persistence) { "\(Int($0.rounded())) ms" }
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L("Analysis and motion")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                if radiant {
                    caption(L("Each particle is one of a band's frequencies in the newest analysis, where it is heard: at the centre of gravity of the speakers, weighted by its amplitude in each. A sound only one speaker carries sits at that speaker; one panned between speakers sits on the line between them where its gains put it, at every frequency; two sounds sharing a band each keep their own place; sound the speakers carry independently scatters along the lines between them, frequency by frequency. Energy that cancels between speakers is tinted ochre where it sits. An estimate from the feeds, not a measured sound field; height channels use a schematic 45 degree elevation. Hover over a particle to read its band, level and what places it there."))
                } else {
                    caption(L("Colored by frequency, a point of the body wears the hues of the bands that are at least that loud in its direction: the edge shows what dominates each direction, the core what all of them share."))
                    caption(L("The body shows how loud the speaker feeds are heard from each direction: its radius is the level in dBFS (the rings on the floor), not a distance. Energy only one speaker carries points at that speaker. Energy several speakers carry coherently points between them, where its phantom image is heard: along their velocity vector below about 700 Hz and their energy vector above (Gerzon), as wide as the energy vector predicts it is heard (Frank). Energy that cancels between speakers has no stable direction: it spreads wide and is tinted ochre. An estimate from the feeds, not a measured sound field; height channels use a schematic 45 degree elevation. Hover over the body to read a direction's level and what forms it."))
                }
                if radiant, let model, model.sourceIsBridge, model.lastSpatialFieldStatus == 1, model.lastSpatialPointsStatus != 1 {
                    caption(L("This plugin sends no frequencies of its own (before build 87), so Radiant draws its particles from the spatial field's statistics. Install the plugins of this build to see each frequency where it is heard."))
                }
                if let model, model.sourceIsBridge, model.lastSpatialFieldStatus == SpatialFieldWire.unsupported {
                    caption(L("This plugin sends no spatial field, so the nebula shows each channel's band energy at its speaker only. Install the plugins of this build for coherent images."))
                }
            case .levels:
                group(L("PEAK HOLD")) {
                    row(L("Hold"), note: L("How long each channel's peak mark stays at its highest reading before it falls. ∞ holds it until Reset.")) {
                        segments(L("Hold"), PeakHoldTime.allCases, $levelsHold) { $0.title }
                    }
                    row(L("Release"), note: L("How fast a mark falls once its hold has passed. Fast: 40 dB/s. Normal: 20 dB/s. PPM: 24 dB in 2.8 s, a peak programme meter's return (IEC 60268-10 Type II). The bars keep their own ballistics.")) {
                        segments(L("Release"), PeakRelease.allCases, $levelsRelease) { $0.title }
                    }
                }
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
                .padding(.top, 2)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline.opacity(ChartInk.minor)).frame(height: 0.5).offset(y: -2) }
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

/// Any loudness target and true-peak ceiling for the mode in use, beyond the summary menu's published standards (a
/// broadcaster's own −20 LUFS, a client's −12…).
private struct StandardSteppers: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let spatial = model.format == .spatial
        let mode = spatial ? L("Immersive") : L("Stereo & Mono")
        HStack(spacing: 10) {
            Text(L("Target")).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: "\(MeterScale.signedTenths(Float(model.loudnessTarget))) LUFS")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            Stepper(L("Target"), value: Binding(get: { model.loudnessTarget },
                                                set: { model.setTarget(($0 * 2).rounded() / 2, spatial: spatial) }),
                    in: -40 ... -5, step: 0.5)
                .labelsHidden().controlSize(.small)
        }
        .frame(minHeight: 24)
        .help(L("The loudness target of %@, in steps of 0.5 LU. The summary's TARGET menu offers the published standards.", mode))
        HStack(spacing: 10) {
            Text(L("True Peak ceiling")).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: "\(MeterScale.signedTenths(Float(model.truePeakCeiling))) dBTP")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            Stepper(L("True Peak ceiling"), value: Binding(get: { model.truePeakCeiling },
                                                           set: { model.setCeiling(($0 * 10).rounded() / 10, spatial: spatial) }),
                    in: -6 ... 0, step: 0.1)
                .labelsHidden().controlSize(.small)
        }
        .frame(minHeight: 24)
        .help(L("The True Peak limit of %@. TRUE PEAK turns amber above it.", mode))
    }
}
