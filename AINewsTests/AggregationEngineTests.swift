import Foundation
import Testing
@testable import AINews

// MARK: - Doubles

/// Records what the engine asked to persist, so the failure policy can be
/// asserted without a database. An actor because the engine calls it from its
/// own isolation domain.
actor RecordingPersistence: AggregationPersisting {
    private(set) var newBySource: [String: Int] = [:]
    private(set) var successes: [String] = []
    /// What recordSuccess was told, so the sidebar's "N new" can be asserted.
    private(set) var reportedNewCounts: [String: Int] = [:]
    private(set) var warnings: [String: AggregationEngine.Warning] = [:]

    func upsert(items: [ParsedItem], sourceID: String, at date: Date) async throws -> Int {
        // Pretend everything is new on the first call for that source.
        let isFirst = newBySource[sourceID] == nil
        newBySource[sourceID] = items.count
        return isFirst ? items.count : 0
    }

    func recordSuccess(sourceID: String, newCount: Int, at date: Date) async {
        successes.append(sourceID)
        reportedNewCounts[sourceID] = newCount
    }

    func recordWarning(sourceID: String, warning: AggregationEngine.Warning, at date: Date) async {
        warnings[sourceID] = warning
    }

    func warning(for id: String) -> AggregationEngine.Warning? { warnings[id] }
    func didSucceed(_ id: String) -> Bool { successes.contains(id) }
}

/// Records which sources it was asked for. An inactive source must never appear
/// here: the engine has to refuse it before any strategy is chosen.
actor RecordingFetcher: SourceFetching {
    private(set) var requested: [String] = []
    private let payload: [ParsedItem]

    init(payload: [ParsedItem] = []) { self.payload = payload }

    func items(for source: SourceSnapshot) async throws -> [ParsedItem] {
        requested.append(source.id)
        return payload
    }
}

struct StubFetcher: SourceFetching {
    let outcomes: [String: Result<[ParsedItem], FeedError>]

    func items(for source: SourceSnapshot) async throws -> [ParsedItem] {
        switch outcomes[source.id] {
        case .success(let items): return items
        case .failure(let error): throw error
        case nil: return []
        }
    }
}

// MARK: - Helpers

private func source(
    _ id: String,
    rank: Int = 1,
    feed: String? = "https://example.com/feed",
    selector: String? = nil,
    inactive: Bool = false,
    cooldown: Int = 60,
    lastAttemptedAt: Date? = nil,
    url: String = "https://example.com"
) -> SourceSnapshot {
    SourceSnapshot(
        id: id,
        name: id,
        url: URL(string: url)!,
        feedURL: feed.flatMap(URL.init(string:)),
        rank: rank,
        cooldownMinutes: cooldown,
        isInactive: inactive,
        headlineSelector: selector,
        lastAttemptedAt: lastAttemptedAt,
        lastFetchedAt: nil
    )
}

private let sampleItem = ParsedItem(
    title: "Headline",
    url: URL(string: "https://example.com/a")!,
    publishedAt: nil
)

@Suite("Aggregation engine")
struct AggregationEngineTests {

    /// 1ms jitter so tests do not sleep for real.
    private func engine(_ fetcher: any SourceFetching, _ persistence: RecordingPersistence) -> AggregationEngine {
        AggregationEngine(fetcher: fetcher, persistence: persistence, jitter: 1...1)
    }

