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
    lastAttemptedAt: Date? = nil
) -> SourceSnapshot {
    SourceSnapshot(
        id: id,
        name: id,
        url: URL(string: "https://example.com")!,
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
    private func engine(_ fetcher: StubFetcher, _ persistence: RecordingPersistence) -> AggregationEngine {
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

    @Test("A source with no feed and no selector warns instead of failing silently")
    func noSourceWarns() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: [:])
        await engine(fetcher, persistence).run([source("a", feed: nil)]) { _ in }
        #expect(await persistence.warning(for: "a") == .noSource("no feed and no selector"))
    }

    @Test("A selector-only source reports scraping as not implemented, not as an error")
    func scrapeRouteReportsNotImplemented() async {
        let persistence = RecordingPersistence()
        let fetcher = StubFetcher(outcomes: [:])
        await engine(fetcher, persistence).run([source("a", feed: nil, selector: "h2 a")]) { _ in }

        guard case .notImplemented = await persistence.warning(for: "a") else {
            Issue.record("expected .notImplemented")
            return
        }
    }

    @Test("Routing warnings do not count as fetch attempts, so they start no cooldown")
    func routingWarningsAreNotAttempts() {
        #expect(AggregationEngine.Warning.noSource("x").wasAttempt == false)
        #expect(AggregationEngine.Warning.notImplemented("x").wasAttempt == false)
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