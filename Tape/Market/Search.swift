import Foundation

/// One row of the watchlist search field, whichever source found it.
nonisolated struct SymbolSearchHit: Identifiable, Hashable, Sendable {
    var symbol: String
    var name: String
    var exchange: String
    var kind: Quote.Kind
    var id: String { symbol }

    init(symbol: String, name: String, exchange: String, kind: Quote.Kind) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.kind = kind
    }

    init(_ hit: Tencent.SearchHit) {
        self.init(symbol: hit.symbol, name: hit.name, exchange: hit.exchange, kind: hit.kind)
    }

    init(_ hit: Yahoo.SearchHit) {
        self.init(symbol: hit.symbol, name: hit.name, exchange: hit.exchange, kind: hit.kind)
    }
}

/// Searches both sources at once: Tencent knows Chinese names and A-shares, Yahoo knows the
/// rest of the world. One of them being down must not empty the results.
nonisolated enum SymbolSearch {
    static func search(_ text: String) async -> [SymbolSearchHit] {
        async let tencent = Tencent.search(text)
        async let yahoo = Yahoo.search(text)
        let local = ((try? await tencent) ?? []).map(SymbolSearchHit.init)
        let global = ((try? await yahoo) ?? []).map(SymbolSearchHit.init)

        var seen: Set<String> = []
        return (local + global).filter { seen.insert($0.symbol).inserted }
    }
}
