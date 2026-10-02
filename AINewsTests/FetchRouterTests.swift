import Foundation
import Testing
@testable import AINews

@Suite("Fetch routing")
struct FetchRouterTests {

    private func snapshot(
        feed: String? = nil,
        selector: String? = nil
    ) -> SourceSnapshot {
        SourceSnapshot(
            id: "x",
            name: "X",
            url: URL(string: "https://example.com")!,
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

    @Test("A selector alone routes to scrape, which is not implemented")
    func selectorRoutesToScrape() {
        let route = FetchRouter.route(snapshot(selector: "article h2 a"))
        #expect(route == .scrape(homepage: URL(string: "https://example.com")!, selector: "article h2 a"))
    }

    @Test("Neither feed nor selector routes to none with a reason")
    func neitherRoutesToNone() {
        let route = FetchRouter.route(snapshot())
        if case .none(let reason) = route {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("expected .none, got \(route)")
        }
    }

    @Test("A whitespace-only selector counts as absent, not as a scrape target")
    func blankSelectorIsNotAScrapeTarget() {
        let route = FetchRouter.route(snapshot(selector: "   "))
        if case .none = route {} else {
            Issue.record("expected .none, got \(route)")
        }
    }
}
