import Foundation

/// How symbols, prices and moves are written on the tape: short, in the Mac's own number format.
nonisolated enum Format {
    /// A price split in three, so the currency can be drawn quieter than the number.
    nonisolated struct Price: Equatable, Sendable {
        var prefix: String
        var number: String
        var suffix: String
        var text: String { prefix + number + suffix }
    }

    // MARK: Labels

    private static let names: [String: String] = [
        "^GSPC": "S&P 500", "^SPX": "S&P 500", "^DJI": "Dow", "^IXIC": "Nasdaq", "^NDX": "Nasdaq 100",
        "^RUT": "Russell 2000", "^VIX": "VIX", "^STOXX50E": "Euro Stoxx 50", "^STOXX": "Stoxx 600",
        "^BFX": "BEL 20", "^AEX": "AEX", "^GDAXI": "DAX", "^FCHI": "CAC 40", "^FTSE": "FTSE 100",
        "^IBEX": "IBEX 35", "FTSEMIB.MI": "FTSE MIB", "^SSMI": "SMI", "^N225": "Nikkei", "^HSI": "Hang Seng",
        "000001.SS": "Shanghai", "^KS11": "KOSPI", "^BSESN": "Sensex", "^AXJO": "ASX 200",
        "GC=F": "Gold", "SI=F": "Silver", "PL=F": "Platinum", "HG=F": "Copper", "CL=F": "WTI",
        "BZ=F": "Brent", "NG=F": "Gas", "ES=F": "S&P fut.", "NQ=F": "Nasdaq fut.", "^TNX": "US 10Y",
    ]

    /// "ASML.AS" → "ASML", "BTC-EUR" → "BTC", "EURUSD=X" → "EUR/USD", "^GSPC" → "S&P 500".
    static func label(for symbol: String, kind: Quote.Kind? = nil) -> String {
        let symbol = symbol.uppercased()
        if let name = names[symbol] { return name }
        if symbol.hasSuffix("=X") {
            let pair = symbol.dropLast(2)
            if pair.count == 6 { return "\(pair.prefix(3))/\(pair.suffix(3))" }
            if pair.count == 3 { return "USD/\(pair)" }
            return String(pair)
        }
        if kind == .crypto || symbol.range(of: #"^[A-Z0-9]+-(USD|EUR|GBP|USDT|USDC|BTC|ETH|JPY|CHF|CAD|AUD)$"#, options: .regularExpression) != nil {
            return String(symbol.split(separator: "-").first ?? Substring(symbol))
        }
        if symbol.hasPrefix("^") { return String(symbol.dropFirst()) }
        if symbol.hasSuffix("=F") { return String(symbol.dropLast(2)) }
        // Exchange suffixes: ".AS", ".BR", ".DE", ".L", ".SW"…
        if let dot = symbol.lastIndex(of: "."), dot != symbol.startIndex {
            let suffix = symbol[symbol.index(after: dot)...]
            if (1...3).contains(suffix.count), suffix.allSatisfy(\.isLetter) { return String(symbol[..<dot]) }
        }
        return symbol
    }

    // MARK: Prices

    static func price(_ value: Double, of quote: Quote, showCurrency: Bool, compact: Bool, locale: Locale = .current) -> Price {
        var decimals = quote.decimals
        if compact {
            // Five-figure prices lose their cents on the tape; the card still shows them.
            if abs(value) >= 10_000 { decimals = 0 } else if abs(value) >= 1 { decimals = min(decimals, 2) }
        }
        let number = self.number(value, decimals: decimals, locale: locale)
        guard showCurrency, quote.kind != .index, quote.kind != .currency else { return Price(prefix: "", number: number, suffix: "") }
        let (prefix, suffix) = currencyMarks(quote.currency)
        return Price(prefix: prefix, number: number, suffix: suffix)
    }

    static func currencyMarks(_ code: String?) -> (prefix: String, suffix: String) {
        switch code {
        case "USD": ("$", "")
        case "EUR": ("€", "")
        case "GBP": ("£", "")
        case "GBp", "GBX": ("", "p")
        case "ZAc", "ZAC": ("", "c")
        case "ILA": ("", " ag.")
        case "JPY", "CNY": ("¥", "")
        case "INR": ("₹", "")
        case "KRW": ("₩", "")
        case "HKD": ("HK$", "")
        case "CAD": ("CA$", "")
        case "AUD": ("A$", "")
        case "SEK", "NOK", "DKK", "ISK": ("", "\u{2009}kr")
        case "CHF": ("CHF\u{2009}", "")
        case "PLN": ("", "\u{2009}zł")
        case nil: ("", "")
        case let code?: ("\(code)\u{2009}", "")
        }
    }

    // MARK: Moves

    /// "1,24%" — the direction is carried by the arrow and the colour, so no sign.
    static func percent(_ value: Double, locale: Locale = .current) -> String {
        number(abs(value), decimals: 2, locale: locale) + "%"
    }

    static func amount(_ value: Double, of quote: Quote, locale: Locale = .current) -> String {
        let decimals = abs(value) >= 100 ? min(quote.decimals, 2) : max(quote.decimals, 2)
        return number(abs(value), decimals: abs(value) >= 1000 ? 0 : decimals, locale: locale)
    }

    /// With a proper minus sign, for the detail card.
    static func signed(_ text: String, _ direction: Change.Direction) -> String {
        switch direction {
        case .up: "+" + text
        case .down: "\u{2212}" + text
        case .flat: text
        }
    }

    static func number(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic).locale(locale))
    }
}
