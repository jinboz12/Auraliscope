// Renders the app icon set from the Icon Composer exports.
// Usage: swift scripts/brand-assets.swift <exports-dir> <iconset-dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(path)") }
    return image
}

func context(width: Int, height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

/// Bounding box of pixels with visible alpha, in CG (bottom-left origin) coordinates.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    let canvas = context(width: width, height: height)
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = canvas.data!.assumingMemoryBound(to: UInt8.self)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for row in 0..<height {
        for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 8 {
            minX = min(minX, column); maxX = max(maxX, column)
            minY = min(minY, row); maxY = max(maxY, row)
        }
    }
    // Bitmap rows run top-down; CG draws bottom-up.
    return CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func write(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(path)") }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: brand-assets.swift <exports> <iconset>") }
let (exports, iconset) = (arguments[1], arguments[2])
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// App icon: the Default export is full-bleed, so place it on Apple's macOS grid (an 824 px body centred
// in a 1024 px canvas) to sit at the same optical size as other Dock and Finder icons.
let icon = load("\(exports)/soundmeter-macOS-Default-1024@1x.png")
let gridBody = 824.0 / 1024.0
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let canvas = context(width: pixels, height: pixels)
        let body = Double(pixels) * gridBody
        let inset = (Double(pixels) - body) / 2
        canvas.draw(icon, in: CGRect(x: inset, y: inset, width: body, height: body))
        write(canvas.makeImage()!, to: "\(iconset)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
    }
}

print("icon body bounds (1024 canvas): \(opaqueBounds(icon))")
