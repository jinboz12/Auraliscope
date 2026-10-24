import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole measurement since the last reset, at the readouts' 10 Hz: momentary and short-term loudness, and the
/// maxima a report states. Kept apart from the published readouts, so the 10 Hz updates never compare or copy it.
@MainActor
final class SessionLog {
    /// Readings per second.
    nonisolated static let rate = 10.0
    /// A day at 10 Hz; older readings leave from the front.
    nonisolated static let capacity = Int(24 * 3600 * rate)

    private(set) var momentary: [Float] = []
    private(set) var shortTerm: [Float] = []
    private(set) var maxMomentary: Float = -100
    private(set) var maxShortTerm: Float = -100
    private(set) var started = Date()
    /// Everything the master check needs, reduced as the session runs.
    private(set) var statistics = SessionStatistics()

    var seconds: Double { Double(shortTerm.count) / Self.rate }

    func add(_ sample: SessionSample) {
        statistics.add(sample)
    }

    func reset() {
        statistics = SessionStatistics()
        momentary.removeAll(keepingCapacity: true)
        shortTerm.removeAll(keepingCapacity: true)
        maxMomentary = -100
        maxShortTerm = -100
        started = Date()
    }

    func append(momentary m: Float, shortTerm s: Float) {
        if shortTerm.isEmpty { started = Date() }
        momentary.append(m)
        shortTerm.append(s)
        maxMomentary = max(maxMomentary, m)
        maxShortTerm = max(maxShortTerm, s)
        if shortTerm.count > Self.capacity {
            momentary.removeFirst(shortTerm.count - Self.capacity)
            shortTerm.removeFirst(shortTerm.count - Self.capacity)
        }
    }

    /// The last `seconds` (all of it when nil) in at most `points` buckets, each the loudest reading in it, so short
    /// peaks survive the reduction. Oldest first.
    func window(seconds: Double?, points: Int) -> (short: [Float], momentary: [Float]) {
        Self.window(short: shortTerm, momentary: momentary, seconds: seconds, points: points)
    }

    nonisolated static func window(short shortTerm: [Float], momentary: [Float], seconds: Double?,
                                   points: Int) -> (short: [Float], momentary: [Float]) {
        let wanted = seconds.map { Int($0 * Self.rate) } ?? shortTerm.count
        let start = max(0, shortTerm.count - wanted)
        let count = shortTerm.count - start
        guard count > 0 else { return ([], []) }
        let buckets = min(points, count)
        var short = [Float](repeating: -100, count: buckets), moment = [Float](repeating: -100, count: buckets)
        for index in 0..<count {
            let bucket = index * buckets / count
            short[bucket] = max(short[bucket], shortTerm[start + index])
            moment[bucket] = max(moment[bucket], momentary[start + index])
        }
        return (short, moment)
    }
}

// MARK: - Report

/// Everything a loudness report states, gathered at the moment of export.
struct LoudnessReportData {
    var title: String
    var date: Date
    var started: Date
    var duration: TimeInterval
    var source: String
    var format: String
    var standard: LoudnessStandard?
    var target: Double
    var ceiling: Double
    var integrated: Float
    var range: Float
    var truePeak: Float
    var samplePeak: Float
    var maxMomentary: Float
    var maxShortTerm: Float
    var breaks: Int
    var missingSeconds: Double
    /// Separate overs above 0 dBTP.
    var overs: Int
    var result: ComplianceResult
    var short: [Float]
    var momentary: [Float]
    var fullShort: [Float]
    var fullMomentary: [Float]
    var version: String
    /// Dynamics, tonal balance, bandwidth, stereo image and integrity, from the whole session.
    var check: MasteringCheck
    /// Measured offline from a file rather than live.
    var fromFile = false

