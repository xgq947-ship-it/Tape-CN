import Foundation

/// The latest price of one listing, with what the tape and the detail card need around it.
nonisolated struct Quote: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case stock, etf, fund, index, crypto, currency, future, other

        init(yahoo type: String?) {
            switch type?.uppercased() {
            case "EQUITY": self = .stock
            case "ETF": self = .etf
            case "MUTUALFUND": self = .fund
            case "INDEX": self = .index
            case "CRYPTOCURRENCY": self = .crypto
            case "CURRENCY": self = .currency
            case "FUTURE": self = .future
            default: self = .other
            }
        }

        var title: String {
            switch self {
            case .stock: "Stock"
            case .etf: "ETF"
            case .fund: "Fund"
            case .index: "Index"
            case .crypto: "Crypto"
            case .currency: "Currency"
            case .future: "Future"
            case .other: "Listing"
            }
        }
    }

    nonisolated struct Point: Codable, Equatable, Sendable {
        var time: Date
        var value: Double
    }

    var symbol: String
    var name: String
    /// Yahoo's currency code. "GBp" is pence, "ZAc" cents.
    var currency: String?
    var exchange: String?
    var kind: Kind
    var price: Double
    var previousClose: Double?
    /// Yahoo's own figure for today's move. For crypto it's the last 24 hours, which the
    /// previous close (midnight UTC) can't give.
    var reportedChangePercent: Double?
    /// Today's opening price, fetched separately once per session.
    var open: Double?
    var dayHigh: Double?
    var dayLow: Double?
    var yearHigh: Double?
    var yearLow: Double?
    /// Decimals Yahoo suggests for this listing.
    var decimals: Int
    var marketTime: Date
    var sessionStart: Date?
    var sessionEnd: Date?
    var timeZone: String?
    /// Today's five-minute closes.
    var intraday: [Point]

    func baseline(_ reference: Reference) -> Double? {
        let base: Double? = switch reference {
        case .previousClose: reportedBaseline ?? previousClose
        case .open: open ?? reportedBaseline ?? previousClose
        }
        guard let base, base > 0, base.isFinite else { return nil }
        return base
    }

    func change(_ reference: Reference) -> Change? {
        guard let base = baseline(reference) else { return nil }
        return Change(amount: price - base, percent: (price - base) / base * 100)
    }

    /// The price Yahoo's reported move is measured from, so tape, card and Yahoo all agree.
    private var reportedBaseline: Double? {
        guard let percent = reportedChangePercent, percent.isFinite, percent > -100 else { return nil }
        return price / (1 + percent / 100)
    }

    /// Crypto never closes; everything else trades inside Yahoo's current regular session.
    func isTrading(at now: Date = .now) -> Bool {
        if kind == .crypto { return true }
        guard let start = sessionStart, let end = sessionEnd else { return false }
        return start <= now && now < end
    }

    var exchangeTimeZone: TimeZone {
        timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}

nonisolated struct Change: Equatable, Sendable {
    nonisolated enum Direction: Sendable { case up, down, flat }

    var amount: Double
    var percent: Double

    /// A move that rounds to 0.00% is flat.
    var direction: Direction {
        if abs(percent) < 0.005 { return .flat }
        return percent > 0 ? .up : .down
    }
}
