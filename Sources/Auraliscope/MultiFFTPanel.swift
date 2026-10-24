import AnalysisCore
import Foundation
import QuartzCore
import SwiftUI

/// A short lock protects only an immutable snapshot handoff; FFT work never holds it.
final class MultiFFTMailbox {
    private let lock = NSLock()
    private var snapshot: MultiFFTSnapshot?
    private var received = 0.0
    func store(_ value: MultiFFTSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        if value?.serial != snapshot?.serial { received = CACurrentMediaTime() }
        snapshot = value
    }
    func read(allowStale: Bool = false) -> MultiFFTSnapshot? {
        lock.lock(); defer { lock.unlock() }
        let timeout = snapshot.map { max(0.25, 2 * Double($0.hop) / $0.sampleRate) } ?? 0.25
        return allowStale || CACurrentMediaTime() - received < timeout ? snapshot : nil
    }
}

/// Diagnostics: how often the plot's canvases actually render, against the engine's frame cadence.
final class MultiFFTRenderCounter {
    static let shared = MultiFFTRenderCounter()
    private let lock = NSLock()
    private var curveRenders = 0, gridRenders = 0
    func noteCurves() { lock.lock(); curveRenders += 1; lock.unlock() }
    func noteGrid() { lock.lock(); gridRenders += 1; lock.unlock() }
    var counts: (curves: Int, grid: Int) { lock.lock(); defer { lock.unlock() }; return (curveRenders, gridRenders) }
}

/// Explicit diagnostic-only PCM source. `--demo --multifft-test-tone` exercises the actual FFT, never fabricates
/// spectrum values, and never starts a microphone or writes audio. Stops with the panel just like the live path.
final class MultiFFTPreviewSource {
    private let queue = DispatchQueue(label: "Auraliscope.multiFFT-test-PCM")
    private let mailbox = MultiFFTMailbox()
    private var configuration: MultiFFTConfiguration?
    private var timer: DispatchSourceTimer?
    func configure(_ next: MultiFFTConfiguration?) {
        guard next != configuration else { return }
        configuration = next
        timer?.cancel(); timer = nil
        queue.sync { mailbox.store(nil) }
        guard let next, let analyser = MultiFFTAnalyzer(sampleRate: 48000, configuration: next) else {
            Diagnostics.log("[multifft] test-tone source stopped")
            return
        }
        Diagnostics.log("[multifft] test-tone source running: \(next.preset.rawValue), span \(analyser.span), hop \(analyser.hop)")
        let source = DispatchSource.makeTimerSource(queue: queue)
        var position = 0
        var ticks = 0
        var left = [Float](repeating: 0, count: 800), right = left
        source.schedule(deadline: .now(), repeating: .nanoseconds(16666667))
        source.setEventHandler { [mailbox] in
            for n in left.indices {
                let t = Double(position+n)/48000
                left[n] = Float(0.3*sin(2 * .pi * 63*t) + 0.2*sin(2 * .pi * 997*t) + 0.1*sin(2 * .pi * 4000*t))
                right[n] = Float(0.2*sin(2 * .pi * 63*t) + 0.1*sin(2 * .pi * 997*t) - 0.15*sin(2 * .pi * 4000*t))
            }
            position += left.count
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
                analyser.consume(left: l.baseAddress!, right: r.baseAddress!, count: left.count)
            } }
            mailbox.store(analyser.latest)
            ticks += 1
            if ticks % 600 == 0 { Diagnostics.log("[multifft] test-tone source: \(ticks) ticks, frame serial \(analyser.latest?.serial ?? 0)") }
        }
        timer = source; source.resume()
    }
    func latest() -> MultiFFTSnapshot? { mailbox.read() }
    deinit { timer?.cancel() }
}

enum MultiFFTPreferences {
    static let key = "spectrum.multiFFT.configuration"
    static let optInKey = "layout.multiFFTOptIn"
    static let legacyKey = "spectrum.legacySTFT"
    static var stored: MultiFFTConfiguration { decode(storedData) }
    /// The raw saved value, so a defaults change that left it alone need not be decoded again.
    static var storedData: Data? { UserDefaults.standard.data(forKey: key) }
    static func decode(_ data: Data?) -> MultiFFTConfiguration {
        guard let data, let c = try? JSONDecoder().decode(MultiFFTConfiguration.self, from: data) else { return .init() }
        return c
    }
    static func save(_ configuration: MultiFFTConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: key) }
    }
    static var legacySTFT: LegacySTFT {
        guard UserDefaults.standard.object(forKey: legacyKey) != nil else { return .shared4096 }
        return LegacySTFT(rawValue: UserDefaults.standard.integer(forKey: legacyKey)) ?? .shared4096
    }
}

