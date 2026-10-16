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
            title: L("Loudness Report"), date: Date(), started: log.started, duration: log.seconds, source: source,
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
            "# source,\(source.replacingOccurrences(of: ",", with: " "))", "# format,\(format)",
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

/// The printed report: one A4 page in fixed print colours, whatever the app's appearance.
struct LoudnessReportPage: View {
    let data: LoudnessReportData
    @ObservedObject private var l10n = Localizer.shared
    static let size = CGSize(width: 595, height: 842)

    private let ink = Color(red: 0.10, green: 0.11, blue: 0.13)
    private let quiet = Color(red: 0.42, green: 0.44, blue: 0.48)
    private let rule = Color(red: 0.86, green: 0.87, blue: 0.89)
    private let accent = Color(red: 0.26, green: 0.53, blue: 0.43)
    private let warn = Color(red: 0.78, green: 0.52, blue: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: data.title).font(.system(size: 22, weight: .semibold))
                Spacer()
                Text(data.date, style: .date).font(.system(size: 10)).foregroundStyle(quiet)
                Text(data.date, style: .time).font(.system(size: 10)).foregroundStyle(quiet)
            }
            VStack(alignment: .leading, spacing: 4) {
                field(L("Source"), data.source)
                field(L("Format"), data.format)
                field(L("Standard"), standardLine)
                field(L("Overs"), data.overs == 0 ? L("None above 0 dBTP") : L("%d above 0 dBTP", data.overs))
                field(L("Duration"), LoudnessReportData.duration(data.duration) + (data.breaks > 0
                      ? "  ·  " + L("Interrupted %d× · %@ s missing", data.breaks, String(format: "%.1f", data.missingSeconds)) : ""))
            }
            verdict
            ReportSummary(check: data.check)
            grid
            chart
            if let loudness = data.check.sections.first { ReportTable(section: loudness) }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Rectangle().fill(rule).frame(height: 0.5)
                Text(verbatim: data.version + " · ITU-R BS.1770-5 · EBU R128 · EBU Tech 3341 / 3342 · 1 / 3")
                Text(L("Integrated loudness and loudness range use the BS.1770 and Tech 3342 gates; true peak is 4× oversampled at 48 kHz. The meter passes the synthetic cases of EBU Tech 3341 (1–6) and Tech 3342 (1–4)."))
                if data.standard?.dialogue == true {
                    Text(L("This specification measures dialogue loudness. The meter reads the full programme (BS.1770 gating), which can read louder when music and effects outweigh speech."))
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(quiet)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(ink)
        .padding(44)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var standardLine: String {
        guard let standard = data.standard else {
            return L("Custom") + " · \(MeterScale.signedTenths(Float(data.target))) LUFS · \(MeterScale.tenths(Float(data.ceiling))) dBTP"
        }
        return "\(standard.title) · \(MeterScale.signedTenths(Float(standard.target))) LUFS \(standard.rule) · \(MeterScale.tenths(Float(standard.ceiling))) dBTP"
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(quiet)
                .frame(width: 70, alignment: .leading)
            Text(verbatim: value).font(.system(size: 10.5))
        }
    }

    private var verdict: some View {
        let color: Color = switch data.result.state {
        case .pass: accent
        case .check: warn
        default: ink
        }
        return HStack(alignment: .center, spacing: 14) {
            Text(verbatim: data.result.headline).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(data.result.reasons, id: \.self) { Text(verbatim: $0).font(.system(size: 10)) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var grid: some View {
        func value(_ number: Float, floor: Float = -99) -> String { MeterScale.tenths(number, floor: floor) }
        let cells: [(String, String, String)] = [
            (L("INTEGRATED"), value(data.integrated), "LUFS"),
            (L("RANGE"), data.range < 0 ? "—" : value(data.range, floor: -1), "LU"),
            (L("TRUE PEAK"), data.truePeak > 0.05 ? MeterScale.signedTenths(data.truePeak) : value(data.truePeak, floor: -119), "dBTP"),
            (L("MAX MOMENTARY"), value(data.maxMomentary), "LUFS"),
            (L("MAX SHORT-TERM"), value(data.maxShortTerm), "LUFS"),
            (L("PEAK"), value(data.samplePeak, floor: -119), "dBFS")
        ]
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let cell = cells[row * 3 + column]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cell.0).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(quiet)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(verbatim: cell.1).font(.system(size: 18, weight: .medium)).monospacedDigit()
                                Text(verbatim: cell.2).font(.system(size: 8, weight: .medium)).foregroundStyle(quiet)
                            }
                        }
                        .frame(width: 150, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Short-term (accent) over momentary (grey) across the whole session, with the target's tolerance band.
    private var chart: some View {
        let target = Float(data.target)
        let tolerance: Float = {
            if case .delivery(let value) = data.standard?.kind ?? .delivery(tolerance: LoudnessStandard.customTolerance) { return Float(value) }
            return 1
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("LOUDNESS OVER TIME")).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(quiet)
            Canvas { context, size in
                let plot = CGRect(x: 28, y: 4, width: size.width - 32, height: size.height - 22)
                let low = min(target - 18, MeterScale.loudnessFloor), high: Float = 0
                func y(_ lufs: Float) -> CGFloat { plot.maxY - CGFloat(max(0, min(1, (lufs - low) / (high - low)))) * plot.height }
                context.fill(Path(CGRect(x: plot.minX, y: y(target + tolerance), width: plot.width,
                                         height: max(1, y(target - tolerance) - y(target + tolerance)))), with: .color(accent.opacity(0.12)))
                for lufs in stride(from: Float(0), through: low, by: -6) {
                    context.fill(Path(CGRect(x: plot.minX, y: y(lufs), width: plot.width, height: 0.5)), with: .color(rule))
                    context.draw(Text(verbatim: MeterScale.signedInteger(lufs)).font(.system(size: 7)).foregroundColor(quiet),
                                 at: CGPoint(x: plot.minX - 4, y: y(lufs)), anchor: .trailing)
                }
                func path(_ values: [Float]) -> Path {
                    var path = Path()
                    let step = plot.width / CGFloat(max(1, values.count - 1))
                    var drawing = false
                    for (index, value) in values.enumerated() {
                        guard value > low - 6 else { drawing = false; continue }
                        let point = CGPoint(x: plot.minX + CGFloat(index) * step, y: y(value))
                        if drawing { path.addLine(to: point) } else { path.move(to: point) }
                        drawing = true
                    }
                    return path
                }
                context.stroke(path(data.momentary), with: .color(quiet.opacity(0.45)), lineWidth: 0.7)
                context.stroke(path(data.short), with: .color(accent), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                context.draw(Text(verbatim: "0:00").font(.system(size: 7)).foregroundColor(quiet), at: CGPoint(x: plot.minX, y: plot.maxY + 9), anchor: .leading)
                context.draw(Text(verbatim: LoudnessReportData.duration(data.duration)).font(.system(size: 7)).foregroundColor(quiet),
                             at: CGPoint(x: plot.maxX, y: plot.maxY + 9), anchor: .trailing)
            }
            .frame(height: 140)
        }
    }
}

/// Meter ▸ Export Loudness Report…: a save panel, then the PDF page or the CSV readings.
@MainActor
enum LoudnessReportExport {
    static func export(model: MeterModel, csv: Bool) {
        let data = LoudnessReportData.gather(model: model)
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = L("Loudness Report") + " " + stamp.string(from: data.date) + (csv ? ".csv" : ".pdf")
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
        var box = CGRect(origin: .zero, size: LoudnessReportPage.size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        let pages: [AnyView] = [AnyView(LoudnessReportPage(data: data)),
                                AnyView(ReportDetailPage(data: data, page: 2)),
                                AnyView(ReportDetailPage(data: data, page: 3))]
        for page in pages {
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(LoudnessReportPage.size)
            context.beginPDFPage(nil)
            renderer.render { _, draw in draw(context) }
            context.endPDFPage()
        }
        context.closePDF()
    }
}

// MARK: - The master check pages

/// Print colours shared by every page of the report.
enum ReportInk {
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let quiet = Color(red: 0.42, green: 0.44, blue: 0.48)
    static let rule = Color(red: 0.86, green: 0.87, blue: 0.89)
    static let accent = Color(red: 0.26, green: 0.53, blue: 0.43)
    static let note = Color(red: 0.36, green: 0.45, blue: 0.62)
    static let warn = Color(red: 0.78, green: 0.52, blue: 0.12)

    static func color(_ status: MasteringCheck.Status) -> Color {
        switch status {
        case .ok: return accent
        case .note: return note
        case .check: return warn
        case .unavailable: return quiet
        }
    }
}

extension MasteringCheck {
    static func statusWord(_ status: Status) -> String {
        switch status {
        case .ok: return L("OK")
        case .note: return L("NOTE")
        case .check: return L("CHECK")
        case .unavailable: return "—"
        }
    }
}

/// One line per section with its worst verdict, under the loudness verdict on the first page.
struct ReportSummary: View {
    let check: MasteringCheck

    var body: some View {
        HStack(spacing: 6) {
            ForEach(check.sections) { section in
                let status = section.worst
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title.uppercased()).font(.system(size: 6.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(ReportInk.quiet).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: MasteringCheck.statusWord(status)).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ReportInk.color(status))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(ReportInk.color(status).opacity(0.08)))
            }
        }
    }
}

