import Foundation

/// Yahoo Finance's public spark, chart and search endpoints: no key, every major exchange.
/// They're unofficial, so decoding is defensive and everything goes through this one type.
nonisolated enum Yahoo {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case status(Int)
        case offline
        case unreadable

        var errorDescription: String? {
            switch self {
            case .status(429): "Yahoo Finance is busy. Trying again shortly."
            case .status(let code): "Yahoo Finance answered \(code)."
            case .offline: "You're offline. Showing the last prices Tape saw."
            case .unreadable: "Yahoo Finance sent something Tape couldn't read."
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

    /// Yahoo answers at most this many symbols per spark request.
    static let sparkLimit = 20

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            // Yahoo serves browsers; a browser user agent keeps the free endpoints answering.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Accept": "application/json",
        ]
        return URLSession(configuration: configuration)
    }()

    // MARK: Requests

    /// Latest quotes with today's five-minute path, in as few requests as Yahoo allows.
    static func quotes(for symbols: [String]) async throws -> [String: Quote] {
        var result: [String: Quote] = [:]
        for start in stride(from: 0, to: symbols.count, by: sparkLimit) {
            let batch = Array(symbols[start..<min(start + sparkLimit, symbols.count)])
            let data = try await get(sparkURL(symbols: batch))
            result.merge(try decodeSpark(data)) { _, new in new }
        }
        return result
    }

    /// Today's opening price. The spark endpoint only carries closes, so this asks the chart endpoint once per session.
    static func dayOpen(of symbol: String) async throws -> Double? {
        let data = try await get(chartURL(symbol: symbol))
        return try decodeOpen(data)
    }

    static func search(_ text: String) async throws -> [SearchHit] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let data = try await get(searchURL(query: query))
        return try decodeSearch(data)
    }

    static func pageURL(for symbol: String) -> URL {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "^="))) ?? symbol
        return URL(string: "https://finance.yahoo.com/quote/\(encoded)/")!
    }

    private static func get(_ url: URL, retries: Int = 2) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (200..<300).contains(status) { return data }
                guard status == 429 || status >= 500, attempt < retries else { throw Failure.status(status) }
            } catch let error as URLError {
                let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut, .dataNotAllowed]
                guard offline.contains(error.code) else { throw error }
                guard attempt < retries else { throw Failure.offline }
            }
            attempt += 1
            try await Task.sleep(for: .milliseconds(600 * attempt * attempt))
        }
    }

    // MARK: URLs

    private static let symbolCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    static func sparkURL(symbols: [String]) -> URL {
        let list = symbols.map { $0.addingPercentEncoding(withAllowedCharacters: symbolCharacters) ?? $0 }.joined(separator: ",")
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/spark")!
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "symbols", value: list),
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "5m"),
        ]
        return components.url!
    }

    static func chartURL(symbol: String) -> URL {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: symbolCharacters) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)")!
        components.queryItems = [URLQueryItem(name: "range", value: "1d"), URLQueryItem(name: "interval", value: "1d")]
        return components.url!
    }

    static func searchURL(query: String) -> URL {
        var components = URLComponents(string: "https://query2.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "8"),
            URLQueryItem(name: "newsCount", value: "0"),
            URLQueryItem(name: "listsCount", value: "0"),
            URLQueryItem(name: "enableFuzzyQuery", value: "false"),
        ]
        return components.url!
    }

    // MARK: Wire format

    private struct SparkEnvelope: Decodable {
        struct Spark: Decodable {
            struct Item: Decodable {
                let symbol: String
                let response: [ChartResult]?
            }
            let result: [Item]?
        }
        let spark: Spark
    }

    private struct ChartEnvelope: Decodable {
        struct Chart: Decodable { let result: [ChartResult]? }
        let chart: Chart
    }

    private struct ChartResult: Decodable {
        struct Meta: Decodable {
            struct Periods: Decodable {
                struct Period: Decodable {
                    let start: Double?
                    let end: Double?
                }
                let regular: Period?
            }
            let currency: String?
            let symbol: String?
            let fullExchangeName: String?
            let exchangeName: String?
            let instrumentType: String?
            let exchangeTimezoneName: String?
            let regularMarketTime: Double?
            let regularMarketPrice: Double?
            let regularMarketChangePercent: Double?
            let previousClose: Double?
            let chartPreviousClose: Double?
            let regularMarketDayHigh: Double?
            let regularMarketDayLow: Double?
            let fiftyTwoWeekHigh: Double?
            let fiftyTwoWeekLow: Double?
            let longName: String?
            let shortName: String?
            let priceHint: Int?
            let currentTradingPeriod: Periods?
        }
        struct Indicators: Decodable {
            struct Series: Decodable {
                let open: [Double?]?
                let close: [Double?]?
            }
            let quote: [Series]?
        }
        let meta: Meta
        let timestamp: [Double]?
        let indicators: Indicators?
    }

    private struct SearchEnvelope: Decodable {
        struct Hit: Decodable {
            let symbol: String?
            let quoteType: String?
            let shortname: String?
            let longname: String?
            let exchDisp: String?
            let exchange: String?
        }
        let quotes: [Hit]?
    }

    // MARK: Decoding

    /// Quotes by the symbol that was asked for. Symbols Yahoo doesn't know are simply absent.
    static func decodeSpark(_ data: Data) throws -> [String: Quote] {
        guard let envelope = try? JSONDecoder().decode(SparkEnvelope.self, from: data) else { throw Failure.unreadable }
        var quotes: [String: Quote] = [:]
        for item in envelope.spark.result ?? [] {
            if let chart = item.response?.first, let quote = quote(from: chart, symbol: item.symbol) {
                quotes[item.symbol] = quote
            }
        }
        return quotes
    }

    static func decodeOpen(_ data: Data) throws -> Double? {
        guard let envelope = try? JSONDecoder().decode(ChartEnvelope.self, from: data) else { throw Failure.unreadable }
        let opens = envelope.chart.result?.first?.indicators?.quote?.first?.open ?? []
        return opens.compactMap { $0 }.first { $0 > 0 && $0.isFinite }
    }

    static func decodeSearch(_ data: Data) throws -> [SearchHit] {
        guard let envelope = try? JSONDecoder().decode(SearchEnvelope.self, from: data) else { throw Failure.unreadable }
        let wanted: Set<String> = ["EQUITY", "ETF", "MUTUALFUND", "INDEX", "CRYPTOCURRENCY", "CURRENCY", "FUTURE"]
        return (envelope.quotes ?? []).compactMap { hit in
            guard let symbol = hit.symbol, let type = hit.quoteType?.uppercased(), wanted.contains(type) else { return nil }
            let kind = Quote.Kind(yahoo: type)
            let name = hit.longname ?? hit.shortname ?? symbol
            return SearchHit(
                symbol: symbol,
                name: kind == .crypto ? cryptoName(name) : name,
                exchange: kind == .crypto ? "Crypto" : (hit.exchDisp ?? hit.exchange ?? ""),
                kind: kind
            )
        }
    }

    private static func quote(from chart: ChartResult, symbol: String) -> Quote? {
        let meta = chart.meta
        guard let price = meta.regularMarketPrice, price > 0, price.isFinite else { return nil }
        let kind = Quote.Kind(yahoo: meta.instrumentType)
        var name = meta.longName ?? meta.shortName ?? symbol
        if kind == .crypto { name = cryptoName(name) }
        let closes = chart.indicators?.quote?.first?.close ?? []
        let points = zip(chart.timestamp ?? [], closes).compactMap { time, close -> Quote.Point? in
            guard let close, close > 0, close.isFinite else { return nil }
            return Quote.Point(time: Date(timeIntervalSince1970: time), value: close)
        }
        return Quote(
            symbol: symbol,
            name: name,
            currency: meta.currency,
            exchange: kind == .crypto ? "Crypto" : (meta.fullExchangeName ?? meta.exchangeName),
            kind: kind,
            price: price,
            previousClose: meta.previousClose ?? meta.chartPreviousClose,
            reportedChangePercent: meta.regularMarketChangePercent,
            open: nil,
            dayHigh: meta.regularMarketDayHigh,
            dayLow: meta.regularMarketDayLow,
            yearHigh: meta.fiftyTwoWeekHigh,
            yearLow: meta.fiftyTwoWeekLow,
            decimals: min(max(meta.priceHint ?? 2, 0), 6),
            marketTime: meta.regularMarketTime.map { Date(timeIntervalSince1970: $0) } ?? .now,
            sessionStart: meta.currentTradingPeriod?.regular?.start.map { Date(timeIntervalSince1970: $0) },
            sessionEnd: meta.currentTradingPeriod?.regular?.end.map { Date(timeIntervalSince1970: $0) },
            timeZone: meta.exchangeTimezoneName,
            intraday: points
        )
    }

    /// "Bitcoin EUR" → "Bitcoin": the pair's currency is shown on its own.
    static func cryptoName(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard words.count > 1, let last = words.last, last.count == 3, last.allSatisfy(\.isUppercase) else { return name }
        return words.dropLast().joined(separator: " ")
    }
}
