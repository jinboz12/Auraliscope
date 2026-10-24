import AppKit
import SwiftUI

/// The two supplied images are bundled verbatim. They are decoded once and only drawn as static backgrounds;
/// none of this artwork receives input or changes the measurement views' opacity.
enum ThemeArtwork {
    static let pearl = image("IconPearl")
    static let milkFrog = image("MilkFrog")

    private static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ThemeAssets") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// P1's actual blue / pearl-white / rose light, held beneath the existing readable glass surfaces.
struct PearlBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (Theme.dark ? Theme.RGB(hex: 0x101216) : Theme.RGB(hex: 0xE9ECF3)).color
                if let image = ThemeArtwork.pearl {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .saturation(Theme.dark ? 0.55 : 1)
                        .opacity(Theme.dark ? 0.23 : 0.17)
                }
                LinearGradient(colors: [.black.opacity(Theme.dark ? 0.14 : 0), .clear,
                                        Theme.dark ? .black.opacity(0.28) : .white.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                Image(nsImage: Grain.tile).resizable(resizingMode: .tile)
                    .opacity(Theme.dark ? 0.035 : 0.045)
                    .blendMode(Theme.dark ? .screen : .multiply)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Frog green, buttery light, and the user's original photograph. The original
/// white background is blended and softly faded at display time; the source pixels and character are untouched.
struct MilkFrogBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height * 1.3
            ZStack {
                (Theme.dark ? Theme.RGB(hex: 0x151A10) : Theme.RGB(hex: 0xF4F0DB)).color
                RadialGradient(colors: [Theme.sage.opacity(Theme.dark ? 0.18 : 0.13), .clear],
                               center: .topLeading, startRadius: 0, endRadius: proxy.size.width * 0.8)
                RadialGradient(colors: [Theme.sand.opacity(Theme.dark ? 0.22 : 0.18), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: proxy.size.width * 0.7)
                if let image = ThemeArtwork.milkFrog {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .frame(width: height * 0.642, height: height)
                        .mask {
                            // Fade to zero on all four image edges; a radial fade alone leaves a rectangular seam.
                            Rectangle().fill(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                                    .init(color: .white, location: 0.20),
                                                                    .init(color: .white, location: 0.80),
                                                                    .init(color: .clear, location: 1)],
                                                            startPoint: .leading, endPoint: .trailing))
                                .mask {
                                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                                           .init(color: .white, location: 0.22),
                                                           .init(color: .white, location: 0.88),
                                                           .init(color: .clear, location: 1)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                        }
                        .blendMode(Theme.dark ? .normal : .multiply)
                        .opacity(Theme.dark ? 0.46 : 0.90)
                        .position(x: proxy.size.width * 0.82, y: proxy.size.height * 0.47)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
