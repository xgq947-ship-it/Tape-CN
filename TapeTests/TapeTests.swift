import AppKit
import Testing
@testable import Tape

// MARK: Yahoo

@Suite struct YahooDecoding {
    let quotes: [String: Quote]

    init() throws {
        let url = try #require(Bundle(for: Marker.self).url(forResource: "spark", withExtension: "json"))
        quotes = try Yahoo.decodeSpark(Data(contentsOf: url))
    }

    @Test func readsEveryKnownListingAndSkipsUnknownOnes() {
        #expect(Set(quotes.keys) == ["AAPL", "ASML.AS", "VWCE.DE", "BTC-EUR", "^GSPC", "EURUSD=X", "GC=F", "VOD.L"])
        #expect(quotes["NOPE.XX"] == nil)
    }

    @Test func mapsKindsCurrenciesAndPreviousClose() throws {
        let asml = try #require(quotes["ASML.AS"])
        #expect(asml.kind == .stock)
        #expect(asml.currency == "EUR")
        #expect(asml.price == 1289.8)
        #expect(asml.previousClose == 1250)
        #expect(asml.exchange == "Amsterdam")
        #expect(quotes["VWCE.DE"]?.kind == .etf)
        #expect(quotes["^GSPC"]?.kind == .index)
        #expect(quotes["EURUSD=X"]?.kind == .currency)
        #expect(quotes["EURUSD=X"]?.decimals == 4)
        #expect(quotes["GC=F"]?.kind == .future)
        #expect(quotes["VOD.L"]?.currency == "GBp")
    }

    @Test func cryptoNamesDropTheirQuoteCurrency() throws {
        let bitcoin = try #require(quotes["BTC-EUR"])
        #expect(bitcoin.kind == .crypto)
        #expect(bitcoin.name == "Bitcoin")
        #expect(bitcoin.isTrading(at: .distantFuture))
        // Yahoo's 24-hour move, not the move since midnight UTC.
        let change = try #require(bitcoin.change(.previousClose))
        #expect(abs(change.percent - -4.707) < 0.001)
    }

    @Test func keepsTodaysPath() throws {
        let apple = try #require(quotes["AAPL"])
        #expect(apple.intraday.count > 10)
        #expect(apple.intraday.allSatisfy { $0.value > 0 })
        #expect(zip(apple.intraday, apple.intraday.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func readsTheOpenFromAChart() throws {
        let json = #"{"chart":{"result":[{"meta":{"regularMarketPrice":1292.0},"timestamp":[1],"indicators":{"quote":[{"open":[1250.0],"close":[1292.0]}]}}],"error":null}}"#
        #expect(try Yahoo.decodeOpen(Data(json.utf8)) == 1250)
    }

    @Test func refusesGarbage() {
        #expect(throws: Yahoo.Failure.unreadable) { try Yahoo.decodeSpark(Data("<html>".utf8)) }
    }

    @Test func encodesSymbolsForTheSparkURL() {
        let url = Yahoo.sparkURL(symbols: ["^GSPC", "EURUSD=X", "ASML.AS"]).absoluteString
        #expect(url.contains("symbols=%5EGSPC,EURUSD%3DX,ASML.AS"))
    }
}

private final class Marker {}

// MARK: Moves

@Suite struct Moves {
    func quote(price: Double, previous: Double?, open: Double?) -> Quote {
        Quote(symbol: "X", name: "X", currency: "USD", exchange: nil, kind: .stock, price: price, previousClose: previous, reportedChangePercent: nil, open: open,
              dayHigh: nil, dayLow: nil, yearHigh: nil, yearLow: nil, decimals: 2, marketTime: .now,
              sessionStart: nil, sessionEnd: nil, timeZone: nil, intraday: [])
    }

    @Test func measuresFromYesterdaysClose() throws {
        let change = try #require(quote(price: 110, previous: 100, open: 105).change(.previousClose))
        #expect(change.amount == 10)
        #expect(abs(change.percent - 10) < 1e-9)
        #expect(change.direction == .up)
    }

