import Foundation
import Testing
import SwiftData
@testable import AINews

/// End-to-end: the bundled resource must be present in the app bundle and the
/// importer must turn it into the 30 expected rows. This is the test that
/// catches a resource that silently fails to be copied into the bundle.
@MainActor
@Suite("Source import")
struct SourceImporterTests {

    /// Owns the container for the lifetime of a test.
    ///
    /// A file-backed store in a temp directory is used rather than
    /// isStoredInMemoryOnly: the in-memory configuration traps inside SwiftData
    /// when the schema carries #Unique constraints, whereas this mirrors the
    /// exact configuration the app itself runs with. Holding the container is
    /// also deliberate, so it cannot be released out from under its context.
    @MainActor
    private final class ScratchStore {
        let container: ModelContainer
        let directory: URL

        init() throws {
            directory = URL.temporaryDirectory.appending(
                path: "AINewsTests-\(UUID().uuidString)", directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = Schema([Source.self, Headline.self])
            let configuration = ModelConfiguration(
                schema: schema,
                url: directory.appending(path: "test.store")
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        }

        var context: ModelContext { container.mainContext }
    }

    @MainActor
    private func withStore(_ body: @MainActor (ModelContext) throws -> Void) throws {
        let store = try ScratchStore()
        try body(store.context)
        withExtendedLifetime(store) {}
    }

    @Test("The bundled sources.json is present and decodes to 30 sources")
    func importsThirtySources() throws {
        try withStore { context in
            let outcome = try SourceImporter.load(into: context)
            #expect(outcome.skipped.isEmpty)
            #expect(outcome.inserted == 30)

            let sources = try context.fetch(
                FetchDescriptor<Source>(sortBy: [SortDescriptor(\Source.rank)])
            )
            #expect(sources.count == 30)
        }
    }

    @Test("Editorial ranking is preserved from the file order")
    func rankingIsPreserved() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let sources = try context.fetch(
                FetchDescriptor<Source>(sortBy: [SortDescriptor(\Source.rank)])
            )
            // Ranks are 1...30 with no gaps, and rank 1 is the AI-first top pick.
            #expect(sources.map(\.rank) == Array(1...30))
            #expect(sources.first?.id == "jiqizhixin")
            #expect(sources.last?.id == "zdnet_korea")
        }
    }

