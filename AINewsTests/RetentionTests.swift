import Foundation
import Testing
import SwiftData
@testable import AINews

/// Retention is what stops the store growing without bound. Feeds limit only
/// what is added per run, never what accumulates, so without this the file and
/// the in-memory fetch grow forever.
@MainActor
@Suite("Retention")
struct RetentionTests {

    @MainActor
    private final class ScratchStore {
        let container: ModelContainer
        init() throws {
            let directory = URL.temporaryDirectory.appending(
                path: "AINewsRetention-\(UUID().uuidString)", directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = Schema([Source.self, Headline.self])
            let configuration = ModelConfiguration(
                schema: schema, url: directory.appending(path: "test.store")
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
        var context: ModelContext { container.mainContext }
    }

    private func insert(_ count: Int, sourceID: String, into context: ModelContext, newestFirst: Bool = false) throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            context.insert(
                Headline(
                    url: URL(string: "https://example.com/\(sourceID)/\(index)")!,
                    title: "Story \(index)",
                    sourceID: sourceID,
                    publishedAt: base.addingTimeInterval(Double(index) * 60),
                    fetchedAt: base,
                    lastSeenAt: base
                )
            )
        }
        try context.save()
    }

    private func count(_ sourceID: String, in context: ModelContext) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<Headline>(predicate: #Predicate<Headline> { $0.sourceID == sourceID })
        )
    }

    @Test("The oldest headlines are pruned once a source exceeds the retained limit")
    func prunesOldest() async throws {
        let store = try ScratchStore()
        let context = store.context
        let persistence = SwiftDataPersistence(context: context)
        let id = "ithome"

        try insert(250, sourceID: id, into: context)

        // A fetch that adds one more is what triggers the prune.
        let newest = ParsedItem(
            title: "Newest",
            url: URL(string: "https://example.com/\(id)/newest")!,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + 400 * 60)
        )
        _ = try await persistence.upsert(items: [newest], sourceID: id, at: .now)

        let kept = try context.fetch(
            FetchDescriptor<Headline>(predicate: #Predicate<Headline> { $0.sourceID == id })
        )
        #expect(kept.count == 200)
        #expect(kept.contains { $0.title == "Newest" })      // newest survived
        #expect(!kept.contains { $0.title == "Story 0" })    // oldest went
    }

    @Test("A source under the limit is left alone")
    func doesNotPruneBelowLimit() async throws {
        let store = try ScratchStore()
        let context = store.context
        let persistence = SwiftDataPersistence(context: context)
        let id = "sspai"

        try insert(20, sourceID: id, into: context)
        let item = ParsedItem(
            title: "Another",
            url: URL(string: "https://example.com/\(id)/another")!,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + 900 * 60)
        )
        _ = try await persistence.upsert(items: [item], sourceID: id, at: .now)

        #expect(try count(id, in: context) == 21)
    }

    @Test("Pruning one source never touches another")
    func pruneIsPerSource() async throws {
        let store = try ScratchStore()
        let context = store.context
        let persistence = SwiftDataPersistence(context: context)

        try insert(250, sourceID: "yonhap", into: context)
        try insert(30, sourceID: "sspai", into: context)

        let item = ParsedItem(
            title: "Trigger",
            url: URL(string: "https://example.com/yonhap/trigger")!,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + 800 * 60)
        )
        _ = try await persistence.upsert(items: [item], sourceID: "yonhap", at: .now)

        #expect(try count("yonhap", in: context) == 200)
        #expect(try count("sspai", in: context) == 30)   // untouched
    }

    @Test("Ordering falls back to first-seen for feeds with no dates")
    func orderingFallsBackToFetchedAt() {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let published = Date(timeIntervalSince1970: 1_600_000_000)

        let dated = Headline(url: URL(string: "https://example.com/a")!, title: "a",
                             sourceID: "x", publishedAt: published,
                             fetchedAt: fetched, lastSeenAt: fetched)
        let undated = Headline(url: URL(string: "https://example.com/b")!, title: "b",
                               sourceID: "x", publishedAt: nil,
                               fetchedAt: fetched, lastSeenAt: fetched)

        #expect(dated.orderingDate == published)   // the feed's own date wins
        #expect(undated.orderingDate == fetched)   // no date: first-seen
    }
}