    @Test func measuresFromTodaysOpen() throws {
        let change = try #require(quote(price: 99, previous: 100, open: 110).change(.open))
        #expect(change.amount == -11)
        #expect(change.direction == .down)
    }

    @Test func fallsBackToTheCloseUntilTheOpenIsKnown() {
        #expect(quote(price: 99, previous: 100, open: nil).change(.open)?.amount == -1)
    }

    @Test func aMoveUnderHalfABasisPointIsFlat() {
        #expect(quote(price: 100.004, previous: 100, open: nil).change(.previousClose)?.direction == .flat)
        #expect(quote(price: 100, previous: nil, open: nil).change(.previousClose) == nil)
    }
}

// MARK: Formatting

@Suite struct Formatting {
    let belgian = Locale(identifier: "nl_BE")
    let american = Locale(identifier: "en_US")

    func quote(_ currency: String, kind: Quote.Kind = .stock, decimals: Int = 2) -> Quote {
        Quote(symbol: "X", name: "X", currency: currency, exchange: nil, kind: kind, price: 1, previousClose: 1, reportedChangePercent: nil, open: nil,
              dayHigh: nil, dayLow: nil, yearHigh: nil, yearLow: nil, decimals: decimals, marketTime: .now,
              sessionStart: nil, sessionEnd: nil, timeZone: nil, intraday: [])
    }

    @Test func labels() {
        #expect(Format.label(for: "ASML.AS") == "ASML")
        #expect(Format.label(for: "VWCE.DE") == "VWCE")
        #expect(Format.label(for: "BTC-EUR") == "BTC")
        #expect(Format.label(for: "EURUSD=X") == "EUR/USD")
        #expect(Format.label(for: "JPY=X") == "USD/JPY")
        #expect(Format.label(for: "^GSPC") == "S&P 500")
        #expect(Format.label(for: "^BFX") == "BEL 20")
        #expect(Format.label(for: "GC=F") == "Gold")
        #expect(Format.label(for: "BRK-B") == "BRK-B")
        #expect(Format.label(for: "nvda") == "NVDA")
    }

    @Test func pricesFollowTheMacsNumberFormat() {
        #expect(Format.price(1292, of: quote("EUR"), showCurrency: true, compact: true, locale: belgian).text == "€1.292,00")
        #expect(Format.price(187.4, of: quote("USD"), showCurrency: true, compact: true, locale: american).text == "$187.40")
        #expect(Format.price(116.4, of: quote("GBp"), showCurrency: true, compact: true, locale: american).text == "116.40p")
    }

    @Test func fiveFigurePricesLoseTheirCentsOnTheTape() {
        #expect(Format.price(68067.72, of: quote("EUR"), showCurrency: true, compact: true, locale: belgian).text == "€68.068")
        #expect(Format.price(68067.72, of: quote("EUR"), showCurrency: true, compact: false, locale: belgian).text == "€68.067,72")
    }

    @Test func indicesAndCurrenciesHaveNoCurrencySign() {
        #expect(Format.price(7353.73, of: quote("USD", kind: .index), showCurrency: true, compact: true, locale: american).text == "7,353.73")
        #expect(Format.price(1.1177, of: quote("USD", kind: .currency, decimals: 4), showCurrency: true, compact: false, locale: american).text == "1.1177")
    }

    @Test func percentagesCarryNoSign() {
        #expect(Format.percent(-1.2391, locale: belgian) == "1,24%")
        #expect(Format.signed(Format.percent(-1.2391, locale: american), .down) == "\u{2212}1.24%")
    }
}

// MARK: Colour

@Suite struct Colour {
    @Test func oklabRoundTrips() {
        for hex: UInt32 in [0x76B900, 0x96151D, 0x0081FB, 0xFFFFFF, 0x000000, 0xFF9900] {
            let color = RGB(hex: hex)
            let back = RGB(color.oklab)
            #expect(abs(back.r - color.r) < 1e-6 && abs(back.g - color.g) < 1e-6 && abs(back.b - color.b) < 1e-6)
        }
    }