    @Test("A successful source is fetched, stored, and recorded as a success")
    func successPath() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .success([sampleItem])])
        await engine(fetcher, persistence).run([source("a")]) { _ in }

        #expect(await persistence.didSucceed("a"))
        #expect(await persistence.newBySource["a"] == 1)
    }

    @Test("A failing source is warned about and the run continues to the next source")
    func warningDoesNotStopTheRun() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: [
            "a": .failure(.http(500)),
            "b": .success([sampleItem]),
        ])
        await engine(fetcher, persistence).run([source("a", rank: 1), source("b", rank: 2)]) { _ in }

        // The whole point: one bad source must never block the rest.
        #expect(await persistence.warning(for: "a") == .serverError(500))
        #expect(await persistence.didSucceed("b"))
    }

    @Test("The engine never deactivates: no failure path writes an inactive state")
    func engineNeverDeactivates() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .failure(.http(403))])
        // Source is active going in.
        await engine(fetcher, persistence).run([source("a")]) { _ in }

        #expect(await persistence.warning(for: "a") == .blocked(403))
        // RecordingPersistence has no way to deactivate at all: the engine has
        // no API for it, which is the property under test.
        #expect(await persistence.successes.isEmpty)
    }

    @Test("A homepage that cannot be requested warns instead of failing silently")
    func unroutableSourceWarns() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: [:])
        // The only unroutable shape left now that a missing selector is no
        // longer disqualifying. This test used to assert the opposite, that a
        // feed-less source warns "no feed and no selector" - which is exactly
        // what the app did wrong, so the suite defended the bug.
        await engine(fetcher, persistence).run(
            [source("a", feed: nil, url: "ftp://example.com/feed")]
        ) { _ in }
        #expect(await persistence.warning(for: "a") == .noSource("homepage URL is not http(s)"))
    }

    @Test("A selector-only source is fetched through the scrape route")
    func scrapeRouteIsFetched() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .success([sampleItem])])
        await engine(fetcher, persistence).run([source("a", feed: nil, selector: "h2 a")]) { _ in }

        // Used to be skipped as not implemented; now it must actually fetch.
        #expect(await persistence.didSucceed("a"))
        #expect(await persistence.warning(for: "a") == nil)
    }

    @Test("A source with no feed and no selector is fetched, not skipped")
    func feedlessWithoutSelectorIsFetched() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .success([sampleItem])])
        await engine(fetcher, persistence).run([source("a", feed: nil, selector: nil)]) { _ in }

        // The exact shape the app failed on: six feed-less sources came back
        // as "no feed and no selector" and were never read, because routing
        // demanded a selector the scrape strategy does not use.
        #expect(await persistence.didSucceed("a"))
        #expect(await persistence.warning(for: "a") == nil)
    }

    @Test("An inactive source is never fetched, whatever route it has")
    func inactiveIsNeverFetched() async {
        let persistence = RecordingPersistence()
        let fetcher = RecordingFetcher(payload: [sampleItem])

        // Both would otherwise be fetched: one has a feed, one routes to
        // scraping. Inactive has to win before a strategy is even chosen -
        // this is the flag that keeps us off sources that asked us to stop.
        let parked = [
            source("feed_inactive", feed: "https://example.com/feed", inactive: true),
            source("scrape_inactive", feed: nil, selector: "h2 a", inactive: true),
        ]
        await engine(fetcher, persistence).run(parked) { _ in }

        #expect(await fetcher.requested.isEmpty)
        #expect(await persistence.successes.isEmpty)
        #expect(await persistence.warnings.isEmpty)
    }

    @Test("Routing warnings do not count as fetch attempts, so they start no cooldown")
    func routingWarningsAreNotAttempts() {
        #expect(AggregationEngine.Warning.noSource("x").wasAttempt == false)
        #expect(AggregationEngine.Warning.blocked(403).wasAttempt == true)
        #expect(AggregationEngine.Warning.emptyFeed.wasAttempt == true)
    }

    @Test("An empty feed is warned about rather than treated as success")
    func emptyFeedWarns() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .failure(.emptyFeed)])
        await engine(fetcher, persistence).run([source("a")]) { _ in }
        #expect(await persistence.warning(for: "a") == .emptyFeed)
    }

    @Test("An inactive source is skipped without any network work")
    func inactiveIsSkipped() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .success([sampleItem])])
        await engine(fetcher, persistence).run([source("a", inactive: true)]) { _ in }

        #expect(await persistence.successes.isEmpty)
        #expect(await persistence.warnings.isEmpty)
    }

    // MARK: - Cooldown

    @Test("Cooldown is measured from the last attempt, not the last success")
    func cooldownUsesAttemptTime() {
        let justNow = Date()
        let cooling = source("a", lastAttemptedAt: justNow)
        let remaining = AggregationEngine.cooldownRemaining(for: cooling, now: justNow)
        #expect(remaining != nil)
        #expect(remaining! > 3500)   // ~60 minutes
    }

    @Test("A source outside its window has no cooldown left")
    func cooldownExpires() {
        let longAgo = Date().addingTimeInterval(-7200)
        #expect(AggregationEngine.cooldownRemaining(for: source("a", lastAttemptedAt: longAgo)) == nil)
    }

    @Test("A never-attempted source is not in cooldown")
    func neverAttemptedIsNotCooling() {
        #expect(AggregationEngine.cooldownRemaining(for: source("a")) == nil)
    }

    @Test("A source inside its cooldown is skipped without fetching")
    func cooldownSkipsTheFetch() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .success([sampleItem])])
        let cooling = source("a", lastAttemptedAt: Date())
        await engine(fetcher, persistence).run([cooling]) { _ in }

        #expect(await persistence.successes.isEmpty)
        #expect(await persistence.newBySource.isEmpty)
    }

    // MARK: - Error mapping

    @Test("HTTP statuses map onto the documented warning cases")
    func errorMapping() {
        #expect(AggregationEngine.warning(from: FeedError.http(403)) == .blocked(403))
        #expect(AggregationEngine.warning(from: FeedError.http(429)) == .blocked(429))
        #expect(AggregationEngine.warning(from: FeedError.http(503)) == .serverError(503))
        #expect(AggregationEngine.warning(from: FeedError.emptyFeed) == .emptyFeed)
        #expect(AggregationEngine.warning(from: FeedError.timedOut) == .unreachable("timed out"))
        // A 404 is not a block and not a server error: report the code plainly.
        if case .unreachable(let detail) = AggregationEngine.warning(from: FeedError.http(404)) {
            #expect(detail.contains("404"))
        } else {
            Issue.record("expected .unreachable for 404")
        }
    }

    @Test("A successful fetch reports how many headlines were new")
    func reportsNewCount() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: ["a": .success([sampleItem])])
        await engine(fetcher, persistence).run([source("a")]) { _ in }

        // The sidebar's 'ok - N new' label reads this, so it has to arrive.
        #expect(await persistence.reportedNewCounts["a"] == 1)
    }
}