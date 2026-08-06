// Builds a macOS AppIcon set from a square source image.
//
// The source is an opaque PNG whose rounded-square artwork floats on black.
// Left as-is the Dock would render a black square, so this crops to the
// artwork, re-masks the corners with a transparent rounded rect, and seats it
// on Apple's icon grid (824pt of art in a 1024pt canvas, with the shadow the
// Dock expects).

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: makeicon <source.png> <appiconset dir>\n".utf8))
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2])

guard let data = try? Data(contentsOf: sourceURL),
      let provider = CGDataProvider(data: data as CFData),
      let source = CGImage(
        pngDataProviderSource: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
else {
    FileHandle.standardError.write(Data("could not read \(sourceURL.path)\n".utf8))
    exit(1)
}

// MARK: Find the artwork inside the black field

/// Tightest box containing anything brighter than near-black. The artwork's
/// outer rim is a light grey, so this lands on the rounded square rather than
/// on the letterboxing around it.
func artworkBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &pixels,
        width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return CGRect(x: 0, y: 0, width: w, height: h) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    let threshold = 14
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            // Alpha-weighted: a transparent pixel is not artwork.
            guard pixels[i + 3] > 8 else { continue }
            let luma = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            guard luma > threshold else { continue }
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
    // Square it off around the centre so the rounded mask stays circularly
    // symmetric — the detected box can be a pixel or two off square.
    let side = max(maxX - minX + 1, maxY - minY + 1)
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    let originX = max(0, min(w - side, cx - side / 2))
    let originY = max(0, min(h - side, cy - side / 2))
    return CGRect(x: originX, y: originY, width: side, height: side)
}

let bounds = artworkBounds(source)
guard let cropped = source.cropping(to: bounds) else {
    FileHandle.standardError.write(Data("crop failed\n".utf8))
    exit(1)
}
print("source \(source.width)×\(source.height) → artwork \(Int(bounds.width))×\(Int(bounds.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY)))")

// MARK: Compose on Apple's grid

/// macOS app icons are not masked by the system: the art carries its own
/// rounded rect, at 824/1024 of the canvas with a corner radius of 185.4, and
/// leaves the remaining margin for the shadow.
let canvas: CGFloat = 1024
let art: CGFloat = 824
let radius: CGFloat = 185.4

func composed() -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: Int(canvas), height: Int(canvas),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high

    let frame = CGRect(
        x: (canvas - art) / 2,
        y: (canvas - art) / 2 + 8, // Optical centring: the shadow falls below.
        width: art, height: art
    )
    let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow first, painted through the shape so it doesn't bleed over the art.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 26,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(cropped, in: frame)
    ctx.restoreGState()

    return ctx.makeImage()
}

guard let master = composed() else {
    FileHandle.standardError.write(Data("compose failed\n".utf8))
    exit(1)
}

// MARK: Emit

func write(_ image: CGImage, side: Int, to url: URL) -> Bool {
    guard let ctx = CGContext(
        data: nil,
        width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = ctx.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: scaled)
    rep.size = NSSize(width: side, height: side)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: url) } catch { return false }
    return true
}

/// (point size, scale) — the ten slots a macOS appiconset asks for.
let slots: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

var entries: [String] = []
for slot in slots {
    let pixels = slot.size * slot.scale
    let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
    guard write(master, side: pixels, to: outputDir.appendingPathComponent(name)) else {
        FileHandle.standardError.write(Data("failed writing \(name)\n".utf8))
        exit(1)
    }
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.size)x\(slot.size)"
        }
    """)
    print("wrote \(name) (\(pixels)px)")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: outputDir.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("wrote Contents.json")
