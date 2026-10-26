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

struct MultiFFTPanel: View {
    @ObservedObject var model: MeterModel
    @ObservedObject private var l10n = Localizer.shared
    @AppStorage(MultiFFTPreferences.key) private var configurationData: Data?
    @AppStorage(FrequencyScale.multiFFTKey) private var scaleKey = FrequencyScale.log.rawValue
    @AppStorage(SpectrumTilt.multiFFTKey) private var tiltSlope = 0.0
    var body: some View {
        let scale = FrequencyScale(rawValue: scaleKey) ?? .log
        let tilt = SpectrumTilt(stored: tiltSlope)
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    header(L("Multi-FFT Spectrum (Beta)").uppercased(), key: true, tilt: tilt)
                    header(L("Multi-FFT Spectrum (Beta)").uppercased(), key: false, tilt: tilt)
                    header("MULTI-FFT", key: false, tilt: tilt)
                }
                PanelTimeline(interval: 1.0/30) {
                    if model.format != .stereo {
                        message(L("Multi-FFT is available in Stereo mode."))
                    } else if model.sourceIsBridge {
                        message(L("Bridge keeps its original analysis. Multi-FFT requires local PCM in this Beta."))
                    } else if let frame = model.multiFFTFrame() {
                        ZStack(alignment: .topLeading) {
                            MultiFFTPlot(frame: frame, scale: scale, tilt: tilt).equatable()
                            MultiFFTInspector(frame: frame, scale: scale, tilt: tilt,
                                              midSide: MultiFFTPreferences.decode(configurationData).midSide)
                        }
                    } else {
                        message(L("Waiting for a full local audio window…"))
                    }
                }
            }
        }
        .onAppear { model.multiFFTPanelVisible(true) }
        .onDisappear { model.multiFFTPanelVisible(false) }
    }
    /// The curve key sits in the header like the Waveform's; the level unit (and the display slope, when one is set)
    /// is its detail. Settings and the window button are the other panels' own.
    private func header(_ title: String, key: Bool, tilt: SpectrumTilt) -> some View {
        let configuration = MultiFFTPreferences.decode(configurationData)
        let unit = configuration.scale == .psd ? "PSD · dBFS/Hz" : "dBFS"
        return PanelHeader(title: title, detail: tilt == .flat ? unit : unit + " · +" + tilt.title) {
            if key {
                HStack(spacing: 10) {
                    ForEach(0..<(configuration.midSide ? 4 : 2), id: \.self) {
                        LegendDot(color: MultiFFTPlot.palette[$0], text: MultiFFTPanel.curveNames[$0])
                    }
                }
            }
            PanelSettingsButton(panel: .multiFFT, model: model)
        }
    }
    /// L, R, M, S as the key and the hover reading name them.
    static var curveNames: [String] { [L("Left"), L("Right"), "M", "S"] }
    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The plot redraws its curves only for a new engine frame (`serial`), never per 30 Hz timeline tick, and keeps the
