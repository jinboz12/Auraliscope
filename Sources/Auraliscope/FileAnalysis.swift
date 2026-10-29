import AnalysisCore
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What an analysed file is, for the report's Source and Format lines.
struct AudioFileInfo {
    var url: URL
    var name: String { url.lastPathComponent }
    var sampleRate: Double
    var channels: Int
    var frames: Int64
    var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    /// "WAV", "MP3", "AAC"…
    var codec: String
    /// Bits per sample of a PCM file; nil for compressed and floating-point files.
    var bitDepth: Int?
    var floatingPoint: Bool
    /// Average bit rate of a compressed file, kbit/s, from its size.
    var bitRate: Int?
    /// Each channel's speaker role (`Role`), in the file's channel order.
    var roles: [Int]
    /// The speaker layout the channels were read as (multichannel files only).
    var layout: SpeakerLayout?

    /// "Stereo · 44.1 kHz · 16-bit · WAV".
    var formatLine: String {
        let rate = sampleRate.truncatingRemainder(dividingBy: 1_000) == 0
            ? "\(Int(sampleRate / 1_000)) kHz" : String(format: "%.1f kHz", sampleRate / 1_000)
        let channelName: String = switch channels {
        case 1: L("Mono")
        case 2: L("Stereo")
        default: layout.map { L("%@ (%d channels, SMPTE order)", $0.name, channels) } ?? L("%d channels", channels)
        }
        var parts = [channelName, rate]
        if let bitDepth { parts.append(floatingPoint ? L("%d-bit float", bitDepth) : L("%d-bit", bitDepth)) }
        parts.append(codec)
        if let bitRate { parts.append("\(bitRate) kbps") }
        return parts.joined(separator: " · ")
    }
}

/// A whole file measured: the same readings a live session gathers, plus what the file is.
struct FileMeasurement {
    var info: AudioFileInfo
    var integrated: Float
    var range: Float
    var truePeak: Float
    var samplePeak: Float
    var maxMomentary: Float
    var maxShortTerm: Float
    var overs: Int
    var momentary: [Float]
    var shortTerm: [Float]
    var statistics: SessionStatistics
    /// Seconds the analysis took.
    var elapsed: Double
}

enum FileAnalysisError: LocalizedError {
    case unreadable
    case channels(Int)
    case empty
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadable: return L("The file could not be read as audio. It may be damaged, protected, or in a format macOS does not decode.")
        case .channels(let count): return L("Files with %d channels are not supported. Mono, stereo and the multichannel layouts from 3.0 to 9.1.6 are.", count)
        case .empty: return L("The file holds no audio.")
        case .cancelled: return L("The analysis was cancelled.")
        }
    }
}

/// Measures a whole audio file offline with the analysis the meter and the Bridge plugins run (`StreamAnalyzer`):
/// every sample at the file's own rate, ticked by the audio, read at the readouts' 10 Hz exactly as a live session
/// is, so the file's report says what metering it in real time would have said.
enum AudioFileAnalyzer {
    /// Formats Core Audio decodes: WAV, AIFF, CAF, MP3, AAC / M4A, ALAC, FLAC and the rest of `public.audio`.
    static let contentTypes: [UTType] = [.audio]

    /// Channel order by count: the conventional SMPTE / BS.2051 order the meter's default routing uses.
    static func layout(channels: Int) -> SpeakerLayout? {
        switch channels {
        case 3: return .lcr
        case 4: return .quad
        case 5: return .s50
        case 6: return .s51
        case 7: return .s70
        case 8: return .s71
        case 10: return .s712
        case 12: return .s714
        case 14: return .s716
        case 16: return .s916
        default: return nil
        }
    }

    static func codecName(_ format: AVAudioFormat, url: URL) -> String {
        let id = format.streamDescription.pointee.mFormatID
        switch id {
        case kAudioFormatLinearPCM:
            let ext = url.pathExtension.lowercased()
            return ["wav": "WAV", "wave": "WAV", "bwf": "BWF", "aif": "AIFF", "aiff": "AIFF", "aifc": "AIFF-C", "caf": "CAF", "w64": "W64", "rf64": "RF64"][ext]
                ?? (ext.isEmpty ? "PCM" : ext.uppercased())
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD: return "AAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        default: return url.pathExtension.uppercased()
        }
    }

