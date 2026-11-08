import AppKit
import CoreText

/// Draws one listing in whichever design is chosen. `brand` is the logo's colour as found; each
/// design decides how to make it read on its own ground.
nonisolated enum DesignRenderer {
    static func render(label: String, brand: RGB?, quote: Quote, style: TapeStyle, flash: Change.Direction? = nil) -> TapeItem? {
        switch style.design {
        case .classic:
            ItemRenderer.render(label: label, labelColor: brand.map { Legibility.adjust($0, for: style.ground) }, quote: quote, style: style, flash: flash)
        case .liquid: LiquidRenderer.render(label: label, brand: brand, quote: quote, style: style, flash: flash)
        case .led: LEDRenderer.render(label: label, brand: brand, quote: quote, style: style, flash: flash)
        case .paper: PaperRenderer.render(label: label, brand: brand, quote: quote, style: style, flash: flash)
        case .aura: AuraRenderer.render(label: label, brand: brand, quote: quote, style: style, flash: flash)
        case .focus: nil
        }
    }

    static func triangle(in rect: CGRect, up: Bool, radius: CGFloat) -> CGPath {
        ItemRenderer.roundedTriangle(in: rect, pointingUp: up, radius: radius)
    }

    static func key(_ text: ListingText, _ brand: RGB?, _ style: TapeStyle, _ flash: Change.Direction?) -> String {
        [text.key, brand?.hexString ?? "-", "\(style)", flash.map { "\($0)" } ?? "-"].joined(separator: "|")
    }
}

// MARK: - Liquid

