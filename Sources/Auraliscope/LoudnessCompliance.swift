import SwiftUI

/// The summary's compliance reading, in the third place of the tiles' second row: the standard in use, its verdict and
/// what decided it. The colours follow the meter's: the accent for a pass, ochre for anything to check.
struct ComplianceTile: View {
    @ObservedObject var readouts: Readouts
    let standard: LoudnessStandard?
    let target: Double
    let ceiling: Double
    var scale: CGFloat = 1
    @ObservedObject private var l10n = Localizer.shared

    var body: some View {
        let values = readouts.values
        let result = ComplianceResult.evaluate(standard: standard, target: target, ceiling: ceiling, integrated: values.integrated,
                                               truePeak: values.truePeakDecibels, elapsed: values.elapsed)
        let color: Color = switch result.state {
        case .pass: Theme.sage
        case .check: Theme.ochre
        case .info: Theme.ink
        case .measuring: Theme.tertiary
        }
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 6) {
                Eyebrow(standard.map { $0.shortTitle.uppercased() } ?? L("CUSTOM"), color: Theme.tertiary)
                    .lineLimit(1)
                if standard?.dialogue == true {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if result.state == .pass || result.state == .check {
                    Image(systemName: result.state == .pass ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12 * scale, weight: .semibold))
                }
                Text(verbatim: result.headline)
                    .font(.system(size: (result.state == .measuring ? 13 : 17) * scale, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help(result))
        .accessibilityElement(children: .combine)
        .accessibilityValue(result.reasons.joined(separator: ". "))
    }

    private func help(_ result: ComplianceResult) -> String {
        var lines = [standard.map { "\($0.title) · \(MeterScale.signedTenths(Float($0.target))) LUFS \($0.rule) · \(MeterScale.tenths(Float($0.ceiling))) dBTP" }
                     ?? L("Custom target, judged within ±%@ LU", MeterScale.tenths(Float(LoudnessStandard.customTolerance)))]
        lines += result.reasons
        if standard?.dialogue == true {
            lines.append(L("This specification measures dialogue loudness. The meter reads the full programme (BS.1770 gating), which can read louder when music and effects outweigh speech."))
        }
        lines.append(L("Judged on integrated loudness and the highest true peak since the last reset."))
        return lines.joined(separator: "\n")
    }
}
