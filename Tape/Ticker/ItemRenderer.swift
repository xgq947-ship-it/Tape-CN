import AppKit
import CoreText

/// How the tape is drawn right now.
nonisolated struct TapeStyle: Equatable, Sendable {
    var fontSize: CGFloat = 14
    var ground: Ground = .dark
    var showCurrency = true
    var changeStyle: ChangeStyle = .percent
    var reference: Reference = .previousClose
    var scale: CGFloat = 2
    var design: TapeDesign = .classic
    /// Focus on a pane of glass rather than straight on the wallpaper.
    var focusGlass = false

    var metrics: DesignMetrics { DesignMetrics(design: design, fontSize: fontSize, scale: scale) }

    /// Room around the text for its shadow, in points.
    var padding: CGFloat { (fontSize * 0.75).rounded(.up) }
    /// Between two listings.
    var spacing: CGFloat { (fontSize * 2.1).rounded() }

    var primary: RGB { ground == .dark ? RGB(hex: 0xF7F7F5) : RGB(hex: 0x141416) }
    var gain: RGB { ground == .dark ? RGB(hex: 0x3EE6A8) : RGB(hex: 0x08875A) }
    var loss: RGB { ground == .dark ? RGB(hex: 0xFF7D76) : RGB(hex: 0xD02E27) }
    var quiet: Double { ground == .dark ? 0.62 : 0.55 }

    func color(for direction: Change.Direction) -> RGB {
        switch direction {
        case .up: gain
        case .down: loss
        case .flat: primary
        }
    }
}

/// One listing on the tape, drawn once into a bitmap whenever its numbers change.
/// The tape then only moves bitmaps around, which costs the CPU next to nothing.
nonisolated struct TapeItem: @unchecked Sendable {
    var symbol: String
    /// Everything the bitmap shows, so an identical redraw can be skipped.
    var key: String
    var image: CGImage
    /// The text itself, in points, without the shadow padding.
    var size: CGSize
    var padding: CGFloat
}

nonisolated enum ItemRenderer {
    /// - Parameter flash: tints the price for a moment after it ticks.
    static func render(label: String, labelColor: RGB?, quote: Quote, style: TapeStyle, flash: Change.Direction? = nil) -> TapeItem? {
        let size = style.fontSize
        let labelFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        let change = quote.change(style.reference)
        let direction = change?.direction ?? .flat

        // Pieces, left to right.
        var runs: [(line: CTLine, gapAfter: CGFloat)] = []
        func line(_ text: String, _ font: NSFont, _ color: RGB, alpha: Double = 1, kern: CGFloat = 0) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.nsColor(alpha: alpha), .kern: kern]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        runs.append((line(label, labelFont, labelColor ?? style.primary, kern: size * 0.01), size * 0.5))

        let price = Format.price(quote.price, of: quote, showCurrency: style.showCurrency, compact: true)
        let priceColor = flash.map(style.color(for:)) ?? style.primary
        if !price.prefix.isEmpty { runs.append((line(price.prefix, numberFont, priceColor, alpha: style.quiet), 0.5)) }
        runs.append((line(price.number, numberFont, priceColor), price.suffix.isEmpty ? size * 0.55 : 0.5))
        if !price.suffix.isEmpty { runs.append((line(price.suffix, numberFont, priceColor, alpha: style.quiet), size * 0.55)) }

        let changeColor = style.color(for: direction)
        let changeAlpha = direction == .flat ? style.quiet : 1
        var changeText = ""
        if let change {
            switch style.changeStyle {
            case .percent: changeText = Format.percent(change.percent)
            case .amount: changeText = Format.amount(change.amount, of: quote)
            case .both: changeText = Format.amount(change.amount, of: quote) + "  " + Format.percent(change.percent)
            }
        } else {
            changeText = "–"
        }
        let changeLine = line(changeText, numberFont, changeColor, alpha: changeAlpha)

        // Metrics
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(changeLine, &ascent, &descent, &leading)
        let capHeight = numberFont.capHeight
        let triangle = CGSize(width: (size * 0.62).rounded(), height: (capHeight * 0.78))
        let triangleGap = (size * 0.3).rounded()
        let widths = runs.map { CGFloat(CTLineGetTypographicBounds($0.line, nil, nil, nil)) }
        let changeWidth = CGFloat(CTLineGetTypographicBounds(changeLine, nil, nil, nil))
        let hasTriangle = direction != .flat && change != nil
        var textWidth = zip(widths, runs).reduce(0) { $0 + $1.0 + $1.1.gapAfter }
        textWidth += (hasTriangle ? triangle.width + triangleGap : 0) + changeWidth
        textWidth = textWidth.rounded(.up)
        let textHeight = (ascent + descent).rounded(.up)

        let pad = style.padding
        let canvas = CGSize(width: textWidth + pad * 2, height: textHeight + pad * 2)
        let pixelsWide = Int((canvas.width * style.scale).rounded(.up))
        let pixelsHigh = Int((canvas.height * style.scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.scaleBy(x: style.scale, y: style.scale)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsAntialiasing(true)

        // Two shadows composited once over the whole line: a tight one for the edges of the glyphs,
        // a wide soft one that lifts the text off busy photographs. Like the labels on the desktop.
        let shadowColor = style.ground == .dark ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.7)
        let glowColor = style.ground == .dark ? CGColor(gray: 0, alpha: 0.32) : CGColor(gray: 1, alpha: 0.45)
        context.setShadow(offset: .zero, blur: size * 0.7, color: glowColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: CGSize(width: 0, height: style.ground == .dark ? -0.5 : 0), blur: size * 0.16, color: shadowColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        let baseline = pad + descent
        var x = pad
        for (index, run) in runs.enumerated() {
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(run.line, context)
            x += widths[index] + run.gapAfter
        }
        if hasTriangle {
            let rect = CGRect(x: x, y: baseline + (capHeight - triangle.height) / 2, width: triangle.width, height: triangle.height)
            context.setFillColor(changeColor.cgColor())
            context.addPath(roundedTriangle(in: rect, pointingUp: direction == .up, radius: size * 0.06))
            context.fillPath()
            x += triangle.width + triangleGap
        }
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(changeLine, context)

        context.endTransparencyLayer()
        context.endTransparencyLayer()

        guard let image = context.makeImage() else { return nil }
        let key = [label, labelColor?.hexString ?? "-", price.text, changeText, "\(direction)", "\(flash.map { "\($0)" } ?? "-")", "\(style)"].joined(separator: "|")
        return TapeItem(symbol: quote.symbol, key: key, image: image, size: CGSize(width: textWidth, height: textHeight), padding: pad)
    }

    /// An equilateral-ish triangle with softened corners, so it sits with the type rather than shouting.
    static func roundedTriangle(in rect: CGRect, pointingUp: Bool, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let apex = pointingUp ? CGPoint(x: rect.midX, y: rect.maxY) : CGPoint(x: rect.midX, y: rect.minY)
        let left = pointingUp ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY)
        let right = pointingUp ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.maxX, y: rect.maxY)
        let start = CGPoint(x: (left.x + right.x) / 2, y: left.y)
        path.move(to: start)
        path.addArc(tangent1End: right, tangent2End: apex, radius: radius)
        path.addArc(tangent1End: apex, tangent2End: left, radius: radius)
        path.addArc(tangent1End: left, tangent2End: right, radius: radius)
        path.closeSubpath()
        return path
    }
}