/// Capsules of glass inside a glass rail: the Dock's own material, extended.
nonisolated enum LiquidRenderer {
    static func pillHeight(fontSize f: CGFloat) -> CGFloat { (f * 1.3 + 11).rounded() }

    static let gain = RGB(hex: 0x52EDB5)
    static let loss = RGB(hex: 0xFF8A82)
    static let white = RGB(hex: 0xFFFFFF)

    static func render(label: String, brand: RGB?, quote: Quote, style: TapeStyle, flash: Change.Direction?) -> TapeItem? {
        let f = style.fontSize
        let text = ListingText(label: label, quote: quote, style: style)
        let labelFont = Typeface.font(f, .semibold)
        let numberFont = Typeface.font(f, .medium, tabular: true)
        let chipFont = Typeface.font((f * 0.86).rounded(), .semibold, tabular: true)
        let labelColor = brand.map { Legibility.adjust($0, for: .dark) } ?? white
        let priceColor = flash.map { $0 == .up ? gain : loss } ?? white
        let moveColor: RGB = switch text.direction {
        case .up: gain
        case .down: loss
        case .flat: RGB(hex: 0xD6D6D6)
        }

        let labelLine = Typeface.line(text.label, labelFont, labelColor)
        let prefix = Typeface.line(text.price.prefix, numberFont, priceColor, alpha: 0.6)
        let number = Typeface.line(text.price.number, numberFont, priceColor)
        let suffix = Typeface.line(text.price.suffix, numberFont, priceColor, alpha: 0.6)
        let change = Typeface.line(text.change, chipFont, moveColor)
        let hasTriangle = text.direction != .flat && text.change != "–"

        let ph = pillHeight(fontSize: f)
        let chipHeight = ph - 9
        let triangle = CGSize(width: (f * 0.5).rounded(), height: chipFont.capHeight * 0.82)
        let chipWidth = (8 + (hasTriangle ? triangle.width + 4 : 0) + Typeface.width(change) + 8).rounded(.up)
        let lead: CGFloat = 12
        let afterLabel = (f * 0.45).rounded()
        let afterPrice = (f * 0.55).rounded()
        let priceWidth = Typeface.width(prefix) + Typeface.width(number) + Typeface.width(suffix)
        let width = (lead + Typeface.width(labelLine) + afterLabel + priceWidth + afterPrice + chipWidth + 4.5).rounded(.up)

        let pad: CGFloat = 3
        guard let canvas = Bitmap(size: CGSize(width: width + pad * 2, height: ph + pad * 2), scale: style.scale) else { return nil }
        let context = canvas.context
        let pill = CGRect(x: pad, y: pad, width: width, height: ph)
        let shape = CGPath(roundedRect: pill, cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil)

        // The capsule: brighter at the top, a hairline edge, a soft catch-light along the top.
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let body = CGGradient(colorsSpace: nil, colors: [white.cgColor(alpha: 0.19), white.cgColor(alpha: 0.07), white.cgColor(alpha: 0.10)] as CFArray, locations: [0, 0.55, 1])!
        context.drawLinearGradient(body, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
        let sheen = CGGradient(colorsSpace: nil, colors: [white.cgColor(alpha: 0.28), white.cgColor(alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.maxY - 3), options: [])
        context.restoreGState()
        context.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25), cornerWidth: ph / 2 - 0.25, cornerHeight: ph / 2 - 0.25, transform: nil))
        context.setStrokeColor(white.cgColor(alpha: 0.24))
        context.setLineWidth(0.5)
        context.strokePath()

        // The move, in a chip of its own colour nested in the capsule.
        let chip = CGRect(x: pill.maxX - 4.5 - chipWidth, y: pill.midY - chipHeight / 2, width: chipWidth, height: chipHeight)
        canvas.fillCapsule(chip, color: (text.direction == .flat ? white : moveColor).cgColor(alpha: text.direction == .flat ? 0.1 : 0.2))

        let baseline = (pill.midY - numberFont.capHeight / 2).rounded(.down) + 0.5
        canvas.shadowed([Bitmap.Shadow(blur: 1.4, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: 0.35))]) {
            var x = pill.minX + lead
            canvas.draw(labelLine, at: CGPoint(x: x, y: baseline))
            x += Typeface.width(labelLine) + afterLabel
            canvas.draw(prefix, at: CGPoint(x: x, y: baseline))
            x += Typeface.width(prefix)
            canvas.draw(number, at: CGPoint(x: x, y: baseline))
            x += Typeface.width(number)
            canvas.draw(suffix, at: CGPoint(x: x, y: baseline))
            var cx = chip.minX + 8
            let chipBaseline = (chip.midY - chipFont.capHeight / 2).rounded(.down) + 0.5
            if hasTriangle {
                let rect = CGRect(x: cx, y: chipBaseline + (chipFont.capHeight - triangle.height) / 2, width: triangle.width, height: triangle.height)
                context.setFillColor(moveColor.cgColor())
                context.addPath(DesignRenderer.triangle(in: rect, up: text.direction == .up, radius: f * 0.05))
                context.fillPath()
                cx += triangle.width + 4
            }
            canvas.draw(change, at: CGPoint(x: cx, y: chipBaseline))
        }
        guard let image = canvas.image() else { return nil }
        return TapeItem(symbol: quote.symbol, key: DesignRenderer.key(text, brand, style, flash), image: image, size: CGSize(width: width, height: ph), padding: pad)
    }
}

// MARK: - LED