extension MultiFFTConfiguration.Preset {
    var title: String {
        switch self {
        case .economy: return L("Economy")
        case .light: return L("Light")
        case .standard: return L("Standard")
        case .high: return L("High")
        case .ultra: return L("Ultra")
        case .custom: return L("Custom")
        }
    }
}
extension MultiFFTConfiguration.Priority {
    var title: String {
        switch self {
        case .precision: return L("Precision")
        case .balanced: return L("Balanced")
        case .responsive: return L("Responsive")
        }
    }
}

struct MultiFFTOptInRow: View {
    @ObservedObject private var placement = PanelPlacement.shared
    @ObservedObject private var l10n = Localizer.shared
    var body: some View {
        Toggle(L("Multi-FFT Spectrum (Beta)"), isOn: Binding(get: { placement.isShown(.multiFFT) },
            set: { placement.setShown(.multiFFT, $0) }))
            .toggleStyle(.switch)
    }
}

struct LegacySTFTSettings: View {
    let model: MeterModel?
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(MultiFFTPreferences.legacyKey) private var size = 4096
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MultiFFTOptInRow()
            Picker(L("Shared STFT · A/B"), selection: $size) {
                Text(L("Legacy (Build 113)")).tag(0)
                ForEach([2048, 4096, 8192], id: \.self) { Text("\($0)").tag($0) }
            }
            Text(model?.sourceIsBridge == true ? L("Bridge keeps its original analysis. Multi-FFT requires local PCM in this Beta.")
                 : L("Shared Hann STFT serves both displays. Enhanced and Immersive keep the original analysis. Switching refills the FFT history."))
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }
}

struct MultiFFTSettingsView: View {
    @State private var configuration = MultiFFTPreferences.stored
    @ObservedObject private var l10n = Localizer.shared
    let sampleRate: Double
    private func edit<T: Equatable>(_ key: WritableKeyPath<MultiFFTConfiguration, T>) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] }, set: {
            guard $0 != configuration[keyPath: key] else { return }
            configuration[keyPath: key] = $0; configuration.preset = .custom; save()
        })
    }
    private func band<T: Equatable>(_ index: Int, _ key: WritableKeyPath<MultiFFTConfiguration.Band, T>) -> Binding<T> {
        Binding(get: { configuration.bands[index][keyPath: key] }, set: {
            guard $0 != configuration.bands[index][keyPath: key] else { return }
            configuration.bands[index][keyPath: key] = $0; configuration.preset = .custom; save()
        })
    }
    private func save() {
        configuration = configuration.validated(sampleRate: max(8000, sampleRate))
        MultiFFTPreferences.save(configuration)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Multi-FFT Spectrum (Beta)")).font(.headline)
            Picker(L("Performance preset"), selection: Binding(get: { configuration.preset }, set: {
                if $0 != .custom { configuration = .make($0, priority: configuration.priority); save() }
            })) {
                ForEach(MultiFFTConfiguration.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(L("Priority"), selection: Binding(get: { configuration.priority }, set: {
                if configuration.preset == .custom { configuration.priority = $0 }
                else { configuration = .make(configuration.preset, priority: $0) }
                save()
            })) {
                ForEach(MultiFFTConfiguration.Priority.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(L("Priority tunes preset sizes and rates. Advanced edits become Custom. All three bands use the slowest requested cadence to keep their analysis centres aligned."))
                .font(.caption).foregroundStyle(Theme.secondary)
            Divider()
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Text([L("Low band"), L("Mid band"), L("High band")][i]).font(.subheadline.bold())
                    Picker("FFT Size", selection: band(i, \.size)) {
                        ForEach(MultiFFTConfiguration.sizes, id: \.self) { Text("\($0)").tag($0) }
                    }
                    HStack {
                        Text(L("Update ceiling (Hz)")); Spacer()
                        TextField("Hz", value: band(i, \.rate), format: .number).frame(width: 64)
                    }
                    Picker(L("Overlap ceiling"), selection: band(i, \.overlap)) {
                        ForEach([0.0, 0.5, 0.75, 0.875, 0.9375, 0.96875], id: \.self) {
                            Text(String(format: "%.3g%%", $0 * 100)).tag($0)
                        }
                    }
                }
            }
            Divider()
            number(L("Low/Mid crossover (Hz)"), edit(\.lowCrossover))
            number(L("Mid/High crossover (Hz)"), edit(\.highCrossover))
            number(L("Fusion width (octaves)"), edit(\.blendOctaves))
            Picker(L("Window function"), selection: edit(\.window)) {
                Text("Hann").tag(MultiFFTConfiguration.Window.hann)
                Text("Blackman–Harris").tag(MultiFFTConfiguration.Window.blackmanHarris)
            }
            Picker(L("Calibration"), selection: edit(\.scale)) {
                Text(L("Tone amplitude · dBFS")).tag(MultiFFTConfiguration.Scale.amplitude)
                Text("PSD · dBFS/Hz").tag(MultiFFTConfiguration.Scale.psd)
            }
            number(L("Time smoothing (s)"), edit(\.smoothingSeconds))
            number(L("Frequency smoothing (octaves)"), edit(\.smoothingOctaves))
            Toggle(L("Show M/S alongside L/R"), isOn: edit(\.midSide))
            let c = configuration.validated(sampleRate: max(8000, sampleRate))
            Text(String(format: "%.1f Hz · %.1f ms", max(8000, sampleRate) / Double(c.hop(sampleRate: max(8000, sampleRate))),
                        Double(c.bands.map(\.size).max()!) / 2 / max(8000, sampleRate) * 1000))
                .font(.caption.monospacedDigit())
            Text(L("Rates are analysis ceilings; milliseconds are the common centre delay. Tone calibration keeps sine peaks correct; PSD keeps noise density comparable across windows. Frequency smoothing lowers narrow peaks. M=(L+R)/2, S=(L−R)/2."))
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { configuration = MultiFFTPreferences.stored.validated(sampleRate: max(8000, sampleRate)) }
    }
    private func number(_ title: String, _ binding: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: binding, format: .number).frame(width: 84) }
    }
}