    /// Reads `url`, without decoding it.
    static func info(_ url: URL) throws -> (AVAudioFile, AudioFileInfo) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw FileAnalysisError.unreadable }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard file.length > 0, format.sampleRate > 0 else { throw FileAnalysisError.empty }
        let roles: [Int]
        let layout: SpeakerLayout?
        switch channels {
        case 1: roles = [Role.left]; layout = nil
        case 2: roles = [Role.left, Role.right]; layout = nil
        default:
            guard let chosen = Self.layout(channels: channels) else { throw FileAnalysisError.channels(channels) }
            roles = chosen.roles
            layout = chosen
        }
        let stored = file.fileFormat.streamDescription.pointee
        let pcm = stored.mFormatID == kAudioFormatLinearPCM
        let floating = pcm && stored.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var info = AudioFileInfo(url: url, sampleRate: format.sampleRate, channels: channels, frames: file.length,
                                 codec: codecName(file.fileFormat, url: url),
                                 bitDepth: pcm && stored.mBitsPerChannel > 0 ? Int(stored.mBitsPerChannel) : nil,
                                 floatingPoint: floating, roles: roles, layout: layout)
        if !pcm, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, info.duration > 1 {
            info.bitRate = Int((Double(size) * 8 / info.duration / 1_000).rounded())
        }
        return (file, info)
    }

    /// Analyses the whole file. `progress` gets the fraction done now and then; returning false from it cancels.
    /// Runs on the caller's thread: call it off the main thread.
    static func analyse(_ url: URL, progress: (Double) -> Bool) throws -> FileMeasurement {
        let began = Date()
        let (file, info) = try info(url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = info.channels
        guard let analyzer = StreamAnalyzer(sampleRate: rate, roles: info.roles, generation: 1, formatEpoch: 1) else {
            throw FileAnalysisError.unreadable
        }
        // A multichannel file sums every channel in the spectrum, as Immersive does live.
        analyzer.spatialSpectrum = channels > 2
        let routed = (0..<Role.count).map { info.roles.contains($0) }
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw FileAnalysisError.empty }
        var interleaved = [Float](repeating: 0, count: Int(chunk) * channels)

        var statistics = SessionStatistics()
        var momentary: [Float] = [], shortTerm: [Float] = []
        let expected = Int(Double(info.frames) / rate * SessionStatistics.rateHz) + 2
        momentary.reserveCapacity(expected)
        shortTerm.reserveCapacity(expected)
        var maxMomentary: Float = -100, maxShortTerm: Float = -100
        var overs = 0, overBefore = false
        // The highest peaks of the 60 Hz ticks since the last 10 Hz reading, so no tick's peak is missed.
        var tickPeak: Float = 0, tickTruePeak: Float = 0, tickOverPeak: Float = 0
        var audioTicks = 0
        var fed: Int64 = 0
        let subTicks = Int(MeterPipeline.tickRate / SessionStatistics.rateHz)
        func tickEnd(_ n: Int) -> Int64 { Int64((Double(n) * rate / MeterPipeline.tickRate).rounded()) }

        func reading(_ v: [Float]) {
            let snapshot = DSPWorker.decode(v)
            momentary.append(snapshot.momentaryLUFS)
            shortTerm.append(snapshot.shortLUFS)
            maxMomentary = max(maxMomentary, snapshot.momentaryLUFS)
            maxShortTerm = max(maxShortTerm, snapshot.shortLUFS)
            let over = tickOverPeak > 1
            if over && !overBefore { overs += 1 }
            overBefore = over
            statistics.add(SessionSample(
                momentary: snapshot.momentaryLUFS, shortTerm: snapshot.shortLUFS,
                truePeak: MeterScale.decibels(tickTruePeak), samplePeak: MeterScale.decibels(tickPeak),
                programme: VUScale.aggregate(rms: snapshot.channelRMS, roles: routed), spectrum: snapshot.spectrumFine,
                upper: MeterScale.upperFrequency(sampleRate: rate),
                bandCorrelation: snapshot.bandCorrelation, bandWidth: snapshot.bandWidth,
                bandBalance: snapshot.bandBalance, bandLevel: snapshot.bandLevel,
                leftRMS: snapshot.channelRMS[Role.left], rightRMS: snapshot.channelRMS[Role.right],
                dcOffset: snapshot.dcOffset, infrasonic: snapshot.infrasonic, healthStatus: snapshot.healthStatus,
                routed: routed))
            tickPeak = 0; tickTruePeak = 0; tickOverPeak = 0
        }

        func tick() {
            let v = analyzer.snapshot
            for role in info.roles {
                let peak = v[SnapshotSlots.peaks + role], truePeak = v[SnapshotSlots.truePeaks + role]
                tickPeak = max(tickPeak, peak)
                tickTruePeak = max(tickTruePeak, truePeak, peak)
                tickOverPeak = max(tickOverPeak, truePeak)
            }
            if audioTicks % subTicks == 0 { reading(v) }
        }

        var lastReport = Date.distantPast
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { throw FileAnalysisError.unreadable }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let planes = buffer.floatChannelData else { break }
            for channel in 0..<channels {
                let plane = planes[channel]
                for frame in 0..<frames { interleaved[frame * channels + channel] = plane[frame] }
            }
            try interleaved.withUnsafeBufferPointer { samples in
                var offset = 0
                while offset < frames {
                    let count = min(frames - offset, Int(tickEnd(audioTicks + 1) - fed))
                    analyzer.consume(samples.baseAddress! + offset * channels, frames: count, position: UInt64(fed),
                                     now: Double(fed) / rate)
                    fed += Int64(count)
                    offset += count
                    if fed == tickEnd(audioTicks + 1) {
                        audioTicks += 1
                        tick()
                    }
                }
                if Date().timeIntervalSince(lastReport) > 0.05 {
                    lastReport = Date()
                    guard progress(Double(fed) / Double(info.frames)) else { throw FileAnalysisError.cancelled }
                }
            }
        }
        guard audioTicks > 0 else { throw FileAnalysisError.empty }
        // The last part of a 10 Hz reading still counts.
        if audioTicks % subTicks != 0 { reading(analyzer.snapshot) }
        let v = analyzer.snapshot
        var heldPeak: Float = 0, heldTruePeak: Float = 0
        for role in info.roles {
            heldPeak = max(heldPeak, v[SnapshotSlots.heldPeaks + role])
            heldTruePeak = max(heldTruePeak, v[SnapshotSlots.heldTruePeaks + role], v[SnapshotSlots.heldPeaks + role])
        }
        _ = progress(1)
        return FileMeasurement(info: info, integrated: v[SnapshotSlots.integrated], range: v[SnapshotSlots.range],
                               truePeak: MeterScale.decibels(heldTruePeak), samplePeak: MeterScale.decibels(heldPeak),
                               maxMomentary: maxMomentary, maxShortTerm: maxShortTerm, overs: overs,
                               momentary: momentary, shortTerm: shortTerm, statistics: statistics,
                               elapsed: Date().timeIntervalSince(began))
    }
}