/// A dot-matrix ticker: every glyph a grid of glowing dots, moving one dot at a time.
nonisolated enum LEDRenderer {
    /// Whole device pixels per dot, so the matrix stays even on a 1× display.
    static func pitch(fontSize f: CGFloat, scale: CGFloat) -> CGFloat {
        max(2, (f * 0.15 * scale).rounded(.down) / scale)
    }

    static let up = RGB(hex: 0x3DFF8E)
    static let down = RGB(hex: 0xFF4B47)
    static let warm = RGB(hex: 0xFFF1DC)
    static let neutral = RGB(hex: 0xC9C9C9)

    /// Brand colours as LEDs: bright, saturated, never murky.
    static func led(_ brand: RGB) -> RGB {
        let lab = brand.oklab
        return Legibility.inGamut(l: min(max(lab.l, 0.8), 0.92), chroma: min(lab.chroma * 1.25, 0.32), hue: lab.hue)
    }

    static func render(label: String, brand: RGB?, quote: Quote, style: TapeStyle, flash: Change.Direction?) -> TapeItem? {
        let p = pitch(fontSize: style.fontSize, scale: style.scale)
        let text = ListingText(label: label.uppercased(), quote: quote, style: style)
        let moveColor: RGB = switch text.direction {
        case .up: up
        case .down: down
        case .flat: neutral
        }
        let priceColor = flash.map { $0 == .up ? up : down } ?? warm
        var segments: [(text: String, color: RGB, alpha: Double, gapAfter: Int)] = [
            (text.label, brand.map(led) ?? warm, 1, 5),
        ]
        if !text.price.prefix.isEmpty { segments.append((text.price.prefix.trimmingCharacters(in: .whitespaces), priceColor, 0.55, 1)) }
        segments.append((text.price.number, priceColor, 1, text.price.suffix.isEmpty ? 4 : 1))
        if !text.price.suffix.isEmpty { segments.append((text.price.suffix.trimmingCharacters(in: .whitespaces).uppercased(), priceColor, 0.55, 4)) }
        if text.direction != .flat, text.change != "–" { segments.append((text.direction == .up ? "▲" : "▼", moveColor, 1, 2)) }
        segments.append((text.change, moveColor, 1, 0))

        var groups: [String: (color: RGB, alpha: Double, dots: [(Int, Int)])] = [:]
        var column = 0
        for segment in segments {
            let laid = LEDFont.layout(segment.text)
            let id = segment.color.hexString + "\(segment.alpha)"
            var group = groups[id] ?? (segment.color, segment.alpha, [])
            group.dots += laid.dots.map { (column + $0.column, $0.row) }
            groups[id] = group
            column += laid.columns + segment.gapAfter
        }
        let size = CGSize(width: CGFloat(column) * p, height: CGFloat(LEDFont.rows) * p)
        let pad = p * 3
        guard let canvas = Bitmap(size: CGSize(width: size.width + pad * 2, height: size.height + pad * 2), scale: style.scale) else { return nil }
        let context = canvas.context
        let diameter = p * 0.8
        for group in groups.values {
            let color = group.color.cgColor(alpha: group.alpha)
            // Each colour glows on its own, so a red move never tints the price beside it.
            canvas.shadowed([Bitmap.Shadow(blur: p * 2.2, color: group.color.cgColor(alpha: 0.55 * group.alpha)),
                             Bitmap.Shadow(blur: p * 0.7, color: group.color.cgColor(alpha: 0.9 * group.alpha))]) {
                context.setFillColor(color)
                for (c, r) in group.dots {
                    let center = CGPoint(x: pad + (CGFloat(c) + 0.5) * p, y: pad + (CGFloat(LEDFont.rows - 1 - r) + 0.5) * p)
                    context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
                }
            }
        }
        guard let image = canvas.image() else { return nil }
        return TapeItem(symbol: quote.symbol, key: DesignRenderer.key(text, brand, style, flash), image: image, size: size, padding: pad)
    }

    /// The unlit matrix behind the moving dots, fixed in place like the real panel.
    static func grid(size: CGSize, pitch p: CGFloat, scale: CGFloat) -> CGImage? {
        guard let canvas = Bitmap(size: size, scale: scale) else { return nil }
        let context = canvas.context
        context.setFillColor(CGColor(gray: 1, alpha: 0.075))
        let diameter = p * 0.62
        var y = p / 2
        while y < size.height {
            var x = p / 2
            while x < size.width {
                context.fillEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                x += p
            }
            y += p
        }
        return canvas.image()
    }
}

// MARK: - Paper

