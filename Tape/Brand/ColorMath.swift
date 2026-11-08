import AppKit
import CoreGraphics

/// An sRGB colour, 0…1 per channel.
nonisolated struct RGB: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent))
    }

    var hexString: String {
        let channel = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    func nsColor(alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var isInGamut: Bool {
        [r, g, b].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
    }

    var clamped: RGB {
        RGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }

    // MARK: OKLab (Björn Ottosson), for adjusting lightness without shifting the hue

    var oklab: OKLab {
        let lr = Self.linear(r), lg = Self.linear(g), lb = Self.linear(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return OKLab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    init(_ lab: OKLab) {
        let l = pow(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b, 3)
        let m = pow(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b, 3)
        let s = pow(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b, 3)
        r = Self.gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        g = Self.gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        b = Self.gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        let sign: Double = c < 0 ? -1 : 1
        let c = abs(c)
        return sign * (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }
}

nonisolated struct OKLab: Hashable, Sendable {
    var l: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    /// Degrees, 0…360.
    var hue: Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(l: Double, chroma: Double, hue: Double) {
        let radians = hue * .pi / 180
        self.init(l: l, a: chroma * cos(radians), b: chroma * sin(radians))
    }
}

/// What the tape is drawn over.
nonisolated enum Ground: Sendable, Equatable {
    case dark, light
}

/// Brand colours are chosen for white paper, not for a photograph behind the Dock. These keep
/// each hue but move its lightness into a band that reads on the ground it's drawn on.
nonisolated enum Legibility {
    static func lightnessBand(for ground: Ground) -> ClosedRange<Double> {
        switch ground {
        case .dark: 0.74...0.93
        case .light: 0.34...0.56
        }
    }

    static func adjust(_ color: RGB, for ground: Ground) -> RGB {
        let lab = color.oklab
        let band = lightnessBand(for: ground)
        let lightness = min(max(lab.l, band.lowerBound), band.upperBound)
        return inGamut(l: lightness, chroma: lab.chroma, hue: lab.hue)
    }

    /// The most colourful sRGB colour with this lightness and hue, up to the chroma asked for.
    static func inGamut(l: Double, chroma: Double, hue: Double) -> RGB {
        let wanted = RGB(OKLab(l: l, chroma: chroma, hue: hue))
        if wanted.isInGamut { return wanted.clamped }
        var low = 0.0, high = chroma
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if RGB(OKLab(l: l, chroma: mid, hue: hue)).isInGamut { low = mid } else { high = mid }
        }
        return RGB(OKLab(l: l, chroma: low, hue: hue)).clamped
    }
}
