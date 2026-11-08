import AppKit

/// Tape's mark: the tape taking one step up, and the live price at its end.
enum Mark {
    /// The line, in a unit square (origin bottom left).
    static let steps: [CGPoint] = [
        CGPoint(x: 0.06, y: 0.38), CGPoint(x: 0.44, y: 0.38), CGPoint(x: 0.56, y: 0.62), CGPoint(x: 0.70, y: 0.62),
    ]
    static let dot = CGPoint(x: 0.89, y: 0.62)
    static let lineWidth: CGFloat = 0.13
    static let dotDiameter: CGFloat = 0.15

    static func linePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let points = steps.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        path.addLines(between: points)
        return path
    }

    static func dotRect(in rect: CGRect) -> CGRect {
        let d = dotDiameter * rect.width
        return CGRect(x: rect.minX + dot.x * rect.width - d / 2, y: rect.minY + dot.y * rect.height - d / 2, width: d, height: d)
    }

    /// A template image for the menu bar.
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(lineWidth * rect.width * 1.05)
            context.setStrokeColor(NSColor.black.cgColor)
            context.addPath(linePath(in: rect))
            context.strokePath()
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: dotRect(in: rect).insetBy(dx: -0.4, dy: -0.4))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tape"
        return image
    }
}