/// Printed ticker tape: ink on cream paper, perforated along both edges, moving with the print.
nonisolated enum PaperRenderer {
    static func paperHeight(fontSize f: CGFloat) -> CGFloat { (f * 2.3).rounded() }

    static let ink = RGB(hex: 0x1B1A19)
    static let green = RGB(hex: 0x0B7A4B)
    static let red = RGB(hex: 0xBF2B25)
    static let perforation: CGFloat = 7

    static func render(label: String, brand: RGB?, quote: Quote, style: TapeStyle, flash: Change.Direction?) -> TapeItem? {
        let f = style.fontSize
        let height = paperHeight(fontSize: f)
        let text = ListingText(label: label, quote: quote, style: style)
        let labelFont = Typeface.font((f * 1.05).rounded(), .bold, design: .serif)
        let numberFont = Typeface.font((f * 0.93).rounded(), .medium, design: .monospaced)
        let labelColor = brand.map { inked($0) } ?? ink
        let moveColor: RGB = text.direction == .up ? green : text.direction == .down ? red : ink
        let priceColor = flash.map { $0 == .up ? green : red } ?? ink

        let labelLine = Typeface.line(text.label, labelFont, labelColor, kern: 0.2)
        let priceLine = Typeface.line(text.price.text, numberFont, priceColor, alpha: 0.92)
        let arrow = text.direction == .up ? "▲" : text.direction == .down ? "▼" : ""
        let changeLine = Typeface.line(arrow.isEmpty ? text.change : "\(arrow)\u{2009}\(text.change)", numberFont, moveColor, alpha: text.direction == .flat ? 0.55 : 0.95)
        let gapLabel = (f * 0.55).rounded()
        let gapPrice = (f * 0.7).rounded()
        let textWidth = Typeface.width(labelLine) + gapLabel + Typeface.width(priceLine) + gapPrice + Typeface.width(changeLine)
        let spacing = (f * 2.2).rounded()
        // Whole perforations per listing, so the holes run on evenly from one listing to the next.
        let width = ((textWidth + spacing) / perforation).rounded(.up) * perforation

        guard let canvas = Bitmap(size: CGSize(width: width, height: height), scale: style.scale) else { return nil }
        let context = canvas.context

        // Perforations: pressed into the paper, catching light on their lower lip.
        for y in [4.6, height - 4.6] {
            var x = perforation / 2
            while x < width {
                context.setFillColor(CGColor(gray: 1, alpha: 0.65))
                context.fillEllipse(in: CGRect(x: x - 1.15, y: y - 1.75, width: 2.3, height: 2.3))
                context.setFillColor(CGColor(red: 0.35, green: 0.3, blue: 0.22, alpha: 0.32))
                context.fillEllipse(in: CGRect(x: x - 1.15, y: y - 1.15, width: 2.3, height: 2.3))
                x += perforation
            }
        }
        // A printer's dot between listings, half on each side of the join.
        context.setFillColor(ink.cgColor(alpha: 0.3))
        for x in [0, width] { context.fillEllipse(in: CGRect(x: x - 1.5, y: height / 2 - 1.5, width: 3, height: 3)) }

        let baseline = (height / 2 - numberFont.capHeight / 2).rounded()
        // A breath of ink bleed so it reads printed, not rendered.
        canvas.shadowed([Bitmap.Shadow(blur: 0.6, color: ink.cgColor(alpha: 0.35))]) {
            var x = ((width - textWidth) / 2).rounded()
            canvas.draw(labelLine, at: CGPoint(x: x, y: baseline))
            x += Typeface.width(labelLine) + gapLabel
            canvas.draw(priceLine, at: CGPoint(x: x, y: baseline))
            x += Typeface.width(priceLine) + gapPrice
            canvas.draw(changeLine, at: CGPoint(x: x, y: baseline))
        }
        guard let image = canvas.image() else { return nil }
        return TapeItem(symbol: quote.symbol, key: DesignRenderer.key(text, brand, style, flash), image: image, size: CGSize(width: width, height: height), padding: 0)
    }

    /// Brand colours as printing ink: deep enough to read on cream.
    static func inked(_ brand: RGB) -> RGB {
        let lab = brand.oklab
        return Legibility.inGamut(l: min(max(lab.l, 0.32), 0.52), chroma: lab.chroma, hue: lab.hue)
    }

    /// The paper itself: cream, faintly grained, curling away at both ends.
    static func paper(size: CGSize, scale: CGFloat) -> CGImage? {
        guard let canvas = Bitmap(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let rect = CGRect(origin: .zero, size: size)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.clip()
        let body = CGGradient(colorsSpace: nil, colors: [RGB(hex: 0xF7F3E8).cgColor(), RGB(hex: 0xEDE7D8).cgColor()] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(body, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        // Grain: a deterministic scatter of specks.
        var seed: UInt64 = 0x7A9E
        for _ in 0..<Int(size.width * size.height / 9) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat((seed >> 33) % 100_000) / 100_000 * size.width
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = CGFloat((seed >> 33) % 100_000) / 100_000 * size.height
            let dark = (seed >> 20) & 1 == 0
            context.setFillColor(dark ? CGColor(red: 0.45, green: 0.38, blue: 0.25, alpha: 0.07) : CGColor(gray: 1, alpha: 0.35))
            context.fill(CGRect(x: x, y: y, width: 0.6, height: 0.6))
        }
        // The ends bend away from the light.
        let curl = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.3, green: 0.25, blue: 0.15, alpha: 0.22), CGColor(red: 0.3, green: 0.25, blue: 0.15, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(curl, start: .zero, end: CGPoint(x: 26, y: 0), options: [])
        context.drawLinearGradient(curl, start: CGPoint(x: size.width, y: 0), end: CGPoint(x: size.width - 26, y: 0), options: [])
        // A highlight along the top edge, where the paper catches the light.
        context.setFillColor(CGColor(gray: 1, alpha: 0.7))
        context.fill(CGRect(x: 0, y: size.height - 0.75, width: size.width, height: 0.75))
        return canvas.image()
    }
}

// MARK: - Aura

/// No background: each listing floats in a soft light, green or coral, as strong as its move.
nonisolated enum AuraRenderer {
    static let up = RGB(hex: 0x14F5A6)
    static let down = RGB(hex: 0xFF3B5C)

    static func render(label: String, brand: RGB?, quote: Quote, style: TapeStyle, flash: Change.Direction?) -> TapeItem? {
        let f = style.fontSize
        let height = DesignMetrics(design: .aura, fontSize: f, scale: style.scale).height
        let text = ListingText(label: label, quote: quote, style: style)
        let dark = style.ground == .dark
        let ink = dark ? RGB(hex: 0xFFFFFF) : RGB(hex: 0x141416)
        let labelFont = Typeface.font(f, .bold, design: .rounded)
        let numberFont = Typeface.font(f, .semibold, design: .rounded, tabular: true)
        let changeFont = Typeface.font((f * 0.93).rounded(), .medium, design: .rounded, tabular: true)
        let glow: RGB? = switch text.direction {
        case .up: up
        case .down: down
        case .flat: nil
        }
        let priceColor = flash.map { $0 == .up ? up : down }.map { Legibility.adjust($0, for: style.ground) } ?? ink

        let labelLine = Typeface.line(text.label, labelFont, ink)
        let prefix = Typeface.line(text.price.prefix, numberFont, priceColor, alpha: 0.6)
        let number = Typeface.line(text.price.number, numberFont, priceColor)
        let suffix = Typeface.line(text.price.suffix, numberFont, priceColor, alpha: 0.6)
        let change = Typeface.line(text.change, changeFont, ink, alpha: 0.88)
        let dot: CGFloat = (f * 0.5).rounded()
        let triangle = CGSize(width: (f * 0.5).rounded(), height: changeFont.capHeight * 0.8)
        let hasTriangle = glow != nil && text.change != "–"
        let widths = [dot + 6, Typeface.width(labelLine), f * 0.5, Typeface.width(prefix), Typeface.width(number), Typeface.width(suffix), f * 0.55,
                      hasTriangle ? triangle.width + 4 : 0, Typeface.width(change)]
        let width = widths.reduce(0, +).rounded(.up)
        let lineHeight = (numberFont.ascender - numberFont.descender).rounded(.up)
        let pad = ((height - lineHeight) / 2).rounded(.down)
        guard let canvas = Bitmap(size: CGSize(width: width + pad * 2, height: lineHeight + pad * 2), scale: style.scale) else { return nil }
        let context = canvas.context
        let center = CGPoint(x: pad + width / 2, y: pad + lineHeight / 2)

        // The aura: an ellipse of light, its strength the size of the move (full at 3.5%).
        if let glow {
            let strength = min(abs(text.percent) / 3.5, 1)
            let alpha = 0.34 + 0.5 * strength
            // A wide halo and a brighter core, both squashed into the shape of the line.
            for (ry, rx, a) in [(lineHeight * 1.45, width / 2 + pad * 0.9, alpha * 0.75), (lineHeight * 0.85, width / 2 + 6, alpha)] {
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: rx / ry, y: 1)
                let light = CGGradient(colorsSpace: nil, colors: [glow.cgColor(alpha: a), glow.cgColor(alpha: a * 0.5), glow.cgColor(alpha: 0)] as CFArray, locations: [0, 0.45, 1])!
                context.drawRadialGradient(light, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ry, options: [])
                context.restoreGState()
            }
        }

        let baseline = (center.y - numberFont.capHeight / 2).rounded()
        let shadow = dark ? CGColor(gray: 0, alpha: 0.5) : CGColor(gray: 1, alpha: 0.6)
        canvas.shadowed([Bitmap.Shadow(blur: 1.6, offset: CGSize(width: 0, height: dark ? -0.5 : 0), color: shadow)]) {
            var x = pad
            // The brand, as a single drop of colour.
            let brandColor = brand.map { Legibility.adjust($0, for: .dark) } ?? RGB(hex: 0xE8E8E8)
            let dotRect = CGRect(x: x, y: baseline + numberFont.capHeight / 2 - dot / 2, width: dot, height: dot)
            context.setFillColor(brandColor.cgColor())
            context.fillEllipse(in: dotRect)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
            context.setLineWidth(0.75)
            context.strokeEllipse(in: dotRect.insetBy(dx: 0.4, dy: 0.4))
            x += widths[0]
            canvas.draw(labelLine, at: CGPoint(x: x, y: baseline))
            x += widths[1] + widths[2]
            canvas.draw(prefix, at: CGPoint(x: x, y: baseline))
            x += widths[3]
            canvas.draw(number, at: CGPoint(x: x, y: baseline))
            x += widths[4]
            canvas.draw(suffix, at: CGPoint(x: x, y: baseline))
            x += widths[5] + widths[6]
            if hasTriangle, let glow {
                let rect = CGRect(x: x, y: baseline + (changeFont.capHeight - triangle.height) / 2, width: triangle.width, height: triangle.height)
                context.setFillColor(Legibility.adjust(glow, for: style.ground).cgColor())
                context.addPath(DesignRenderer.triangle(in: rect, up: text.direction == .up, radius: f * 0.06))
                context.fillPath()
                x += triangle.width + 4
            }
            canvas.draw(change, at: CGPoint(x: x, y: baseline))
        }
        guard let image = canvas.image() else { return nil }
        return TapeItem(symbol: quote.symbol, key: DesignRenderer.key(text, brand, style, flash), image: image, size: CGSize(width: width, height: lineHeight), padding: pad)
    }
}
