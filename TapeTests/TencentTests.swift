import Foundation
import Testing
@testable import Tape

// MARK: Symbols

@Suite struct TencentSymbols {
    @Test func mapsYahooStyleSymbolsToTencentWires() {
        #expect(Tencent.wireSymbol(for: "600519.SS") == "sh600519")
        #expect(Tencent.wireSymbol(for: "000001.SZ") == "sz000001")
        #expect(Tencent.wireSymbol(for: "0700.HK") == "hk00700")
        #expect(Tencent.wireSymbol(for: "00700.HK") == "hk00700")
        #expect(Tencent.wireSymbol(for: "AAPL") == "usAAPL")
        #expect(Tencent.wireSymbol(for: "^GSPC") == "usINX")
        #expect(Tencent.wireSymbol(for: "^HSI") == "hkHSI")
    }

    @Test func readsBareChineseCodes() {
        #expect(Tencent.wireSymbol(for: "600519") == "sh600519")
        #expect(Tencent.wireSymbol(for: "000001") == "sz000001")
        #expect(Tencent.wireSymbol(for: "300750") == "sz300750")
    }

    @Test func leavesWhatTencentDoesNotCarryToYahoo() {
        #expect(Tencent.wireSymbol(for: "BTC-USD") == nil)
        #expect(Tencent.wireSymbol(for: "VWCE.DE") == nil)
        #expect(Tencent.wireSymbol(for: "EURUSD=X") == nil)
        #expect(Tencent.wireSymbol(for: "^N225") == nil)
        #expect(Tencent.wireSymbol(for: "BRK-B") == nil)
    }
}

// MARK: Quotes

@Suite struct TencentQuotes {
    /// A-share line, fields trimmed to the positions Tape reads.
    private let maotai = #"v_sh600519="1~贵州茅台~600519~1444.99~1453.00~1440.06~24801~12123~12678~1444.90~1~1444.89~2~1444.87~4~1444.30~2~1444.29~1~1444.99~40~1445.00~133~1445.08~2~1445.20~2~0~0~0~20261109161440~-8.01~-0.55~1449.99~1435.08~1444.99/24801/3578407287~24801~357841";"#

    @Test func readsAnAShareLine() throws {
        let quotes = Tencent.parse(text: maotai, mapping: ["sh600519": "600519.SS"])
        let quote = try #require(quotes["600519.SS"])
        #expect(quote.name == "贵州茅台")
        #expect(quote.price == 1444.99)
        #expect(quote.previousClose == 1453.00)
        #expect(quote.open == 1440.06)
        #expect(quote.dayHigh == 1449.99)
        #expect(quote.dayLow == 1435.08)
        #expect(quote.reportedChangePercent == -0.55)
        #expect(quote.kind == .stock)
        #expect(quote.currency == "CNY")
        #expect(quote.exchange == "Shanghai")
        #expect(quote.decimals == 2)
        #expect(quote.timeZone == "Asia/Shanghai")
    }

    @Test func readsHongKongAndUSLines() {
        let hk = #"v_hk00700="100~腾讯控股~00700~418.400~419.800~425.200~16369186.0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~2026/11/09 16:08:10~-1.400~-0.33~428.400~416.000~418.400~16369186.0~6891646411.288";"#
        let us = #"v_usAAPL="200~苹果~AAPL.OQ~342.37~344.17~338.73~44703806~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~2026-11-06 16:00:01~-1.80~-0.52~345.79~338.30~USD~44703806~15326963640";"#

        let quotes = Tencent.parse(text: hk + us, mapping: ["hk00700": "0700.HK", "usAAPL": "AAPL"])
        #expect(quotes["0700.HK"]?.currency == "HKD")
        #expect(quotes["0700.HK"]?.exchange == "Hong Kong")
        #expect(quotes["0700.HK"]?.price == 418.4)
        #expect(quotes["AAPL"]?.currency == "USD")
        #expect(quotes["AAPL"]?.exchange == "United States")
        #expect(quotes["AAPL"]?.name == "苹果")
    }

    @Test func classifiesIndicesAndETFs() {
        let index = #"v_sh000001="1~上证指数~000001~3660.79~3649.18~3659.02~427722257~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~20261109161428~11.61~0.32~3665.00~3640.00~0~0~0";"#
        let etf = #"v_sh510300="1~沪深300ETF~510300~4.100~4.090~4.095~1000~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~20261109161428~0.010~0.24~4.110~4.080~0~0~0";"#
        let quotes = Tencent.parse(text: index + etf, mapping: ["sh000001": "000001.SS", "sh510300": "510300.SS"])
        #expect(quotes["000001.SS"]?.kind == .index)
        #expect(quotes["510300.SS"]?.kind == .etf)
    }

    @Test func skipsSuspendedListingsRatherThanShowingZero() {
        let suspended = #"v_sz000002="51~万科A~000002~0.00~8.00~0.00~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~20261109150000~0~0~0~0~0~0~0";"#
        #expect(Tencent.parse(text: suspended, mapping: ["sz000002": "000002.SZ"]).isEmpty)
    }

    @Test func weekendSessionStartsMonday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let saturday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12)))
        let session = try #require(Tencent.session(for: "sh600519", now: saturday))
        let start = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: session.start)
        #expect(start.year == 2026)
        #expect(start.month == 11)
        #expect(start.day == 16)
        #expect(start.hour == 9)
        #expect(start.minute == 30)
        #expect(session.start < session.end)
    }
}

// MARK: Search

@Suite struct TencentSearch {
    @Test func readsChineseNamesAndCodes() throws {
        let text = #"v_hint="sh~600519~贵州茅台~gzmt~GP-A^hk~00700~腾讯控股~txkg~GP^us~AAPL.OQ~AAPL~aapl~GP-A";"#
        let hits = Tencent.parseSearch(text: text)
        #expect(hits.count == 3)
        #expect(hits[0].symbol == "600519.SS")
        #expect(hits[0].name == "贵州茅台")
        #expect(hits[0].kind == .stock)
        #expect(hits[0].exchange == "Shanghai")
        #expect(hits[1].symbol == "0700.HK")
        #expect(hits[1].name == "腾讯控股")
        #expect(hits[2].symbol == "AAPL")
    }

    @Test func skipsTypesTapeCannotQuote() {
        let text = #"v_hint="sh~600519~贵州茅台~gzmt~QZ^sh~600000~浦发银行~pfyh~GP-A";"#
        let hits = Tencent.parseSearch(text: text)
        #expect(hits.map(\.symbol) == ["600000.SS"])
    }

    @Test func emptyHintReturnsNothing() {
        #expect(Tencent.parseSearch(text: #"v_hint="";"#).isEmpty)
    }
}
