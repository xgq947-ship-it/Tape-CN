import AppKit
import ImageIO

/// Looks at the wallpaper right behind the tape to choose light or dark text.
nonisolated enum Wallpaper {
    nonisolated struct Sample: Equatable, Sendable {
        /// Mean OKLab lightness, 0…1.
        var lightness: Double
        var ground: Ground { lightness > 0.68 ? .light : .dark }
    }

    nonisolated enum Scaling: Sendable { case fill, fit, stretch, center }

    /// - Parameters:
    ///   - region: the tape's frame, relative to the screen's bottom-left corner.
    static func sample(imageAt url: URL, screenSize: CGSize, region: CGRect, scaling: Scaling) -> Sample? {
        guard let image = thumbnail(url) else { return nil }
        return sample(image, screenSize: screenSize, region: region, scaling: scaling)
    }

    static func sample(_ image: CGImage, screenSize: CGSize, region: CGRect, scaling: Scaling) -> Sample? {
        let columns = 64, rows = 12
        guard let context = render(image, screenSize: screenSize, region: region, scaling: scaling, pixels: CGSize(width: columns, height: rows)),
              let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: columns * rows * 4)
        var total = 0.0
        for index in 0..<(columns * rows) {
            let rgb = RGB(r: Double(pixels[index * 4]) / 255, g: Double(pixels[index * 4 + 1]) / 255, b: Double(pixels[index * 4 + 2]) / 255)
            total += rgb.oklab.l
        }
        return Sample(lightness: total / Double(columns * rows))
    }

    /// The part of the wallpaper behind `region`, for the preview in Settings.
    static func crop(imageAt url: URL, screenSize: CGSize, region: CGRect, scaling: Scaling, scale: CGFloat) -> CGImage? {
        guard let image = thumbnail(url) else { return nil }
        let pixels = CGSize(width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
        return render(image, screenSize: screenSize, region: region, scaling: scaling, pixels: pixels)?.makeImage()
    }

    /// Draws the wallpaper the way the desktop does, then keeps only `region`, at `pixels` size.
    private static func render(_ image: CGImage, screenSize: CGSize, region: CGRect, scaling: Scaling, pixels: CGSize) -> CGContext? {
        guard region.width > 1, region.height > 1, screenSize.width > 0, screenSize.height > 0, pixels.width >= 1, pixels.height >= 1 else { return nil }
        let imageSize = CGSize(width: image.width, height: image.height)
        let drawn: CGRect
        switch scaling {
        case .stretch:
            drawn = CGRect(origin: .zero, size: screenSize)
        case .fill, .fit, .center:
            let ratio: CGFloat = switch scaling {
            case .fill: max(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            case .fit: min(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            default: 1
            }
            let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
            drawn = CGRect(x: (screenSize.width - size.width) / 2, y: (screenSize.height - size.height) / 2, width: size.width, height: size.height)
        }
        let width = Int(pixels.width), height = Int(pixels.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Whatever the wallpaper doesn't cover shows the desktop colour; assume mid grey.
        context.setFillColor(CGColor(gray: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / region.width, y: CGFloat(height) / region.height)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.draw(image, in: drawn)
        return context
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func scaling(for screen: NSScreen) -> Scaling {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let allowClipping = options[.allowClipping] as? Bool ?? true
        guard let raw = options[.imageScaling] as? UInt, let scaling = NSImageScaling(rawValue: raw) else { return .fill }
        switch scaling {
        case .scaleAxesIndependently: return .stretch
        case .scaleNone: return .center
        case .scaleProportionallyUpOrDown, .scaleProportionallyDown: return allowClipping ? .fill : .fit
        @unknown default: return .fill
        }
    }
}
