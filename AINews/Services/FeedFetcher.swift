import Foundation

/// The only SourceFetching conformer in v1.
///
/// It owns the whole feed path: route check, HTTP, parse, and the conversion of
/// an empty parse into an error. The engine stays ignorant of all of it.
struct FeedFetcher: SourceFetching {
    let client: HTTPClient
    let parser: FeedParser

    init(client: HTTPClient = HTTPClient(), parser: FeedParser = FeedParser()) {
        self.client = client
        self.parser = parser
    }

    func items(for source: SourceSnapshot) async throws -> [ParsedItem] {
        guard case .feed(let url) = FetchRouter.route(source) else {
            throw FeedError.parseFailed("source is not routed to a feed")
        }

        let data = try await client.get(url)

        // Cancellation must win over a parse: a stopped run should not persist
        // results it fetched a moment before the user pressed Stop.
        try Task.checkCancellation()

        let items = try parser.items(from: data, feedURL: url)

        // A feed that parses cleanly but yields nothing is almost always a
        // format change or a paywall interstitial, not an empty news day.
        guard !items.isEmpty else { throw FeedError.emptyFeed }
        return items
    }
}
