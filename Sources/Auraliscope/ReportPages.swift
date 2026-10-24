import SwiftUI

// MARK: - Print style

/// Print colours and type shared by every page of the report: fixed, whatever the app's appearance or palette.
enum ReportInk {
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let quiet = Color(red: 0.40, green: 0.42, blue: 0.47)
    static let faint = Color(red: 0.62, green: 0.64, blue: 0.68)
    static let rule = Color(red: 0.86, green: 0.87, blue: 0.90)
    static let panel = Color(red: 0.965, green: 0.968, blue: 0.976)
    /// The main window’s muted steel-blue signal, fixed for predictable print contrast.
    static let signal = Color(red: 0.32, green: 0.42, blue: 0.55)
    static let accent = Color(red: 0.27, green: 0.45, blue: 0.39)
    static let note = Color(red: 0.46, green: 0.42, blue: 0.56)
    /// CHECK: the brand light's coral, deepened to read on paper.
    static let warn = Color(red: 0.72, green: 0.32, blue: 0.28)
    /// The night of the page's header band, as the app's dark window.
    static let night = Color(red: 0.075, green: 0.082, blue: 0.105)
    /// Radius of the page's cards (the app's 22-point cards at print scale).
    static let radius: CGFloat = Theme.cardRadius * 0.6
    static let inset: CGFloat = 10
    static let gap: CGFloat = 10

    static func color(_ status: MasteringCheck.Status) -> Color {
        switch status {
        case .ok: return accent
        case .note: return note
        case .check: return warn
        case .unavailable: return faint
        }
    }

    static func color(_ state: ComplianceResult.State) -> Color {
        switch state {
        case .pass: return accent
        case .check: return warn
        case .info: return note
        case .measuring: return quiet
        }
    }

    /// The app's eyebrow voice (SF Pro Expanded, semibold, uppercase, tracked), at print sizes.
    static func eyebrow(_ size: CGFloat = 7) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
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

/// An uppercase, tracked label in the eyebrow voice.
private struct PrintEyebrow: View {
    let text: String
    var size: CGFloat = 7
    var color: Color = ReportInk.quiet

    var body: some View {
        Text(verbatim: text.uppercased()).font(ReportInk.eyebrow(size)).tracking(0.9).foregroundStyle(color)
    }
}

/// A verdict as a small tinted pill: OK, NOTE, CHECK or —.
private struct StatusPill: View {
    let status: MasteringCheck.Status

    var body: some View {
        Text(verbatim: MasteringCheck.statusWord(status))
            .font(ReportInk.eyebrow(6.5)).tracking(0.6)
            .foregroundStyle(ReportInk.color(status))
            .frame(width: 40, height: 14)
            .background(Capsule().fill(ReportInk.color(status).opacity(0.12)))
    }
}

// MARK: - Page frame

/// Each page's ground, as the main window's: at the head a night band with the brand light (blue on the left, a
/// white-hot core, coral on the right) rising from its lower edge, then the light appearance's sky, steel blue thinning
/// to white toward the foot, with the window's fine film grain over both. Drawn pixel by pixel into one bitmap per kind
/// of page and kept as a JPEG, so every PDF viewer shows it alike and the file stays small.
enum ReportBackdrop {
    private static let stops: [(Double, SIMD3<Double>)] = [
        (0.00, SIMD3(0.30, 0.52, 0.97)), (0.26, SIMD3(0.58, 0.80, 1.00)), (0.50, SIMD3(1.00, 0.99, 1.00)),
        (0.74, SIMD3(1.00, 0.78, 0.75)), (1.00, SIMD3(0.98, 0.45, 0.42))]
    private static let night = SIMD3(0.075, 0.082, 0.105)
    /// The light sky from just under the band to the foot of the page (a little lighter than the window's, for print).
    private static let sky: [(Double, SIMD3<Double>)] = [
        (0.00, SIMD3(0.70, 0.745, 0.80)), (0.30, SIMD3(0.81, 0.835, 0.865)), (0.70, SIMD3(0.885, 0.895, 0.91)),
        (1.00, SIMD3(0.925, 0.925, 0.93))]
    private static var cache: [CGFloat: CGImage] = [:]

