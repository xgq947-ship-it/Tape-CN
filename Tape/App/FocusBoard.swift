import AppKit

/// `Tape -TapeFocusBoard <folder>`: the pictures for brand/focus.html, every one drawn by Focus
/// itself over the real wallpaper beside the real Dock. The states (up, down, flat, closed, light)
/// use sample days, so each shows a whole session; the rest use today's prices.
enum FocusBoard {
    /// The bottom corner of the screen where the tape runs, in its own coordinates.
    struct Scene {
        var local: CGRect
        var tiles: CGRect
        var size: CGSize
        var wallpaper: CGImage?
        var sampled: Ground?
        var scale: CGFloat

        /// The scene with `draw` on top: over the wallpaper, or over a pale one for dark text.
        func image(light: Bool = false, _ draw: (CGContext) -> Void) -> CGImage? {
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            let rect = CGRect(origin: .zero, size: size)
            if light {
                let pale = CGGradient(colorsSpace: nil, colors: [RGB(hex: 0xEDE8E0).cgColor(), RGB(hex: 0xD9D3CA).cgColor()] as CFArray, locations: [0, 1])!
                context.drawLinearGradient(pale, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
            } else if let wallpaper {
                context.draw(wallpaper, in: rect)
            }
            Preview.drawDock(tiles, in: context)
            draw(context)
            return context.makeImage()
        }
    }

    static func scene(_ model: AppModel, height: CGFloat, scale: CGFloat) -> Scene? {
        guard let layout = DockLocator.locate(),
              let screen = NSScreen.screens.first(where: { $0.frame == layout.screenFrame }) ?? NSScreen.main,
              let frame = TickerController.frame(for: layout, side: model.settings.side, gap: model.settings.dockGap, height: height) else { return nil }
        let onScreen = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let tiles = layout.tiles.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        // From the screen's edge to a little way into the Dock.
        let top = max(onScreen.maxY, tiles.maxY) + 18
        let region = model.settings.side == .left
            ? CGRect(x: 0, y: 0, width: min(screen.frame.width, onScreen.maxX + 140), height: top)
            : CGRect(x: max(0, onScreen.minX - 140), y: 0, width: screen.frame.width - max(0, onScreen.minX - 140), height: top)
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let scaling = Wallpaper.scaling(for: screen)
        let wallpaper = url.flatMap { Wallpaper.crop(imageAt: $0, screenSize: screen.frame.size, region: region, scaling: scaling, scale: scale) }
        let sampled = url.flatMap { Wallpaper.sample(imageAt: $0, screenSize: screen.frame.size, region: onScreen, scaling: scaling)?.ground }
        return Scene(local: onScreen.offsetBy(dx: -region.minX, dy: 0), tiles: tiles.offsetBy(dx: -region.minX, dy: 0),
                     size: region.size, wallpaper: wallpaper, sampled: sampled, scale: scale)
    }

    static func export(_ model: AppModel, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scale: CGFloat = 2
        let trailing = model.settings.side == .left
        var anatomy: [String: Any] = [:]

        func style(_ scene: Scene, glass: Bool = false, fontSize: CGFloat? = nil, light: Bool = false) -> TapeStyle {
            var style = model.tapeStyle(scale: scene.scale, design: .focus)
            style.focusGlass = glass
            if let fontSize { style.fontSize = fontSize }
            if glass {
                style.ground = .dark
            } else if light {
                style.ground = .light
            } else if model.settings.contrast == .automatic, let sampled = scene.sampled {
                style.ground = sampled
            }
            return style
        }

        func picture(_ slide: FocusSlide, _ style: TapeStyle, _ scene: Scene, light: Bool = false, countdown: CGFloat = 0.35) -> (CGImage?, FocusMetrics.Layout) {
            let metrics = FocusMetrics(fontSize: style.fontSize, glass: style.focusGlass)
            let layout = metrics.layout(in: scene.local, gridWidth: slide.size.width, trailing: trailing, clock: slide.clock, tile: slide.tile)
            let image = scene.image(light: light) { context in
                if metrics.glass {
                    Preview.drawGlass(layout.platter, radius: metrics.platterRadius(tile: slide.tile), wallpaper: scene.wallpaper, regionSize: scene.size, scale: scene.scale, in: context)
                }
                FocusRenderer.draw(slide, layout: layout, metrics: metrics, countdown: slide.clock ? countdown : -1, in: context)
            }
            return (image, layout)
        }

        func save(_ image: CGImage?, _ name: String) {
            guard let image else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: name))
        }

