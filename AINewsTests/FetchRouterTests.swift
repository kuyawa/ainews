import Foundation
import Testing
@testable import AINews

@Suite("Fetch routing")
struct FetchRouterTests {

    private func snapshot(
        feed: String? = nil,
        selector: String? = nil,
        url: String = "https://example.com"
    ) -> SourceSnapshot {
        SourceSnapshot(
            id: "x",
            name: "X",
            url: URL(string: url)!,
            feedURL: feed.flatMap(URL.init(string:)),
            rank: 1,
            cooldownMinutes: 60,
            isInactive: false,
            headlineSelector: selector,
            lastAttemptedAt: nil,
            lastFetchedAt: nil
        )
    }

    @Test("A feed URL routes to the feed strategy")
    func feedRoutes() {
        let route = FetchRouter.route(snapshot(feed: "https://example.com/feed"))
        #expect(route == .feed(URL(string: "https://example.com/feed")!))
    }

    @Test("A feed wins when a selector is also present")
    func feedBeatsSelector() {
        let route = FetchRouter.route(
            snapshot(feed: "https://example.com/feed", selector: "article h2 a")
        )
        if case .feed = route {} else {
            Issue.record("expected .feed, got \(route)")
        }
    }

    @Test("A selector alone routes to scrape")
    func selectorRoutesToScrape() {
        let route = FetchRouter.route(snapshot(selector: "article h2 a"))
        #expect(route == .scrape(homepage: URL(string: "https://example.com")!, selector: "article h2 a"))
    }

    @Test("No feed routes to scrape even with no selector at all")
    func feedlessWithoutSelectorStillScrapes() {
        // The scrape strategy needs no selector. Requiring one here silently
        // disabled every feed-less source while the tests stayed green.
        let route = FetchRouter.route(snapshot())
        #expect(route == .scrape(homepage: URL(string: "https://example.com")!, selector: ""))
    }

    @Test("A whitespace-only selector still scrapes, normalised to empty")
    func blankSelectorStillScrapes() {
        let route = FetchRouter.route(snapshot(selector: "   "))
        #expect(route == .scrape(homepage: URL(string: "https://example.com")!, selector: ""))
    }

    @Test("A homepage that is not http(s) is the one unroutable case")
    func nonHTTPSourceHasNoRoute() {
        let route = FetchRouter.route(snapshot(url: "ftp://example.com/feed"))
        if case .none(let reason) = route {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("expected .none, got \(route)")
        }
    }
}
