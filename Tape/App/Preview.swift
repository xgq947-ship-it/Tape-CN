import AppKit
import CoreImage

/// Still images of the tape over the wallpaper behind it, for the README and for checking the
/// drawing without a screen recording:
///   `Tape -TapeRender <file.png>`        the current design
///   `Tape -TapeRenderAll <folder>`       every design, one file each
///   `-TapeScale 1`                       at 1× instead of 2×
///   `-TapeStrip 368`                     as if the Dock left a strip that wide
///   `Tape -TapeFocusBoard <folder>`      the pictures for brand/focus.html (see FocusBoard)
///   `Tape -TapeDockInfo <file.txt>`      what Tape measures of the Dock (open it with `open`, so
///                                        it runs with Tape's own Accessibility access)
/// The glass is simulated with a blur of the same wallpaper; on the desktop the system does it.
enum Preview {
    static func runIfAsked(model: AppModel) -> Bool {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "TapeRender") {
            Task {
                await prepare(model)
                await render(model, design: model.settings.design, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return true
        }
        if let path = defaults.string(forKey: "TapeDockInfo") {
            try? DockLocator.report().write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return true
        }
        if let path = defaults.string(forKey: "TapeFocusBoard") {
            Task {
                await prepare(model)
                FocusBoard.export(model, into: URL(fileURLWithPath: path, isDirectory: true))
                NSApp.terminate(nil)
            }
            return true
        }
        if let path = defaults.string(forKey: "TapeRenderAll") {
            Task {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await prepare(model)
                for design in TapeDesign.allCases {
                    await render(model, design: design, to: folder.appending(path: "\(design.rawValue).png"))
                }
                NSApp.terminate(nil)
            }
            return true
        }
        return false
    }

    static func prepare(_ model: AppModel) async {
        let symbols = model.settings.watchlist.map(\.symbol)
        model.market.symbols = symbols
        model.market.start()
        model.brands.prepare(symbols)
        for _ in 0..<60 where model.market.quotes.count < symbols.count || model.market.isLoading {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(3))
    }

    private static func render(_ model: AppModel, design: TapeDesign, to url: URL) async {
        let asked = CGFloat(UserDefaults.standard.double(forKey: "TapeScale"))
        let scale: CGFloat = asked > 0 ? asked : 2
        guard var layout = DockLocator.locate(),
              let screen = NSScreen.screens.first(where: { $0.frame == layout.screenFrame }) ?? NSScreen.main else { return }
        // `-TapeStrip 74`: as if the Dock left a strip that wide, to check another screen's fit.
        let strip = CGFloat(UserDefaults.standard.double(forKey: "TapeStrip"))
        if strip > 0, layout.edge == .bottom, model.settings.side == .left {
            layout.tiles.origin.x = layout.screenFrame.minX + 14 + strip + model.settings.dockGap
        }
        var style = model.tapeStyle(scale: scale, design: design)
        let metrics = style.metrics
        guard let frame = TickerController.frame(for: layout, side: model.settings.side, gap: model.settings.dockGap, height: metrics.height) else { return }
        let local = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let scaling = Wallpaper.scaling(for: screen)
        if design.followsWallpaper, model.settings.contrast == .automatic, let wallpaperURL,
           let sample = Wallpaper.sample(imageAt: wallpaperURL, screenSize: screen.frame.size, region: local, scaling: scaling) {
            model.ground = sample.ground
            style = model.tapeStyle(scale: scale, design: design)
        }

        // The bottom-left of the screen: the tape, and the start of the Dock beside it.
        let tiles = layout.tiles.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let region = CGRect(x: 0, y: 0, width: min(screen.frame.width, local.maxX + 260), height: max(local.maxY, tiles.maxY) + 22)
        let width = Int(region.width * scale), height = Int(region.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        let wallpaper = wallpaperURL.flatMap {
            Wallpaper.crop(imageAt: $0, screenSize: screen.frame.size, region: region, scaling: scaling, scale: scale)
        }
        if let wallpaper { context.draw(wallpaper, in: CGRect(origin: .zero, size: region.size)) }
        drawDock(tiles, in: context)

        let panel = local.insetBy(dx: metrics.backdropInset, dy: metrics.backdropInset)
        let tape = panel.insetBy(dx: metrics.tapeInsets.width, dy: metrics.tapeInsets.height)
        drawBackdrop(design, panel: panel, tape: tape, metrics: metrics, wallpaper: wallpaper, regionSize: region.size, scale: scale, in: context)

        if design == .focus {
            if let slide = model.focusSlides(style: style, room: local.width).first {
                let focus = FocusMetrics(fontSize: style.fontSize, glass: style.focusGlass)
                let centre = TickerController.corner(for: layout, side: model.settings.side).map { $0 - screen.frame.minX }
                let layout = focus.layout(in: local, gridWidth: slide.size.width, trailing: model.settings.side == .left, clock: slide.clock, tile: slide.tile, centre: centre)
                if focus.glass {
                    drawGlass(layout.platter, radius: focus.platterRadius(tile: slide.tile), wallpaper: wallpaper, regionSize: region.size, scale: scale, in: context)
                }
                FocusRenderer.draw(slide, layout: layout, metrics: focus, countdown: slide.clock ? 0.35 : -1, in: context)
            }
        } else {
            let items = model.settings.watchlist.compactMap { model.renderItem(for: $0, style: style) }
            context.saveGState()
            context.clip(to: tape)
            var x = tape.minX + (metrics.step.map { $0 * 4 } ?? style.fontSize * 1.5)
            if let step = metrics.step { x = tape.minX + ((x - tape.minX) / step).rounded() * step }
            for item in items where x < tape.maxX {
                let y = tape.minY + ((tape.height - item.size.height) / 2).rounded() - item.padding
                context.draw(item.image, in: CGRect(x: x - item.padding, y: y, width: item.size.width + item.padding * 2, height: item.size.height + item.padding * 2))
                x += item.size.width + metrics.spacing
            }
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A stand-in for the Dock's glass, so the still shows where the tape stops.
    static func drawDock(_ tiles: CGRect, in context: CGContext) {
        let path = CGPath(roundedRect: tiles, cornerWidth: 26, cornerHeight: 26, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 0.16))
        context.fillPath()
        context.addPath(CGPath(roundedRect: tiles.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 25.5, cornerHeight: 25.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
        context.setLineWidth(1)
        context.strokePath()
        let colors: [UInt32] = [0x2E8BF6, 0xDADADF, 0x2A9BFF, 0x3D7BF7, 0xF2A33A]
        for (index, hex) in colors.enumerated() {
            let tile = CGRect(x: tiles.minX + 10 + CGFloat(index) * 69, y: tiles.midY - 32.5, width: 65, height: 65)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 15, cornerHeight: 15, transform: nil))
            context.setFillColor(RGB(hex: hex).cgColor())
            context.fillPath()
        }
        context.restoreGState()
    }

    private static func drawBackdrop(_ design: TapeDesign, panel: CGRect, tape: CGRect, metrics: DesignMetrics, wallpaper: CGImage?, regionSize: CGSize, scale: CGFloat, in context: CGContext) {
        let radius = metrics.cornerRadius
        let shape = CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil)
        switch design {
        case .liquid:
            // What the system's glass shows: the wallpaper behind, blurred, deepened and more saturated.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: CGColor(gray: 0, alpha: 0.28))
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 0.01))
            context.fillPath()
            context.restoreGState()
            if let wallpaper, let blurred = blur(wallpaper, size: regionSize, scale: scale) {
                context.saveGState()
                context.addPath(shape)
                context.clip()
                context.draw(blurred, in: CGRect(origin: .zero, size: regionSize))
                context.setFillColor(CGColor(gray: 0.08, alpha: 0.42))
                context.fill(panel)
                context.restoreGState()
            }
        case .led, .paper:
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: design == .paper ? -2.5 : -2), blur: design == .paper ? 10 : 14,
                              color: CGColor(gray: 0, alpha: design == .paper ? 0.34 : 0.28))
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        case .classic, .aura, .focus:
            return
        }
        if let image = Backdrops.image(for: design, size: panel.size, metrics: metrics, scale: scale) {
            context.draw(image, in: panel)
        }
        if design == .led, let step = metrics.step, let grid = LEDRenderer.grid(size: tape.size, pitch: step, scale: scale) {
            context.draw(grid, in: tape)
        }
    }

    /// What the system's glass shows: the wallpaper behind, blurred, deepened and more saturated, under a lit rim.
    static func drawGlass(_ rect: CGRect, radius: CGFloat, wallpaper: CGImage?, regionSize: CGSize, scale: CGFloat, in context: CGContext) {
        let shape = Shapes.continuous(rect, radius: radius)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0, alpha: 0.01))
        context.fillPath()
        context.restoreGState()
        if let wallpaper, let blurred = blur(wallpaper, size: regionSize, scale: scale) {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.draw(blurred, in: CGRect(origin: .zero, size: regionSize))
            context.setFillColor(CGColor(gray: 0.08, alpha: 0.42))
            context.fill(rect)
            context.restoreGState()
        }
        if let edge = Backdrops.glassEdge(size: rect.size, radius: radius, scale: scale, continuous: true) {
            context.draw(edge, in: rect)
        }
    }

    static func blur(_ image: CGImage, size: CGSize, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: 16 * scale])?.outputImage,
              let saturated = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: blurred, kCIInputSaturationKey: 1.5])?.outputImage
        else { return nil }
        return CIContext().createCGImage(saturated, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