        func file(_ symbol: String) -> String {
            symbol.lowercased().replacingOccurrences(of: "^", with: "").replacingOccurrences(of: ".", with: "-")
        }

        let base = FocusMetrics(fontSize: model.settings.fontSize)
        guard let scene = scene(model, height: base.height, scale: scale) else { return }
        let watchlist = model.settings.watchlist.compactMap(model.focusListing(for:))

        // Today, every listing, clear and on glass.
        for glass in [false, true] {
            let style = style(scene, glass: glass)
            let slides = FocusRenderer.slides(for: watchlist, style: style, room: scene.local.width)
            for slide in slides {
                save(picture(slide, style, scene).0, "\(glass ? "glass" : "clear")-\(file(slide.symbol)).png")
            }
        }

        // Sample days, on one shared grid like the real thing.
        let samples: [(String, Double, Double)] = [("NVDA", 3.12, 0.72), ("TSLA", -2.47, 0.55), ("MSFT", 0.002, 0.4), ("ASML.AS", 1.08, 1)]
        let sampled = samples.compactMap { symbol, move, progress -> FocusListing? in
            guard var listing = watchlist.first(where: { $0.quote.symbol == symbol }) else { return nil }
            listing.quote = sampleDay(listing.quote, move: move, progress: progress, seed: symbol.unicodeScalars.reduce(7) { $0 &* 31 &+ UInt64($1.value) })
            return listing
        }
        let names = ["up", "down", "flat", "closed"]
        for glass in [false, true] {
            let style = style(scene, glass: glass)
            let metrics = FocusMetrics(fontSize: style.fontSize, glass: glass)
            let slides = FocusRenderer.slides(for: sampled, style: style, room: scene.local.width)
            for (index, slide) in slides.enumerated() where index < names.count {
                let (image, layout) = picture(slide, style, scene)
                save(image, "state-\(names[index])\(glass ? "-glass" : "").png")
                if index == 0 {
                    anatomy[glass ? "glass" : "clear"] = describe(slide, layout: layout, metrics: metrics, height: scene.size.height)
                }
            }
        }
        anatomy["scene"] = ["width": scene.size.width, "height": scene.size.height, "scale": scale]

        // Dark text for pale wallpapers.
        do {
            let style = style(scene, light: true)
            let slides = FocusRenderer.slides(for: sampled, style: style, room: scene.local.width)
            for (index, slide) in slides.prefix(2).enumerated() {
                save(picture(slide, style, scene, light: true).0, "light-\(names[index]).png")
            }
        }

        // The countdown, a quarter, half and nearly all the way round.
        if let first = sampled.first {
            let style = style(scene)
            if let slide = FocusRenderer.slides(for: [first], style: style, room: scene.local.width).first {
                for (index, amount) in [0.08, 0.5, 0.92].enumerated() {
                    save(picture(slide, style, scene, countdown: amount).0, "ring-\(index).png")
                }
            }
        }

        // Three text sizes.
        for size: CGFloat in [12, 14, 18] {
            let metrics = FocusMetrics(fontSize: size)
            guard let scene = self.scene(model, height: metrics.height, scale: scale), let first = sampled.first else { continue }
            let style = style(scene, fontSize: size)
            if let slide = FocusRenderer.slides(for: [first], style: style, room: scene.local.width).first {
                save(picture(slide, style, scene).0, "size-\(Int(size)).png")
            }
        }

