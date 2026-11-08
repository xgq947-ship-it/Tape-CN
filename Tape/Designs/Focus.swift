import AppKit
import CoreImage
import CoreText

// MARK: - What Focus shows

/// One listing, before Focus draws it.
nonisolated struct FocusListing: @unchecked Sendable {
    var label: String
    var name: String
    var brand: RGB?
    var logo: CGImage?
    /// A symbol, drawn as a vector at the tile's size.
    var glyph: NSImage?
    var quote: Quote
}

/// One listing in Focus. It's drawn as separate columns on a grid that every listing shares, so the
/// tile, the name, the price, the move and the chart each keep their place from one listing to the
/// next, and each can come into focus on its own.
nonisolated struct FocusSlide: @unchecked Sendable {
    nonisolated enum Column: Int, CaseIterable, Sendable { case tile, identity, price, move, chart }

    nonisolated struct Part: @unchecked Sendable {
        var column: Column
        var image: CGImage
        /// Where it sits on the slide, in points, with room around it for its shadow.
        var frame: CGRect
        /// Everything it shows: a column that hasn't changed stays still while the others move.
        var key: String
    }

    var symbol: String
    var price: Double
    var parts: [Part]
    /// The grid: as wide as its columns and as tall as the window. Shadows spill past it.
    var size: CGSize
    /// Where the chart ends while its market trades, which is where the live dot breathes.
    var live: CGPoint?
    var accent: RGB
    var isDark: Bool
    /// A soft shade behind the whole grid, so text keeps its contrast over a busy photograph.
    /// The same picture for every slide on a grid; `veilFrame` is relative to the grid.
    var veil: CGImage?
    var veilFrame: CGRect = .zero
    /// Whether there's room for the countdown beside the slide.
    var clock = true
    /// The tile's side: smaller in the compact layout. The glass's padding and corners follow it.
    var tile: CGFloat = 0

    var key: String { parts.map(\.key).joined(separator: "‖") }
    func part(_ column: Column) -> Part? { parts.first { $0.column == column } }
}

// MARK: - Geometry

/// Focus's sizes at a text size, and where the grid, the countdown and the glass go.
nonisolated struct FocusMetrics: Equatable, Sendable {
    let fontSize: CGFloat
    let height: CGFloat
    let tile: CGFloat
    let glass: Bool

    init(fontSize f: CGFloat, glass: Bool = false) {
        fontSize = f
        height = max(56, (f * 4).rounded())
        tile = (height * 0.57).rounded()
        self.glass = glass
    }

    /// An app icon's corner, so a logo looks at home next to the Dock.
    var tileRadius: CGFloat { tile * 0.225 }
    /// Room around each column for its shadow, and for the blur it passes through.
    var room: CGFloat { (fontSize * 0.75).rounded(.up) }

    var labelFont: NSFont { Typeface.font((fontSize * 1.07).rounded(), .semibold) }
    var nameFont: NSFont { Typeface.font((fontSize * 0.8).rounded(), .regular) }
    var priceFont: NSFont { Typeface.font((fontSize * 1.6).rounded(), .semibold, design: .rounded, tabular: true) }
    /// The currency mark and units: smaller than the number, hung from its cap height.
    var markFont: NSFont { Typeface.font((fontSize * 1.0).rounded(), .semibold, design: .rounded) }
    var moveFont: NSFont { Typeface.font((fontSize * 0.86).rounded(), .semibold, design: .rounded, tabular: true) }

    var stackGap: CGFloat { (fontSize * 0.34).rounded() }
    var pillHeight: CGFloat { (fontSize * 1.43).rounded() }
    var pillPadding: CGFloat { (fontSize * 0.5).rounded() }
    var chartHeight: CGFloat { (fontSize * 1.45).rounded() }

    /// A chart a little over four, three or two and a half characters wide.
    func chartWidth(_ size: Int) -> CGFloat { (fontSize * [4, 3, 2.4][min(max(size, 0), 2)]).rounded() }

    /// Between tile and name, name and price, price and move, move and chart.
    func gaps(tight: Bool) -> [CGFloat] {
        (tight ? [0.5, 0.71, 0.43, 0.57] : [0.72, 1.15, 0.64, 0.86]).map { (fontSize * $0).rounded() }
    }

    // The countdown: a small ring between the slide and the Dock that closes as the next listing
    // approaches, from twelve o'clock round.
    var ringDiameter: CGFloat { max(11, (fontSize * 0.86).rounded()) }
    var ringLine: CGFloat { 1.5 }
    var ringGap: CGFloat { (tile * 0.34).rounded() }

    // The glass, when there is one: as tall as the window allows, with corners concentric with
    // the tile's, so tile and glass read as one object.
    var platterInset: CGFloat { glass ? 4 : 0 }
    var platterHeight: CGFloat { height - platterInset * 2 }
    var platterPadding: CGFloat { platterPadding(tile: tile) }
    var platterRadius: CGFloat { platterRadius(tile: tile) }
    func platterPadding(tile: CGFloat) -> CGFloat { glass ? ((platterHeight - tile) / 2).rounded() : 0 }
    func platterRadius(tile: CGFloat) -> CGFloat { tile * 0.225 + platterPadding(tile: tile) }
    /// Room left at the Dock's end of the window: for the glass's shadow, or a pixel of air.
    private var dockEdge: CGFloat { glass ? 6 : 2 }
    /// The ring's inset from the glass's end, so it sits as far in as the tile does at the other.
    private func ringPadding(tile: CGFloat) -> CGFloat { glass ? ((platterHeight - ringDiameter) / 2 * 0.62).rounded() : 0 }
    /// Room on the far side for the tile's shadow, when the slide fills the strip.
    private var outerRoom: CGFloat { glass ? 6 : 5 }

    /// How wide the grid can be in a window this wide, with or without the countdown beside it.
    func gridRoom(in width: CGFloat, clock: Bool = true, tile: CGFloat? = nil) -> CGFloat {
        let tile = tile ?? self.tile
        let end = clock ? ringPadding(tile: tile) + ringDiameter + ringGap : platterPadding(tile: tile)
        let chrome = dockEdge + end + platterPadding(tile: tile) + outerRoom
        return max(0, width - chrome)
    }

    nonisolated struct Layout: Equatable {
        var grid: CGRect
        var ring: CGRect
        var platter: CGRect
    }

    /// With the Dock to the right (`trailing`), the slide ends at the Dock; otherwise it starts there.
    /// Without the clock, the grid moves up to where the clock was. With a `centre` (the middle of
    /// the corner, between the screen's edge and the Dock's glass), a slide with room to spare sits
    /// in the middle of the corner instead, never closer to the Dock than the strip allows.
    func layout(in bounds: CGRect, gridWidth: CGFloat, trailing: Bool, clock: Bool = true, tile: CGFloat? = nil, centre: CGFloat? = nil) -> Layout {
        let placed = layout(in: bounds, gridWidth: gridWidth, trailing: trailing, clock: clock, tile: tile)
        guard let centre else { return placed }
        let lowest = bounds.minX + outerRoom - placed.platter.minX
        let highest = (bounds.maxX - dockEdge).rounded() - placed.platter.maxX
        guard lowest <= highest else { return placed }
        let shift = min(max((centre - placed.platter.midX).rounded(), lowest), highest)
        return Layout(grid: placed.grid.offsetBy(dx: shift, dy: 0), ring: placed.ring.offsetBy(dx: shift, dy: 0), platter: placed.platter.offsetBy(dx: shift, dy: 0))
    }

    private func layout(in bounds: CGRect, gridWidth: CGFloat, trailing: Bool, clock: Bool, tile: CGFloat?) -> Layout {
        let tile = tile ?? self.tile
        let padding = platterPadding(tile: tile)
        let ringY = (bounds.midY - ringDiameter / 2).rounded()
        let platterY = bounds.minY + platterInset
        // The clock and the gap after it, or nothing but the glass's padding.
        let end = clock ? ringPadding(tile: tile) + ringDiameter + ringGap : padding
        if trailing {
            let platterMaxX = (bounds.maxX - dockEdge).rounded()
            let ring = CGRect(x: platterMaxX - ringPadding(tile: tile) - ringDiameter, y: ringY, width: ringDiameter, height: ringDiameter)
            let grid = CGRect(x: platterMaxX - end - gridWidth, y: bounds.minY, width: gridWidth, height: bounds.height)
            let platter = CGRect(x: grid.minX - padding, y: platterY, width: platterMaxX - grid.minX + padding, height: platterHeight)
            return Layout(grid: grid, ring: ring, platter: platter)
        }
        let platterMinX = (bounds.minX + dockEdge).rounded()
        let ring = CGRect(x: platterMinX + ringPadding(tile: tile), y: ringY, width: ringDiameter, height: ringDiameter)
        let grid = CGRect(x: platterMinX + end, y: bounds.minY, width: gridWidth, height: bounds.height)
        let platter = CGRect(x: platterMinX, y: platterY, width: grid.maxX + padding - platterMinX, height: platterHeight)
        return Layout(grid: grid, ring: ring, platter: platter)
    }
}