    @Test("Exactly 17 sources have a feed and 13 do not")
    func feedSplitMatchesThePlan() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let sources = try context.fetch(FetchDescriptor<Source>())
            #expect(sources.filter { $0.feedURL != nil }.count == 17)
            #expect(sources.filter { $0.feedURL == nil }.count == 13)
        }
    }

    @Test("The inactive flags match the editorial decision, exactly")
    func inactiveFlagsAreAsDecided() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let sources = try context.fetch(FetchDescriptor<Source>())

            // Twelve sources produce nothing - five with a dead feed, seven that
            // cannot be scraped - and are marked inactive so a run does not
            // spend a request on them. Asserted exactly rather than counted,
            // because a silent flip either way costs something real: a wasted
            // request, or a source that quietly stops being fetched.
            let inactive = Set(sources.filter { $0.isInactive }.map(\.id))
            let expected: Set<String> = [
                "jiqizhixin", "aiera", "leitech", "jiazi", "etnews", "bnext",
                "tnglobal", "inside_tw", "thenewslens", "nikkei_robotics",
                "nikkei_tech_foresight", "zdnet_korea",
            ]
            #expect(inactive == expected)
            #expect(sources.count == 30)
        }
    }

    @Test("Fetched sources start clean, and no selector is seeded")
    func activeDefaultsAreClean() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let sources = try context.fetch(FetchDescriptor<Source>())
            let active = sources.filter { !$0.isInactive }

            #expect(active.count == 18)
            #expect(active.allSatisfy { $0.headlineSelector == nil })
            #expect(active.allSatisfy { $0.consecutiveFailures == 0 })
            #expect(active.allSatisfy { $0.cooldownMinutes == 60 })
            #expect(active.allSatisfy { $0.lastNewCount == nil })
        }
    }

    @Test("Re-importing upserts and never clobbers fetch history")
    func reimportPreservesOperationalState() throws {
        try withStore { context in
            try SourceImporter.load(into: context)

            let sources = try context.fetch(FetchDescriptor<Source>())
            let target = try #require(sources.first { $0.id == "ithome" })
            target.consecutiveFailures = 4
            target.lastFetchedAt = Date(timeIntervalSince1970: 1_000_000)
            target.lastWarning = "unreachable (timed out)"
            try context.save()

            let second = try SourceImporter.load(into: context)
            #expect(second.inserted == 0)
            #expect(second.updated == 30)

            let reloaded = try context.fetch(FetchDescriptor<Source>())
            let again = try #require(reloaded.first { $0.id == "ithome" })
            #expect(again.consecutiveFailures == 4)
            #expect(again.lastWarning == "unreachable (timed out)")
            #expect(again.lastFetchedAt == Date(timeIntervalSince1970: 1_000_000))
        }
    }

    @Test("The plain-HTTP feed is present, which is what the ATS exception exists for")
    func plainHTTPFeedIsSeeded() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let sources = try context.fetch(FetchDescriptor<Source>())
            let leiphone = try #require(sources.first { $0.id == "leiphone" })
            #expect(leiphone.feedURL?.scheme == "http")
        }
    }

    @Test("Every source keeps a stable id, so renaming a display name never orphans headlines")
    func idsAreStable() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let sources = try context.fetch(
                FetchDescriptor<Source>(sortBy: [SortDescriptor(\Source.rank)])
            )
            // Ids are what Headline.sourceID references. If a rename ever
            // changes one, the importer treats the source as new, inserts a
            // duplicate, and deletes the original along with its headlines.
            // This test fails loudly instead.
            let expected = [
                "jiqizhixin",
                "qbitai",
                "aiera",
                "zhidongxi",
                "leitech",
                "leiphone",
                "jiazi",
                "digitimes",
                "etnews",
                "nikkei_xtech",
                "ithome",
                "aiwatch",
                "technews_tw",
                "bnext",
                "ifanr",
                "sspai",
                "technode",
                "tnglobal",
                "techorange",
                "inside_tw",
                "inc42",
                "thenewslens",
                "thebridge",
                "nikkei_asia",
                "toyokeizai",
                "yonhap",
                "digitaltoday",
                "nikkei_robotics",
                "nikkei_tech_foresight",
                "zdnet_korea",
            ]
            #expect(sources.map(\.id) == expected)
        }
    }

    // MARK: - Explicit ids

    /// Builds a minimal sources.json. Passing nil for the id omits the key,
    /// which is how the missing-id path gets exercised.
    private func fixture(_ entries: [(id: String?, name: String)]) throws -> Data {
        let objects: [[String: Any]] = entries.map { entry in
            var object: [String: Any] = [
                "name": entry.name,
                "url": "https://example.com",
                "feed_url": "https://example.com/feed",
                "status": "ready",
                "inactive": false,
                "note": "fixture",
            ]
            if let id = entry.id { object["source_id"] = id }
            return object
        }
        return try JSONSerialization.data(withJSONObject: objects)
    }

    @Test("Renaming a source keeps its id and every headline it owns")
    func renameKeepsIdentityAndHeadlines() throws {
        try withStore { context in
            let before = try fixture([("jiqizhixin", "机器之心 (Jiqizhixin)")])
            _ = try SourceImporter.load(from: before, into: context)

            let url = URL(string: "https://example.com/story")!
            context.insert(Headline(url: url, title: "A story", sourceID: "jiqizhixin",
                                   publishedAt: nil, fetchedAt: .now, lastSeenAt: .now))
            try context.save()

            // Same id, different display name - exactly what broke before ids
            // were explicit, when the id was derived from the name.
            let after = try fixture([("jiqizhixin", "Jiqizhixin (机器之心)")])
            let outcome = try SourceImporter.load(from: after, into: context)

            #expect(outcome.inserted == 0)   // not treated as a new source
            #expect(outcome.updated == 1)    // matched by id and updated
            #expect(outcome.removed == 0)    // so nothing was orphaned

            let sources = try context.fetch(FetchDescriptor<Source>())
            #expect(sources.count == 1)
            #expect(sources.first?.id == "jiqizhixin")
            #expect(sources.first?.name == "Jiqizhixin (机器之心)")

            // The whole point: the headline survived the rename.
            let headlines = try context.fetch(FetchDescriptor<Headline>())
            #expect(headlines.count == 1)
        }
    }

    @Test("A missing source_id is skipped, never guessed at")
    func missingSourceIDIsSkipped() throws {
        try withStore { context in
            let data = try fixture([(nil, "No Id Source"), ("ithome", "ITHome (IT之家)")])
            let outcome = try SourceImporter.load(from: data, into: context)

            #expect(outcome.inserted == 1)          // only the well-formed one
            #expect(outcome.skipped.count == 1)
            #expect(outcome.skipped.first?.contains("missing source_id") == true)

            let sources = try context.fetch(FetchDescriptor<Source>())
            #expect(sources.count == 1)
            #expect(sources.first?.id == "ithome")
        }
    }

    @Test("A blank source_id counts as missing")
    func blankSourceIDIsSkipped() throws {
        try withStore { context in
            let data = try fixture([("   ", "Whitespace Id")])
            let outcome = try SourceImporter.load(from: data, into: context)
            #expect(outcome.inserted == 0)
            #expect(outcome.skipped.count == 1)
        }
    }

    @Test("Two rows claiming one id do not fight over a single source")
    func duplicateSourceIDIsSkipped() throws {
        try withStore { context in
            let data = try fixture([("ithome", "ITHome (IT之家)"), ("ithome", "Somewhere Else")])
            let outcome = try SourceImporter.load(from: data, into: context)

            #expect(outcome.inserted == 1)
            #expect(outcome.skipped.count == 1)
            #expect(outcome.skipped.first?.contains("duplicate source_id") == true)

            let sources = try context.fetch(FetchDescriptor<Source>())
            #expect(sources.count == 1)
            #expect(sources.first?.name == "ITHome (IT之家)")
        }
    }

    @Test("A source the user skipped is not re-enabled by the next launch")
    func skipSurvivesReimport() throws {
        try withStore { context in
            try SourceImporter.load(into: context)

            let sources = try context.fetch(FetchDescriptor<Source>())
            let target = try #require(sources.first { $0.id == "yonhap" })
            target.isInactive = true
            target.deactivationReason = "manual: disabled by user"
            try context.save()

            // The app re-imports on every launch. isInactive used to be
            // reapplied from sources.json here, so the sidebar's skip
            // silently reverted at the next start.
            _ = try SourceImporter.load(into: context)

            let reloaded = try context.fetch(FetchDescriptor<Source>())
            let again = try #require(reloaded.first { $0.id == "yonhap" })
            #expect(again.isInactive)
            #expect(again.deactivationReason == "manual: disabled by user")
        }
    }

    @Test("Re-enabling a source also survives a re-import")
    func reenableSurvivesReimport() throws {
        try withStore { context in
            try SourceImporter.load(into: context)
            let id = "yonhap"
            let sources = try context.fetch(FetchDescriptor<Source>())
            let target = try #require(sources.first { $0.id == id })
            target.isInactive = true
            try context.save()

            target.isInactive = false
            target.deactivationReason = nil
            try context.save()

            _ = try SourceImporter.load(into: context)
            let reloaded = try context.fetch(FetchDescriptor<Source>())
            let again = try #require(reloaded.first { $0.id == id })
            #expect(again.isInactive == false)
        }
    }

    @Test("Adding a source to the file adds it without disturbing anything else")
    func addingASourceIsAdditive() throws {
        try withStore { context in
            _ = try SourceImporter.load(into: context)   // the shipped 30

            // A headline belonging to a source that already exists.
            let url = URL(string: "https://example.com/keep")!
            context.insert(Headline(url: url, title: "Keep me", sourceID: "ithome",
                                   publishedAt: nil, fetchedAt: .now, lastSeenAt: .now))
            try context.save()

            // The same file with one entry appended - the workflow for adding
            // an outlet later.
            let bundled = try Data(contentsOf: try #require(
                Bundle.main.url(forResource: "sources", withExtension: "json")
            ))
            guard var array = try JSONSerialization.jsonObject(with: bundled) as? [[String: Any]] else {
                Issue.record("sources.json is not an array of objects")
                return
            }
            array.append([
                "source_id": "newsource",
                "name": "New Source",
                "url": "https://example.com",
                "feed_url": "https://example.com/feed",
                "status": "ready",
                "inactive": false,
                "note": "added later",
            ])
            let modified = try JSONSerialization.data(withJSONObject: array)

            let outcome = try SourceImporter.load(from: modified, into: context)

            #expect(outcome.inserted == 1)    // the new one
            #expect(outcome.updated == 30)   // the rest, untouched
            #expect(outcome.removed == 0)    // nothing orphaned

            let sources = try context.fetch(FetchDescriptor<Source>())
            #expect(sources.count == 31)
            #expect(sources.contains { $0.id == "newsource" })

            // The pre-existing headline survived.
            #expect(try context.fetchCount(FetchDescriptor<Headline>()) == 1)
        }
    }
}