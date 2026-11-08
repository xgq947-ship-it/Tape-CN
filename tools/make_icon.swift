// Renders Tape's app icon into an AppIcon.appiconset: graphite, a band of glass for the tape,
// the silver step and the mint live dot. Full bleed; macOS draws the rounded square itself.
// Usage: swift tools/make_icon.swift Tape/Resources/Assets.xcassets/AppIcon.appiconset [preview.png]
import AppKit
import CoreGraphics

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let preview = CommandLine.arguments.dropFirst(2).first.map { URL(fileURLWithPath: $0) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// The mark, in a unit square — the same geometry as Tape/DesignSystem/Mark.swift.
let steps = [CGPoint(x: 0.06, y: 0.38), CGPoint(x: 0.44, y: 0.38), CGPoint(x: 0.56, y: 0.62), CGPoint(x: 0.70, y: 0.62)]
let dot = CGPoint(x: 0.89, y: 0.62)

func render(side: Int) -> CGImage {
    let s = CGFloat(side)
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high

    // Ground: graphite, lit softly from the top left.
    let ground = CGGradient(colorsSpace: space, colors: [rgb(0x2C2D33), rgb(0x16171B), rgb(0x0B0B0E)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(ground, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    let light = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.13), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(light, startCenter: CGPoint(x: s * 0.18, y: s * 0.95), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.18, y: s * 0.95), endRadius: s * 0.9, options: [])

    // The tape: a band of glass running edge to edge behind the mark.
    let box = CGRect(x: s * 0.16, y: s * 0.17, width: s * 0.68, height: s * 0.68)
    let bandY = box.minY + 0.5 * box.height
    let band = CGRect(x: 0, y: bandY - s * 0.17, width: s, height: s * 0.34)
    context.saveGState()
    context.clip(to: band)
    let glass = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.085), rgb(0xFFFFFF, 0.03)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(glass, start: CGPoint(x: 0, y: band.maxY), end: CGPoint(x: 0, y: band.minY), options: [])
    context.restoreGState()
    context.setFillColor(rgb(0xFFFFFF, 0.16))
    context.fill(CGRect(x: 0, y: band.maxY - max(1, s * 0.0025), width: s, height: max(1, s * 0.0025)))
    context.setFillColor(rgb(0x000000, 0.35))
    context.fill(CGRect(x: 0, y: band.minY, width: s, height: max(1, s * 0.0025)))
    // Faint ticks along the tape, like the marks on a printed strip.
    if side >= 128 {
        context.setFillColor(rgb(0xFFFFFF, 0.07))
        let tick = s * 0.006
        for index in 0..<24 {
            let x = (CGFloat(index) + 0.5) * s / 24
            context.fill(CGRect(x: x - tick / 2, y: band.minY + s * 0.025, width: tick, height: s * 0.022))
        }
    }

    // The live price's glow sits under everything else.
    let center = CGPoint(x: box.minX + dot.x * box.width, y: box.minY + dot.y * box.height)
    let radius = s * 0.05
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x3EE6A8, 0.38), rgb(0x3EE6A8, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: center, startRadius: radius * 0.6, endCenter: center, endRadius: radius * 3.4, options: [])

    // The step, in brushed silver with a soft shadow beneath.
    let width = s * 0.074
    let path = CGMutablePath()
    path.addLines(between: steps.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) })
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: rgb(0x000000, 0.55))
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(rgb(0xDCDCDA))
    context.addPath(path)
    context.strokePath()
    context.restoreGState()
    context.saveGState()
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    context.replacePathWithStrokedPath()
    context.clip()
    let silver = CGGradient(colorsSpace: space, colors: [rgb(0xFAFAF8), rgb(0xDCDCDA), rgb(0xA9A9A7)] as CFArray, locations: [0, 0.5, 1])!
    context.drawLinearGradient(silver, start: CGPoint(x: 0, y: box.minY + box.height * 0.72), end: CGPoint(x: 0, y: box.minY + box.height * 0.28), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    // The live price: mint, glowing.
    let mint = CGGradient(colorsSpace: space, colors: [rgb(0x7DF5C6), rgb(0x2FCF96)] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    context.drawLinearGradient(mint, start: CGPoint(x: center.x, y: center.y + radius), end: CGPoint(x: center.x, y: center.y - radius), options: [])
    context.restoreGState()

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(render(side: points * scale), to: folder.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appending(path: "Contents.json"))
if let preview { try write(render(side: 1024), to: preview) }
print("Wrote \(images.count) icons to \(folder.path)")