    /// Repeatable noise in 0…1 for a grain cell, so every export of a report looks the same.
    private static func noise(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double((h ^ (h >> 16)) & 0xFFFF) / 65_535
    }

    private static func ramp(_ stops: [(Double, SIMD3<Double>)], _ u: Double) -> SIMD3<Double> {
        for (lower, upper) in zip(stops, stops.dropFirst()) where u <= upper.0 {
            let t = (u - lower.0) / (upper.0 - lower.0)
            let s = t * t * (3 - 2 * t)
            return lower.1 + (upper.1 - lower.1) * s
        }
        return stops[stops.count - 1].1
    }

    /// The page's ground with a band `band` points tall (the first page's is taller).
    static func image(band: CGFloat) -> CGImage? {
        if let image = cache[band] { return image }
        let page = ReportPageFrame<EmptyView>.size
        let scale = 2.0
        let width = Int(page.width * scale), height = Int(page.height * scale)
        let bandRows = Double(band) * scale
        // How far up the band the light climbs, as a share of its height.
        let reach = band > 100 ? 0.5 : 0.62
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = Double(y)
            for x in 0..<width {
                let u = Double(x) / Double(width - 1)
                let side = abs(u - 0.5) * 2
                var c: SIMD3<Double>
                if row < bandRows {
                    // 0 at the band's lower edge (the horizon), 1 at the top.
                    let up = 1 - row / (bandRows - 1)
                    // The light is tallest at the core and spreads a little wider toward the sides, as in the brand image.
                    let d = up / (reach * (0.85 + 0.35 * side))
                    let light = exp(-d * d * 2.2) * (0.78 + 0.22 * exp(-side * side * 3)) * (1 - 0.18 * pow(side, 6))
                    let core = exp(-pow((u - 0.5) / 0.16, 2) - d * d * 6)
                    c = night * (1 - light) + ramp(stops, u) * light
                    c += (SIMD3(1, 1, 1) - c) * core * 0.75
                    // The window's grain, screened onto the night.
                    let grain = noise(x, y) * Grain.darkOpacity * 0.22
                    c = SIMD3(1, 1, 1) - (SIMD3(1, 1, 1) - c) * (1 - grain)
                } else {
                    let t = (row - bandRows) / (Double(height) - bandRows)
                    c = ramp(sky, t)
                    // The brand light spills a little below the horizon, so band and sky meet softly.
                    let below = (row - bandRows) / scale
                    let spill = exp(-pow(below / 22, 2)) * 0.55
                    c += (ramp(stops, u) - c) * spill
                    // A white bloom low in the page, as the light sky's horizon.
                    let bx = (u - 0.55) / 0.75, by = (row / Double(height) - 1.12) / 0.55
                    c += (SIMD3(1, 1, 1) - c) * exp(-(bx * bx + by * by) * 2.2) * 0.45
                    // Fine grain at print scale; full window opacity becomes coarse stippling on paper.
                    let grain = noise(x, y)
                    c *= 1 - Grain.lightOpacity * 0.22 * (1 - grain)
                }
                let i = (y * width + x) * 4
                pixels[i] = UInt8(max(0, min(255, c.x * 255)))
                pixels[i + 1] = UInt8(max(0, min(255, c.y * 255)))
                pixels[i + 2] = UInt8(max(0, min(255, c.z * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let raw = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // As a JPEG: the PDF carries it as it is, a fraction of the raw grain's size.
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return raw }
        CGImageDestinationAddImage(destination, raw, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let source = CGDataProvider(data: jpeg),
              let image = CGImage(jpegDataProviderSource: source, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return raw }
        cache[band] = image
        return image
    }
}

/// A frosted glass card on the page, as the window's panels: translucent white over the sky (which softens its grain),
/// a light rim and a soft shadow. Solid layers only: PDF viewers draw translucent gradients as hard bands.
struct ReportSurface: View {
    var radius: CGFloat = ReportInk.radius
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Color.white.opacity(0.46))
            .overlay { shape.strokeBorder(Color.white.opacity(0.9), lineWidth: 0.75) }
            .overlay { shape.inset(by: 0.75).strokeBorder(ReportInk.ink.opacity(0.05), lineWidth: 0.5) }
            .shadow(color: Color(red: 0.20, green: 0.25, blue: 0.35).opacity(0.12), radius: 8, y: 3)
    }
}

/// A recess in a card for a chart or a table, matching the light window’s plot wash.
struct ReportWell: View {
    var radius: CGFloat = Theme.wellRadius * 0.6
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.48))
    }
}

