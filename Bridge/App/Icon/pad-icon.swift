// pad.swift <dir>: redraws every PNG in <dir> on Apple's pre-26 macOS grid (824 px body in a 1024 px canvas), in place.
import CoreGraphics
import Foundation
import ImageIO

let dir = CommandLine.arguments[1]
for name in try FileManager.default.contentsOfDirectory(atPath: dir) where name.hasSuffix(".png") {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let size = image.width
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let body = Double(size) * 824 / 1024, inset = (Double(size) - body) / 2
    context.draw(image, in: CGRect(x: inset, y: inset, width: body, height: body))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
