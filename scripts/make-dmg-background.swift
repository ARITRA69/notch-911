// Draws the drag-to-install backdrop for the release DMG.
//
//   swift scripts/make-dmg-background.swift assets/dmg
//
// Emits background.png and background@2x.png; release.sh pairs them into the
// HiDPI background.tiff that Finder actually reads. Coordinates below are
// top-left origin points in the *content* area of the DMG window, and the two
// icon centres have to stay in sync with the positions release.sh hands Finder.

import AppKit

let width: CGFloat = 660
let height: CGFloat = 420

let appIconCentre = CGPoint(x: 196, y: 210)
let dropIconCentre = CGPoint(x: 464, y: 210)

// Straight off the app icon: near-black shell, corgi orange, siren red.
let backdropTop = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1)
let backdropBottom = NSColor(srgbRed: 0.05, green: 0.04, blue: 0.035, alpha: 1)
let glow = NSColor(srgbRed: 0.91, green: 0.45, blue: 0.18, alpha: 1)
let card = NSColor(srgbRed: 0.969, green: 0.941, blue: 0.894, alpha: 1)
let cardEdge = NSColor(srgbRed: 0.85, green: 0.80, blue: 0.72, alpha: 1)
let arrow = NSColor(srgbRed: 0.91, green: 0.45, blue: 0.18, alpha: 1)
let caption = NSColor(srgbRed: 0.94, green: 0.90, blue: 0.85, alpha: 1)

let cardRect = CGRect(x: 46, y: 59, width: width - 92, height: 271)
let cardRadius: CGFloat = 28

func draw(into ctx: CGContext) {
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let space = CGColorSpaceCreateDeviceRGB()

    // Backdrop, warm charcoal top to near-black bottom.
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [backdropTop.cgColor, backdropBottom.cgColor] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: []
        )
    }

    // Siren glow behind the card so the dark frame doesn't read as flat.
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            glow.withAlphaComponent(0.20).cgColor,
            glow.withAlphaComponent(0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: width / 2, y: 180),
            startRadius: 0,
            endCenter: CGPoint(x: width / 2, y: 180),
            endRadius: 330,
            options: []
        )
    }

    // The card. Finder draws both icons and their labels on top of this, so it
    // stays light — label text is black under the light system appearance.
    let cardPath = CGPath(
        roundedRect: cardRect,
        cornerWidth: cardRadius,
        cornerHeight: cardRadius,
        transform: nil
    )
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.setFillColor(card.cgColor)
    ctx.addPath(cardPath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setStrokeColor(cardEdge.cgColor)
    ctx.setLineWidth(1)
    ctx.addPath(cardPath)
    ctx.strokePath()

    // Wavy arrow from the app icon toward Applications. The amplitude fades to
    // nothing at the tip so the head can sit flat on the baseline.
    let start = appIconCentre.x + 78
    let end = dropIconCentre.x - 86
    let baseline = appIconCentre.y
    let amplitude: CGFloat = 9
    let waves: CGFloat = 2.5

    let path = CGMutablePath()
    var x = start
    while x <= end {
        let t = (x - start) / (end - start)
        let fade = min(1, (1 - t) / 0.28)
        let y = baseline + sin(t * waves * 2 * .pi) * amplitude * fade
        if x == start { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        x += 1
    }

    ctx.setStrokeColor(arrow.cgColor)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()

    let head = CGMutablePath()
    head.move(to: CGPoint(x: end - 19, y: baseline - 15))
    head.addLine(to: CGPoint(x: end + 1, y: baseline))
    head.addLine(to: CGPoint(x: end - 19, y: baseline + 15))
    ctx.addPath(head)
    ctx.strokePath()

    // Caption sits on the dark frame, not the card, so its colour is fixed.
    let text = "Drag notch-911 to Applications"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 21, weight: .bold),
        .foregroundColor: caption,
        .kern: 0.2,
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let size = line.size()
    // Glyphs would come out mirrored under the flip above, so undo it just for
    // the text and let it draw upward from the bottom of its box.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 375 + size.height / 2)
    ctx.scaleBy(x: 1, y: -1)
    line.draw(at: CGPoint(x: (width - size.width) / 2, y: 0))
    ctx.restoreGState()
}

func render(scale: CGFloat, to url: URL) throws {
    let pixelsWide = Int(width * scale)
    let pixelsHigh = Int(height * scale)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "dmg-background", code: 1)
    }
    rep.size = NSSize(width: width, height: height)

    guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "dmg-background", code: 2)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let ctx = nsContext.cgContext
    ctx.scaleBy(x: scale, y: scale)
    // Flip to top-left origin so these coordinates match Finder's.
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    draw(into: ctx)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "dmg-background", code: 3)
    }
    try data.write(to: url)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try render(scale: 1, to: outputDir.appendingPathComponent("background.png"))
print("wrote background.png to \(outputDir.path)")