/// Pages two and three: the master check's sections as tables, with the average spectrum on page two.
struct ReportDetailPage: View {
    let data: LoudnessReportData
    let page: Int
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let sections = data.check.sections
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: data.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: data.source).font(.system(size: 9)).foregroundStyle(ReportInk.quiet)
            }
            if page == 2 {
                if let dynamics = sections.first(where: { $0.title == L("Dynamics") }) { table(dynamics) }
                spectrumChart
                if let tonal = sections.first(where: { $0.title == L("Tonal balance") }) { table(tonal) }
            } else {
                ForEach(sections.filter { [L("Bandwidth"), L("Stereo image"), L("Signal integrity")].contains($0.title) }) { table($0) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("HOW TO READ THIS REPORT")).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(ReportInk.quiet)
                    Text(L("OK meets the rule beside it. NOTE is worth a listen: the reading is outside what most finished masters show, which can be intended. CHECK needs attention before delivery. Loudness and true peak are judged against the chosen standard; every other rule is mastering guidance, not a specification."))
                    Text(L("All readings cover the whole measurement since the last reset. Tonal balance, bandwidth and stereo image use the meter's live spectrum (128 bands, about 1/13 octave) and its five stereo bands, averaged in power over the moments with sound. DC offset and the energy below 20 Hz come from a signal-health meter in the analysis: each channel's 1 s mean, and a fourth-order 20 Hz low-pass after the drift is removed."))
                }
                .font(.system(size: 9))
                .foregroundStyle(ReportInk.ink)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Rectangle().fill(ReportInk.rule).frame(height: 0.5)
            Text(verbatim: data.version + " · \(page) / 3").font(.system(size: 8)).foregroundStyle(ReportInk.quiet)
        }
        .foregroundStyle(ReportInk.ink)
        .padding(44)
        .frame(width: LoudnessReportPage.size.width, height: LoudnessReportPage.size.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func table(_ section: MasteringCheck.Section) -> some View { ReportTable(section: section) }

    /// The session's average spectrum on a log axis, with the band shares under it and resonances marked.
    private var spectrumChart: some View {
        let check = data.check
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("AVERAGE SPECTRUM")).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(ReportInk.quiet)
            Canvas { context, size in
                let plot = CGRect(x: 30, y: 4, width: size.width - 34, height: size.height - 20)
                guard !check.spectrum.isEmpty else { return }
                let upper = check.spectrumUpper
                let top = (check.spectrum.max() ?? 0).rounded(.up) + 3, bottom = top - 66
                func x(_ f: Double) -> CGFloat { plot.minX + CGFloat(log(f / 20) / log(upper / 20)) * plot.width }
                func y(_ db: Float) -> CGFloat { plot.maxY - CGFloat(max(0, min(1, (db - bottom) / (top - bottom)))) * plot.height }
                for f in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] where f <= upper {
                    context.fill(Path(CGRect(x: x(f), y: plot.minY, width: 0.5, height: plot.height)), with: .color(ReportInk.rule))
                    context.draw(Text(verbatim: f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))").font(.system(size: 6.5)).foregroundColor(ReportInk.quiet),
                                 at: CGPoint(x: x(f), y: plot.maxY + 8), anchor: .center)
                }
                for db in stride(from: top - 6, through: bottom, by: -12) {
                    context.fill(Path(CGRect(x: plot.minX, y: y(db), width: plot.width, height: 0.5)), with: .color(ReportInk.rule))
                    context.draw(Text(verbatim: MeterScale.signedInteger(db)).font(.system(size: 6.5)).foregroundColor(ReportInk.quiet),
                                 at: CGPoint(x: plot.minX - 4, y: y(db)), anchor: .trailing)
                }
                var path = Path()
                for (band, level) in check.spectrum.enumerated() {
                    let f = 20 * pow(upper / 20, (Double(band) + 0.5) / Double(check.spectrum.count))
                    let point = CGPoint(x: x(f), y: y(level))
                    if band == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                var fill = path
                fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                fill.closeSubpath()
                context.fill(fill, with: .color(ReportInk.accent.opacity(0.10)))
                context.stroke(path, with: .color(ReportInk.accent), lineWidth: 1.2)
                if let cutoff = check.cutoff {
                    context.fill(Path(CGRect(x: x(cutoff), y: plot.minY, width: 1, height: plot.height)), with: .color(ReportInk.warn))
                }
                for resonance in check.resonances.prefix(3) {
                    let px = x(resonance.frequency)
                    let band = Int((log(resonance.frequency / 20) / log(upper / 20) * Double(check.spectrum.count) - 0.5).rounded())
                    let py = y(check.spectrum[max(0, min(check.spectrum.count - 1, band))]) - 6
                    context.fill(Path(ellipseIn: CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)), with: .color(ReportInk.warn))
                    context.draw(Text(verbatim: MasteringCheck.hertz(resonance.frequency)).font(.system(size: 6.5, weight: .semibold))
                                    .foregroundColor(ReportInk.warn), at: CGPoint(x: px, y: py - 8), anchor: .center)
                }
            }
            .frame(height: 150)
            Text(L("ENERGY BY BAND, AGAINST THE WHOLE")).font(.system(size: 8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(ReportInk.quiet).padding(.top, 4)
            HStack(spacing: 6) {
                ForEach(check.bands, id: \.name) { band in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(band.name.uppercased()).font(.system(size: 6.5, weight: .semibold)).tracking(0.6).foregroundStyle(ReportInk.quiet)
                        Text(verbatim: MeterScale.signedTenths(band.relative) + " dB").font(.system(size: 10, weight: .medium).monospacedDigit())
                        Text(verbatim: "\(MasteringCheck.hertz(band.range.lowerBound))–\(MasteringCheck.hertz(band.range.upperBound))")
                            .font(.system(size: 6.5)).foregroundStyle(ReportInk.quiet)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// One section of the master check as a table: verdict, name, value and what it means.
struct ReportTable: View {
    let section: MasteringCheck.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(section.title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8)
                Spacer()
                Text(verbatim: MasteringCheck.statusWord(section.worst)).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ReportInk.color(section.worst))
            }
            .padding(.bottom, 6)
            ForEach(section.items) { item in
                VStack(spacing: 0) {
                    Rectangle().fill(ReportInk.rule).frame(height: 0.75)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HStack(spacing: 4) {
                            Circle().fill(ReportInk.color(item.status)).frame(width: 5, height: 5)
                            Text(verbatim: MasteringCheck.statusWord(item.status)).font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(ReportInk.color(item.status))
                        }
                        .frame(width: 46, alignment: .leading)
                        Text(verbatim: item.name).font(.system(size: 9.5, weight: .semibold)).frame(width: 128, alignment: .leading)
                        Text(verbatim: item.value).font(.system(size: 9.5).monospacedDigit()).frame(width: 100, alignment: .leading)
                        Text(verbatim: item.note).font(.system(size: 8)).foregroundStyle(ReportInk.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

}
