import Foundation
import Observation

/// Keeps the quotes for the watchlist fresh: every `refreshInterval` while any of its markets
/// trades, at the next opening bell (or every fifteen minutes) when they're all closed.
/// The last answer is kept on disk, so the tape is full the moment Tape launches.
@Observable
final class Market {
    private(set) var quotes: [String: Quote] = [:]
    private(set) var updatedAt: Date?
    private(set) var problem: String?
    private(set) var isLoading = false

    @ObservationIgnored var symbols: [String] = [] {
        didSet { if oldValue != symbols { refreshNow() } }
    }
    @ObservationIgnored var interval: Duration = .seconds(30)

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// Opening prices by symbol, for the session they belong to.
    @ObservationIgnored private var opens: [String: (session: Date, value: Double)] = [:]
    @ObservationIgnored private let cacheURL: URL

    init() {
        let folder = URL.applicationSupportDirectory.appending(path: "Tape", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cacheURL = folder.appending(path: "quotes.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([String: Quote].self, from: data) {
            quotes = cached
            updatedAt = cached.values.map(\.marketTime).max()
        }
    }

    func start() {
        guard loop == nil else { return }
        refreshNow()
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Fetches right away and restarts the schedule from there.
    func refreshNow() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetch()
                try? await Task.sleep(for: self.nextDelay())
            }
        }
    }

    private func fetch() async {
        let wanted = symbols
        guard !wanted.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var fresh = try await Yahoo.quotes(for: wanted)
            guard !Task.isCancelled else { return }
            for (symbol, quote) in fresh {
                if let start = quote.sessionStart, let known = opens[symbol], known.session == start {
                    fresh[symbol]?.open = known.value
                }
            }
            // Keep listings Yahoo skipped this time rather than blinking them off the tape.
            for symbol in wanted where fresh[symbol] == nil {
                if let old = quotes[symbol] { fresh[symbol] = old }
            }
            quotes = fresh
            updatedAt = .now
            problem = nil
            save()
            fetchMissingOpens()
        } catch is CancellationError {
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One chart request per listing per session, spaced out so Yahoo stays friendly.
    private func fetchMissingOpens() {
        guard openTask == nil else { return }
        let missing = quotes.values.filter { quote in
            guard quote.kind != .crypto, quote.kind != .currency, let start = quote.sessionStart, start <= .now else { return false }
            return opens[quote.symbol]?.session != start
        }
        guard !missing.isEmpty else { return }
        openTask = Task { [weak self] in
            for quote in missing {
                guard !Task.isCancelled, let start = quote.sessionStart else { break }
                if let value = try? await Yahoo.dayOpen(of: quote.symbol) {
                    self?.opens[quote.symbol] = (start, value)
                    if self?.quotes[quote.symbol]?.sessionStart == start { self?.quotes[quote.symbol]?.open = value }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.openTask = nil
        }
    }

    private func nextDelay() -> Duration {
        if problem != nil { return .seconds(45) }
        let now = Date.now
        let current = symbols.compactMap { quotes[$0] }
        if current.isEmpty || current.contains(where: { $0.isTrading(at: now) }) { return interval }
        // Everything is closed: wake at the next opening bell Yahoo told us about, or check in now and then.
        let nextOpen = current.compactMap(\.sessionStart).filter { $0 > now }.min()
        let wait = nextOpen.map { $0.timeIntervalSince(now) + 5 } ?? 15 * 60
        return .seconds(min(max(wait, 60), 15 * 60))
    }

    private func save() {
        let snapshot = quotes
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