struct MultiFFTPanel: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @State private var settings = false
    @AppStorage(MultiFFTPreferences.key) private var configurationData: Data?
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    header(L("Multi-FFT Spectrum (Beta)").uppercased(), key: true)
                    header(L("Multi-FFT Spectrum (Beta)").uppercased(), key: false)
                    header("MULTI-FFT", key: false)
                }
                .popover(isPresented: $settings) {
                    ScrollView { MultiFFTSettingsView(sampleRate: model.sampleRate).padding(16) }
                        .frame(width: 420, height: 560)
                }
                PanelTimeline(interval: 1.0/30) {
                    if model.format != .stereo {
                        message(L("Multi-FFT is available in Stereo mode."))
                    } else if model.sourceIsBridge {
                        message(L("Bridge keeps its original analysis. Multi-FFT requires local PCM in this Beta."))
                    } else if let frame = model.multiFFTFrame() {
                        MultiFFTPlot(frame: frame).equatable()
                    } else {
                        message(L("Waiting for a full local audio window…"))
                    }
                }
            }
        }
        .onAppear { model.multiFFTPanelVisible(true) }
        .onDisappear { model.multiFFTPanelVisible(false) }
        .onAppear {
            if Diagnostics.snapshotPanelSettings, Diagnostics.snapshotPanelSettingsPanel == "multiFFT" {
                DispatchQueue.main.asyncAfter(deadline: .now()+2) { settings = true }
            }
        }
    }
    /// The curve key sits in the header like the Waveform's; the level unit replaces the old footer.
    private func header(_ title: String, key: Bool) -> some View {
        let configuration = MultiFFTPreferences.decode(configurationData)
        return PanelHeader(title: title, detail: configuration.scale == .psd ? "PSD · dBFS/Hz" : "dBFS") {
            if key {
                HStack(spacing: 10) {
                    ForEach(0..<(configuration.midSide ? 4 : 2), id: \.self) {
                        LegendDot(color: MultiFFTPlot.palette[$0], text: [L("Left"), L("Right"), "M", "S"][$0])
                    }
                }
            }
            DiscButton(symbol: "slider.horizontal.3", help: L("Panel settings"), diameter: 22, on: settings) { settings.toggle() }
            PanelWindowButton(panel: .multiFFT)
        }
    }
    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The plot redraws its curves only for a new engine frame (`serial`), never per 30 Hz timeline tick, and keeps the