        // Tiles, large: the watchlist's logos, then what stands in when there's no logo.
        let tileStyle = TapeStyle(fontSize: 14, ground: .dark, scale: 4, design: .focus)
        let metrics = FocusMetrics(fontSize: 14)
        var tiles = watchlist
        if let template = watchlist.first?.quote {
            func standIn(_ label: String, _ kind: Quote.Kind, _ brand: UInt32?) -> FocusListing {
                var quote = template
                quote.kind = kind
                return FocusListing(label: label, name: label, brand: brand.map(RGB.init(hex:)), logo: nil, glyph: AppModel.glyph(for: kind, label: label), quote: quote)
            }
            tiles += [standIn("ETH", .crypto, 0x627EEA), standIn("EUR/USD", .currency, nil), standIn("Gold", .future, 0xB8932F), standIn("XYZ", .stock, nil)]
        }
        for (index, listing) in tiles.enumerated() {
            let room: CGFloat = 14
            guard let canvas = Bitmap(size: CGSize(width: metrics.tile + room * 2, height: metrics.tile + room * 2), scale: tileStyle.scale) else { continue }
            FocusRenderer.drawTile(listing, in: CGRect(x: room, y: room, width: metrics.tile, height: metrics.tile), metrics: metrics, style: tileStyle, canvas: canvas)
            save(canvas.image(), String(format: "tile-%02d.png", index))
        }
        anatomy["tiles"] = tiles.count

        if let data = try? JSONSerialization.data(withJSONObject: anatomy, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appending(path: "anatomy.json"))
        }
    }

    /// Where everything sits, measured from the top left of the picture, for the construction drawing.
    private static func describe(_ slide: FocusSlide, layout: FocusMetrics.Layout, metrics: FocusMetrics, height: CGFloat) -> [String: Any] {
        func box(_ rect: CGRect) -> [String: CGFloat] {
            ["x": rect.minX, "y": height - rect.maxY, "w": rect.width, "h": rect.height]
        }
        let grid = layout.grid
        var columns: [[String: Any]] = []
        for part in slide.parts {
            let frame = part.frame.insetBy(dx: metrics.room, dy: 0).offsetBy(dx: grid.minX, dy: grid.minY)
            columns.append(["name": "\(part.column)", "x": frame.minX, "w": frame.width])
        }
        let lines = FocusRenderer.baselines(metrics)
        let tile = CGRect(x: grid.minX, y: grid.minY + ((metrics.height - metrics.tile) / 2).rounded(), width: metrics.tile, height: metrics.tile)
        return [
            "grid": box(grid), "ring": box(layout.ring), "platter": box(layout.platter), "tile": box(tile), "columns": columns,
            "baselines": ["label": height - (grid.minY + lines.label), "name": height - (grid.minY + lines.name), "price": height - (grid.minY + lines.price)],
            "tileRadius": metrics.tileRadius, "platterRadius": metrics.platterRadius,
        ]
    }

    /// A believable day: an opening gap, then a walk that ends where the move says.
    static func sampleDay(_ quote: Quote, move: Double, progress: Double, seed: UInt64) -> Quote {
        var quote = quote
        let base = quote.previousClose ?? quote.price
        let length: TimeInterval = 6.5 * 3600
        let now = Date()
        let start = progress < 1 ? now.addingTimeInterval(-length * progress) : now.addingTimeInterval(-length - 3600)
        quote.sessionStart = start
        quote.sessionEnd = start.addingTimeInterval(length)
        quote.previousClose = base
        quote.reportedChangePercent = move
        quote.price = base * (1 + move / 100)
        let count = max(3, Int(78 * min(progress, 1)))
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var walk: [Double] = [0]
        for _ in 1..<count { walk.append(walk[walk.count - 1] + (random() - 0.5)) }
        let first = base * (1 + move * 0.3 / 100), last = quote.price
        let wobble = base * (abs(move) < 0.5 ? 0.0005 : 0.0021)
        quote.intraday = (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            let bridge = walk[index] - walk[count - 1] * t
            return Quote.Point(time: start.addingTimeInterval(Double(index) * 300), value: first + (last - first) * t + bridge * wobble)
        }
        quote.open = first
        quote.marketTime = quote.intraday[quote.intraday.count - 1].time
        return quote
    }
}