    @Test func darkBrandColoursAreLiftedOnDarkWallpapers() {
        let vanguard = RGB(hex: 0x96151D)
        let adjusted = Legibility.adjust(vanguard, for: .dark)
        #expect(adjusted.oklab.l >= 0.739)
        #expect(adjusted.isInGamut)
        // Still recognisably red.
        #expect(abs(adjusted.oklab.hue - vanguard.oklab.hue) < 8)
    }

    @Test func lightBrandColoursAreDeepenedOnLightWallpapers() {
        let amazon = RGB(hex: 0xFF9900)
        #expect(Legibility.adjust(amazon, for: .light).oklab.l <= 0.561)
    }

    @Test func coloursThatAlreadyReadAreLeftAlone() {
        // Amazon's orange is already light enough for a dark wallpaper.
        let amazon = RGB(hex: 0xFF9900)
        #expect(Legibility.adjust(amazon, for: .dark).hexString == amazon.hexString)
    }

    @Test func hexStrings() {
        #expect(RGB(hexString: "#76b900")?.hexString == "#76B900")
        #expect(RGB(hexString: "nope") == nil)
    }
}

@Suite struct Logos {
    func image(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    @Test func findsTheBrandColourOnWhite() throws {
        let logo = image { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(RGB(hex: 0x1ED760).cgColor())
            context.fillEllipse(in: CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        let found = try #require(LogoColor.dominant(in: logo))
        #expect(abs(found.oklab.hue - RGB(hex: 0x1ED760).oklab.hue) < 6)
    }

    @Test func aColouredTileWinsOverItsWhiteLetters() throws {
        let logo = image { context in
            context.setFillColor(RGB(hex: 0xF40009).cgColor())
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(.white)
            context.fill(CGRect(x: 10, y: 40, width: 80, height: 20))
        }
        let found = try #require(LogoColor.dominant(in: logo))
        #expect(found.r > 0.8 && found.g < 0.2)
    }

    @Test func blackAndWhiteLogosAreMonochrome() {
        let logo = image { context in
            context.setFillColor(.black)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(.white)
            context.fillEllipse(in: CGRect(x: 25, y: 25, width: 50, height: 50))
        }
        #expect(LogoColor.dominant(in: logo) == nil)
    }

    @Test func curatedColoursComeFirst() {
        #expect(BrandTable.color(for: "NVDA") == .color(RGB(hex: 0x76B900)))
        #expect(BrandTable.color(for: "AAPL") == .neutral)
        #expect(BrandTable.color(for: "VWCE.DE") == .color(RGB(hex: 0x96151D)))
        #expect(BrandTable.color(for: "^GSPC") == .neutral)
        #expect(BrandTable.hasLogo("ABI.BR"))
        #expect(!BrandTable.hasLogo("BTC-EUR"))
        #expect(!BrandTable.hasLogo("EURUSD=X"))
    }
}

// MARK: Placement

@Suite struct Placement {
    func layout(tiles: CGRect, edge: DockLayout.Edge = .bottom, autohides: Bool = false) -> DockLayout {
        DockLayout(edge: edge, autohides: autohides, screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                   visibleFrame: CGRect(x: 0, y: 91, width: 1920, height: 959), tiles: tiles, tileSize: 65, isExact: true)
    }

    @Test func runsFromTheScreensEdgeToTheDock() throws {
        let dock = CGRect(x: 460, y: 13, width: 1000, height: 65)
        let left = try #require(TickerController.frame(for: layout(tiles: dock), side: .left, gap: 20, height: 42))
        #expect(left.minX == 14)
        #expect(left.maxX == 440)
        #expect(abs(left.midY - dock.midY) <= 0.5)
        let right = try #require(TickerController.frame(for: layout(tiles: dock), side: .right, gap: 20, height: 42))
        #expect(right.minX == 1480)
        #expect(right.maxX == 1906)
    }

    /// The MacBook's 1512 points with a 67-point Dock of seventeen icons: a strip of about 80 points,
    /// which used to hide the tape altogether.
    @Test func showsBesideALongDockOnALaptop() throws {
        let laptop = DockLayout(edge: .bottom, autohides: false, screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: CGRect(x: 0, y: 93, width: 1512, height: 856),
                                tiles: CGRect(x: 111.125, y: 13, width: 1289.75, height: 67), tileSize: 67, isExact: false)
        let frame = try #require(TickerController.frame(for: laptop, side: .left, gap: 22.68, height: 56))
        #expect(frame.minX == 7)
        #expect(frame.maxX == 88)
        #expect(frame.width >= TickerController.minimumWidth)
    }

    @Test func givesUpWhenThereIsNoRoom() {
        let wide = CGRect(x: 60, y: 13, width: 1800, height: 65)
        #expect(TickerController.frame(for: layout(tiles: wide), side: .left, gap: 20, height: 42) == nil)
    }

    @Test func runsAlongTheBottomWhenTheDockIsOnASide() throws {
        let frame = try #require(TickerController.frame(for: layout(tiles: CGRect(x: 4, y: 200, width: 65, height: 700), edge: .left), side: .left, gap: 20, height: 42))
        #expect(frame.minY == 2)
    }

    /// Measured from a screenshot of a 65-point Dock with 15 icons and two dividers: 1,118 points of glass.
    @Test func matchesARealDock() {
        var prefs = DockPreferences()
        prefs.tileSize = 65
        prefs.pinnedApps = (0..<10).map { "app.\($0)" }
        prefs.pinnedTileUnits = 10
        prefs.others = 1
        prefs.recentApps = ["com.microsoft.Powerpoint", "com.anthropic.claudefordesktop"]
        let width = DockLocator.estimatedWidth(prefs: prefs, running: ["com.microsoft.Powerpoint", "com.anthropic.claudefordesktop", "app.3"])
        #expect(abs(width - 1118) < 10)
    }

    @Test func estimatesTheDocksWidthFromItsPreferences() {
        var prefs = DockPreferences()
        prefs.tileSize = 65
        prefs.pinnedApps = (0..<10).map { "app.\($0)" }
        prefs.pinnedTileUnits = 10
        prefs.others = 1
        prefs.recentApps = ["recent.a", "recent.b", "recent.c"]
        prefs.showsRecents = true
        // Finder + 10 pinned + 3 recents + 1 folder + Trash, two dividers.
        let width = DockLocator.estimatedWidth(prefs: prefs, running: ["app.0", "com.apple.finder"])
        #expect(abs(width - (16 * 65 * 1.06 + 2 * 65 * 0.485 + 65 * 0.26)) < 0.01)
    }
}

// MARK: Rendering

@Suite struct Rendering {
    @Test func drawsAListingWithRoomForItsShadow() throws {
        let quote = Quote(symbol: "NVDA", name: "NVIDIA", currency: "USD", exchange: nil, kind: .stock, price: 187.42, previousClose: 185,
                          reportedChangePercent: nil, open: nil, dayHigh: nil, dayLow: nil, yearHigh: nil, yearLow: nil, decimals: 2, marketTime: .now,
                          sessionStart: nil, sessionEnd: nil, timeZone: nil, intraday: [])
        let style = TapeStyle(fontSize: 14, scale: 2)
        let item = try #require(ItemRenderer.render(label: "NVDA", labelColor: RGB(hex: 0x76B900), quote: quote, style: style))
        #expect(item.size.width > 80)
        #expect(item.image.width == Int(((item.size.width + item.padding * 2) * 2).rounded(.up)))
        let flashed = try #require(ItemRenderer.render(label: "NVDA", labelColor: nil, quote: quote, style: style, flash: .up))
        #expect(flashed.size == item.size)
    }
}

// MARK: Designs

@Suite struct Designs {
    let quote = Quote(symbol: "ASML.AS", name: "ASML Holding N.V.", currency: "EUR", exchange: "Amsterdam", kind: .stock, price: 1282.4,
                      previousClose: 1250, reportedChangePercent: nil, open: nil, dayHigh: nil, dayLow: nil, yearHigh: nil, yearLow: nil,
                      decimals: 2, marketTime: .now, sessionStart: nil, sessionEnd: nil, timeZone: nil,
                      intraday: (0..<20).map { Quote.Point(time: Date(timeIntervalSince1970: Double($0) * 300), value: 1250 + Double($0)) })

    @Test(arguments: TapeDesign.allCases.filter(\.scrolls))
    func everyScrollingDesignDrawsAListing(_ design: TapeDesign) throws {
        var style = TapeStyle(fontSize: 14, scale: 2)
        style.design = design
        let item = try #require(DesignRenderer.render(label: "ASML", brand: RGB(hex: 0x0F238C), quote: quote, style: style))
        #expect(item.size.width > 60)
        #expect(item.size.height + item.padding * 2 <= style.metrics.height + 0.5)
    }

    @Test func theLEDFaceCoversEverythingAPriceCanContain() {
        let unknown = LEDFont.glyph(for: "?").lit
        for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,%$€£¥&/-+()▲▼ \u{2212}\u{00A0}\u{2009}" where character != "?" {
            #expect(LEDFont.glyph(for: character).lit != unknown, "\(character) falls back to ?")
        }
        #expect(LEDFont.glyph(for: "a").lit == LEDFont.glyph(for: "A").lit)
    }

    @Test func ledListingsSitOnTheDotGrid() throws {
        var style = TapeStyle(fontSize: 14, scale: 1)
        style.design = .led
        let pitch = try #require(style.metrics.step)
        let item = try #require(DesignRenderer.render(label: "ASML", brand: nil, quote: quote, style: style))
        #expect(item.size.width.truncatingRemainder(dividingBy: pitch) == 0)
        #expect(item.padding.truncatingRemainder(dividingBy: pitch) == 0)
        #expect(style.metrics.spacing.truncatingRemainder(dividingBy: pitch) == 0)
        // Nine rows of dots: seven for the glyphs and one free above and below.
        #expect(style.metrics.height - style.metrics.backdropInset * 2 - style.metrics.tapeInsets.height * 2 == pitch * 9)
    }

    @Test func paperPerforationsRunOnEvenly() throws {
        var style = TapeStyle(fontSize: 14, scale: 2)
        style.design = .paper
        let item = try #require(DesignRenderer.render(label: "ASML", brand: nil, quote: quote, style: style))
        #expect(item.size.width.truncatingRemainder(dividingBy: PaperRenderer.perforation) == 0)
    }

    @Test func ledColoursAreBright() {
        let vanguard = LEDRenderer.led(RGB(hex: 0x96151D))
        #expect(vanguard.oklab.l >= 0.79)
        #expect(vanguard.isInGamut)
    }
}

// MARK: Focus

@Suite struct Focus {
    func listing(_ label: String, name: String, price: Double, previous: Double, kind: Quote.Kind = .stock, points: Int = 20) -> FocusListing {
        let quote = Quote(symbol: label, name: name, currency: "USD", exchange: "NasdaqGS", kind: kind, price: price,
                          previousClose: previous, reportedChangePercent: nil, open: nil, dayHigh: nil, dayLow: nil, yearHigh: nil, yearLow: nil,
                          decimals: 2, marketTime: .now, sessionStart: nil, sessionEnd: nil, timeZone: nil,
                          intraday: (0..<points).map { Quote.Point(time: Date(timeIntervalSince1970: Double($0) * 300), value: previous + Double($0) * 0.1) })
        return FocusListing(label: label, name: name, brand: nil, logo: nil, glyph: nil, quote: quote)
    }

    var watchlist: [FocusListing] {
        [listing("NVDA", name: "NVIDIA Corporation", price: 187.27, previous: 181.6),
         listing("ASML", name: "ASML Holding N.V.", price: 1263.5, previous: 1250),
         listing("TSLA", name: "Tesla, Inc.", price: 335.2, previous: 343.69)]
    }

    @Test func everyListingSharesOneGrid() throws {
        let slides = FocusRenderer.slides(for: watchlist, style: TapeStyle(fontSize: 14, scale: 2, design: .focus))
        #expect(slides.count == 3)
        #expect(Set(slides.map(\.size.width)).count == 1)
        // Each column sits in the same place on every slide, so a flip changes content, not layout.
        for column in FocusSlide.Column.allCases {
            #expect(Set(slides.compactMap { $0.part(column)?.frame.minX }).count <= 1, "\(column) moves")
        }
    }

    @Test func givesUpNamesThenAirThenTheChart() throws {
        let style = TapeStyle(fontSize: 14, scale: 2, design: .focus)
        let roomy = try #require(FocusRenderer.slides(for: watchlist, style: style).first)
        #expect(roomy.part(.chart) != nil)
        let metrics = FocusMetrics(fontSize: 14)
        let chrome = 400 - metrics.gridRoom(in: 400)
        let snug = try #require(FocusRenderer.slides(for: watchlist, style: style, room: roomy.size.width - 40 + chrome).first)
        #expect(snug.size.width <= roomy.size.width - 40)
        #expect(snug.part(.chart) != nil)
        let narrow = try #require(FocusRenderer.slides(for: watchlist, style: style, room: 290 + chrome).first)
        #expect(narrow.part(.chart) == nil)
        #expect(narrow.part(.identity) != nil)
        #expect(narrow.size.width <= 290)
    }

    /// A laptop with a long Dock leaves 130 points or less beside it; with seventeen icons, about 80.
    @Test(arguments: [180, 129, 100, 81, 64] as [CGFloat])
    func narrowStripsGoCompactAndStillFit(_ room: CGFloat) throws {
        let style = TapeStyle(fontSize: 14, scale: 2, design: .focus)
        let slides = FocusRenderer.slides(for: watchlist, style: style, room: room)
        #expect(slides.count == 3)
        let slide = try #require(slides.first)
        let metrics = FocusMetrics(fontSize: 14)
        let layout = metrics.layout(in: CGRect(x: 0, y: 0, width: room, height: metrics.height), gridWidth: slide.size.width, trailing: true, clock: slide.clock, tile: slide.tile)
        #expect(layout.grid.minX >= 0, "the slide starts off the window")
        #expect(slide.part(.chart) == nil)
        #expect(slide.part(.price) != nil)
        #expect(slide.part(.move) != nil)
        if room >= 129 { #expect(slide.part(.tile) != nil) }
        #expect(Set(slides.map(\.size.width)).count == 1)
        // Narrowest, the move gets its own line under the price rather than shrinking the type.
        if room < 100 {
            let price = try #require(slide.part(.price)), move = try #require(slide.part(.move))
            #expect(move.frame.minX == price.frame.minX)
        }
    }

    /// A card with room to spare sits in the middle of the corner, but no closer to the Dock than
    /// the strip allows; one that fills the strip stays where it was.
    @Test func aSmallCardSitsInTheMiddleOfTheCorner() {
        let metrics = FocusMetrics(fontSize: 14)
        let strip = CGRect(x: 0, y: 0, width: 170, height: metrics.height)
        let docked = metrics.layout(in: strip, gridWidth: 100, trailing: true, clock: false, tile: 28)
        let centred = metrics.layout(in: strip, gridWidth: 100, trailing: true, clock: false, tile: 28, centre: 90)
        #expect(abs(centred.platter.midX - 90) <= 0.5)
        #expect(centred.grid.width == docked.grid.width)
        #expect(centred.platter.maxX <= docked.platter.maxX)
        let towardsTheDock = metrics.layout(in: strip, gridWidth: 100, trailing: true, clock: false, tile: 28, centre: 400)
        #expect(towardsTheDock == docked)
        let full = metrics.layout(in: strip, gridWidth: 160, trailing: true, clock: false, tile: 28, centre: 20)
        #expect(full.platter.minX >= strip.minX)
    }

    @Test func aChartNeedsAPath() throws {
        let flat = listing("NEW", name: "Newly Listed", price: 10, previous: 10, points: 1)
        let slide = try #require(FocusRenderer.slides(for: [flat], style: TapeStyle(fontSize: 14, scale: 2, design: .focus)).first)
        #expect(slide.part(.chart) == nil)
        #expect(slide.live == nil)
    }

    @Test func namesLoseTheirLegalForm() {
        #expect(FocusRenderer.shortName("Microsoft Corporation", kind: .stock) == "Microsoft")
        #expect(FocusRenderer.shortName("Amazon.com, Inc.", kind: .stock) == "Amazon.com")
        #expect(FocusRenderer.shortName("ASML Holding N.V.", kind: .stock) == "ASML Holding")
        #expect(FocusRenderer.shortName("Vanguard FTSE All-World UCITS ETF USD Accumulation", kind: .etf) == "Vanguard FTSE All-World")
        #expect(FocusRenderer.shortName("Siemens Aktiengesellschaft", kind: .stock) == "Siemens Aktiengesellschaft")
    }

    @Test func anIndexSaysWhatAndWhere() {
        var sp = listing("S&P 500", name: "S&P 500", price: 7400, previous: 7350, kind: .index)
        sp.quote.exchange = "SNP"
        #expect(FocusRenderer.subtitle(for: sp) == "Index · S&P")
    }

    @Test func longNamesBreakBetweenWords() throws {
        let font = NSFont.systemFont(ofSize: 11)
        let line = try #require(FocusRenderer.truncated("Vanguard FTSE All-World", font: font, color: RGB(hex: 0xFFFFFF), alpha: 1, width: 90))
        #expect(Typeface.width(line) <= 90)
        let full = Typeface.width(Typeface.line("Vanguard FTSE…", font, RGB(hex: 0xFFFFFF)))
        #expect(abs(Typeface.width(line) - full) < 0.5)
    }

    @Test func movesCarryTheirSign() {
        let style = TapeStyle(fontSize: 14, scale: 2, design: .focus)
        #expect(FocusRenderer.moveText(watchlist[0].quote, style: style).0.hasPrefix("+"))
        #expect(FocusRenderer.moveText(watchlist[2].quote, style: style).0.hasPrefix("\u{2212}"))
    }

    @Test func theClockSitsByTheDockAndTheGlassIsConcentric() {
        let metrics = FocusMetrics(fontSize: 14, glass: true)
        let bounds = CGRect(x: 0, y: 0, width: 380, height: metrics.height)
        let trailing = metrics.layout(in: bounds, gridWidth: 300, trailing: true)
        let clockless = metrics.layout(in: bounds, gridWidth: 300, trailing: true, clock: false)
        #expect(clockless.grid.maxX > trailing.grid.maxX)
        #expect(clockless.platter.maxX == trailing.platter.maxX)
        #expect(trailing.ring.minX > trailing.grid.maxX)
        #expect(trailing.platter.maxX <= bounds.maxX)
        #expect(trailing.platter.contains(trailing.ring))
        let leading = metrics.layout(in: bounds, gridWidth: 300, trailing: false)
        #expect(leading.ring.maxX < leading.grid.minX)
        // Glass and tile share a centre for their corners: the glass's radius is the tile's plus the gap between them.
        #expect(abs(metrics.platterRadius - (metrics.tileRadius + (metrics.platterHeight - metrics.tile) / 2)) < 0.51)
        #expect(metrics.gridRoom(in: 380) <= 380 - metrics.ringDiameter - metrics.ringGap)
    }

    @Test func continuousCornersStayInsideTheirRect() {
        let rect = CGRect(x: 10, y: 20, width: 32, height: 32)
        let path = Shapes.continuous(rect, radius: 7.2)
        #expect(path.boundingBoxOfPath.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingBoxOfPath))
        #expect(!path.contains(CGPoint(x: rect.minX + 0.6, y: rect.minY + 0.6)))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }
}