    @MainActor
    static func gather(model: MeterModel) -> LoudnessReportData {
        let values = model.readouts.values
        let log = model.readouts.session
        let window = log.window(seconds: nil, points: 600)
        let standard = model.loudnessStandard
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(AppName.full) \(info["AuraliscopeVersionLabel"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "") "
            + L("build %@", info["CFBundleVersion"] as? String ?? "")
        let device = model.selectedDevice
        var source = Diagnostics.demo ? L("Demo signal") : (device?.name ?? "—")
        if !Diagnostics.demo, let detail = device?.detail, !detail.isEmpty { source += " · " + detail }
        return LoudnessReportData(
            title: L("Loudness & Master Report"), date: Date(), started: log.started, duration: log.seconds, source: source,
            format: model.format == .spatial ? model.shownLayoutName : model.format.title, standard: standard,
            target: model.loudnessTarget, ceiling: model.truePeakCeiling, integrated: values.integrated, range: values.range,
            truePeak: values.truePeakDecibels, samplePeak: MeterScale.decibels(values.maxPeak),
            maxMomentary: log.maxMomentary, maxShortTerm: log.maxShortTerm,
            breaks: model.measurementBreaks, missingSeconds: model.missingSeconds, overs: values.overs,
            result: ComplianceResult.evaluate(standard: standard, target: model.loudnessTarget, ceiling: model.truePeakCeiling,
                                              integrated: values.integrated, truePeak: values.truePeakDecibels,
                                              elapsed: max(values.elapsed, log.seconds)),
            short: window.short, momentary: window.momentary, fullShort: log.shortTerm, fullMomentary: log.momentary,
            version: version,
            check: MasteringCheck(statistics: log.statistics, integrated: values.integrated, range: values.range,
                                  truePeak: values.truePeakDecibels, samplePeak: MeterScale.decibels(values.maxPeak),
                                  overs: values.overs, breaks: model.measurementBreaks, missingSeconds: model.missingSeconds,
                                  dropped: model.droppedFrames, ceiling: model.truePeakCeiling, stereo: model.format == .stereo))
    }

    /// A whole file measured offline (Meter ▸ Analyze Audio File…), judged against `standard`, or against `target`
    /// and `ceiling` set by hand when it is nil.
    static func gather(file m: FileMeasurement, standard: LoudnessStandard?, target: Double, ceiling: Double) -> LoudnessReportData {
        let window = SessionLog.window(short: m.shortTerm, momentary: m.momentary, seconds: nil, points: 600)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(AppName.full) \(info["AuraliscopeVersionLabel"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "") "
            + L("build %@", info["CFBundleVersion"] as? String ?? "")
        let duration = m.info.duration
        return LoudnessReportData(
            title: L("Loudness & Master Report"), date: Date(), started: Date(), duration: duration, source: m.info.name,
            format: m.info.formatLine, standard: standard, target: target, ceiling: ceiling,
            integrated: m.integrated, range: m.range, truePeak: m.truePeak, samplePeak: m.samplePeak,
            maxMomentary: m.maxMomentary, maxShortTerm: m.maxShortTerm, breaks: 0, missingSeconds: 0, overs: m.overs,
            result: ComplianceResult.evaluate(standard: standard, target: target, ceiling: ceiling,
                                              integrated: m.integrated, truePeak: m.truePeak, elapsed: duration),
            short: window.short, momentary: window.momentary, fullShort: m.shortTerm, fullMomentary: m.momentary,
            version: version,
            check: MasteringCheck(statistics: m.statistics, integrated: m.integrated, range: m.range, truePeak: m.truePeak,
                                  samplePeak: m.samplePeak, overs: m.overs, breaks: 0, missingSeconds: 0, dropped: 0,
                                  ceiling: ceiling, stereo: m.info.channels == 2),
            fromFile: true)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The readings as CSV: a commented summary, then one row per tenth of a second.
    var csv: String {
        let formatter = ISO8601DateFormatter()
        func number(_ value: Float, floor: Float = -99) -> String { value > floor ? String(format: "%.1f", value) : "" }
        var lines = [
            "# \(title)", "# \(version)", "# exported,\(formatter.string(from: date))", "# started,\(formatter.string(from: started))",
            "# source,\(source.replacingOccurrences(of: ",", with: " "))", "# format,\(format.replacingOccurrences(of: ",", with: " "))",
            "# measured,\(fromFile ? "file" : "live")",
            "# standard,\((standard?.title ?? L("Custom")).replacingOccurrences(of: ",", with: " "))",
            "# target_lufs,\(String(format: "%.1f", target))", "# ceiling_dbtp,\(String(format: "%.1f", ceiling))",
            "# integrated_lufs,\(number(integrated))", "# loudness_range_lu,\(range < 0 ? "" : String(format: "%.1f", range))",
            "# max_true_peak_dbtp,\(number(truePeak, floor: -119))", "# max_sample_peak_dbfs,\(number(samplePeak, floor: -119))",
            "# max_momentary_lufs,\(number(maxMomentary))", "# max_short_term_lufs,\(number(maxShortTerm))",
            "# duration_s,\(String(format: "%.1f", duration))", "# interruptions,\(breaks)", "# overs_above_0_dbtp,\(overs)",
            "# verdict,\(result.headline)"
        ]
        for section in check.sections {
            for item in section.items {
                lines.append("# check,\(section.title.replacingOccurrences(of: ",", with: " ")),\(item.name.replacingOccurrences(of: ",", with: " ")),"
                             + "\(item.value.replacingOccurrences(of: ",", with: " ")),\(MasteringCheck.statusWord(item.status))")
            }
        }
        if !check.spectrum.isEmpty {
            lines.append("# average_spectrum_hz_dbfs")
            for (band, level) in check.spectrum.enumerated() {
                let frequency = 20 * pow(check.spectrumUpper / 20, (Double(band) + 0.5) / Double(check.spectrum.count))
                lines.append("# spectrum,\(String(format: "%.1f", frequency)),\(String(format: "%.1f", level))")
            }
        }
        lines.append("time_s,momentary_lufs,short_term_lufs")
        for index in fullShort.indices {
            lines.append(String(format: "%.1f", Double(index) / SessionLog.rate) + ",\(number(fullMomentary[index])),\(number(fullShort[index]))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Meter ▸ Export Loudness Report…: a save panel, then the PDF page or the CSV readings.
@MainActor
enum LoudnessReportExport {
    static func export(model: MeterModel, csv: Bool) {
        let data = LoudnessReportData.gather(model: model)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        save(data, csv: csv, baseName: L("Loudness Report") + " " + stamp.string(from: data.date))
    }

    static func save(_ data: LoudnessReportData, csv: Bool, baseName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + (csv ? ".csv" : ".pdf")
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv {
                try data.csv.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try writePDF(data, to: url)
            }
            DiagnosticLog.event(csv ? "Report: CSV exported" : "Report: PDF exported")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func writePDF(_ data: LoudnessReportData, to url: URL) throws {
        let size = ReportPageFrame<EmptyView>.size
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [kCGPDFContextTitle: "\(data.title) – \(data.source)", kCGPDFContextCreator: data.version]
        info[kCGPDFContextSubject] = data.format
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        for page in ReportPages.pages(data) {
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(size)
            context.beginPDFPage(nil)
            renderer.render { _, draw in draw(context) }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
