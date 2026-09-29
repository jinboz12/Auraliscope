// The Auraliscope Labs beta icon, derived from the release icon so the two read as one family:
// the same hexagon mark and glass body, the body turned from sage to slate indigo, and an ochre "LABS" ribbon
// across the lower-right corner. Usage: labs-icon <release 1024 png> <iconset dir> <preview png>
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(path)") }
    return image
}

func canvas(_ size: Int) -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

func write(_ image: CGImage, _ path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(path)") }
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fatalError("usage: labs-icon <release png> <iconset> <preview>") }
let release = load(arguments[1])
let size = release.width

// 1. Recolour: every saturated pixel (the sage body and its shading) is rotated to slate indigo; the white
//    rings are unsaturated and keep their colour.
let body = canvas(size)
body.draw(release, in: CGRect(x: 0, y: 0, width: size, height: size))
let pixels = body.data!.assumingMemoryBound(to: UInt8.self)
let hueShift: CGFloat = 135.0 / 360.0     // sage (≈ 80°) → slate indigo (≈ 215°)
for index in stride(from: 0, to: size * size * 4, by: 4) {
    let alpha = CGFloat(pixels[index + 3]) / 255
    guard alpha > 0 else { continue }
    let color = NSColor(srgbRed: CGFloat(pixels[index]) / 255 / alpha, green: CGFloat(pixels[index + 1]) / 255 / alpha,
                        blue: CGFloat(pixels[index + 2]) / 255 / alpha, alpha: 1)
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, a: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &a)
    guard saturation > 0.06 else { continue }
    let shifted = NSColor(hue: (hue + hueShift).truncatingRemainder(dividingBy: 1), saturation: min(1, saturation * 1.15),
                          brightness: brightness * 0.86, alpha: 1).usingColorSpace(.sRGB)!
    pixels[index] = UInt8(max(0, min(255, shifted.redComponent * 255 * alpha)))
    pixels[index + 1] = UInt8(max(0, min(255, shifted.greenComponent * 255 * alpha)))
    pixels[index + 2] = UInt8(max(0, min(255, shifted.blueComponent * 255 * alpha)))
}
let recoloured = body.makeImage()!

// 2. The ribbon, clipped to the icon's own shape so it follows the squircle.
let icon = canvas(size)
icon.draw(recoloured, in: CGRect(x: 0, y: 0, width: size, height: size))
icon.saveGState()
icon.clip(to: CGRect(x: 0, y: 0, width: size, height: size), mask: release)
let s = CGFloat(size)
icon.translateBy(x: s * 0.765, y: s * 0.235)   // centre of the band, bottom-right (CG origin is bottom-left)
icon.rotate(by: .pi / 4)
let band = CGRect(x: -s * 0.75, y: -s * 0.085, width: s * 1.5, height: s * 0.17)
icon.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.35).cgColor)
icon.setFillColor(CGColor(srgbRed: 0.867, green: 0.698, blue: 0.376, alpha: 1))   // Theme ochre
icon.fill(band)
icon.setShadow(offset: .zero, blur: 0, color: nil)
icon.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))              // glass highlight on its upper edge
icon.fill(CGRect(x: band.minX, y: band.maxY - s * 0.012, width: band.width, height: s * 0.012))
let font = NSFont.systemFont(ofSize: s * 0.092, weight: .heavy, width: .expanded)
let text = NSAttributedString(string: "LABS", attributes: [
    .font: font, .kern: s * 0.012,
    .foregroundColor: NSColor(srgbRed: 0.102, green: 0.110, blue: 0.125, alpha: 1),  // Theme ink (light)
])
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetImageBounds(line, icon)
icon.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
CTLineDraw(line, icon)
icon.restoreGState()
let labs = icon.makeImage()!
write(labs, arguments[3])

// 3. The iconset, on Apple's macOS grid (824 px body in a 1024 px canvas), as scripts/brand-assets.swift does.
try FileManager.default.createDirectory(atPath: arguments[2], withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixelsWide = points * scale
        let context = canvas(pixelsWide)
        let bodySize = Double(pixelsWide) * 824 / 1024, inset = (Double(pixelsWide) - bodySize) / 2
        context.draw(labs, in: CGRect(x: inset, y: inset, width: bodySize, height: bodySize))
        write(context.makeImage()!, "\(arguments[2])/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
    }
}