/// grid and its labels in a separate canvas that is laid out again only when the axes change, the theme changes or the
/// panel resizes. It sits in the same recessed well as the Spectrum card, with that card's plot margins and axis type.
struct MultiFFTPlot: View, Equatable {
    let frame: MultiFFTSnapshot
    var scale = FrequencyScale.log
    var tilt = SpectrumTilt.flat
    var ink = Theme.ink
    var colors = Self.palette
    static func == (a: Self, b: Self) -> Bool {
        a.frame.serial == b.frame.serial && a.frame.centreSample == b.frame.centreSample && a.frame.scale == b.frame.scale
            && a.frame.sampleRate == b.frame.sampleRate && a.frame.hop == b.frame.hop && a.frame.lengths == b.frame.lengths
            && a.frame.curves.count == b.frame.curves.count && a.scale == b.scale && a.tilt == b.tilt
            && a.ink == b.ink && a.colors == b.colors
    }
    /// L, R, M, S in the Waveform's channel colours.
    static var palette: [Color] { [Theme.sage, Theme.sand, Theme.heather, Theme.clay] }
    static func floor(_ scale: MultiFFTConfiguration.Scale) -> Double { scale == .psd ? -150 : -120 }
    /// Where a frequency and a level land in `plot`.
    static func x(_ frequency: Double, plot: CGRect, sampleRate: Double, scale: FrequencyScale) -> CGFloat {
        plot.minX + MeterScale.frequencyFraction(frequency, sampleRate: sampleRate, scale: scale) * plot.width
    }
    static func y(_ level: Double, plot: CGRect, floor: Double) -> CGFloat {
        plot.minY + max(0, min(1, level / floor)) * plot.height
    }
    /// The Spectrum card's plot rectangle: level labels on the left, frequency labels underneath.
    static func plot(in size: CGSize) -> CGRect {
        let top: CGFloat = 8, margin: CGFloat = 12
        return CGRect(x: SpectrumCardLayout.levelLabels, y: top, width: max(1, size.width - SpectrumCardLayout.levelLabels - margin),
                      height: max(1, size.height - top - FrequencyAxis.labelHeight))
    }
    var body: some View {
        let floor = Self.floor(frame.scale)
        ZStack {
                MultiFFTGrid(floor: floor, sampleRate: frame.sampleRate, scale: scale, ink: ink).equatable()
                Canvas { context, size in
                    MultiFFTRenderCounter.shared.noteCurves()
                    let plot = Self.plot(in: size)
                    context.clip(to: Path(plot))
                    let xs = frame.frequencies.map { Self.x($0, plot: plot, sampleRate: frame.sampleRate, scale: scale) }
                    let slope = frame.frequencies.map { Double(tilt.offset(frequency: $0)) }
                    for c in frame.curves.indices {
                        var path = Path()
                        let curve = frame.curves[c]
                        for p in curve.indices where p < xs.count {
                            let point = CGPoint(x: xs[p], y: Self.y(Double(curve[p]) + slope[p], plot: plot, floor: floor))
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
    let sampleRate: Double
    let scale: FrequencyScale
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
            for (f, label, named) in Self.marks(plot: plot, sampleRate: sampleRate, scale: scale) {
                let x = MultiFFTPlot.x(f, plot: plot, sampleRate: sampleRate, scale: scale)
                let major = scale.isMajor(f)
                var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(ink.opacity(major ? ChartInk.major : ChartInk.minor)), lineWidth: 0.5)
                guard named else { continue }
                // The top of the axis is named just inside the plot's right edge, as on the Spectrum card; 0 Hz just
                // inside its left edge.
                let edge: CGFloat = f >= MeterScale.upperFrequency(sampleRate: sampleRate) ? -10 : (f == 0 ? 4 : 0)
                context.draw(Text(verbatim: label).font(.axis).foregroundColor(major ? Theme.secondary : Theme.tertiary),
                             at: CGPoint(x: x + edge, y: plot.maxY + FrequencyAxis.labelHeight / 2))
            }
        }
    }

    /// The grid's frequency lines, and whether each is named. Log: 20, 50, 100 Hz… with the octave-and-a-bit
    /// neighbours named only where labels keep their room. Linear: 0, 1k… every line named where it keeps its room
    /// from the ones named already, the top of the axis always.
    static func marks(plot: CGRect, sampleRate: Double, scale: FrequencyScale) -> [(Double, String, Bool)] {
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        switch scale {
        case .log:
            return [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000].filter { $0 <= upper }.map { f in
                let named = [20.0, 100, 1000, 10000, 20000].contains(f) || plot.width * log(2)/log(1000) >= SpectrumCardLayout.labelSpacing
                return (f, f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))", named)
            }
        case .linear:
            let top = (upper, upper >= 1_000 ? "\(Int((upper / 1_000).rounded()))k" : "\(Int(upper))")
            let candidates = [top] + scale.marks.filter { scale.isMajor($0.0) && $0.0 < upper } + scale.marks.filter { !scale.isMajor($0.0) && $0.0 < upper }
            var named: [Double] = []
            for (f, _) in candidates {
                let x = MultiFFTPlot.x(f, plot: plot, sampleRate: sampleRate, scale: scale)
                if named.allSatisfy({ abs(MultiFFTPlot.x($0, plot: plot, sampleRate: sampleRate, scale: scale) - x) >= SpectrumCardLayout.labelSpacing }) {
                    named.append(f)
                }
            }
            return ([top] + scale.marks.filter { $0.0 < upper }).map { ($0.0, $0.1, named.contains($0.0)) }
        }
    }
}

/// Hover over the plot to read it: the pitch and frequency under the pointer, and each curve's level there (as
/// analysed, without the display slope), on a tag like the Spectrum card's, with a hairline at the frequency and a
/// ring where each curve crosses it.
private struct MultiFFTInspector: View {
    let frame: MultiFFTSnapshot
    let scale: FrequencyScale
    let tilt: SpectrumTilt
    let midSide: Bool
    @State private var location: CGPoint? = Diagnostics.multiFFTProbePoint
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GeometryReader { proxy in
            let plot = MultiFFTPlot.plot(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        // A held diagnostic point (`--snapshot-multifft-probe`) is not moved by the real pointer.
                        guard Diagnostics.multiFFTProbePoint == nil else { return }
                        switch phase {
                        case .active(let point): location = point
                        case .ended: location = nil
                        }
                    }
                if let location, plot.insetBy(dx: -1, dy: -1).contains(location), !frame.frequencies.isEmpty {
                    overlay(at: location, plot: plot).allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func overlay(at point: CGPoint, plot: CGRect) -> some View {
        let frequencies = frame.frequencies
        let wanted = MeterScale.frequency(fraction: Double((point.x - plot.minX) / max(1, plot.width)), sampleRate: frame.sampleRate, scale: scale)
        // The analysis' points run up the log axis from 20 Hz: the nearest one to the frequency under the pointer.
        let upper = MeterScale.upperFrequency(sampleRate: frame.sampleRate)
        let index = max(0, min(frequencies.count - 1,
                               Int((Double(MeterScale.frequencyFraction(wanted, sampleRate: frame.sampleRate)) * Double(frequencies.count) - 0.5).rounded())))
        let frequency = min(upper, frequencies[index])
        let x = MultiFFTPlot.x(frequency, plot: plot, sampleRate: frame.sampleRate, scale: scale)
        let floor = MultiFFTPlot.floor(frame.scale)
        let count = min(frame.curves.count, midSide ? 4 : 2)
        let levels = (0..<count).map { frame.curves[$0].indices.contains(index) ? frame.curves[$0][index] : nil }
        let slope = Double(tilt.offset(frequency: frequency))
        let pitch = Pitch(frequency: frequency)
        let font = Font.caption2.weight(.medium).monospacedDigit()
        let unit = frame.scale == .psd ? " dBFS/Hz" : " dBFS"
        let tag = HStack(spacing: 5) {
            Text(verbatim: pitch.map { "\($0.label) \($0.centsLabel)" } ?? "--").font(font.weight(.semibold)).foregroundStyle(Theme.sage)
            Text(verbatim: frequency < 100 ? String(format: "%.1f Hz", frequency)
                 : frequency < 1_000 ? String(format: "%.0f Hz", frequency) : String(format: "%.2f kHz", frequency / 1_000))
                .font(font).foregroundStyle(Theme.ink)
            ForEach(0..<count, id: \.self) { c in
                Text("•").font(.caption2).foregroundStyle(Theme.tertiary)
                Circle().fill(MultiFFTPlot.palette[c]).frame(width: 5, height: 5)
                Text(verbatim: MultiFFTPanel.curveNames[c].prefix(1) + " " + (levels[c].map { MeterScale.tenths($0, floor: Float(floor) + 0.1) } ?? "--"))
                    .font(font).foregroundStyle(levels[c] == nil ? Theme.tertiary : Theme.ink)
            }
            Text(verbatim: unit.trimmingCharacters(in: .whitespaces)).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background { BadgeSurface() }
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
            .stroke(Theme.ink.opacity(Theme.dark ? 0.55 : 0.5), style: StrokeStyle(lineWidth: 0.5))
            ForEach(0..<count, id: \.self) { c in
                if let level = levels[c] {
                    let y = MultiFFTPlot.y(Double(level) + slope, plot: plot, floor: floor)
                    Circle().strokeBorder(MultiFFTPlot.palette[c], lineWidth: 1.25)
                        .background(Circle().fill(Theme.display.opacity(0.6)))
                        .frame(width: 7, height: 7)
                        .offset(x: x - 3.5, y: y - 3.5)
                }
            }
            tag
                .frame(width: plot.width, alignment: x > plot.midX ? .leading : .trailing)
                .padding(.horizontal, 4)
                .offset(x: plot.minX - 4, y: plot.minY + 4)
        }
    }
}