// MARK: - The analysis panel

/// Meter ▸ Analyze Audio File… and the toolbar's analysis button: picks a file, measures it in the background and
/// offers its report, in a panel that fills the main window as an enlarged panel does.
@MainActor
final class FileAnalysisController: ObservableObject {
    static let shared = FileAnalysisController()

    enum State {
        case idle
        case analysing(name: String, progress: Double)
        case done(LoudnessReportData)
        case failed(name: String, message: String)
        /// Stopped by Cancel: nothing was measured, and the previous result is gone.
        case cancelled(name: String)
    }

    @Published private(set) var state = State.idle
    /// The last file measured, kept so a different standard can judge it again without measuring again.
    private var measurement: FileMeasurement?
    /// The standard the report judges against (`LoudnessStandard.id`); nil = the meter's target and ceiling set by hand.
    @Published var standardID: String? { didSet { if standardID != oldValue { rejudge() } } }
    /// The analysis panel fills the main window in place of the meters.
    @Published private(set) var shown = false
    private var token = FileAnalysisToken()
    private var generation = 0
    weak var model: MeterModel?

    var busy: Bool { if case .analysing = state { return true } else { return false } }

    /// Shows the panel, out of the strip and over an enlarged panel.
    func show() {
        if PanelPlacement.shared.strip { PanelPlacement.shared.leaveStrip() }
        PanelPlacement.shared.restore()
        withAnimation(.panelZoom) { shown = true }
        MainWindow.window?.makeKeyAndOrderFront(nil)
    }

    func close() { withAnimation(.panelZoom) { shown = false } }

    func toggle() { shown ? close() : show() }

