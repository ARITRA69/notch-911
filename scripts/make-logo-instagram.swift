// Draws the Instagram glyph into a Logos imageset at 1x/2x/3x.
//
// A script rather than a checked-in binary for the same reason `makeicon.swift`
// is one: the mark is pure geometry over a gradient, so the source of truth can
// be the geometry itself and the PNGs can be regenerated at any size.
//
// Proportions are taken off the official mark on a 1024 grid: a rounded-square
// tile, a rounded-square stroke inset within it, a centred circle stroke, and
// the lens dot up in the top-right corner.

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-logo-instagram <imageset dir>\n".utf8))
    exit(2)
}
let outputDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

/// Everything below is expressed against this, then scaled.
let grid: CGFloat = 1024

// The tile itself. 22.5% is the corner radius Apple's own squircle lands near,
// and it is what the mark reads as at a glance.
let tileRadius = grid * 0.225
// The camera body: a stroked rounded square, inset and rounded more tightly.
let bodyInset = grid * 0.140
let bodyRadius = grid * 0.200
let stroke = grid * 0.072
// The lens, centred.
let lensRadius = grid * 0.181
// The little indicator, up and to the right. `y` is measured from the bottom —
// CoreGraphics' origin, not the image's — so "up" is the larger number.
let dotRadius = grid * 0.046
let dotCentre = CGPoint(x: grid * 0.705, y: grid * 0.705)

/// The gradient runs out of the bottom-left corner — amber into orange, through
/// pink and magenta, landing on violet at the far corners. Radial rather than
/// linear: a linear ramp puts a flat band across the middle that the real mark
/// does not have.
let stops: [(CGFloat, NSColor)] = [
    (0.00, NSColor(srgbRed: 0.99, green: 0.85, blue: 0.36, alpha: 1)),
    (0.11, NSColor(srgbRed: 0.98, green: 0.60, blue: 0.15, alpha: 1)),
    (0.34, NSColor(srgbRed: 0.96, green: 0.24, blue: 0.31, alpha: 1)),
    (0.58, NSColor(srgbRed: 0.90, green: 0.11, blue: 0.53, alpha: 1)),
    (0.78, NSColor(srgbRed: 0.75, green: 0.13, blue: 0.79, alpha: 1)),
    (1.00, NSColor(srgbRed: 0.44, green: 0.24, blue: 0.89, alpha: 1)),
]

func render(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let scale = size / grid
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    // Corners stay transparent: this sits on the notch's black, not on white.
    let tile = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: grid, height: grid),
        cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil
    )
    context.saveGState()
    context.addPath(tile)
    context.clip()

    let colors = stops.map { $0.1.cgColor } as CFArray
    let locations = stops.map { $0.0 }
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors,
        locations: locations
    ) {
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: grid * 0.28, y: grid * 0.06), startRadius: 0,
            endCenter: CGPoint(x: grid * 0.28, y: grid * 0.06), endRadius: grid * 1.05,
            options: [.drawsAfterEndLocation]
        )
    }
    context.restoreGState()

    context.setStrokeColor(NSColor.white.cgColor)
    context.setFillColor(NSColor.white.cgColor)
    context.setLineWidth(stroke)

    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: grid - bodyInset * 2, height: grid - bodyInset * 2)
        .insetBy(dx: stroke / 2, dy: stroke / 2)
    context.addPath(CGPath(roundedRect: body,
                           cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
    context.strokePath()

    context.addEllipse(in: CGRect(
        x: grid / 2 - lensRadius + stroke / 2, y: grid / 2 - lensRadius + stroke / 2,
        width: (lensRadius - stroke / 2) * 2, height: (lensRadius - stroke / 2) * 2
    ))
    context.strokePath()

    context.addEllipse(in: CGRect(
        x: dotCentre.x - dotRadius, y: dotCentre.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    ))
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// 256 matches the other four marks in Logos/.
for (suffix, pixels) in [("", 256), ("@2x", 512), ("@3x", 768)] {
    guard let data = render(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed at \(pixels)px\n".utf8))
        exit(1)
    }
    let url = outputDir.appendingPathComponent("logo.instagram\(suffix).png")
    try data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(pixels)px)")
}

let contents = """
{
  "images" : [
    { "filename" : "logo.instagram.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "logo.instagram@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "logo.instagram@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {  "preserves-vector-representation" : false }
}
"""
try contents.write(
    to: outputDir.appendingPathComponent("Contents.json"),
    atomically: true, encoding: .utf8
)
print("wrote Contents.json")
