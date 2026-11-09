import Foundation

/// Tencent's public quote endpoint (`qt.gtimg.cn`, unofficial): Shanghai, Shenzhen, Hong Kong
/// and US listings in one request, no key. This is the source that works where Yahoo doesn't.
///
/// The payload is GBK text of the form
/// `v_sh600519="1~贵州茅台~600519~1444.99~1453.00~1440.06~…";` with fields separated by `~`.
nonisolated enum Tencent {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case status(Int)
        case offline
        case unreadable
        case unknownSymbols

        var errorDescription: String? {
            switch self {
            case .status(429): "Tencent's quote service is busy. Trying again shortly."
            case .status(let code): "Tencent answered \(code)."
            case .offline: "You're offline. Showing the last prices Tape saw."
            case .unreadable: "Tencent sent something Tape couldn't read."
            case .unknownSymbols: "Tencent didn't recognise any of these symbols."
            }
        }
    }

    nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
        var symbol: String
        var name: String
        var exchange: String
        var kind: Quote.Kind
        var id: String { symbol }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Referer": "https://gu.qq.com/",
        ]
        return URLSession(configuration: configuration)
    }()

    /// One request carries more symbols than Tape will ever show at once.
    private static let batchLimit = 60

    // MARK: - Symbols

    /// Indices whose Yahoo code and Tencent code share no common shape.
    private static let indexWires: [String: String] = [
        "^GSPC": "usINX", "^IXIC": "usIXIC", "^DJI": "usDJI", "^NDX": "usNDX", "^VIX": "usVIX",
        "^HSI": "hkHSI", "^HSTECH": "hkHSTECH",
    ]

    /// Whether Tencent is worth asking for this symbol. Symbols it doesn't cover go to Yahoo.
    static func supports(_ symbol: String) -> Bool {
        wireSymbol(for: symbol) != nil
    }

    /// "600519.SS" → "sh600519", "0700.HK" → "hk00700", "AAPL" → "usAAPL", "^GSPC" → "usINX".
    static func wireSymbol(for symbol: String) -> String? {
        let symbol = symbol.uppercased()
        if let known = indexWires[symbol] { return known }
        guard !symbol.hasPrefix("^") else { return nil }

        if symbol.hasSuffix(".SS") {
            let code = String(symbol.dropLast(3))
            guard isChineseCode(code) else { return nil }
            return "sh" + code
        }
        if symbol.hasSuffix(".SZ") {
            let code = String(symbol.dropLast(3))
            guard isChineseCode(code) else { return nil }
            return "sz" + code
        }
        if symbol.hasSuffix(".HK") {
            let digits = symbol.dropLast(3).filter(\.isNumber)
            guard (1...5).contains(digits.count) else { return nil }
            return "hk" + String(repeating: "0", count: 5 - digits.count) + digits
        }
        // A bare six-digit code is an A-share: 6/9 are Shanghai, 0/1/3 are Shenzhen.
        if isChineseCode(symbol) {
            guard let first = symbol.first else { return nil }
            return ("69".contains(first) ? "sh" : "sz") + symbol
        }
        // Plain US tickers only; anything with an exchange suffix or a class dash stays on Yahoo.
        if symbol.range(of: #"^[A-Z]{1,5}$"#, options: .regularExpression) != nil {
            return "us" + symbol
        }
        return nil
    }

    private static func isChineseCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy(\.isNumber)
    }

    /// The symbol Tape stores for a search hit.
    private static func canonicalSymbol(market: String, code: String) -> String {
        switch market {
        case "sh": return "\(code).SS"
        case "sz": return "\(code).SZ"
        case "hk":
            let digits = code.filter(\.isNumber)
            let padded = String(repeating: "0", count: max(0, 5 - digits.count)) + digits
            // Yahoo writes Hong Kong codes with four digits; Tencent pads to five.
            let trimmed = padded.count == 5 && padded.first == "0" ? String(padded.dropFirst()) : padded
            return "\(trimmed).HK"
        default: return code.uppercased()
        }
    }

    // MARK: - Quotes

    static func quotes(for symbols: [String]) async throws -> [String: Quote] {
        guard !symbols.isEmpty else { return [:] }
        var result: [String: Quote] = [:]
        var lastFailure: Failure?

        for start in stride(from: 0, to: symbols.count, by: batchLimit) {
            let chunk = Array(symbols[start..<min(start + batchLimit, symbols.count)])
            var mapping: [String: String] = [:]
            for symbol in chunk {
                if let wire = wireSymbol(for: symbol) { mapping[wire] = symbol }
            }
            guard !mapping.isEmpty else { continue }

            guard let url = URL(string: "https://qt.gtimg.cn/q=\(mapping.keys.sorted().joined(separator: ","))") else { continue }
            do {
                let data = try await get(url)
                guard let text = data.decodedGB18030() ?? String(data: data, encoding: .utf8) else {
                    throw Failure.unreadable
                }
                result.merge(parse(text: text, mapping: mapping)) { _, new in new }
            } catch let failure as Failure {
                lastFailure = failure
            }
        }

        guard !result.isEmpty else { throw lastFailure ?? .unknownSymbols }
        return result
    }

    private static func get(_ url: URL) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut, .dataNotAllowed]
            throw offline.contains(error.code) ? Failure.offline : Failure.unreadable
        } catch {
            throw Failure.unreadable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return data
    }

    /// Parses `v_<wire>="<fields>";` lines. Symbols Tencent doesn't know are simply absent.
    static func parse(text: String, mapping: [String: String], now: Date = .now) -> [String: Quote] {
        var quotes: [String: Quote] = [:]
        for line in text.split(separator: ";") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("v_") else { continue }
            let wire = String(key.dropFirst(2))
            guard let symbol = mapping[wire] else { continue }
            let payload = line[line.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n\r "))
            if let quote = quote(wire: wire, symbol: symbol, payload: payload, now: now) {
                quotes[symbol] = quote
            }
        }
        return quotes
    }

    /// Field positions: 1 name, 3 last price, 4 previous close, 5 open, 30 quote time,
    /// 32 change percent, 33 day high, 34 day low.
    private static func quote(wire: String, symbol: String, payload: String, now: Date) -> Quote? {
        let fields = payload.components(separatedBy: "~")
        guard fields.count > 34,
              let price = Double(fields[3]), price > 0, price.isFinite else { return nil }

        let previousClose = positive(fields[4])
        let venue = venue(for: wire)
        let session = session(for: wire, now: now)
        let name = fields[1].isEmpty ? symbol : fields[1]

        return Quote(
            symbol: symbol,
            name: name,
            currency: venue.currency,
            exchange: venue.exchange,
            kind: kind(for: wire),
            price: price,
            previousClose: previousClose,
            reportedChangePercent: Double(fields[32]),
            open: positive(fields[5]),
            dayHigh: positive(fields[33]),
            dayLow: positive(fields[34]),
            yearHigh: nil,
            yearLow: nil,
            decimals: decimals(for: wire, price: price),
            marketTime: parseTime(fields[30], timeZone: venue.timeZone) ?? now,
            sessionStart: session?.start,
            sessionEnd: session?.end,
            timeZone: venue.timeZone.identifier,
            intraday: []
        )
    }

    private static func positive(_ raw: String) -> Double? {
        guard let value = Double(raw), value > 0, value.isFinite else { return nil }
        return value
    }

    // MARK: - Venue

    private struct Venue {
        var currency: String
        var exchange: String
        var timeZone: TimeZone
        var closeHour: Int
        var closeMinute: Int = 0
    }

    private static func venue(for wire: String) -> Venue {
        if wire.hasPrefix("sh") {
            return Venue(currency: "CNY", exchange: "Shanghai", timeZone: TimeZone(identifier: "Asia/Shanghai")!, closeHour: 15)
        }
        if wire.hasPrefix("sz") {
            return Venue(currency: "CNY", exchange: "Shenzhen", timeZone: TimeZone(identifier: "Asia/Shanghai")!, closeHour: 15)
        }
        if wire.hasPrefix("hk") {
            return Venue(currency: "HKD", exchange: "Hong Kong", timeZone: TimeZone(identifier: "Asia/Hong_Kong")!, closeHour: 16)
        }
        return Venue(currency: "USD", exchange: "United States", timeZone: TimeZone(identifier: "America/New_York")!, closeHour: 16)
    }

    private static func kind(for wire: String) -> Quote.Kind {
        if wire.hasPrefix("sh") {
            let code = wire.dropFirst(2)
            if code.hasPrefix("000") { return .index }
            if ["50", "51", "56", "58"].contains(where: code.hasPrefix) { return .etf }
            return .stock
        }
        if wire.hasPrefix("sz") {
            let code = wire.dropFirst(2)
            if code.hasPrefix("399") { return .index }
            if ["15", "16", "50"].contains(where: code.hasPrefix) { return .etf }
            return .stock
        }
        if indexWires.values.contains(wire) { return .index }
        return .stock
    }

    private static func decimals(for wire: String, price: Double) -> Int {
        if wire.hasPrefix("hk") || wire.hasPrefix("us") {
            return price < 1 ? 4 : (wire.hasPrefix("hk") && price < 10 ? 3 : 2)
        }
        return 2
    }

    /// The regular session the quote belongs to, today or on the next weekday.
    /// The tape uses it to decide when to poll, so a weekend must not look open.
    static func session(for wire: String, now: Date) -> (start: Date, end: Date)? {
        let venue = venue(for: wire)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = venue.timeZone
        var day = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1, weekday != 7,
               let start = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: day),
               let end = calendar.date(bySettingHour: venue.closeHour, minute: venue.closeMinute, second: 0, of: day) {
                if now < end { return (start, end) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return nil
    }

    private static func parseTime(_ raw: String, timeZone: TimeZone) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyyMMddHHmmss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Search

    static func search(_ text: String) async throws -> [SearchHit] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var components = URLComponents(string: "https://smartbox.gtimg.cn/s3/")!
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "t", value: "all"),
        ]
        let data = try await get(components.url!)
        guard let body = data.decodedGB18030() ?? String(data: data, encoding: .utf8) else {
            throw Failure.unreadable
        }
        return parseSearch(text: body)
    }

    /// `v_hint="sh~600519~贵州茅台~gzmt~GP-A^hk~00700~…"`.
    /// Entries are separated by `^`, fields by `~`: market, code, name, pinyin, type.
    static func parseSearch(text: String) -> [SearchHit] {
        guard let start = text.firstIndex(of: "\""),
              let end = text.lastIndex(of: "\""), start < end else { return [] }
        var seen: Set<String> = []
        var hits: [SearchHit] = []
        for entry in text[text.index(after: start)..<end].split(separator: "^") {
            let fields = entry.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            let market = fields[0]
            guard ["sh", "sz", "hk", "us"].contains(market) else { continue }

            var code = fields[1]
            if market == "us", let dot = code.firstIndex(of: ".") {
                code = String(code[..<dot])
            }
            guard !code.isEmpty else { continue }

            let kind: Quote.Kind? = switch fields[4].prefix(2).uppercased() {
            case "GP": .stock
            case "ZS": .index
            case "ET": .etf
            case "JJ", "LO": .fund
            default: nil
            }
            guard let kind else { continue }

            let name = unescapeUnicode(fields[2])
            guard !name.isEmpty else { continue }
            let symbol = canonicalSymbol(market: market, code: code)
            guard seen.insert(symbol).inserted else { continue }
            hits.append(SearchHit(
                symbol: symbol,
                name: name,
                exchange: marketTitle(market),
                kind: kind
            ))
        }
        return hits
    }

    private static func marketTitle(_ market: String) -> String {
        switch market {
        case "sh": "Shanghai"
        case "sz": "Shenzhen"
        case "hk": "Hong Kong"
        default: "United States"
        }
    }

    /// smartbox returns Chinese names as `\uXXXX` escapes.
    private static func unescapeUnicode(_ raw: String) -> String {
        guard raw.contains("\\u") else { return raw }
        return raw.applyingTransform(StringTransform("Hex-Any"), reverse: false) ?? raw
    }
}

extension Data {
    /// Tencent answers in GBK; GB18030 is its superset.
    nonisolated func decodedGB18030() -> String? {
        let encoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String(data: self, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
    }
}