    /// The file chooser, as a sheet on the main window (a free-standing panel could open behind it).
    func choose() {
        show()
        let panel = NSOpenPanel()
        panel.title = L("Analyze Audio File")
        panel.prompt = L("Analyze")
        panel.allowedContentTypes = AudioFileAnalyzer.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let picked: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.analyse(url)
        }
        if let window = MainWindow.window { panel.beginSheetModal(for: window, completionHandler: picked) } else { picked(panel.runModal()) }
    }

    func analyse(_ url: URL) {
        guard let model else { return }
        generation += 1
        let run = generation
        token.cancel()
        measurement = nil
        let token = FileAnalysisToken()
        self.token = token
        state = .analysing(name: url.lastPathComponent, progress: 0)
        ReportExportState.shared.saved = nil
        show()
        DiagnosticLog.event("File analysis: started")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try AudioFileAnalyzer.analyse(url) { fraction in
                    DispatchQueue.main.async {
                        guard let self, self.generation == run, self.busy else { return }
                        self.state = .analysing(name: url.lastPathComponent, progress: fraction)
                    }
                    return !token.cancelled
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                switch result {
                case .success(let measurement):
                    self.measurement = measurement
                    // The meter's standard for the file's format: Immersive for a multichannel file, Stereo otherwise.
                    let standard = model.standard(spatial: measurement.info.channels > 2)
                    if self.standardID != standard?.id { self.standardID = standard?.id } else { self.rejudge() }
                    DiagnosticLog.event(String(format: "File analysis: done, %.1f s of audio in %.1f s",
                                               measurement.info.duration, measurement.elapsed))
                case .failure(FileAnalysisError.cancelled):
                    self.state = .cancelled(name: url.lastPathComponent)
                    DiagnosticLog.event("File analysis: cancelled")
                case .failure(let error):
                    self.state = .failed(name: url.lastPathComponent, message: error.localizedDescription)
                    DiagnosticLog.event("File analysis: failed")
                }
            }
        }
    }

    /// The meter's own target and ceiling for the file's format, judged as Custom.
    var custom: (target: Double, ceiling: Double) {
        let spatial = (measurement?.info.channels ?? 2) > 2
        guard let model else { return (-18, -1) }
        return spatial ? (model.spatialTarget, model.spatialCeiling) : (model.stereoTarget, model.stereoCeiling)
    }

    private func rejudge() {
        guard let measurement else { return }
        let standard = LoudnessStandard.with(id: standardID)
        state = .done(LoudnessReportData.gather(file: measurement, standard: standard,
                                                target: standard?.target ?? custom.target, ceiling: standard?.ceiling ?? custom.ceiling))
    }

    func cancel() {
        token.cancel()
        generation += 1
        if case .analysing(let name, _) = state { state = .cancelled(name: name) } else { state = .idle }
        DiagnosticLog.event("File analysis: cancelled")
    }

    func save(csv: Bool) {
        guard case .done(let data) = state else { return }
        LoudnessReportExport.save(data, csv: csv, baseName: L("Loudness Report") + " – " + data.source.deletingPathExtension)
    }
}

private extension String {
    var deletingPathExtension: String { (self as NSString).deletingPathExtension }
}

