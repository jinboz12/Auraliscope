import SwiftUI

/// The Auraliscope logo from `SoundmeterIcon/soundmeter Exports/soundmeter logo.png`, drawn as vectors so it
/// stays sharp at every size: a heavy hexagon ring with a lighter hexagon ring set inside its right half.
///
/// Geometry is measured from the 5000 px master, in units of the large ring's circumradius R (526 px there):
/// the large ring's inner radius is 0.749 R; the small ring is centred 0.4725 R right of the large one, with
/// radii 0.402 R and 0.275 R. Both hexagons have a vertex pointing left and right. The small ring's hole
/// meets the large ring's inner edge at one corner, exactly as in the artwork.
struct BrandLogo: View {
    var color: Color = Theme.ink
    /// Height in points; the width follows the artwork's 2 : √3 aspect.
    let height: CGFloat

    static let aspect: CGFloat = 2 / sqrt(3)

    var body: some View {
        Canvas { context, size in
            let radius = size.height / sqrt(3)
            let center = CGPoint(x: radius, y: size.height / 2)
            var large = Path()
            large.addPath(Self.hexagon(center: center, radius: radius))
            large.addPath(Self.hexagon(center: center, radius: radius * 0.749))
            context.fill(large, with: .color(color), style: FillStyle(eoFill: true))
            let smallCenter = CGPoint(x: center.x + radius * 0.4725, y: center.y)
            var small = Path()
            small.addPath(Self.hexagon(center: smallCenter, radius: radius * 0.402))
            small.addPath(Self.hexagon(center: smallCenter, radius: radius * 0.275))
            // The master tints the small ring a shade warmer than the large one.
            context.fill(small, with: .color(color.opacity(0.94)), style: FillStyle(eoFill: true))
        }
        .frame(width: height * Self.aspect, height: height)
        .accessibilityHidden(true)
    }

    private static func hexagon(center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            for corner in 0..<6 {
                let angle = CGFloat(corner) * .pi / 3
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

/// The name this build shows: Auraliscope (the 2.0 beta, with the DAW Bridge).
enum AppName {
    static let full = "Auraliscope"
}

/// Logo plus "AURALISCOPE" in the heading voice (SF Pro Expanded, semibold, uppercase, tracked). Every window
/// that names the app uses this one mark, scaled by `size` (the wordmark's point size).
struct BrandMark: View {
    var size: CGFloat = 13
    var color: Color = Theme.ink
    /// False where the app icon already stands beside the title (About).
    var showsLogo = true

    var body: some View {
        HStack(spacing: size * 0.62) {
            if showsLogo { BrandLogo(color: color, height: (size * 1.55).rounded()) }
            // Title case, as the app's name appears everywhere else on the system. Lowercase letters read
            // smaller than capitals at one point size, so the name is set a little larger, with the light
            // tracking that mixed case wants (the wide spacing suited the former all-caps wordmark).
            Text(verbatim: "Auraliscope").foregroundColor(color)
                .font(.wordmark(size * 1.18))
                .tracking(Tracking.wordmark(size: size * 1.18))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppName.full))
        .accessibilityAddTraits(.isHeader)
    }
}
