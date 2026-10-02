import Foundation

/// Everything the fetch layer needs about a source, as a value type.
///
/// SwiftData models are not Sendable, so the engine never sees one; it sees
/// this snapshot instead. That also makes the whole pipeline testable with no
/// database and no network.
struct SourceSnapshot: Sendable, Hashable {
    let id: String
    let name: String
    let url: URL
    let feedURL: URL?
    let rank: Int
    let cooldownMinutes: Int
    let isInactive: Bool
    let headlineSelector: String?
    let lastAttemptedAt: Date?
    let lastFetchedAt: Date?
}

/// One headline, however it was obtained. The feed strategy and the future
/// scrape strategy both produce these, so callers cannot tell which was used.
struct ParsedItem: Sendable, Hashable {
    let title: String
    let url: URL
    let publishedAt: Date?
}

/// The single abstraction the aggregation engine depends on.
///
/// v1 ships exactly one conformer, FeedFetcher. HTML scraping is the planned
/// second one, which is why this protocol exists now rather than later: adding
/// it must not require touching the engine.
protocol SourceFetching: Sendable {
    func items(for source: SourceSnapshot) async throws -> [ParsedItem]
}

/// Which strategy a source should use.
///
/// The scrape case is deliberately present and routed in v1 even though
/// nothing implements it. The engine turns it into a visible "not implemented"
/// warning rather than a silent skip, so the seam stays exercised and tested.
enum FetchRoute: Sendable, Equatable {
    case feed(URL)
    case scrape(homepage: URL, selector: String)
    case none(reason: String)
}

enum FetchRouter {
    /// A feed wins when both are available: it is the publisher's own
    /// structured output and far cheaper to read than a homepage.
    static func route(_ source: SourceSnapshot) -> FetchRoute {
        if let feed = source.feedURL {
            return .feed(feed)
        }
        if let selector = source.headlineSelector,
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .scrape(homepage: source.url, selector: selector)
        }
        return .none(reason: "no feed and no selector")
    }
}
