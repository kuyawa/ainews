import Foundation

/// Chooses the strategy for each source.
///
/// The engine knows only SourceFetching, and neither fetcher knows the other
/// exists. Whether a source is fetched AT ALL is settled before this is
/// reached: the store leaves inactive sources out of the list, and the engine
/// refuses them outright. This type only decides HOW an allowed source is read.
struct RoutingFetcher: SourceFetching {
    let feed: FeedFetcher
    let scrape: ScrapeFetcher

    init(feed: FeedFetcher = FeedFetcher(), scrape: ScrapeFetcher = ScrapeFetcher()) {
        self.feed = feed
        self.scrape = scrape
    }

    func items(for source: SourceSnapshot) async throws -> [ParsedItem] {
        switch FetchRouter.route(source) {
        case .feed:
            return try await feed.items(for: source)
        case .scrape:
            return try await scrape.items(for: source)
        case .none(let reason):
            // The engine skips these before fetching, so arriving here means a
            // route changed underneath us. Fail loudly rather than return an
            // empty list, which would read on screen as a quiet news day.
            throw FeedError.parseFailed(reason)
        }
    }
}
