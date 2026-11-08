import Foundation

/// A listing's colour: the brand's own, or none for monochrome marks like Apple's.
nonisolated enum BrandColor: Codable, Hashable, Sendable {
    case color(RGB)
    case neutral

    var rgb: RGB? {
        if case .color(let rgb) = self { return rgb }
        return nil
    }
}

/// Official colours for the names people watch most, so they're exact from the first frame.
/// Everything else gets its colour from its logo (see `LogoColor`).
nonisolated enum BrandTable {
    static func color(for symbol: String) -> BrandColor? {
        let symbol = symbol.uppercased()
        if let exact = bySymbol[symbol] { return exact }
        if symbol.hasPrefix("^") || symbol.hasSuffix("=X") { return .neutral }
        return byBase[Format.label(for: symbol)]
    }

    /// Whether a logo is worth looking up: indices, currencies, futures and crypto pairs have none.
    static func hasLogo(_ symbol: String) -> Bool {
        let symbol = symbol.uppercased()
        if symbol.hasPrefix("^") || symbol.hasSuffix("=X") || symbol.hasSuffix("=F") { return false }
        return symbol.range(of: #"-(USD|EUR|GBP|USDT|USDC|BTC|ETH|JPY|CHF|CAD|AUD)$"#, options: .regularExpression) == nil
    }

    private static let bySymbol: [String: BrandColor] = [
        "GC=F": .color(RGB(hex: 0xE2B33C)),
        "SI=F": .neutral,
        "PL=F": .neutral,
        "HG=F": .color(RGB(hex: 0xC8794B)),
    ]

    private static let vanguard = BrandColor.color(RGB(hex: 0x96151D))

    private static let byBase: [String: BrandColor] = [
        // Technology
        "AAPL": .neutral,
        "NVDA": .color(RGB(hex: 0x76B900)),
        "MSFT": .color(RGB(hex: 0x00A4EF)),
        "GOOGL": .color(RGB(hex: 0x4285F4)),
        "GOOG": .color(RGB(hex: 0x4285F4)),
        "AMZN": .color(RGB(hex: 0xFF9900)),
        "META": .color(RGB(hex: 0x0081FB)),
        "TSLA": .color(RGB(hex: 0xE31937)),
        "NFLX": .color(RGB(hex: 0xE50914)),
        "AMD": .color(RGB(hex: 0xED1C24)),
        "INTC": .color(RGB(hex: 0x0068B5)),
        "ORCL": .color(RGB(hex: 0xC74634)),
        "CRM": .color(RGB(hex: 0x00A1E0)),
        "ADBE": .color(RGB(hex: 0xFA0F00)),
        "IBM": .color(RGB(hex: 0x0F62FE)),
        "CSCO": .color(RGB(hex: 0x049FD9)),
        "QCOM": .color(RGB(hex: 0x3253DC)),
        "AVGO": .color(RGB(hex: 0xCC092F)),
        "SAP": .color(RGB(hex: 0x0FAAFF)),
        "SPOT": .color(RGB(hex: 0x1ED760)),
        "SHOP": .color(RGB(hex: 0x95BF47)),
        "ABNB": .color(RGB(hex: 0xFF5A5F)),
        "PYPL": .color(RGB(hex: 0x009CDE)),
        "ADYEN": .color(RGB(hex: 0x0ABF53)),
        "UBER": .neutral,
        // Consumer
        "KO": .color(RGB(hex: 0xF40009)),
        "PEP": .color(RGB(hex: 0x005CB4)),
        "MCD": .color(RGB(hex: 0xFFC72C)),
        "SBUX": .color(RGB(hex: 0x00704A)),
        "DIS": .color(RGB(hex: 0x113CCF)),
        "NKE": .neutral,
        "WMT": .color(RGB(hex: 0x0071DC)),
        "HD": .color(RGB(hex: 0xF96302)),
        "TGT": .color(RGB(hex: 0xCC0000)),
        "COST": .color(RGB(hex: 0xE31837)),
        // Finance & industry
        "V": .color(RGB(hex: 0x1A1F71)),
        "MA": .color(RGB(hex: 0xEB001B)),
        "BA": .color(RGB(hex: 0x0033A1)),
        // Crypto
        "BTC": .color(RGB(hex: 0xF7931A)),
        "ETH": .color(RGB(hex: 0x627EEA)),
        "SOL": .color(RGB(hex: 0x9945FF)),
        "ADA": .color(RGB(hex: 0x0033AD)),
        "DOGE": .color(RGB(hex: 0xC2A633)),
        "LTC": .color(RGB(hex: 0x345D9D)),
        "BNB": .color(RGB(hex: 0xF3BA2F)),
        "XRP": .neutral,
        // Vanguard's ETFs carry the house colour
        "VWCE": vanguard, "VWRL": vanguard, "VWRA": vanguard, "VUSA": vanguard, "VUAA": vanguard,
        "VEVE": vanguard, "VFEM": vanguard, "VHYL": vanguard, "VAGF": vanguard, "VOO": vanguard,
        "VTI": vanguard, "VT": vanguard, "VEA": vanguard, "VWO": vanguard, "VGT": vanguard,
        "VIG": vanguard, "VYM": vanguard,
    ]
}
