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
/// Two conformers: FeedFetcher and ScrapeFetcher, chosen per source by
/// RoutingFetcher. The engine never learns which was used.
protocol SourceFetching: Sendable {
    func items(for source: SourceSnapshot) async throws -> [ParsedItem]
}

/// Which strategy a source should use.
enum FetchRoute: Sendable, Equatable {
    case feed(URL)
    case scrape(homepage: URL, selector: String)
    case none(reason: String)
}

enum FetchRouter {
    /// A feed wins when both are available: it is the publisher's own
    /// structured output and far cheaper to read than a homepage.
    ///
    /// Anything without a feed is scraped, and a selector is NOT required to
    /// get there. The scrape strategy is a general heuristic that reads any
    /// news homepage; headlineSelector is an optional refinement for a source
    /// it handles badly. Demanding one here meant six sources that scrape
    /// perfectly well were reported as "no feed and no selector" and never
    /// read at all - and every component test still passed, because each part
    /// was tested and only the route between them was wrong.
    static func route(_ source: SourceSnapshot) -> FetchRoute {
        if let feed = source.feedURL {
            return .feed(feed)
        }

        let homepage = source.url
        let scheme = homepage.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            // The only genuinely unroutable source: one whose homepage is not
            // something that can be requested at all.
            return .none(reason: "homepage URL is not http(s)")
        }

        let selector = source.headlineSelector?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .scrape(homepage: homepage, selector: selector)
    }
}
