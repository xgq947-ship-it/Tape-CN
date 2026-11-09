import Foundation

/// Picks the source per symbol and merges the answers.
///
/// Tencent carries Shanghai, Shenzhen, Hong Kong and the US through one endpoint that answers
/// from mainland China; Yahoo fills in everything else (crypto, currencies, futures, Europe,
/// Japan, Korea) and stands in whenever Tencent has nothing. A failure on one side never
/// discards the other side's quotes.
nonisolated enum QuoteFeed {
    static func quotes(for symbols: [String]) async throws -> [String: Quote] {
        guard !symbols.isEmpty else { return [:] }

        let local = symbols.filter(Tencent.supports)
        let global = symbols.filter { !Tencent.supports($0) }
        var result: [String: Quote] = [:]
        var firstFailure: (any Error)?

        if !local.isEmpty {
            do {
                result.merge(try await Tencent.quotes(for: local)) { _, new in new }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstFailure = firstFailure ?? error
            }
        }

        // Anything Tencent couldn't answer — an unsupported listing, a bad code, an outage —
        // still gets a chance from Yahoo.
        let remaining = global + local.filter { result[$0] == nil }
        if !remaining.isEmpty {
            do {
                result.merge(try await Yahoo.quotes(for: remaining)) { _, new in new }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstFailure = firstFailure ?? error
            }
        }

        if result.isEmpty, let firstFailure { throw firstFailure }
        return result
    }
}
