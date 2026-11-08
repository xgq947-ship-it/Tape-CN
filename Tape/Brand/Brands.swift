import AppKit
import Observation

/// Finds each listing's colour and logo: the curated table first, then the logo itself,
/// downloaded once and kept on disk for a month.
@Observable
final class Brands {
    /// Colours found in logos, by symbol.
    private(set) var extracted: [String: BrandColor] = [:]
    /// Logo tiles for the detail card, by symbol.
    private(set) var logos: [String: NSImage] = [:]

    @ObservationIgnored private var inFlight: Set<String> = []
    /// Logos read back from disk; kept out of observation so reading one never redraws anything.
    @ObservationIgnored private var stored: [String: NSImage] = [:]
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]

    private struct Index: Codable {
        var colors: [String: BrandColor]
        var fetchedAt: [String: Date]
    }

    init() {
        folder = URL.applicationSupportDirectory.appending(path: "Tape/Logos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        indexURL = folder.appending(path: "index.json")
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            extracted = index.colors
            fetchedAt = index.fetchedAt
        }
    }

    /// The colour to draw a watchlist line in, before legibility adjustments. Nil means neutral.
    func color(for item: WatchItem) -> RGB? {
        if let hex = item.color, let custom = RGB(hexString: hex) { return custom }
        if let curated = BrandTable.color(for: item.symbol) { return curated.rgb }
        return extracted[item.symbol]?.rgb
    }

    /// Where the colour comes from, for the watchlist editor.
    func source(for item: WatchItem) -> String {
        if item.color != nil { return "Your colour" }
        if BrandTable.color(for: item.symbol) != nil { return "Brand colour" }
        if let found = extracted[item.symbol] { return found == .neutral ? "Monochrome logo" : "From the logo" }
        return BrandTable.hasLogo(item.symbol) ? "Looking at the logo…" : "No logo"
    }

    func logo(for symbol: String) -> NSImage? {
        if let logo = logos[symbol] ?? stored[symbol] { return logo }
        guard let image = NSImage(contentsOf: fileURL(for: symbol)) else { return nil }
        stored[symbol] = image
        return image
    }

    /// Looks up logos for symbols that don't have a colour (or logo) yet.
    func prepare(_ symbols: [String]) {
        for symbol in symbols where BrandTable.hasLogo(symbol) && !inFlight.contains(symbol) {
            let stale = fetchedAt[symbol].map { Date.now.timeIntervalSince($0) > 30 * 24 * 3600 } ?? true
            let hasFile = FileManager.default.fileExists(atPath: fileURL(for: symbol).path)
            guard stale || !hasFile || extracted[symbol] == nil else { continue }
            inFlight.insert(symbol)
            Task { await fetch(symbol) }
        }
    }

    private func fetch(_ symbol: String) async {
        defer { inFlight.remove(symbol) }
        var found: (data: Data, color: BrandColor)?
        for url in Self.sources(for: symbol) {
            guard let data = try? await Self.download(url), let image = NSImage(data: data),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let color = LogoColor.dominant(in: cgImage).map(BrandColor.color) ?? .neutral
            if found == nil { found = (data, color) }
            // A monochrome tile may be a monochrome logo, or just a poor crop: give the next source a chance.
            if color != .neutral { found = (found?.data ?? data, color); break }
        }
        guard let found else { return }
        try? found.data.write(to: fileURL(for: symbol), options: .atomic)
        logos[symbol] = NSImage(data: found.data)
        extracted[symbol] = found.color
        fetchedAt[symbol] = .now
        saveIndex()
    }

    nonisolated private static func sources(for symbol: String) -> [URL] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? symbol
        return [
            URL(string: "https://assets.parqet.com/logos/symbol/\(encoded)?format=png&size=200"),
            URL(string: "https://financialmodelingprep.com/image-stock/\(encoded).png"),
        ].compactMap { $0 }
    }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await Yahoo.session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image") ?? false else { throw URLError(.badServerResponse) }
        return data
    }

    private func fileURL(for symbol: String) -> URL {
        let safe = symbol.replacingOccurrences(of: "/", with: "_")
        return folder.appending(path: "\(safe).png")
    }

    private func saveIndex() {
        let index = Index(colors: extracted, fetchedAt: fetchedAt)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }
}

/// The colour a logo is remembered by: the most vivid hue that covers a real part of it.
/// Whites, greys and blacks don't count, so Apple's grey apple is monochrome and
/// Coca-Cola's white script on red is red.
nonisolated enum LogoColor {
    static func dominant(in image: CGImage) -> RGB? {
        let side = 48
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = context.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let binCount = 36
        var weight = [Double](repeating: 0, count: binCount)
        var sumL = [Double](repeating: 0, count: binCount)
        var sumA = [Double](repeating: 0, count: binCount)
        var sumB = [Double](repeating: 0, count: binCount)
        var opaque = 0.0
        var colored = 0.0

        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let rgb = RGB(
                r: Double(pixels[index * 4]) / 255 / alpha,
                g: Double(pixels[index * 4 + 1]) / 255 / alpha,
                b: Double(pixels[index * 4 + 2]) / 255 / alpha
            ).clamped
            let lab = rgb.oklab
            opaque += 1
            guard lab.chroma > 0.06, lab.l > 0.2, lab.l < 0.97 else { continue }
            colored += 1
            let bin = Int(lab.hue / 360 * Double(binCount)) % binCount
            let w = lab.chroma
            weight[bin] += w
            sumL[bin] += lab.l * w
            sumA[bin] += lab.a * w
            sumB[bin] += lab.b * w
        }
        // A few coloured pixels in a black-and-white logo are anti-aliasing, not a brand colour.
        guard opaque > 0, colored / opaque > 0.04 else { return nil }

        // Merge each bin with its neighbours so a hue split across a bin edge still wins.
        var best = 0
        var bestWeight = 0.0
        for bin in 0..<binCount {
            let total = weight[(bin + binCount - 1) % binCount] + weight[bin] + weight[(bin + 1) % binCount]
            if total > bestWeight {
                bestWeight = total
                best = bin
            }
        }
        var w = 0.0, l = 0.0, a = 0.0, b = 0.0
        for bin in [(best + binCount - 1) % binCount, best, (best + 1) % binCount] {
            w += weight[bin]
            l += sumL[bin]
            a += sumA[bin]
            b += sumB[bin]
        }
        guard w > 0 else { return nil }
        return RGB(OKLab(l: l / w, a: a / w, b: b / w)).clamped
    }
}
