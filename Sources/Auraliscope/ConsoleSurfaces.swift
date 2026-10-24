import SwiftUI

/// Opaque metal for the optional console theme. All decoration stays behind the existing panel contents;
/// the same corner radii, insets and controls keep the meter's geometry and interaction unchanged.
struct ConsoleCardSurface: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(LinearGradient(stops: [
            .init(color: Theme.style.card.mixed(with: Theme.RGB(hex: 0xFFFFFF), amount: Theme.dark ? 0.12 : 0.18).color, location: 0),
            .init(color: Theme.cardTint, location: 0.12),
            .init(color: Theme.cardTint, location: 0.82),
            .init(color: Theme.style.card.scaled(Theme.dark ? 0.88 : 0.96).color, location: 1)
        ], startPoint: .top, endPoint: .bottom))
        .overlay { ConsoleBrushing().clipShape(shape) }
        .overlay {
            shape.gradientBorder(LinearGradient(colors: [
                .white.opacity(Theme.dark ? 0.38 : 0.95),
                .black.opacity(Theme.dark ? 0.35 : 0.10),
                .black.opacity(Theme.dark ? 0.65 : 0.22)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        }
        .overlay {
            shape.inset(by: 3).gradientBorder(LinearGradient(colors: [
                .black.opacity(Theme.dark ? 0.28 : 0.10), .white.opacity(Theme.dark ? 0.06 : 0.45)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
        .overlay { ConsoleFasteners().clipShape(shape) }
        .shadow(color: .black.opacity(Theme.dark ? 0.46 : 0.24), radius: 2, x: 0, y: 3)
        .shadow(color: .black.opacity(Theme.dark ? 0.20 : 0.08), radius: 7, x: 0, y: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small slotted fasteners in the existing empty corner margins. Pure background decoration, never a control.
private struct ConsoleFasteners: View {
    var body: some View {
        Canvas { context, size in
            guard size.width > 100, size.height > 70 else { return }
            let inset: CGFloat = 10.5
            for center in [CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset, y: inset),
                           CGPoint(x: inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset)] {
                let collar = Path(ellipseIn: CGRect(x: center.x - 3.1, y: center.y - 3.1, width: 6.2, height: 6.2))
                let head = Path(ellipseIn: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4))
                context.fill(collar, with: .color(.black.opacity(Theme.dark ? 0.55 : 0.25)))
                context.fill(head, with: .linearGradient(Gradient(colors: [
                    .white.opacity(Theme.dark ? 0.42 : 0.86), .gray.opacity(0.28)
                ]), startPoint: CGPoint(x: center.x - 2, y: center.y - 2), endPoint: CGPoint(x: center.x + 2, y: center.y + 2)))
                var slot = Path()
                slot.move(to: CGPoint(x: center.x - 1.3, y: center.y + 0.8))
                slot.addLine(to: CGPoint(x: center.x + 1.3, y: center.y - 0.8))
                context.stroke(slot, with: .color(.black.opacity(0.72)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The same button bounds and glyph, now carried by a raised keycap with a shaded sidewall and machined rim.
struct ConsoleDiscSurface: View {
    let face: Color
    let pressed: Bool
    let hovering: Bool
    let illuminated: Bool

    var body: some View {
        Circle().fill(.black.opacity(Theme.dark ? 0.7 : 0.25))
            .overlay {
                Circle().inset(by: 1).fill(face)
                    .overlay {
                        Circle().inset(by: 1).fill(LinearGradient(stops: [
                            .init(color: .white.opacity(pressed ? 0.0 : (hovering && !illuminated ? 0.20 : 0.12)), location: 0),
                            .init(color: .clear, location: 0.30),
                            .init(color: .clear, location: 0.70),
                            .init(color: .black.opacity(pressed ? 0.08 : 0.25), location: 1)
                        ], startPoint: pressed ? .bottom : .top, endPoint: pressed ? .top : .bottom))
                    }
                    .overlay {
                        Circle().inset(by: 1).gradientBorder(LinearGradient(colors: [
                            .white.opacity(pressed ? 0.10 : 0.55), .black.opacity(pressed ? 0.60 : 0.40)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }
                    .offset(y: pressed ? 0.5 : -0.5)
            }
            .shadow(color: .black.opacity(pressed ? 0.0 : (Theme.dark ? 0.55 : 0.22)), radius: 1, x: 0, y: 1.5)
            .shadow(color: illuminated ? Theme.litHalo : .clear, radius: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A warm backlit paper face behind the existing VU drawing. No scale or needle geometry is changed.
struct ConsoleVUDialSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous)
        shape.fill(LinearGradient(colors: [Theme.RGB(hex: 0xCFC3A5).color, Theme.RGB(hex: 0xEFE3C7).color,
                                          Theme.RGB(hex: 0xE3D6B7).color], startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.gradientBorder(LinearGradient(colors: [.black.opacity(0.70), .black.opacity(0.22),
                                                              .white.opacity(0.65)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
            }
            .overlay {
                shape.inset(by: 2).gradientBorder(LinearGradient(colors: [.black.opacity(0.14), .clear, .white.opacity(0.40)],
                                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension Theme {
    static var vuInkRGB: RGB { isConsole ? RGB(hex: 0x30332E) : inkRGB }
    static var vuInk: Color { vuInkRGB.color }
    static var vuSecondary: Color { isConsole ? vuInk.opacity(0.82) : tertiary }
    static var vuEmber: Color { isConsole ? emberRGB.legible(on: RGB(hex: 0xCFC3A5), ratio: 4.5).color : ember }
}

/// Fine, static horizontal machining marks, with no animation, timer or audio dependencies.
private struct ConsoleBrushing: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for y in stride(from: CGFloat(1), to: size.height, by: 3) {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.white.opacity(Theme.dark ? 0.018 : 0.055)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A neutral console chassis replaces the sky only while Studio Console is selected.
struct ConsoleBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Theme.windowTop, Theme.windowBottom], startPoint: .top, endPoint: .bottom)
            .overlay { ConsoleBrushing() }
            .overlay {
                LinearGradient(colors: [.white.opacity(Theme.dark ? 0.035 : 0.16), .clear, .black.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .allowsHitTesting(false)
    }
}
