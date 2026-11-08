import Foundation
import Observation

/// Which side of the Dock the tape runs on.
nonisolated enum DockSide: String, CaseIterable, Codable, Sendable {
    case left, right
}

/// How a move is written after the price.
nonisolated enum ChangeStyle: String, CaseIterable, Codable, Sendable {
    case percent, amount, both
}

/// What a move is measured against.
nonisolated enum Reference: String, CaseIterable, Codable, Sendable {
    case previousClose, open
}

/// Whether the text is drawn for a dark or a light wallpaper.
nonisolated enum Contrast: String, CaseIterable, Codable, Sendable {
    case automatic, lightText, darkText
}

/// One line of the watchlist: a Yahoo symbol, optionally with its own label and colour.
nonisolated struct WatchItem: Codable, Hashable, Identifiable, Sendable {
    var symbol: String
    var label: String?
    /// "#RRGGBB". Overrides the colour taken from the logo.
    var color: String?

    var id: String { symbol }

    init(_ symbol: String, label: String? = nil, color: String? = nil) {
        self.symbol = symbol
        self.label = label
        self.color = color
    }
}

/// Everything the person can change, kept in UserDefaults.
@Observable
final class Settings {
    static let shared = Settings()

    static let defaultWatchlist: [WatchItem] = [
        "^GSPC", "NVDA", "AAPL", "MSFT", "ASML.AS", "VWCE.DE", "META", "AMZN", "TSLA", "BTC-EUR",
    ].map { WatchItem($0) }

    @ObservationIgnored private let defaults: UserDefaults

    var watchlist: [WatchItem] { didSet { store(watchlist, Key.watchlist) } }
    var design: TapeDesign { didSet { defaults.set(design.rawValue, forKey: Key.design) } }
    var side: DockSide { didSet { defaults.set(side.rawValue, forKey: Key.side) } }
    /// Points per second.
    var speed: Double { didSet { defaults.set(speed, forKey: Key.speed) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var showCurrency: Bool { didSet { defaults.set(showCurrency, forKey: Key.showCurrency) } }
    var changeStyle: ChangeStyle { didSet { defaults.set(changeStyle.rawValue, forKey: Key.changeStyle) } }
    var reference: Reference { didSet { defaults.set(reference.rawValue, forKey: Key.reference) } }
    var contrast: Contrast { didSet { defaults.set(contrast.rawValue, forKey: Key.contrast) } }
    var brandColors: Bool { didSet { defaults.set(brandColors, forKey: Key.brandColors) } }
    var pauseOnHover: Bool { didSet { defaults.set(pauseOnHover, forKey: Key.pauseOnHover) } }
    /// Seconds between refreshes while a market is open.
    var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    /// Points between the tape and the Dock's icons.
    var dockGap: Double { didSet { defaults.set(dockGap, forKey: Key.dockGap) } }
    var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: Key.hasLaunchedBefore) } }
    /// Seconds each listing stays in Focus.
    var focusDwell: Double { didSet { defaults.set(focusDwell, forKey: Key.focusDwell) } }
    /// Focus on a pane of glass, rather than straight on the wallpaper.
    var focusGlass: Bool { didSet { defaults.set(focusGlass, forKey: Key.focusGlass) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watchlist = Self.load([WatchItem].self, Key.watchlist, from: defaults) ?? Self.defaultWatchlist
        design = defaults.string(forKey: Key.design).flatMap(TapeDesign.init(rawValue:)) ?? .liquid
        side = defaults.string(forKey: Key.side).flatMap(DockSide.init(rawValue:)) ?? .left
        speed = defaults.object(forKey: Key.speed) as? Double ?? 30
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 14
        showCurrency = defaults.object(forKey: Key.showCurrency) as? Bool ?? true
        changeStyle = defaults.string(forKey: Key.changeStyle).flatMap(ChangeStyle.init(rawValue:)) ?? .percent
        reference = defaults.string(forKey: Key.reference).flatMap(Reference.init(rawValue:)) ?? .previousClose
        contrast = defaults.string(forKey: Key.contrast).flatMap(Contrast.init(rawValue:)) ?? .automatic
        brandColors = defaults.object(forKey: Key.brandColors) as? Bool ?? true
        pauseOnHover = defaults.object(forKey: Key.pauseOnHover) as? Bool ?? true
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Int ?? 30
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        dockGap = defaults.object(forKey: Key.dockGap) as? Double ?? 22
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore)
        focusDwell = defaults.object(forKey: Key.focusDwell) as? Double ?? 6
        focusGlass = defaults.object(forKey: Key.focusGlass) as? Bool ?? false
    }

    // MARK: Watchlist edits

    func add(_ symbol: String) {
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty, !watchlist.contains(where: { $0.symbol == symbol }) else { return }
        watchlist.append(WatchItem(symbol))
    }

    func remove(_ symbol: String) {
        watchlist.removeAll { $0.symbol == symbol }
    }

    func setColor(_ hex: String?, for symbol: String) {
        guard let index = watchlist.firstIndex(where: { $0.symbol == symbol }) else { return }
        watchlist[index].color = hex
    }

    func setLabel(_ label: String?, for symbol: String) {
        guard let index = watchlist.firstIndex(where: { $0.symbol == symbol }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        watchlist[index].label = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func resetAppearance() {
        speed = 30
        fontSize = 14
        showCurrency = true
        changeStyle = .percent
        reference = .previousClose
        contrast = .automatic
        brandColors = true
        focusDwell = 6
        focusGlass = false
    }

    // MARK: Storage

    private enum Key {
        static let watchlist = "watchlist"
        static let design = "design"
        static let side = "side"
        static let speed = "speed"
        static let fontSize = "fontSize"
        static let showCurrency = "showCurrency"
        static let changeStyle = "changeStyle"
        static let reference = "reference"
        static let contrast = "contrast"
        static let brandColors = "brandColors"
        static let pauseOnHover = "pauseOnHover"
        static let refreshInterval = "refreshInterval"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let dockGap = "dockGap"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let focusDwell = "focusDwell"
        static let focusGlass = "focusGlass"
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
