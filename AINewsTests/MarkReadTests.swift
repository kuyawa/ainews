import Foundation
import Testing
import SwiftData
@testable import AINews

/// Marking read is destructive in the sense that it is tedious to undo by
/// hand, and the button sits next to a list the reader has narrowed on
/// purpose. So the scope has to be exactly right in both directions.
@MainActor
@Suite("Marking as read")
struct MarkReadTests {

    @MainActor
    private final class ScratchStore {
        let container: ModelContainer
        init() throws {
            let directory = URL.temporaryDirectory.appending(
                path: "AINewsMarkRead-\(UUID().uuidString)", directoryHint: .isDirectory
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

    private func insert(_ sourceID: String, _ count: Int, into context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            context.insert(
                Headline(
                    url: URL(string: "https://example.com/\(sourceID)/\(index)")!,
                    title: "\(sourceID) story \(index)",
                    sourceID: sourceID,
                    publishedAt: base,
                    fetchedAt: base,
                    lastSeenAt: base
                )
            )
        }
        try? context.save()
    }

    private func unreadCount(_ context: ModelContext, sourceID: String? = nil) throws -> Int {
        let all = try context.fetch(FetchDescriptor<Headline>())
        return all.filter { !$0.isRead && (sourceID == nil || $0.sourceID == sourceID) }.count
    }

    @Test("With a source selected, only that source is marked read")
    func scopedToSelection() throws {
        let scratch = try ScratchStore()
        insert("yonhap", 5, into: scratch.context)
        insert("ithome", 7, into: scratch.context)
        let store = AggregatorStore(context: scratch.context)

        store.markAllRead(sourceID: "yonhap")

        #expect(try unreadCount(scratch.context, sourceID: "yonhap") == 0)
        // The other source must be untouched - this is the whole point.
        #expect(try unreadCount(scratch.context, sourceID: "ithome") == 7)
    }

    @Test("With nothing selected, everything is marked read")
    func globalWhenUnscoped() throws {
        let scratch = try ScratchStore()
        insert("yonhap", 5, into: scratch.context)
        insert("ithome", 7, into: scratch.context)
        let store = AggregatorStore(context: scratch.context)

        store.markAllRead()

        #expect(try unreadCount(scratch.context) == 0)
    }

    @Test("An empty selection string is not a wildcard")
    func emptyStringScopesToNothing() throws {
        let scratch = try ScratchStore()
        insert("yonhap", 3, into: scratch.context)
        let store = AggregatorStore(context: scratch.context)

        store.markAllRead(sourceID: "nonexistent")

        #expect(try unreadCount(scratch.context) == 3)
    }
}