/// A section on its own card.
struct ReportCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(ReportInk.inset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background { ReportSurface() }
    }
}

/// Every page: the header band (the brand light rising under the logo, the wordmark and the report's name), the
/// content, and a footer with the build, the export time and the page number. A4 portrait; the page itself stays
/// white for print.
struct ReportPageFrame<Content: View>: View {
    let data: LoudnessReportData
    let page: Int
    let pages: Int
    @ViewBuilder let content: Content
    @ObservedObject private var l10n = Localizer.shared

    static var size: CGSize { CGSize(width: 595, height: 842) }
    /// The first page's band is taller: it carries the report's title.
    private var bandHeight: CGFloat { page == 1 ? 132 : 62 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            band
            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 22)
        }
        .foregroundStyle(ReportInk.ink)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background {
            if let ground = ReportBackdrop.image(band: bandHeight) {
                Image(decorative: ground, scale: 2).resizable().frame(width: Self.size.width, height: Self.size.height)
            } else {
                Color.white
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var band: some View {
        let size = CGSize(width: Self.size.width, height: bandHeight)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 8) {
                        BrandLogo(color: .white, height: 16)
                        Text(verbatim: "Auraliscope").foregroundColor(.white)
                            .font(.system(size: 13.5, weight: .semibold).width(.expanded))
                            .tracking(0.3)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        PrintEyebrow(text: L("Loudness & Master Report"), size: 6.5, color: .white.opacity(0.92))
                        if page > 1 {
                            Text(verbatim: data.source).font(.system(size: 7.5)).foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .trailing)
                        }
                    }
                }
                if page == 1 {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Loudness & Master Report")).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                        Text(verbatim: data.source).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, page == 1 ? 22 : 17)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Rectangle().fill(ReportInk.rule).frame(height: 0.5)
            HStack {
                Text(verbatim: data.version + "  ·  " + L("Generated %@", ReportFormat.dateTime(data.date)))
                Spacer()
                Text(verbatim: L("Page %d of %d", page, pages)).monospacedDigit()
            }
            .font(.system(size: 7.5))
            .foregroundStyle(ReportInk.quiet)
        }
    }
}

enum ReportFormat {
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func db(_ value: Float, floor: Float = -99) -> String { MeterScale.tenths(value, floor: floor) }
    static func peak(_ value: Float) -> String { value > 0.05 ? MeterScale.signedTenths(value) : MeterScale.tenths(value, floor: -119) }
}

// MARK: - Page 1: summary

