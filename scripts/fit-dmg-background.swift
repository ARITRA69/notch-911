// Fits an arbitrary source image to the DMG window backdrop.
//
//   swift scripts/fit-dmg-background.swift <source-image> assets/dmg
//
// Aspect-fills to 660x420 (centre-cropped) and writes background.png. Use this
// for hand-made art; make-dmg-background.swift draws the generated version.
// 660x420 exactly — see dmg-window.applescript for why 2x art cannot work.

import AppKit

let width: CGFloat = 660
let height: CGFloat = 420

let args = CommandLine.arguments
guard args.count > 2, let source = NSImage(contentsOfFile: args[1]),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: fit-dmg-background <image> <output-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outputDir = URL(fileURLWithPath: args[2])

let sourceSize = CGSize(width: cgSource.width, height: cgSource.height)
let scale = max(width / sourceSize.width, height / sourceSize.height)
let drawn = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
let origin = CGPoint(x: (width - drawn.width) / 2, y: (height - drawn.height) / 2)

print("source \(Int(sourceSize.width))x\(Int(sourceSize.height)) -> 660x420, "
      + "cropping \(Int(-origin.x))pt per side horizontally, \(Int(-origin.y))pt vertically")

func render(scale factor: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * factor), pixelsHigh: Int(height * factor),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "fit-dmg-background", code: 1)
    }
    rep.size = NSSize(width: width, height: height)
    ctx.cgContext.scaleBy(x: factor, y: factor)
    ctx.cgContext.interpolationQuality = .high
    ctx.cgContext.draw(cgSource, in: CGRect(origin: origin, size: drawn))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "fit-dmg-background", code: 2)
    }
    try data.write(to: url)
}

try render(scale: 1, to: outputDir.appendingPathComponent("background.png"))
print("wrote background.png to \(outputDir.path)")
