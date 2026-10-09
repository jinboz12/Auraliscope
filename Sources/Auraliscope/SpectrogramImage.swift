import AnalysisCore
import AppKit
import UniformTypeIdentifiers

/// The spectrogram as a still image, for the Spectrum well's context menu (Copy, Save): the columns on screen, from
/// the float history at full resolution (one pixel row per analysis row, each analysis column at least two pixels
/// wide and the plot at least `minimumPlotWidth`), in the current colour map, colour range and tilt, with a caption,
/// a colour scale and frequency and time axes. Newest at the right whatever the panel's orientation, as a
/// spectrogram is conventionally read on paper.
enum SpectrogramImage {
    static let minimumPlotWidth = 900
    static let left = 46, bottom = 22, top = 44, right = 12

    /// `columns` analysis columns ending at the newest, or nil when nothing has been recorded.
    static func make(history: SpectrogramHistory, columns requested: Int, sampleRate: Double, options: DisplayOptions,
                     caption: String) -> CGImage? {
        let columns = min(requested, history.count)
        guard columns > 1 else { return nil }
        let rows = SpectrogramHistory.rows
        let columnWidth = max(2, (minimumPlotWidth + columns - 1) / columns)
        let plotWidth = columns * columnWidth
        let width = left + plotWidth + right, height = top + rows + bottom
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let background = Theme.displayRGB
        context.setFillColor(CGColor(srgbRed: CGFloat(background.r), green: CGFloat(background.g), blue: CGFloat(background.b), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // The plot, written pixel by pixel. CoreGraphics' origin is bottom-left, so row 0 (20 Hz) is at `bottom`.
        let upper = MeterScale.upperFrequency(sampleRate: sampleRate)
        let tilt = (0..<rows).map { options.tilt.offset(frequency: 20 * pow(upper / 20, (Double($0) + 0.5) / Double(rows))) }
        var pixels = [UInt8](repeating: 255, count: plotWidth * rows * 4)
        // A small lookup of the ramp keeps this to one table read per pixel.
        let steps = 1024
        let ramp = (0...steps).map { Theme.ramp(position: Float($0) / Float(steps), colors: options.spectrogramColors) }
        for column in 0..<columns {
            let age = Double(columns - 1 - column)
            for row in 0..<rows {
                let level = (history.level(age: age, row: Double(row)) ?? SpectrogramHistory.silence) + tilt[row]
                let color = ramp[Int(SpectrogramTone.position(level, range: options.spectrogramRange) * Float(steps))]
                let y = rows - 1 - row
                for dx in 0..<columnWidth {
                    let offset = (y * plotWidth + column * columnWidth + dx) * 4
                    pixels[offset] = UInt8(max(0, min(255, color.r * 255)))
                    pixels[offset + 1] = UInt8(max(0, min(255, color.g * 255)))
                    pixels[offset + 2] = UInt8(max(0, min(255, color.b * 255)))
                }
            }
        }
        if let provider = CGDataProvider(data: Data(pixels) as CFData),
           let plot = CGImage(width: plotWidth, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: plotWidth * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            context.draw(plot, in: CGRect(x: left, y: bottom, width: plotWidth, height: rows))
        }

        // Axes and caption, drawn with AppKit text in the image's own context.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        let ink = Theme.inkRGB
        let faint = NSColor(srgbRed: CGFloat(ink.r), green: CGFloat(ink.g), blue: CGFloat(ink.b), alpha: 0.55)
        let strong = NSColor(srgbRed: CGFloat(ink.r), green: CGFloat(ink.g), blue: CGFloat(ink.b), alpha: 0.9)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        func text(_ string: String, at point: CGPoint, color: NSColor, align: NSTextAlignment) {
            let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let size = attributed.size()
            let x = align == .right ? point.x - size.width : align == .center ? point.x - size.width / 2 : point.x
            attributed.draw(at: CGPoint(x: x, y: point.y - size.height / 2))
        }
        context.setLineWidth(1)
        for (frequency, label) in SpectrogramLayout.frequencyMarks where frequency < upper {
            let y = CGFloat(bottom) + CGFloat(log(frequency / 20) / log(upper / 20)) * CGFloat(rows)
            context.setStrokeColor(faint.withAlphaComponent(0.25).cgColor)
            context.stroke(CGRect(x: CGFloat(left), y: y.rounded() + 0.5, width: CGFloat(plotWidth), height: 0).insetBy(dx: 0, dy: 0))
            text(label, at: CGPoint(x: CGFloat(left - 6), y: y), color: [100.0, 1_000, 10_000].contains(frequency) ? strong : faint, align: .right)
        }
        text(upper >= 1_000 ? "\(Int((upper / 1_000).rounded()))k" : "\(Int(upper))", at: CGPoint(x: CGFloat(left - 6), y: CGFloat(bottom + rows - 6)),
             color: faint, align: .right)
        let seconds = Double(columns) / SpectrogramLayout.analysisRate
        let step = seconds > 10 ? 2 : 1
        for second in stride(from: 0, through: Int(seconds), by: step) {
            let x = CGFloat(left + plotWidth) - CGFloat(Double(second) * SpectrogramLayout.analysisRate) * CGFloat(columnWidth)
            guard x >= CGFloat(left) else { continue }
            context.setStrokeColor(faint.withAlphaComponent(0.6).cgColor)
            context.stroke(CGRect(x: x.rounded() - 0.5, y: CGFloat(bottom - 4), width: 0, height: 4))
            text(second == 0 ? L("now") : "−\(second) s", at: CGPoint(x: x, y: CGFloat(bottom) / 2 - 2), color: faint,
                 align: second == 0 ? .right : .center)
        }
        text(caption, at: CGPoint(x: CGFloat(left), y: CGFloat(height - 13)), color: strong, align: .left)
        // The colour scale under the caption: the range's floor and ceiling either side of the map, as in the header.
        let range = options.spectrogramRange
        let scaleY = CGFloat(height - 32), barWidth: CGFloat = 160
        text(MeterScale.signedInteger(range.floor), at: CGPoint(x: CGFloat(left), y: scaleY), color: faint, align: .left)
        let barX = CGFloat(left) + 30
        for x in 0..<Int(barWidth) {
            let level = range.floor + (range.ceiling - range.floor) * Float(x) / Float(barWidth - 1)
            let color = ramp[Int(SpectrogramTone.position(level, range: range) * Float(steps))]
            context.setFillColor(color.cgColor())
            context.fill(CGRect(x: barX + CGFloat(x), y: scaleY - 3, width: 1, height: 6))
        }
        var scale = MeterScale.signedInteger(range.ceiling) + " dBFS"
        if options.tilt != .flat { scale += " · +" + options.tilt.title }
        text(scale, at: CGPoint(x: barX + barWidth + 6, y: scaleY), color: faint, align: .left)
        return context.makeImage()
    }

    /// The caption: what was analysed and how, the scale and when.
    static func caption(source: String, sampleRate: Double, options: DisplayOptions) -> String {
        let range = options.spectrogramRange
        var parts = ["Auraliscope LABS", L("Spectrogram"), source, SpectrogramResolution.range(sampleRate: sampleRate),
                     "\(MeterScale.signedInteger(range.floor))…\(MeterScale.signedInteger(range.ceiling)) dBFS"]
        if options.tilt != .flat { parts.append("+" + options.tilt.title) }
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        parts.append(date)
        return parts.joined(separator: " · ")
    }

    static func copy(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    @MainActor
    static func save(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "Spectrogram \(stamp.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