/// grid and its labels in a separate canvas that is laid out again only when the axes change, the theme changes or the
/// panel resizes. It sits in the same recessed well as the Spectrum card, with that card's plot margins and axis type.
struct MultiFFTPlot: View, Equatable {
    let frame: MultiFFTSnapshot
    var ink = Theme.ink
    var colors = Self.palette
    static func == (a: Self, b: Self) -> Bool {
        a.frame.serial == b.frame.serial && a.frame.centreSample == b.frame.centreSample && a.frame.scale == b.frame.scale
            && a.frame.sampleRate == b.frame.sampleRate && a.frame.hop == b.frame.hop && a.frame.lengths == b.frame.lengths
            && a.frame.curves.count == b.frame.curves.count && a.ink == b.ink && a.colors == b.colors
    }
    /// L, R, M, S in the Waveform's channel colours.
    static var palette: [Color] { [Theme.sage, Theme.sand, Theme.heather, Theme.clay] }
    /// The Spectrum card's plot rectangle: level labels on the left, frequency labels underneath.
    static func plot(in size: CGSize) -> CGRect {
        let top: CGFloat = 8, margin: CGFloat = 12
        return CGRect(x: SpectrumCardLayout.levelLabels, y: top, width: max(1, size.width - SpectrumCardLayout.levelLabels - margin),
                      height: max(1, size.height - top - FrequencyAxis.labelHeight))
    }
    var body: some View {
        let floor = frame.scale == .psd ? -150.0 : -120.0
        ZStack {
                MultiFFTGrid(floor: floor, upper: min(20000, frame.sampleRate/2), ink: ink).equatable()
                Canvas { context, size in
                    MultiFFTRenderCounter.shared.noteCurves()
                    let plot = Self.plot(in: size)
                    context.clip(to: Path(plot))
                    for c in frame.curves.indices {
                        var path = Path()
                        let curve = frame.curves[c], count = Double(curve.count)
                        for p in curve.indices {
                            let point = CGPoint(x: plot.minX + (Double(p)+0.5)/count*plot.width,
                                                y: plot.minY + max(0, min(1, Double(curve[p])/floor))*plot.height)
                            if p == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        context.stroke(path, with: .color(colors[c]), lineWidth: 1.2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
            .background { PlotPlate() }
    }
}

/// Level and frequency grid with labels: the same geometry as the curves canvas, drawn once per axis change/resize.
private struct MultiFFTGrid: View, Equatable {
    let floor: Double
    let upper: Double
    let ink: Color
    var body: some View {
        Canvas { context, size in
            MultiFFTRenderCounter.shared.noteGrid()
            let plot = MultiFFTPlot.plot(in: size)
            for db in stride(from: 0, through: Int(floor), by: -30) {
                let y = plot.minY + Double(db) / floor * plot.height
                var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(ink.opacity(db == 0 ? ChartInk.reference : ChartInk.major)), lineWidth: 0.5)
                guard db > Int(floor) else { continue }
                context.draw(Text(verbatim: db == 0 ? "0 dB" : "−\(-db)").font(.axis).foregroundColor(Theme.tertiary),
                             at: CGPoint(x: plot.minX - SpectrumCardLayout.levelLabels / 2, y: db == 0 ? y + 7 : y))
            }
            for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] where f <= upper {
                let x = plot.minX + log(f/20)/log(upper/20)*plot.width
                let decade = [100.0, 1000, 10000].contains(f)
                var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(ink.opacity(decade ? ChartInk.major : ChartInk.minor)), lineWidth: 0.5)
                // Octave-and-a-bit neighbours sit a tenth of the axis apart: name them only where labels keep their room.
                guard [20.0, 100, 1000, 10000, 20000].contains(f) || plot.width * log(2)/log(1000) >= SpectrumCardLayout.labelSpacing else { continue }
                // The top of the axis is named just inside the plot's right edge, as on the Spectrum card.
                let edge = f == 20000 || f == upper
                context.draw(Text(verbatim: f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))").font(.axis)
                                .foregroundColor(decade ? Theme.secondary : Theme.tertiary),
                             at: CGPoint(x: x - (edge ? 10 : 0), y: plot.maxY + FrequencyAxis.labelHeight / 2))
            }
        }
    }
}
