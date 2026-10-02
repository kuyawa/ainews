import Foundation
import SwiftData
import OSLog

/// Imports the bundled sources.json into SwiftData.
///
/// The JSON is authoritative for editorial fields. Re-importing is safe and
/// non-destructive: it updates editorial fields and leaves every operational
/// field (counters, timestamps, warnings) exactly as the app left them, so a
/// reload never erases what the app has learned.
@MainActor
enum SourceImporter {

    private static let log = Logger(subsystem: "net.kuyawa.ainews", category: "import")

    /// Mirrors sources.json.
    ///
    /// CodingKeys are explicit rather than relying on convertFromSnakeCase:
    /// that strategy maps feed_url to feedUrl, which does NOT match a property
    /// named feedURL, and every source silently decoded with a nil feed.
    private struct Seed: Decodable {
        let sourceID: String?
        let name: String
        let url: String
        let feedURL: String?
        let status: String
        let inactive: Bool
        let note: String

        enum CodingKeys: String, CodingKey {
            case name, url, status, inactive, note
            case sourceID = "source_id"
            case feedURL = "feed_url"
        }
    }

    struct Outcome: Sendable, Equatable {
        var inserted = 0
        var updated = 0
        var removed = 0
        var skipped: [String] = []
        var total: Int { inserted + updated }
    }

    enum ImportError: Error, LocalizedError {
        case missingResource

        var errorDescription: String? {
            "sources.json is missing from the app bundle"
        }
    }

    private static func bundledData() throws -> Data {
        guard let url = Bundle.main.url(forResource: "sources", withExtension: "json") else {
            throw ImportError.missingResource
        }
        return try Data(contentsOf: url)
    }

    @discardableResult
    static func load(into context: ModelContext) throws -> Outcome {
        try load(from: try bundledData(), into: context)
    }

    /// The real work, with the JSON injected so it can be tested against
    /// deliberately awkward input - a missing id, a duplicate, a renamed
    /// source - without shipping broken data in the bundle.
    @discardableResult
    static func load(from data: Data, into context: ModelContext) throws -> Outcome {
        let seeds = try JSONDecoder().decode([Seed].self, from: data)

        let existing = try context.fetch(FetchDescriptor<Source>())
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var outcome = Outcome()
        var seen = Set<String>()

        // The order in the file is the editorial AI-first ranking and is
        // preserved as rank. Never re-sort it.
        for (index, seed) in seeds.enumerated() {
            let rank = index + 1

            // The id is the identity, and it must be explicit. Deriving it from
            // the display name is what made renaming destructive, so a missing
            // id is skipped and reported rather than guessed at: a guess can
            // collide with nothing, insert a duplicate, and orphan the original
            // along with every headline it owned.
            guard let rawID = seed.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawID.isEmpty else {
                outcome.skipped.append("\(seed.name): missing source_id")
                log.warning("skip \(seed.name, privacy: .public): missing source_id")
                continue
            }

            // Two rows claiming one id would fight over a single row, and the
            // loser would look like a source that vanished.
            guard seen.insert(rawID).inserted else {
                outcome.skipped.append("\(seed.name): duplicate source_id '\(rawID)'")
                log.warning("skip \(seed.name, privacy: .public): duplicate source_id")
                continue
            }

            guard let homepage = URL(string: seed.url) else {
                outcome.skipped.append("\(seed.name): invalid url")
                log.warning("skip \(seed.name, privacy: .public): invalid url")
                continue
            }

            var feed: URL?
            if let rawFeed = seed.feedURL {
                guard let parsed = URL(string: rawFeed) else {
                    outcome.skipped.append("\(seed.name): invalid feed_url")
                    log.warning("skip feed for \(seed.name, privacy: .public): invalid feed_url")
                    continue
                }
                feed = parsed
            }

            if let row = byID[rawID] {
                // Editorial fields only. Operational fields are untouched, and
                // because the lookup is by id, a renamed source updates in
                // place instead of being replaced.
                //
                // isInactive is deliberately NOT set here. It is the one
                // editorial field the user also owns: the sidebar's Disable
                // writes it, and re-applying the JSON on every launch meant the
                // toggle silently reverted at the next start. The JSON seeds it
                // on insert; after that the app is authoritative, which is what
                // makes "skip this source for now" actually stick.
                row.name = seed.name
                row.url = homepage
                row.feedURL = feed
                row.status = seed.status
                row.note = seed.note
                row.rank = rank
                byID.removeValue(forKey: rawID)
                outcome.updated += 1
            } else {
                context.insert(
                    Source(
                        id: rawID,
                        name: seed.name,
                        url: homepage,
                        feedURL: feed,
                        status: seed.status,
                        isInactive: seed.inactive,
                        note: seed.note,
                        rank: rank
                    )
                )
                outcome.inserted += 1
            }
        }

        // Whatever is left was dropped from the JSON. The file is authoritative
        // and Reload Sources is an explicit user action, so orphans go, along
        // with their headlines, which would otherwise be unreachable in the UI.
        for (id, row) in byID {
            let descriptor = FetchDescriptor<Headline>(
                predicate: #Predicate<Headline> { $0.sourceID == id }
            )
            for orphan in try context.fetch(descriptor) { context.delete(orphan) }
            context.delete(row)
            outcome.removed += 1
            log.info("removed source absent from sources.json: \(id, privacy: .public)")
        }

        try context.save()
        log.info("import +\(outcome.inserted) ~\(outcome.updated) -\(outcome.removed)")
        return outcome
    }
}
