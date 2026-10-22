// make-icon.swift — draws the ThermalMonitor app icon and writes a macOS .iconset folder.
//
// HOW TO RUN (from the project folder; build.sh does this for you):
//   swift tools/make-icon.swift .build/icon/AppIcon.iconset
//   iconutil -c icns .build/icon/AppIcon.iconset -o Resources/AppIcon.icns
//
// Design: dark slate rounded square (the widget card colour) with a glass thermometer whose
// fill runs through the app's own heat scale — green → yellow → orange → red — plus tick marks.
// Pure CoreGraphics, vector-drawn at every size (no upscaled bitmaps).

import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? ".build/icon/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Bulb + tube as one path, in 1024-unit space.
func thermometerPath(centerX: CGFloat, bulbY: CGFloat, bulbRadius: CGFloat, tubeHalfWidth: CGFloat, topY: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: centerX - bulbRadius, y: bulbY - bulbRadius, width: bulbRadius * 2, height: bulbRadius * 2))
    path.addRoundedRect(in: CGRect(x: centerX - tubeHalfWidth, y: bulbY, width: tubeHalfWidth * 2, height: topY - bulbY),
                        cornerWidth: tubeHalfWidth, cornerHeight: tubeHalfWidth)
    return path
}

func draw(in ctx: CGContext, size: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: Apple's macOS icon grid — 824 pt rounded square centred on 1024, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0.086, 0.106, 0.122)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0.17, 0.19, 0.33), rgb(0.08, 0.09, 0.13)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Warm glow behind the bulb, the "heat" the app is about.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(1.0, 0.36, 0.25, 0.42), rgb(1.0, 0.36, 0.25, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 300), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 300), endRadius: 330, options: [])
    ctx.restoreGState()

    // Hairline edge, like the widget card's border.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.14)); ctx.setLineWidth(6); ctx.strokePath()

    // Thermometer glass.
    let cx: CGFloat = 470, bulbY: CGFloat = 300
    let glass = thermometerPath(centerX: cx, bulbY: bulbY, bulbRadius: 128, tubeHalfWidth: 74, topY: 790)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(glass); ctx.setFillColor(rgb(0.93, 0.94, 0.97)); ctx.fillPath()
    ctx.restoreGState()

    // Fill: the app's heat scale, red in the bulb rising to green at the top of the column.
    let fill = thermometerPath(centerX: cx, bulbY: bulbY, bulbRadius: 92, tubeHalfWidth: 38, topY: 700)
    ctx.saveGState()
    ctx.addPath(fill); ctx.clip()
    let heat = CGGradient(colorsSpace: space,
                          colors: [rgb(1.00, 0.27, 0.23), rgb(1.00, 0.27, 0.23), rgb(1.00, 0.58, 0.00),
                                   rgb(1.00, 0.80, 0.00), rgb(0.20, 0.78, 0.35)] as CFArray,
                          locations: [0, 0.30, 0.52, 0.74, 1])!
    ctx.drawLinearGradient(heat, start: CGPoint(x: cx, y: bulbY - 92), end: CGPoint(x: cx, y: 700), options: [])
    // Glass highlight on the bulb.
    ctx.setFillColor(rgb(1, 1, 1, 0.35))
    ctx.fillEllipse(in: CGRect(x: cx - 62, y: bulbY + 8, width: 48, height: 48))
    ctx.restoreGState()

    // Tick marks to the right of the tube, longest at the red threshold.
    ctx.setLineCap(.round)
    let ticks: [(y: CGFloat, length: CGFloat, color: CGColor)] = [
        (720, 70, rgb(1, 1, 1, 0.55)),
        (630, 110, rgb(1.00, 0.27, 0.23, 0.95)),
        (540, 70, rgb(1, 1, 1, 0.55)),
        (450, 70, rgb(1, 1, 1, 0.55)),
    ]
    for tick in ticks {
        ctx.setStrokeColor(tick.color); ctx.setLineWidth(22)
        ctx.move(to: CGPoint(x: cx + 122, y: tick.y))
        ctx.addLine(to: CGPoint(x: cx + 122 + tick.length, y: tick.y))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(in: ctx, size: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("Wrote \(sizes.count) PNGs to \(outDir)")