/// Cancels an analysis from the main thread; the analysis thread polls it between chunks.
final class FileAnalysisToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// The analysis panel: progress while the file is measured, then the verdict, the headline numbers and the
/// report's section verdicts, with the PDF and CSV a click away. A file dropped on it is analysed.
struct FileAnalysisView: View {
    @ObservedObject var controller = FileAnalysisController.shared
    @ObservedObject private var export = ReportExportState.shared
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: L("Analyze Audio File").uppercased()) {
                    DiscButton(symbol: "xmark", help: L("Close"), diameter: 22) { controller.close() }
                }
                // A column of the report's width, centred in the well; it scrolls in a short window.
                GeometryReader { well in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            content
                                .padding(22)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            HStack(spacing: 10) {
                                buttons
                            }
                            .padding(.horizontal, 22)
                            .padding(.bottom, 20)
                        }
                        .frame(maxWidth: 600)
                        .frame(maxWidth: .infinity, minHeight: well.size.height)
                    }
                }
                .background { PlotPlate() }
            }
        }
        .tint(Theme.action)
        .background {
            // Esc closes a finished analysis (while measuring it cancels, and idle it closes, by the buttons' own keys).
            if case .done = controller.state {
                Button("") { controller.close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        // A file dropped on the panel is analysed in place of the current one.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !controller.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { FileAnalysisController.shared.analyse(url) }
            }
            return true
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Analyze Audio File")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(L("Measures a whole file — WAV, AIFF, MP3, AAC, ALAC, FLAC and more — with the meter's own analysis, then writes the loudness and master report as a PDF. The file stays on your Mac."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .analysing(let name, let progress):
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Analyzing")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(verbatim: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                ProgressView(value: progress)
                Text(verbatim: String(format: "%.0f %%", progress * 100)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        case .failed(let name, let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Analysis failed")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ember)
                Text(verbatim: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(verbatim: message).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(L("Check that the file plays in another app, or choose another file."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .cancelled(let name):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Analysis cancelled")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(verbatim: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(L("Nothing was measured. Choose the file again to start over."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .done(let data):
            FileAnalysisSummary(data: data, standardID: $controller.standardID, custom: controller.custom)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch controller.state {
        case .analysing:
            Spacer()
            Button { controller.cancel() } label: { Label(L("Cancel"), systemImage: "xmark") }
                .keyboardShortcut(.cancelAction)
                .glassButton(prominent: false)
                .controlSize(.large)
        case .done:
            Button { controller.choose() } label: { Label(L("Analyze Another…"), systemImage: "waveform.badge.magnifyingglass") }
                .glassButton(prominent: false)
                .controlSize(.large)
                .disabled(export.saving)
            Spacer()
            if export.saving {
                ProgressView().controlSize(.small)
                Text(L("Saving…")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else if let saved = export.saved {
                Button { NSWorkspace.shared.activateFileViewerSelecting([saved]) } label: {
                    Label(L("Show in Finder"), systemImage: "folder")
                }
                .buttonStyle(.link)
                .help(saved.path)
            }
            Button { controller.save(csv: true) } label: { Label(L("Save CSV…"), systemImage: "tablecells") }
                .glassButton(prominent: false)
                .controlSize(.large)
                .disabled(export.saving)
            Button { controller.save(csv: false) } label: {
                Label(L("Save PDF Report…"), systemImage: "doc.richtext").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8)
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
            .controlSize(.large)
            .disabled(export.saving)
        case .idle, .failed, .cancelled:
            Button { controller.close() } label: { Label(L("Close"), systemImage: "xmark") }
                .keyboardShortcut(.cancelAction)
                .glassButton(prominent: false)
                .controlSize(.large)
            Spacer()
            Button { controller.choose() } label: {
                Label(L("Choose File…"), systemImage: "folder").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8)
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
            .controlSize(.large)
        }
    }
}

/// The finished analysis: verdict, the six headline readings and each report section's verdict.
private struct FileAnalysisSummary: View {
    let data: LoudnessReportData
    @Binding var standardID: String?
    let custom: (target: Double, ceiling: Double)
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: data.source).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: data.format + " · " + LoudnessReportData.duration(data.duration))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: data.result.headline).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(data.result.state == .check ? Theme.ember : Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(data.result.reasons, id: \.self) {
                        Text(verbatim: $0).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Picker(L("Standard"), selection: $standardID) {
                Text(verbatim: L("Custom") + " · \(MeterScale.signedTenths(Float(custom.target))) LUFS · \(MeterScale.tenths(Float(custom.ceiling))) dBTP")
                    .tag(String?.none)
                Divider()
                ForEach(LoudnessStandard.all) { standard in Text(verbatim: standard.title).tag(String?.some(standard.id)) }
            }
            .font(.system(size: 12))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    cell(L("INTEGRATED"), MeterScale.tenths(data.integrated, floor: -99), "LUFS")
                    cell(L("RANGE"), data.range < 0 ? "—" : MeterScale.tenths(data.range, floor: -1), "LU")
                    cell(L("TRUE PEAK"), data.truePeak > 0.05 ? MeterScale.signedTenths(data.truePeak) : MeterScale.tenths(data.truePeak, floor: -119), "dBTP")
                }
                GridRow {
                    cell(L("MAX MOMENTARY"), MeterScale.tenths(data.maxMomentary, floor: -99), "LUFS")
                    cell(L("MAX SHORT-TERM"), MeterScale.tenths(data.maxShortTerm, floor: -99), "LUFS")
                    cell(L("PEAK"), MeterScale.tenths(data.samplePeak, floor: -119), "dBFS")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: Theme.cardRadius - 4, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(data.check.sections) { section in
                    HStack {
                        Text(verbatim: section.title).font(.system(size: 12)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(verbatim: MasteringCheck.statusWord(section.worst)).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(section.worst == .check ? Theme.ember : (section.worst == .ok ? Theme.ink : Theme.secondary))
                    }
                    .padding(.vertical, 5)
                    if section.id != data.check.sections.last?.id { Divider().opacity(0.5) }
                }
            }
        }
    }

    private func cell(_ name: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value).font(.system(size: 17, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink)
                Text(verbatim: unit).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 150, alignment: .leading)
    }
}