/// The first page: what was measured, the verdict against the standard, the six headline readings, every section's
/// verdict and the loudness over the whole measurement.
struct LoudnessReportPage: View {
    let data: LoudnessReportData
    var pages = ReportPages.count
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        ReportPageFrame(data: data, page: 1, pages: pages) {
            VStack(alignment: .leading, spacing: ReportInk.gap) {
                details
                verdict
                metrics
                overview
                ReportCard { ReportLoudnessChart(data: data) }
            }
        }
    }

    private var standardName: String { data.standard?.title ?? L("Custom") }

    private var targetLine: String {
        let rule = data.standard?.rule ?? "±\(MeterScale.tenths(Float(LoudnessStandard.customTolerance))) LU"
        return "\(MeterScale.signedTenths(Float(data.target))) LUFS \(rule)"
    }

    /// Two columns of what was measured and against what.
    private var details: some View {
        let measured = data.fromFile ? L("Offline file analysis")
            : L("Live input, started %@", ReportFormat.dateTime(data.started))
        var duration = LoudnessReportData.duration(data.duration)
        if data.breaks > 0 {
            duration += "  ·  " + L("Interrupted %d× · %@ s missing", data.breaks, String(format: "%.1f", data.missingSeconds))
        }
        let left: [(String, String)] = [(L("Format"), data.format), (L("Duration"), duration), (L("Measured"), measured)]
        let right: [(String, String)] = [(L("Standard"), standardName), (L("Target"), targetLine),
                                         (L("Ceiling"), "\(MeterScale.tenths(Float(data.ceiling))) dBTP")]
        return HStack(alignment: .top, spacing: 20) {
            column(left)
            column(right)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ReportSurface() }
    }

    private func column(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PrintEyebrow(text: row.0, size: 6.5).frame(width: 62, alignment: .leading)
                    Text(verbatim: row.1).font(.system(size: 9.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdict: some View {
        let color = ReportInk.color(data.result.state)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                PrintEyebrow(text: L("Delivery verdict"), size: 6.5)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(verbatim: data.result.headline)
                        .font(.system(size: 20, weight: .medium)).monospacedDigit()
                        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .frame(width: 150, alignment: .leading)
            Rectangle().fill(ReportInk.rule).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: standardName).font(.system(size: 10.5, weight: .semibold))
                ForEach(data.result.reasons, id: \.self) {
                    Text(verbatim: $0).font(.system(size: 9.5)).foregroundStyle(ReportInk.quiet)
                }
                if data.standard?.dialogue == true {
                    Text(L("This specification measures dialogue loudness. The meter reads the full programme (BS.1770 gating), which can read louder when music and effects outweigh speech."))
                        .font(.system(size: 7.5)).foregroundStyle(ReportInk.quiet).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(minHeight: 66, alignment: .leading)
        .background { ReportSurface() }
    }

    /// Six recessed readouts, using the main window’s panel and plot hierarchy.
    private var metrics: some View {
        let plr = data.truePeak - data.integrated
        let cells: [(String, String, String, String)] = [
            (L("INTEGRATED"), ReportFormat.db(data.integrated), "LUFS", L("Target %@", MeterScale.signedTenths(Float(data.target)))),
            (L("TRUE PEAK"), ReportFormat.peak(data.truePeak), "dBTP", L("Ceiling %@", MeterScale.tenths(Float(data.ceiling)))),
            (L("RANGE"), data.range < 0 ? "—" : ReportFormat.db(data.range, floor: -1), "LU", "EBU Tech 3342"),
            (L("MAX SHORT-TERM"), ReportFormat.db(data.maxShortTerm), "LUFS", L("3 s window")),
            (L("MAX MOMENTARY"), ReportFormat.db(data.maxMomentary), "LUFS", L("400 ms window")),
            (L("PEAK"), ReportFormat.db(data.samplePeak, floor: -119), "dBFS",
             data.integrated > -70 ? L("PLR %@ LU", MeterScale.tenths(plr)) : L("Sample peak"))
        ]
        return VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { column in
                        metric(cells[row * 3 + column])
                            .background { ReportWell() }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ReportInk.inset)
        .background { ReportSurface() }
    }

    private func metric(_ cell: (String, String, String, String)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            PrintEyebrow(text: cell.0, size: 6.5)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: cell.1).font(.system(size: 22, weight: .regular)).monospacedDigit()
                Text(verbatim: cell.2).font(.system(size: 8, weight: .medium)).foregroundStyle(ReportInk.quiet)
            }
            Text(verbatim: cell.3).font(.system(size: 7.5)).foregroundStyle(ReportInk.faint)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every section of the master check with its worst verdict.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            PrintEyebrow(text: L("Master check"))
            HStack(spacing: 6) {
                ForEach(data.check.sections) { section in
                    let status = section.worst
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: section.title).font(.system(size: 8, weight: .medium)).foregroundStyle(ReportInk.ink)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        StatusPill(status: status)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                    .background { ReportSurface(radius: ReportInk.radius - 2) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Short-term over momentary across the whole measurement, with the target's tolerance band, a time axis and a key.
private struct ReportLoudnessChart: View {
    let data: LoudnessReportData
    @ObservedObject private var l10n = Localizer.shared

    private var tolerance: Float {
        switch data.standard?.kind ?? .delivery(tolerance: LoudnessStandard.customTolerance) {
        case .delivery(let value): return Float(value)
        default: return 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                PrintEyebrow(text: L("LOUDNESS OVER TIME"))
                Text(verbatim: "LUFS").font(.system(size: 7)).foregroundStyle(ReportInk.faint)
                Spacer()
                key(L("Short-term"), line: ReportInk.signal, width: 1.6)
                key(L("Momentary"), line: ReportInk.faint, width: 0.8)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(ReportInk.signal.opacity(0.14)).frame(width: 12, height: 7)
                    Text(verbatim: L("Target")).font(.system(size: 7.5)).foregroundStyle(ReportInk.quiet)
                }
            }
            Canvas { context, size in draw(context, size) }
                .frame(height: 160)
                .padding(8)
                .background { ReportWell() }
        }
    }

    private func key(_ name: String, line: Color, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(line).frame(width: 12, height: width)
            Text(verbatim: name).font(.system(size: 7.5)).foregroundStyle(ReportInk.quiet)
        }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let plot = CGRect(x: 30, y: 4, width: size.width - 34, height: size.height - 20)
        let target = Float(data.target)
        let low = min((target - 24) / 6 * 6, -42), high: Float = 0
        func y(_ lufs: Float) -> CGFloat { plot.maxY - CGFloat(max(0, min(1, (lufs - low) / (high - low)))) * plot.height }
        context.stroke(Path(roundedRect: plot, cornerRadius: 6), with: .color(ReportInk.rule), lineWidth: 0.5)
        context.fill(Path(CGRect(x: plot.minX, y: y(target + tolerance), width: plot.width,
                                 height: max(1, y(target - tolerance) - y(target + tolerance)))), with: .color(ReportInk.signal.opacity(0.10)))
        context.fill(Path(CGRect(x: plot.minX, y: y(target) - 0.25, width: plot.width, height: 0.5)), with: .color(ReportInk.signal.opacity(0.55)))
        for lufs in stride(from: high, through: low, by: -6) {
            if lufs < high && lufs > low {
                context.fill(Path(CGRect(x: plot.minX, y: y(lufs), width: plot.width, height: 0.4)), with: .color(ReportInk.rule))
            }
            context.draw(Text(verbatim: MeterScale.signedInteger(lufs)).font(.system(size: 6.5).monospacedDigit()).foregroundColor(ReportInk.quiet),
                         at: CGPoint(x: plot.minX - 4, y: y(lufs)), anchor: .trailing)
        }
        // Time axis: whole steps that give at most seven gridlines.
        let duration = max(data.duration, 1)
        let step = [5.0, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200].first { duration / $0 <= 7 } ?? 14_400
        var t = 0.0
        while t <= duration + 0.001 {
            let x = plot.minX + CGFloat(t / duration) * plot.width
            if t > 0 && t < duration - step * 0.3 {
                context.fill(Path(CGRect(x: x, y: plot.minY, width: 0.4, height: plot.height)), with: .color(ReportInk.rule))
            }
            if t < duration - step * 0.3 || t == 0 {
                context.draw(Text(verbatim: LoudnessReportData.duration(t)).font(.system(size: 6.5).monospacedDigit()).foregroundColor(ReportInk.quiet),
                             at: CGPoint(x: x, y: plot.maxY + 8), anchor: t == 0 ? .leading : .center)
            }
            t += step
        }
        context.draw(Text(verbatim: LoudnessReportData.duration(duration)).font(.system(size: 6.5).monospacedDigit()).foregroundColor(ReportInk.quiet),
                     at: CGPoint(x: plot.maxX, y: plot.maxY + 8), anchor: .trailing)
        func path(_ values: [Float]) -> Path {
            var path = Path()
            let stepX = plot.width / CGFloat(max(1, values.count - 1))
            var drawing = false
            for (index, value) in values.enumerated() {
                guard value > low - 6 else { drawing = false; continue }
                let point = CGPoint(x: plot.minX + CGFloat(index) * stepX, y: y(value))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            return path
        }
        var clipped = context
        clipped.clip(to: Path(roundedRect: plot, cornerRadius: 6))
        clipped.stroke(path(data.momentary), with: .color(ReportInk.faint.opacity(0.8)), lineWidth: 0.6)
        clipped.stroke(path(data.short), with: .color(ReportInk.signal), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
    }
}

// MARK: - Detail pages

/// The pages of the report, in order.
enum ReportPages {
    static let count = 4

    static func pages(_ data: LoudnessReportData) -> [AnyView] {
        [AnyView(LoudnessReportPage(data: data)),
         AnyView(ReportDetailPage(data: data, page: 2)),
         AnyView(ReportDetailPage(data: data, page: 3)),
         AnyView(ReportDetailPage(data: data, page: 4))]
    }
}

/// Pages two to four: the master check's sections as tables (loudness, dynamics and stereo image; the average spectrum
/// with tonal balance and bandwidth; integrity, then how to read the report).
struct ReportDetailPage: View {
    let data: LoudnessReportData
    let page: Int
    @ObservedObject private var l10n = Localizer.shared

    private func section(_ title: String) -> MasteringCheck.Section? { data.check.sections.first { $0.title == title } }

    var body: some View {
        ReportPageFrame(data: data, page: page, pages: ReportPages.count) {
            // A language whose notes run longer than English sets the page's tables tighter rather than off the page.
            ViewThatFits(in: .vertical) {
                tables
                tables.environment(\.reportDensity, 1)
                tables.environment(\.reportDensity, 2)
            }
        }
    }

    private var tables: some View {
        VStack(alignment: .leading, spacing: ReportInk.gap) {
            switch page {
            case 2:
                if let loudness = data.check.sections.first { ReportCard { ReportTable(section: loudness) } }
                if let dynamics = section(L("Dynamics")) { ReportCard { ReportTable(section: dynamics) } }
                if let image = section(L("Stereo image")) { ReportCard { ReportTable(section: image) } }
            case 3:
                ReportCard { ReportSpectrum(check: data.check) }
                if let tonal = section(L("Tonal balance")) { ReportCard { ReportTable(section: tonal) } }
                if let bandwidth = section(L("Bandwidth")) { ReportCard { ReportTable(section: bandwidth) } }
            default:
                if let integrity = section(L("Signal integrity")) { ReportCard { ReportTable(section: integrity) } }
                ReportCard { about }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            PrintEyebrow(text: L("HOW TO READ THIS REPORT"), color: ReportInk.ink)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    legend(.ok, L("Meets the rule beside it."))
                    legend(.note, L("Worth a listen: outside what most finished masters show, which can be intended."))
                    legend(.check, L("Needs attention before delivery."))
                    Text(L("Loudness and true peak are judged against the chosen standard; every other rule is mastering guidance, not a specification."))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(data.fromFile
                         ? L("All readings cover the whole file. Tonal balance, bandwidth and stereo image use the meter's spectrum (128 bands, about 1/13 octave) and its five stereo bands, averaged in power over the moments with sound. DC offset and the energy below 20 Hz come from a signal-health meter in the analysis: each channel's 1 s mean, and a fourth-order 20 Hz low-pass after the drift is removed.")
                         : L("All readings cover the whole measurement since the last reset. Tonal balance, bandwidth and stereo image use the meter's live spectrum (128 bands, about 1/13 octave) and its five stereo bands, averaged in power over the moments with sound. DC offset and the energy below 20 Hz come from a signal-health meter in the analysis: each channel's 1 s mean, and a fourth-order 20 Hz low-pass after the drift is removed."))
                    Text(L("Integrated loudness and loudness range use the BS.1770 and Tech 3342 gates; true peak is 4× oversampled at 48 kHz. The meter passes the synthetic cases of EBU Tech 3341 (1–6) and Tech 3342 (1–4)."))
                    if data.fromFile {
                        Text(L("Measured offline from the whole file at its own sample rate, with the same analysis and 10 Hz readings as live metering."))
                    }
                    Text(verbatim: "ITU-R BS.1770-5 · EBU R128 · EBU Tech 3341 / 3342").foregroundStyle(ReportInk.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 7.5))
            .foregroundStyle(ReportInk.quiet)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background { ReportWell() }
        }
    }

    private func legend(_ status: MasteringCheck.Status, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusPill(status: status)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The average spectrum on a log axis, the band shares under it, resonances and any steep high-frequency loss marked.
private struct ReportSpectrum: View {
    let check: MasteringCheck
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PrintEyebrow(text: L("AVERAGE SPECTRUM"), size: 8, color: ReportInk.ink)
                Text(verbatim: "dBFS").font(.system(size: 7)).foregroundStyle(ReportInk.faint)
                Spacer()
                if let tilt = check.tilt {
                    Text(verbatim: L("Tilt %@", String(format: "%+.1f dB/oct", tilt).replacingOccurrences(of: "-", with: "−")))
                        .font(.system(size: 7.5).monospacedDigit()).foregroundStyle(ReportInk.quiet)
                }
            }
            Canvas { context, size in draw(context, size) }
                .frame(height: 150)
                .padding(8)
                .background { ReportWell() }
            PrintEyebrow(text: L("ENERGY BY BAND, AGAINST THE WHOLE"), size: 6.5).padding(.top, 2)
            HStack(spacing: 0) {
                ForEach(Array(check.bands.enumerated()), id: \.offset) { index, band in
                    if index > 0 { Rectangle().fill(ReportInk.rule).frame(width: 0.5) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: band.name).font(.system(size: 7.5, weight: .medium)).foregroundStyle(ReportInk.quiet)
                        Text(verbatim: MeterScale.signedTenths(band.relative) + " dB").font(.system(size: 11, weight: .medium).monospacedDigit())
                        Text(verbatim: "\(MasteringCheck.hertz(band.range.lowerBound))–\(MasteringCheck.hertz(band.range.upperBound))")
                            .font(.system(size: 6.5)).foregroundStyle(ReportInk.faint)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background { ReportWell() }
        }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let plot = CGRect(x: 30, y: 6, width: size.width - 34, height: size.height - 22)
        context.stroke(Path(roundedRect: plot, cornerRadius: 6), with: .color(ReportInk.rule), lineWidth: 0.5)
        guard !check.spectrum.isEmpty else {
            context.draw(Text(L("Nothing measured yet.")).font(.system(size: 8)).foregroundColor(ReportInk.quiet),
                         at: CGPoint(x: plot.midX, y: plot.midY))
            return
        }
        let upper = check.spectrumUpper
        let top = ((check.spectrum.max() ?? 0) / 6).rounded(.up) * 6 + 6, bottom = top - 72
        func x(_ f: Double) -> CGFloat { plot.minX + CGFloat(log(f / 20) / log(upper / 20)) * plot.width }
        func y(_ db: Float) -> CGFloat { plot.maxY - CGFloat(max(0, min(1, (db - bottom) / (top - bottom)))) * plot.height }
        for f in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] where f < upper * 0.98 {
            context.fill(Path(CGRect(x: x(f), y: plot.minY, width: 0.4, height: plot.height)), with: .color(ReportInk.rule))
        }
        for f in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] where f <= upper {
            context.draw(Text(verbatim: f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))").font(.system(size: 6.5).monospacedDigit()).foregroundColor(ReportInk.quiet),
                         at: CGPoint(x: x(f), y: plot.maxY + 8), anchor: f == 20 ? .leading : (f >= upper * 0.98 ? .trailing : .center))
        }
        for db in stride(from: top, through: bottom, by: -12) {
            if db < top && db > bottom {
                context.fill(Path(CGRect(x: plot.minX, y: y(db), width: plot.width, height: 0.4)), with: .color(ReportInk.rule))
            }
            context.draw(Text(verbatim: MeterScale.signedInteger(db)).font(.system(size: 6.5).monospacedDigit()).foregroundColor(ReportInk.quiet),
                         at: CGPoint(x: plot.minX - 4, y: y(db)), anchor: .trailing)
        }
        context.draw(Text(verbatim: "Hz").font(.system(size: 6)).foregroundColor(ReportInk.faint),
                     at: CGPoint(x: plot.maxX, y: plot.maxY + 16), anchor: .trailing)
        var clipped = context
        clipped.clip(to: Path(roundedRect: plot, cornerRadius: 6))
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
        clipped.fill(fill, with: .color(ReportInk.signal.opacity(0.10)))
        clipped.stroke(path, with: .color(ReportInk.signal), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        if let cutoff = check.cutoff {
            clipped.fill(Path(CGRect(x: x(cutoff) - 0.5, y: plot.minY, width: 1, height: plot.height)), with: .color(ReportInk.warn))
            context.draw(Text(verbatim: MasteringCheck.hertz(cutoff)).font(.system(size: 6.5, weight: .semibold)).foregroundColor(ReportInk.warn),
                         at: CGPoint(x: x(cutoff) - 3, y: plot.minY + 7), anchor: .trailing)
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
}

/// One section of the master check as a ruled table: verdict, measure, value and the guideline it was judged against.
private struct ReportDensityKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    /// How tightly the report's tables are set (`ReportDetailPage`): 0 as designed, 1 with rows a little closer, 2 with
    /// rows closer still and notes a little smaller.
    var reportDensity: Int {
        get { self[ReportDensityKey.self] }
        set { self[ReportDensityKey.self] = newValue }
    }
}

struct ReportTable: View {
    let section: MasteringCheck.Section
    @ObservedObject private var l10n = Localizer.shared
    @Environment(\.reportDensity) private var density

    private static let status: CGFloat = 44, name: CGFloat = 116, value: CGFloat = 106

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PrintEyebrow(text: section.title, size: 8, color: ReportInk.ink)
                Spacer()
                StatusPill(status: section.worst)
            }
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    PrintEyebrow(text: L("Status"), size: 5.5, color: ReportInk.faint).frame(width: Self.status, alignment: .leading)
                    PrintEyebrow(text: L("Measure"), size: 5.5, color: ReportInk.faint).frame(width: Self.name, alignment: .leading)
                    PrintEyebrow(text: L("Value"), size: 5.5, color: ReportInk.faint).frame(width: Self.value, alignment: .leading)
                    PrintEyebrow(text: L("Guideline"), size: 5.5, color: ReportInk.faint).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
                ForEach(section.items) { item in
                    Rectangle().fill(ReportInk.rule).frame(height: 0.5)
                    HStack(alignment: .top, spacing: 10) {
                        StatusPill(status: item.status).frame(width: Self.status, alignment: .leading)
                        Text(verbatim: item.name).font(.system(size: 9, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true).frame(width: Self.name, alignment: .leading)
                        Text(verbatim: item.value).font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(item.status == .unavailable ? ReportInk.faint : ReportInk.ink)
                            .fixedSize(horizontal: false, vertical: true).frame(width: Self.value, alignment: .leading)
                        Text(verbatim: item.note).font(.system(size: density > 1 ? 7 : 7.5)).foregroundStyle(ReportInk.quiet)
                            .lineSpacing(density > 1 ? 0.5 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, [6, 4.5, 3.5][min(2, density)])
                }
                Rectangle().fill(ReportInk.rule).frame(height: 0.5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { ReportWell() }
            .padding(.top, 6)
        }
    }
}