/// How wide each column is, the same for every listing on the slide show.
nonisolated struct FocusGrid: Equatable, Sendable {
    var tile: CGFloat
    var identity: CGFloat
    var price: CGFloat
    var move: CGFloat
    /// Zero when there's no room for a chart, or nothing to chart.
    var chart: CGFloat
    var gaps: [CGFloat]

    var identityX: CGFloat { tile + gaps[0] }
    var priceX: CGFloat { identityX + identity + gaps[1] }
    var moveX: CGFloat { priceX + price + gaps[2] }
    var chartX: CGFloat { moveX + move + gaps[3] }
    var width: CGFloat { (chart > 0 ? chartX + chart : moveX + move).rounded(.up) }
}

// MARK: - Drawing

nonisolated enum FocusRenderer {
    /// What one listing will say, measured before the grid is chosen.
    private struct Measured {
        var listing: FocusListing
        var label: CTLine
        var labelWidth: CGFloat
        var subtitle: String
        var nameWidth: CGFloat
        var price: PriceText
        var move: String
        var direction: Change.Direction
        var moveWidth: CGFloat
        var hasChart: Bool
    }

    /// Every listing on one grid that fits a window `room` points wide. On a wide strip: tile, name,
    /// price, pill and chart in a row, where names give way first, then air, then the chart. On a
    /// narrow one (a laptop with a long Dock) Focus goes compact: the tile beside the ticker and its
    /// move over the price, without the clock, then smaller; narrowest, ticker, price and move stacked.
    static func slides(for listings: [FocusListing], style: TapeStyle, room: CGFloat = .infinity) -> [FocusSlide] {
        let metrics = FocusMetrics(fontSize: style.fontSize, glass: style.focusGlass)
        guard !listings.isEmpty else { return [] }
        let measured = listings.map { measure($0, metrics: metrics, style: style) }
        let wideRoom = metrics.gridRoom(in: room)
        let wide = grid(for: measured, metrics: metrics, maxWidth: wideRoom)
        if wide.width <= wideRoom {
            return finish(measured.compactMap { render($0, grid: wide, metrics: metrics, style: style) }, width: wide.width, metrics: metrics, style: style)
        }
        // Two lines beside the tile while they fit; then three, ticker over price over move, which
        // keeps the type a readable size in a strip only a few words wide.
        var compact: CompactGrid?
        for (scale, tile, clock) in [(1.0, true, true), (1.0, true, false), (0.9, true, false), (0.82, true, false)] {
            let grid = CompactGrid(listings, style: style, metrics: metrics, scale: scale, tile: tile, clock: clock)
            if grid.width <= metrics.gridRoom(in: room, clock: clock, tile: grid.tile) {
                compact = grid
                break
            }
        }
        if compact == nil {
            for scale in [1.0, 0.9, 0.82, 0.74] {
                var grid = CompactGrid(listings, style: style, metrics: metrics, scale: scale, tile: false, clock: false, stacked: true)
                let fits = metrics.gridRoom(in: room, clock: false, tile: grid.nominalTile)
                // Narrower still: the longest tickers give up their last letters.
                if scale == 0.74 { grid.narrow(to: fits) }
                compact = grid
                if grid.width <= fits { break }
            }
        }
        guard let compact else { return [] }
        let slides = listings.compactMap { renderCompact($0, grid: compact, metrics: metrics, style: style) }
        return finish(slides, width: compact.width, metrics: metrics, style: style)
    }

    /// The veil, which every slide on a grid shares.
    private static func finish(_ slides: [FocusSlide], width: CGFloat, metrics: FocusMetrics, style: TapeStyle) -> [FocusSlide] {
        let (veil, veilFrame) = style.focusGlass ? (nil, CGRect.zero) : veil(width: width, metrics: metrics, style: style)
        return slides.map {
            var slide = $0
            slide.veil = veil
            slide.veilFrame = veilFrame
            return slide
        }
    }

    private static func grid(for measured: [Measured], metrics m: FocusMetrics, maxWidth: CGFloat) -> FocusGrid {
        let f = m.fontSize
        let labels = measured.map(\.labelWidth).max() ?? 0
        let names = measured.map(\.nameWidth).max() ?? 0
        let price = (measured.map(\.price.width).max() ?? 0).rounded(.up)
        let move = ((measured.map(\.moveWidth).max() ?? 0) + m.pillPadding * 2).rounded(.up)
        let charts = measured.contains(where: \.hasChart)
        func identity(_ cap: CGFloat) -> CGFloat { max(labels, min(names, cap)).rounded(.up) }
        func grid(_ cap: CGFloat, tight: Bool, chart: CGFloat?) -> FocusGrid {
            FocusGrid(tile: m.tile, identity: identity(cap), price: price, move: move, chart: charts ? (chart ?? 0) : 0, gaps: m.gaps(tight: tight))
        }
        let options = [
            grid(f * 7.5, tight: false, chart: m.chartWidth(0)),
            grid(f * 5.5, tight: false, chart: m.chartWidth(0)),
            grid(f * 5.5, tight: false, chart: m.chartWidth(1)),
            grid(f * 5.5, tight: true, chart: m.chartWidth(1)),
            grid(f * 4, tight: true, chart: m.chartWidth(1)),
            grid(0, tight: true, chart: m.chartWidth(1)),
            grid(0, tight: true, chart: m.chartWidth(2)),
            grid(f * 5.5, tight: false, chart: nil),
            grid(0, tight: false, chart: nil),
            grid(0, tight: true, chart: nil),
        ]
        var chosen = options.first { $0.width <= maxWidth } ?? options[options.count - 1]
        // A chart takes whatever room is left, up to its full width.
        if chosen.chart > 0, maxWidth.isFinite {
            chosen.chart = min(m.chartWidth(0), (chosen.chart + maxWidth - chosen.width).rounded(.down))
        }
        return chosen
    }

    private static func measure(_ listing: FocusListing, metrics m: FocusMetrics, style: TapeStyle) -> Measured {
        let quote = listing.quote
        let label = Typeface.line(listing.label, m.labelFont, .init(hex: 0xFFFFFF))
        let subtitle = subtitle(for: listing)
        let name = Typeface.line(subtitle, m.nameFont, .init(hex: 0xFFFFFF))
        let price = PriceText(Format.price(quote.price, of: quote, showCurrency: style.showCurrency, compact: true), metrics: m, ink: style.primary, dims: style.ground == .dark ? 0.6 : 0.56)
        let (move, direction) = moveText(quote, style: style)
        let moveWidth = Typeface.width(Typeface.line(move, m.moveFont, .init(hex: 0xFFFFFF)))
        return Measured(listing: listing, label: label, labelWidth: Typeface.width(label), subtitle: subtitle, nameWidth: Typeface.width(name),
                        price: price, move: move, direction: direction, moveWidth: moveWidth, hasChart: quote.intraday.count > 2)
    }

    // MARK: Words

    /// "+2.31%", "−4.25", "+4.25  +2.31%": with its sign, since the pill has no arrow.
    static func moveText(_ quote: Quote, style: TapeStyle) -> (String, Change.Direction) {
        guard let move = quote.change(style.reference) else { return ("–", .flat) }
        let direction = move.direction
        let sign = direction == .up ? "+" : direction == .down ? "\u{2212}" : ""
        switch style.changeStyle {
        case .percent: return (sign + Format.percent(move.percent), direction)
        case .amount: return (sign + Format.amount(move.amount, of: quote), direction)
        case .both: return (sign + Format.amount(move.amount, of: quote) + "  " + sign + Format.percent(move.percent), direction)
        }
    }

    /// The company without its legal form ("Microsoft", not "Microsoft Corporation"), a fund
    /// without its share class, or, where the name is the label ("S&P 500"), what it is and where.
    static func subtitle(for listing: FocusListing) -> String {
        let quote = listing.quote
        let name = shortName(quote.name, kind: quote.kind)
        if name.isEmpty || name.caseInsensitiveCompare(listing.label) == .orderedSame {
            return [quote.kind.title, exchangeName(quote.exchange)].compactMap(\.self).joined(separator: " · ")
        }
        return name
    }

    static func shortName(_ name: String, kind: Quote.Kind) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        if kind == .etf || kind == .fund {
            for marker in [" UCITS", " ETF"] {
                if let range = name.range(of: marker), range.lowerBound > name.startIndex { name = String(name[..<range.lowerBound]) }
            }
        }
        let forms = [
            "Incorporated", "Inc.", "Inc", "Corporation", "Corp.", "Corp", "Company", "Co.", "N.V.", "NV", "S.A.", "SA", "SE", "AG",
            "plc", "PLC", "Ltd.", "Ltd", "Limited", "LLC", "L.P.", "A/S", "ASA", "AB (publ)", "AB", "Oyj", "S.p.A.", "SpA", "KGaA", "& Co.",
        ]
        var trimmed = true
        while trimmed {
            trimmed = false
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            for form in forms where name.hasSuffix(" " + form) || name.hasSuffix("," + form) {
                name = String(name.dropLast(form.count))
                trimmed = true
                break
            }
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    static func exchangeName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let names: [String: String] = [
            "NasdaqGS": "Nasdaq", "NasdaqGM": "Nasdaq", "NasdaqCM": "Nasdaq", "NMS": "Nasdaq", "NGM": "Nasdaq", "NCM": "Nasdaq",
            "NYQ": "NYSE", "NYSEArca": "NYSE Arca", "PCX": "NYSE Arca", "SNP": "S&P", "DJI": "Dow Jones", "XETRA": "Xetra",
            "CCC": "Crypto", "CCY": "FX", "Crypto": "Crypto", "CME": "CME", "NYM": "NYMEX", "CMX": "COMEX", "CBT": "CBOT",
        ]
        if let name = names[code] { return name }
        return code.count <= 3 ? code.uppercased() : code
    }

    // MARK: Columns

    private static func render(_ item: Measured, grid: FocusGrid, metrics m: FocusMetrics, style: TapeStyle) -> FocusSlide? {
        let quote = item.listing.quote
        let height = m.height, room = m.room
        let dark = style.ground == .dark
        let ink = style.primary
        let accent: RGB = switch item.direction {
        case .up: style.gain
        case .down: style.loss
        case .flat: ink
        }
        let styleKey = "\(style.fontSize)|\(style.scale)|\(dark)|\(style.focusGlass)"
        var parts: [FocusSlide.Part] = []
        func part(_ column: FocusSlide.Column, x: CGFloat, width: CGFloat, key: String, _ draw: (Bitmap, CGContext) -> Void) {
            let frame = CGRect(x: x - room, y: 0, width: width + room * 2, height: height)
            guard let canvas = Bitmap(size: frame.size, scale: style.scale, smoothFonts: true) else { return }
            draw(canvas, canvas.context)
            guard let image = canvas.image() else { return }
            parts.append(.init(column: column, image: image, frame: frame, key: [key, styleKey, "\(frame.size)"].joined(separator: "|")))
        }
        let shadows = textShadows(dark: dark, glass: style.focusGlass, fontSize: m.fontSize)

        // The tile: the logo, or a glyph or initials on the listing's colour.
        let brand = item.listing.brand
        part(.tile, x: 0, width: grid.tile, key: "\(item.listing.label)|\(brand?.hexString ?? "-")|\(item.listing.logo != nil)|\(item.listing.glyph != nil)") { canvas, context in
            drawTile(item.listing, in: CGRect(x: room, y: ((height - m.tile) / 2).rounded(), width: m.tile, height: m.tile), metrics: m, style: style, canvas: canvas)
        }

        // Who: the label in its brand's colour over a quieter name, on two shared baselines.
        let labelColor = brand.map { Legibility.adjust($0, for: style.ground) } ?? ink
        let label = Typeface.line(item.listing.label, m.labelFont, labelColor)
        let fullName = Typeface.line(item.subtitle, m.nameFont, ink, alpha: dark ? 0.62 : 0.6)
        var name = truncated(item.subtitle, font: m.nameFont, color: ink, alpha: dark ? 0.62 : 0.6, width: grid.identity) ?? fullName
        // "ASML Holding" cut to "ASML…" only repeats the label; say where it trades instead.
        if Typeface.width(fullName) > grid.identity,
           let first = item.subtitle.split(separator: " ").first, first.caseInsensitiveCompare(item.listing.label) == .orderedSame,
           let place = [quote.kind.title, exchangeName(quote.exchange)].compactMap(\.self).last {
            name = truncated(place, font: m.nameFont, color: ink, alpha: dark ? 0.62 : 0.6, width: grid.identity) ?? name
        }
        let (labelBaseline, nameBaseline, priceBaseline) = baselines(m)
        part(.identity, x: grid.identityX, width: grid.identity, key: "\(item.listing.label)|\(item.subtitle)|\(labelColor.hexString)|\(grid.identity)") { canvas, _ in
            canvas.shadowed(shadows) {
                canvas.draw(label, at: CGPoint(x: room, y: labelBaseline))
                canvas.draw(name, at: CGPoint(x: room, y: nameBaseline))
            }
        }

        // The price, right-aligned so the decimals line up from one listing to the next.
        part(.price, x: grid.priceX, width: grid.price, key: "\(item.price.text)|\(grid.price)") { canvas, _ in
            canvas.shadowed(shadows) {
                item.price.draw(in: canvas, right: room + grid.price, baseline: priceBaseline)
            }
        }

        // The move, in a solid pill: it reads on any wallpaper, and all pills are one width.
        part(.move, x: grid.moveX, width: grid.move, key: "\(item.move)|\(item.direction)|\(grid.move)") { canvas, context in
            let pill = CGRect(x: room, y: ((height - m.pillHeight) / 2).rounded(), width: grid.move, height: m.pillHeight)
            let (fill, text) = pillColors(item.direction, style: style)
            let line = Typeface.line(item.move, m.moveFont, text.color, alpha: text.alpha)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 3, color: CGColor(gray: 0, alpha: dark ? 0.32 : 0.12))
            canvas.fillCapsule(pill, color: fill)
            context.restoreGState()
            // A breath of light along the top edge, as on the system's own buttons.
            context.saveGState()
            context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            context.clip()
            let sheen = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.midY), options: [])
            context.restoreGState()
            let x = pill.minX + ((pill.width - Typeface.width(line)) / 2)
            canvas.draw(line, at: CGPoint(x: (x * style.scale).rounded() / style.scale, y: (pill.midY - m.moveFont.capHeight / 2).rounded()))
        }

        // Today's path across the trading day, from where the move is measured.
        var live: CGPoint?
        if grid.chart > 0, item.hasChart {
            let trading = quote.isTrading()
            let frame = CGRect(x: room, y: ((height - m.chartHeight) / 2).rounded(), width: grid.chart, height: m.chartHeight)
            let last = quote.intraday.last.map { "\($0.time.timeIntervalSince1970)|\($0.value)" } ?? "-"
            var end: CGPoint?
            part(.chart, x: grid.chartX, width: grid.chart, key: "\(quote.intraday.count)|\(last)|\(item.direction)|\(trading)|\(grid.chart)|\(style.reference)") { canvas, context in
                end = drawChart(quote, reference: style.reference, in: frame, color: accent, live: trading, dark: dark, scale: style.scale, context: context)
            }
            if trading, let end { live = CGPoint(x: grid.chartX - room + end.x, y: end.y) }
        }

        return FocusSlide(symbol: quote.symbol, price: quote.price, parts: parts, size: CGSize(width: grid.width, height: height), live: live, accent: accent, isDark: dark, tile: m.tile)
    }

    // MARK: Compact

    /// The compact layout's sizes, shared by every listing: a tile, then the ticker with its move
    /// (right-aligned) over the price. Stacked, there's no tile and the move gets a line of its own.
    nonisolated struct CompactGrid {
        var scale: CGFloat
        var tile: CGFloat
        var clock: Bool
        var stacked: Bool
        var labelFont: NSFont
        var moveFont: NSFont
        var priceFont: NSFont
        var markFont: NSFont
        var gap: CGFloat
        var lineGap: CGFloat
        var stack: CGFloat
        var label: CGFloat
        var move: CGFloat
        /// The tile the glass sizes itself by, when there's no tile to show.
        var nominalTile: CGFloat
        var stackX: CGFloat { tile > 0 ? tile + gap : 0 }
        var width: CGFloat { (stackX + stack).rounded(.up) }

        init(_ listings: [FocusListing], style: TapeStyle, metrics m: FocusMetrics, scale k: CGFloat, tile: Bool, clock: Bool, stacked: Bool = false) {
            let f = m.fontSize
            scale = k
            self.clock = clock
            self.stacked = stacked
            nominalTile = (m.height * 0.5 * k).rounded()
            self.tile = tile ? nominalTile : 0
            labelFont = Typeface.font((f * 0.8 * k).rounded(), .semibold)
            // On a line of its own the move can be as large as the ticker.
            moveFont = Typeface.font((f * (stacked ? 0.8 : 0.74) * k).rounded(), .semibold, design: .rounded, tabular: true)
            priceFont = Typeface.font((f * 1.1 * k).rounded(), .semibold, design: .rounded, tabular: true)
            markFont = Typeface.font((f * 0.74 * k).rounded(), .semibold, design: .rounded)
            gap = (f * 0.5 * k).rounded()
            lineGap = (f * (stacked ? 0.26 : 0.3) * k).rounded()
            let ticker = (f * 0.4 * k).rounded()
            let white = RGB(hex: 0xFFFFFF)
            var labels: CGFloat = 0, moves: CGFloat = 0, prices: CGFloat = 0
            for listing in listings {
                labels = max(labels, Typeface.width(Typeface.line(listing.label, labelFont, white)))
                moves = max(moves, Typeface.width(Typeface.line(FocusRenderer.moveText(listing.quote, style: style).0, moveFont, white)))
                let price = Format.price(listing.quote.price, of: listing.quote, showCurrency: style.showCurrency, compact: true)
                prices = max(prices, PriceText(price, priceFont: priceFont, markFont: markFont, fontSize: f * k, ink: white, dims: 1).width)
            }
            move = moves.rounded(.up)
            if stacked {
                label = labels.rounded(.up)
                stack = max(labels, moves, prices).rounded(.up)
            } else {
                stack = max(labels + ticker + move, prices).rounded(.up)
                label = stack - move - ticker
            }
        }

        /// Fits a stacked grid into `width` by cutting the longest tickers short; prices and moves stay whole.
        mutating func narrow(to width: CGFloat) {
            guard stacked, stack > width else { return }
            stack = max(width.rounded(.down), move)
            label = min(label, stack)
        }

        /// The baselines of the ticker's line, the price's and, stacked, the move's, centred as a block.
        func baselines(height: CGFloat) -> (label: CGFloat, price: CGFloat, move: CGFloat) {
            guard stacked else {
                let price = (height / 2 - (labelFont.capHeight + lineGap + priceFont.capHeight) / 2).rounded()
                let label = (price + priceFont.capHeight + lineGap).rounded()
                return (label, price, label)
            }
            // A little more air under the price: the figures below have no ascenders to soften the gap.
            let below = lineGap + 1
            let block = labelFont.capHeight + lineGap + priceFont.capHeight + below + moveFont.capHeight
            let move = (height / 2 - block / 2).rounded()
            let price = (move + moveFont.capHeight + below).rounded()
            return ((price + priceFont.capHeight + lineGap).rounded(), price, move)
        }
    }

    private static func renderCompact(_ listing: FocusListing, grid: CompactGrid, metrics m: FocusMetrics, style: TapeStyle) -> FocusSlide? {
        let quote = listing.quote
        let height = m.height, room = m.room
        let dark = style.ground == .dark
        let ink = style.primary
        let (move, direction) = moveText(quote, style: style)
        let accent: RGB = switch direction {
        case .up: style.gain
        case .down: style.loss
        case .flat: ink
        }
        let styleKey = "compact|\(grid.stacked)|\(grid.scale)|\(grid.tile)|\(style.fontSize)|\(style.scale)|\(dark)|\(style.focusGlass)"
        var parts: [FocusSlide.Part] = []
        func part(_ column: FocusSlide.Column, x: CGFloat, width: CGFloat, key: String, _ draw: (Bitmap) -> Void) {
            let frame = CGRect(x: x - room, y: 0, width: width + room * 2, height: height)
            guard let canvas = Bitmap(size: frame.size, scale: style.scale, smoothFonts: true) else { return }
            draw(canvas)
            guard let image = canvas.image() else { return }
            parts.append(.init(column: column, image: image, frame: frame, key: [key, styleKey, "\(frame.size)"].joined(separator: "|")))
        }
        let shadows = textShadows(dark: dark, glass: style.focusGlass, fontSize: m.fontSize * grid.scale)
        let (labelBaseline, priceBaseline, moveBaseline) = grid.baselines(height: height)

        if grid.tile > 0 {
            let tileMetrics = FocusMetrics(fontSize: m.fontSize, glass: m.glass)
            part(.tile, x: 0, width: grid.tile, key: "\(listing.label)|\(listing.brand?.hexString ?? "-")|\(listing.logo != nil)|\(listing.glyph != nil)") { canvas in
                drawTile(listing, in: CGRect(x: room, y: ((height - grid.tile) / 2).rounded(), width: grid.tile, height: grid.tile), metrics: tileMetrics, radius: grid.tile * 0.225, style: style, canvas: canvas)
            }
        }
        let labelColor = listing.brand.map { Legibility.adjust($0, for: style.ground) } ?? ink
        let label = truncated(listing.label, font: grid.labelFont, color: labelColor, alpha: 1, width: grid.label) ?? Typeface.line(listing.label, grid.labelFont, labelColor)
        part(.identity, x: grid.stackX, width: grid.label, key: "\(listing.label)|\(labelColor.hexString)|\(grid.label)") { canvas in
            canvas.shadowed(shadows) { canvas.draw(label, at: CGPoint(x: room, y: labelBaseline)) }
        }
        // The move as coloured figures: right-aligned on the ticker's line, or on a line of its own.
        let moveLine = Typeface.line(move, grid.moveFont, direction == .flat ? ink : accent, alpha: direction == .flat ? 0.7 : 1)
        let moveX = grid.stacked ? grid.stackX : grid.stackX + grid.stack - grid.move
        part(.move, x: moveX, width: grid.move, key: "\(move)|\(direction)|\(grid.move)") { canvas in
            let x = grid.stacked ? room : room + grid.move - Typeface.width(moveLine)
            canvas.shadowed(shadows) { canvas.draw(moveLine, at: CGPoint(x: x, y: moveBaseline)) }
        }
        let price = PriceText(Format.price(quote.price, of: quote, showCurrency: style.showCurrency, compact: true), priceFont: grid.priceFont, markFont: grid.markFont,
                              fontSize: m.fontSize * grid.scale, ink: ink, dims: dark ? 0.6 : 0.56)
        part(.price, x: grid.stackX, width: grid.stack, key: "\(price.text)|\(grid.stack)") { canvas in
            canvas.shadowed(shadows) { price.draw(in: canvas, right: room + price.width, baseline: priceBaseline) }
        }
        var slide = FocusSlide(symbol: quote.symbol, price: quote.price, parts: parts, size: CGSize(width: grid.width, height: height), live: nil, accent: accent, isDark: dark)
        slide.clock = grid.clock
        // Without a tile the glass still sizes itself as if there were one.
        slide.tile = grid.tile > 0 ? grid.tile : grid.nominalTile
        return slide
    }

    /// Whole words where they fit ("Vanguard FTSE…"), letters only when even one word doesn't.
    static func truncated(_ text: String, font: NSFont, color: RGB, alpha: Double, width: CGFloat) -> CTLine? {
        let full = Typeface.line(text, font, color, alpha: alpha)
        guard Typeface.width(full) > width else { return full }
        let words = text.split(separator: " ")
        for count in stride(from: words.count - 1, through: 1, by: -1) {
            let line = Typeface.line(words.prefix(count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,·-–")) + "…", font, color, alpha: alpha)
            if Typeface.width(line) <= width, count > 1 || words[0].count > 2 { return line }
        }
        let ellipsis = Typeface.line("…", font, color, alpha: alpha)
        return CTLineCreateTruncatedLine(full, Double(width), .end, ellipsis)
    }

    /// A shade the shape of the grid, blurred until it has no edge: dark under light text, pale under dark.
    static func veil(width: CGFloat, metrics m: FocusMetrics, style: TapeStyle) -> (CGImage?, CGRect) {
        let margin: CGFloat = 26
        let size = CGSize(width: width + margin * 2, height: m.height)
        let dark = style.ground == .dark
        let core = CGRect(x: margin + 6, y: (m.height * 0.36).rounded(), width: width - 12, height: (m.height * 0.28).rounded())
        guard let canvas = Bitmap(size: size, scale: style.scale) else { return (nil, .zero) }
        canvas.fillCapsule(core, color: CGColor(gray: dark ? 0 : 1, alpha: dark ? 0.62 : 0.7))
        guard let sharp = canvas.image() else { return (nil, .zero) }
        let input = CIImage(cgImage: sharp)
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: m.height * 0.17 * style.scale])?.outputImage,
              let image = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(blurred, from: input.extent)
        else { return (nil, .zero) }
        return (image, CGRect(x: -margin, y: 0, width: size.width, height: size.height))
    }

    /// The two lines of the name share their baselines with every listing; the price is centred on its caps.
    static func baselines(_ m: FocusMetrics) -> (label: CGFloat, name: CGFloat, price: CGFloat) {
        let name = (m.height / 2 - (m.labelFont.capHeight + m.stackGap + m.nameFont.capHeight) / 2).rounded()
        let label = (name + m.nameFont.capHeight + m.stackGap).rounded()
        let price = (m.height / 2 - m.priceFont.capHeight / 2).rounded()
        return (label, name, price)
    }

    static func textShadows(dark: Bool, glass: Bool, fontSize f: CGFloat) -> [Bitmap.Shadow] {
        if glass { return [Bitmap.Shadow(blur: f * 0.12, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: 0.28))] }
        return dark
            ? [Bitmap.Shadow(blur: f * 0.16, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: 0.55)), Bitmap.Shadow(blur: f * 0.8, color: CGColor(gray: 0, alpha: 0.3))]
            : [Bitmap.Shadow(blur: f * 0.3, color: CGColor(gray: 1, alpha: 0.7))]
    }

    /// Mint and coral filled pills with deep text on dark grounds; deep pills with white text on light ones.
    static func pillColors(_ direction: Change.Direction, style: TapeStyle) -> (fill: CGColor, text: (color: RGB, alpha: Double)) {
        let dark = style.ground == .dark
        switch direction {
        case .flat:
            return dark ? (CGColor(gray: 1, alpha: 0.2), (RGB(hex: 0xFFFFFF), 0.92)) : (CGColor(gray: 0, alpha: 0.09), (RGB(hex: 0x141416), 0.8))
        case .up, .down:
            let color = direction == .up ? style.gain : style.loss
            guard dark else { return (color.cgColor(), (RGB(hex: 0xFFFFFF), 1)) }
            let lab = color.oklab
            return (color.cgColor(), (Legibility.inGamut(l: 0.29, chroma: lab.chroma * 0.55, hue: lab.hue), 1))
        }
    }

    // MARK: Tile

    static func drawTile(_ listing: FocusListing, in rect: CGRect, metrics m: FocusMetrics, radius: CGFloat? = nil, style: TapeStyle, canvas: Bitmap) {
        let context = canvas.context
        let dark = style.ground == .dark
        let radius = radius ?? m.tileRadius
        let shape = Shapes.continuous(rect, radius: radius)
        let px = 1 / style.scale
        // Lifted off the wallpaper: a tight contact shadow under a soft one.
        canvas.shadowed([
            Bitmap.Shadow(blur: 1.2, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: dark ? 0.35 : 0.16)),
            Bitmap.Shadow(blur: rect.width * 0.22, offset: CGSize(width: 0, height: -rect.width * 0.05), color: CGColor(gray: 0, alpha: dark ? 0.3 : 0.14)),
        ]) {
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fillPath()
        }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let logo = listing.logo {
            context.interpolationQuality = .high
            context.draw(logo, in: rect)
        } else {
            // The listing's own colour, or graphite like Tape's icon, lit from above.
            let base = listing.brand ?? RGB(hex: 0x37383D)
            let lab = base.oklab
            let top = Legibility.inGamut(l: min(lab.l + 0.06, 0.95), chroma: lab.chroma, hue: lab.hue)
            let bottom = Legibility.inGamut(l: max(lab.l - 0.07, 0.08), chroma: lab.chroma, hue: lab.hue)
            let gradient = CGGradient(colorsSpace: nil, colors: [top.cgColor(), bottom.cgColor()] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
            let foreground = lab.l > 0.78 ? CGColor(gray: 0.1, alpha: 0.9) : CGColor(gray: 1, alpha: 0.96)
            if let glyph = listing.glyph {
                let aspect = glyph.size.width / max(glyph.size.height, 1)
                let box = rect.width * 0.56
                let size = aspect >= 1 ? CGSize(width: box, height: box / aspect) : CGSize(width: box * aspect, height: box)
                let frame = CGRect(x: canvas.snap(rect.midX - size.width / 2), y: canvas.snap(rect.midY - size.height / 2), width: size.width, height: size.height)
                // Drawn from its outlines at this size, then filled with the tile's ink.
                context.saveGState()
                context.beginTransparencyLayer(in: frame.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                glyph.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
                context.setBlendMode(.sourceIn)
                context.setFillColor(foreground)
                context.fill(frame.insetBy(dx: -1, dy: -1))
                context.endTransparencyLayer()
                context.restoreGState()
            } else {
                let letters = String(listing.label.filter { $0.isLetter || $0.isNumber }.prefix(listing.label.count <= 3 ? 3 : 2)).uppercased()
                let font = Typeface.font(rect.width * (letters.count > 2 ? 0.3 : 0.38), .bold, design: .rounded)
                let line = Typeface.line(letters, font, lab.l > 0.78 ? RGB(hex: 0x1A1A1A) : RGB(hex: 0xFFFFFF))
                canvas.draw(line, at: CGPoint(x: rect.midX - Typeface.width(line) / 2, y: (rect.midY - font.capHeight / 2).rounded()))
            }
        }
        // One material for every tile: a soft sheen from the top.
        let sheen = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.13), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
        context.restoreGState()
        // A pixel-wide edge: light on dark wallpapers, dark on light ones, so white logos keep their shape.
        context.addPath(Shapes.continuous(rect.insetBy(dx: px / 2, dy: px / 2), radius: radius - px / 2))
        context.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.12))
        context.setLineWidth(px)
        context.strokePath()
    }

    // MARK: Chart

    /// Draws today's path and returns where it ends. Across a stock's whole session, so at
    /// eleven in the morning the line stops a quarter of the way along.
    @discardableResult
    static func drawChart(_ quote: Quote, reference: Reference, in frame: CGRect, color: RGB, live: Bool, dark: Bool, scale: CGFloat, context: CGContext) -> CGPoint? {
        let points = quote.intraday
        let values = points.map(\.value)
        guard let firstPoint = points.first, let lastPoint = points.last, var low = values.min(), var high = values.max() else { return nil }
        var start = firstPoint.time, end = lastPoint.time
        if let open = quote.sessionStart, let close = quote.sessionEnd,
           firstPoint.time >= open.addingTimeInterval(-3600), lastPoint.time <= close.addingTimeInterval(3600) {
            start = min(start, open)
            end = max(end, close)
        }
        let base = quote.baseline(reference)
        if let base {
            low = min(low, base)
            high = max(high, base)
        }
        // A quarter of a percent at least, so a quiet day draws a quiet line rather than magnified noise.
        let span = max(high - low, abs(high) * 0.0025, .ulpOfOne)
        let middle = (high + low) / 2
        low = min(low, middle - span / 2)
        let duration = max(end.timeIntervalSince(start), 1)
        let dot: CGFloat = 2.25
        let plot = frame.insetBy(dx: dot, dy: dot)
        func point(_ p: Quote.Point) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat(p.time.timeIntervalSince(start) / duration) * plot.width,
                    y: plot.minY + CGFloat((p.value - low) / span) * plot.height)
        }
        let first = point(firstPoint), last = point(lastPoint)
        let px = 1 / scale
        // A day of minutes in a few dozen points reads as noise: average them a pixel column or
        // two at a time, keeping the open and the latest price exact.
        let bucket = max(1, 2 * px)
        var path = [first]
        var sum = CGPoint.zero, count: CGFloat = 0, column = Int.min
        for p in points.dropFirst().dropLast().map(point) {
            let index = Int(((p.x - plot.minX) / bucket).rounded(.down))
            if index != column, count > 0 {
                path.append(CGPoint(x: sum.x / count, y: sum.y / count))
                sum = .zero
                count = 0
            }
            column = index
            sum.x += p.x
            sum.y += p.y
            count += 1
        }
        if count > 0 { path.append(CGPoint(x: sum.x / count, y: sum.y / count)) }
        if points.count > 1 { path.append(last) }
        let line = CGMutablePath()
        line.addLines(between: path)

        // Where the move is measured from, dotted, across the whole day.
        if let base {
            let y = ((plot.minY + CGFloat((base - low) / span) * plot.height) * scale).rounded(.down) / scale + px / 2
            context.saveGState()
            context.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.3 : 0.28))
            context.setLineWidth(px)
            context.setLineDash(phase: 0, lengths: scale >= 2 ? [1, 1.5] : [2, 2])
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.maxX, y: y))
            context.strokePath()
            context.restoreGState()
        }

        // A wash of the move's colour under the line, fading to nothing.
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: last.x, y: frame.minY))
        area.addLine(to: CGPoint(x: first.x, y: frame.minY))
        area.closeSubpath()
        context.saveGState()
        context.addPath(area)
        context.clip()
        let wash = CGGradient(colorsSpace: nil, colors: [color.cgColor(alpha: dark ? 0.3 : 0.22), color.cgColor(alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(wash, start: CGPoint(x: 0, y: frame.maxY), end: CGPoint(x: 0, y: frame.minY), options: [])
        context.restoreGState()

        context.saveGState()
        if dark { context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2.5, color: CGColor(gray: 0, alpha: 0.45)) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(line)
        context.setStrokeColor(color.cgColor())
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        // The latest price: a solid dot while the market trades, a ring once it has closed.
        let ring = CGRect(x: last.x - dot, y: last.y - dot, width: dot * 2, height: dot * 2)
        if live {
            context.setFillColor(color.cgColor())
            context.fillEllipse(in: ring)
        } else {
            context.setBlendMode(.clear)
            context.fillEllipse(in: ring)
            context.setBlendMode(.normal)
            context.setStrokeColor(color.cgColor())
            context.setLineWidth(1.25)
            context.strokeEllipse(in: ring.insetBy(dx: 0.625, dy: 0.625))
        }
        context.endTransparencyLayer()
        context.restoreGState()
        return last
    }

    // MARK: Still pictures

    /// The countdown is a clock face: a fine ring, and inside it a wedge that sweeps round from
    /// twelve o'clock. (An arc on its own would read as a spinner, as if something were loading.)
    static func ringPath(in rect: CGRect, line: CGFloat) -> CGPath {
        CGPath(ellipseIn: rect.insetBy(dx: line / 2, dy: line / 2), transform: nil)
    }

    /// The wedge, drawn as a circle stroked as wide as it is round, so `strokeEnd` sweeps it.
    static func wedgeCircle(in rect: CGRect, line: CGFloat) -> (path: CGPath, width: CGFloat) {
        let radius = rect.width / 2 - line - 1
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return (path, radius)
    }

    static func ringColors(dark: Bool) -> (track: CGColor, fill: CGColor) {
        (CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.55 : 0.4), CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.85 : 0.62))
    }

    /// The slide as the desktop shows it at rest, for stills: the columns and a countdown a third round.
    static func draw(_ slide: FocusSlide, layout: FocusMetrics.Layout, metrics: FocusMetrics, countdown: CGFloat = 0.35, in context: CGContext) {
        if let veil = slide.veil {
            context.draw(veil, in: slide.veilFrame.offsetBy(dx: layout.grid.minX, dy: layout.grid.minY))
        }
        for part in slide.parts {
            context.draw(part.image, in: part.frame.offsetBy(dx: layout.grid.minX, dy: layout.grid.minY))
        }
        guard countdown >= 0 else { return }
        let colors = ringColors(dark: slide.isDark)
        context.saveGState()
        if slide.isDark, !metrics.glass { context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: CGColor(gray: 0, alpha: 0.45)) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineWidth(metrics.ringLine * 0.75)
        context.addPath(ringPath(in: layout.ring, line: metrics.ringLine * 0.75))
        context.setStrokeColor(colors.track)
        context.strokePath()
        let wedge = wedgeCircle(in: layout.ring, line: metrics.ringLine * 0.75)
        context.addPath(wedge.path.copy(dashingWithPhase: 0, lengths: [CGFloat.pi * wedge.width * countdown, 1000]))
        context.setLineWidth(wedge.width)
        context.setStrokeColor(colors.fill)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// A price in Focus: the currency mark smaller and hung from the cap height, the whole number in
/// full, the decimals a step quieter.
nonisolated struct PriceText {
    private struct Run {
        var line: CTLine
        var width: CGFloat
        var rise: CGFloat = 0
        var before: CGFloat = 0
        var after: CGFloat = 0
    }

    private var runs: [Run] = []
    let text: String

    init(_ price: Format.Price, metrics m: FocusMetrics, ink: RGB, dims: Double) {
        self.init(price, priceFont: m.priceFont, markFont: m.markFont, fontSize: m.fontSize, ink: ink, dims: dims)
    }

    init(_ price: Format.Price, priceFont: NSFont, markFont: NSFont, fontSize: CGFloat, ink: RGB, dims: Double) {
        text = price.text
        let gap = (fontSize * 0.1).rounded(.up) / 2
        func run(_ text: String, _ font: NSFont, alpha: Double) -> Run {
            let line = Typeface.line(text, font, ink, alpha: alpha)
            return Run(line: line, width: Typeface.width(line))
        }
        if !price.prefix.isEmpty {
            let mark = price.prefix.trimmingCharacters(in: .whitespaces)
            var prefix = run(mark, markFont, alpha: dims)
            prefix.rise = priceFont.capHeight - markFont.capHeight
            prefix.after = gap + (mark.count > 1 ? 1 : 0)
            runs.append(prefix)
        }
        let separator = Locale.current.decimalSeparator ?? "."
        var whole = price.number, fraction = ""
        if let range = price.number.range(of: separator, options: .backwards) {
            whole = String(price.number[..<range.lowerBound])
            fraction = String(price.number[range.lowerBound...])
        }
        runs.append(run(whole, priceFont, alpha: 1))
        if !fraction.isEmpty { runs.append(run(fraction, priceFont, alpha: min(1, dims + 0.22))) }
        if !price.suffix.isEmpty {
            var unit = run(price.suffix.trimmingCharacters(in: .whitespaces), markFont, alpha: dims)
            unit.before = gap + 1
            runs.append(unit)
        }
    }

    var width: CGFloat { runs.reduce(0) { $0 + $1.before + $1.width + $1.after } }

    func draw(in canvas: Bitmap, right: CGFloat, baseline: CGFloat) {
        var x = right - width
        for run in runs {
            x += run.before
            canvas.draw(run.line, at: CGPoint(x: x, y: baseline + run.rise))
            x += run.width + run.after
        }
    }
}
