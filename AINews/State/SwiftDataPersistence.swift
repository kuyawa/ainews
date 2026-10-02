import Foundation
import SwiftData
import OSLog

/// The SwiftData side of AggregationPersisting.
///
/// MainActor-isolated because ModelContext is not Sendable. The engine awaits
/// these from its own actor, so each call hops to the main actor and back.
@MainActor
final class SwiftDataPersistence: AggregationPersisting {

    private let context: ModelContext
    private let log = Logger(subsystem: "net.kuyawa.ainews", category: "store")

    init(context: ModelContext) {
        self.context = context
    }

    private func source(id: String) throws -> Source? {
        var descriptor = FetchDescriptor<Source>(predicate: #Predicate<Source> { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func upsert(items: [ParsedItem], sourceID: String, at date: Date) async throws -> Int {
        // Match against this source's existing headlines by URL. The comparison
        // is done in memory rather than in a predicate because SwiftData
        // predicates on URL are unreliable; sourceID is a String, which is safe.
        let descriptor = FetchDescriptor<Headline>(
            predicate: #Predicate<Headline> { $0.sourceID == sourceID }
        )
        var known = Dictionary(
            try context.fetch(descriptor).map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var newCount = 0
        for item in items {
            if let existing = known[item.url] {
                existing.lastSeenAt = date
                // Publishers fix typos in headlines after publishing.
                if existing.title != item.title { existing.title = item.title }
                if existing.publishedAt == nil { existing.publishedAt = item.publishedAt }
            } else {
                let headline = Headline(
                    url: item.url,
                    title: item.title,
                    sourceID: sourceID,
                    publishedAt: item.publishedAt,
                    fetchedAt: date,
                    lastSeenAt: date
                )
                context.insert(headline)
                known[item.url] = headline
                newCount += 1
            }
        }

        if newCount > 0 {
            try prune(sourceID: sourceID)
            try context.save()
        }
        return newCount
    }

    /// Keeps only the newest headlines for a source.
    ///
    /// Without this the store grows without bound - the feeds only limit what
    /// is *added* per run, never what accumulates - and every launch would load
    /// the whole archive into memory to draw a list nobody scrolls to the end
    /// of. The retained count is deliberately above the number the list shows,
    /// so a headline that scrolls out of a feed's window is still remembered as
    /// seen rather than re-added and re-translated later.
    private func prune(sourceID: String) throws {
        let limit = Self.retainedPerSource
        guard limit > 0 else { return }

        let descriptor = FetchDescriptor<Headline>(
            predicate: #Predicate<Headline> { $0.sourceID == sourceID }
        )
        let all = try context.fetch(descriptor)
        guard all.count > limit else { return }

        let newestFirst = all.sorted { $0.orderingDate > $1.orderingDate }
        for stale in newestFirst.dropFirst(limit) {
            context.delete(stale)
        }
        log.info("pruned \(all.count - limit) old headlines for \(sourceID, privacy: .public)")
    }

    /// How many headlines to keep per source. Read from UserDefaults rather
    /// than @AppStorage because this type is not a View.
    static var retainedPerSource: Int {
        let stored = UserDefaults.standard.integer(forKey: "retainedPerSource")
        return stored > 0 ? stored : 200
    }

    func recordSuccess(sourceID: String, at date: Date) async {
        do {
            guard let row = try source(id: sourceID) else { return }
            row.consecutiveFailures = 0
            row.lastFetchedAt = date
            row.lastAttemptedAt = date
            row.lastWarning = nil
            row.lastWarningAt = nil
            try context.save()
        } catch {
            log.error("recordSuccess failed for \(sourceID, privacy: .public): \(error)")
        }
    }

    /// Records a non-fatal problem.
    ///
    /// Note what this deliberately does NOT do: it never writes isInactive.
    /// The only writer of that flag in v1 is the user.
    func recordWarning(sourceID: String, warning: AggregationEngine.Warning, at date: Date) async {
        do {
            guard let row = try source(id: sourceID) else { return }
            row.lastWarning = warning.text
            row.lastWarningAt = date
            if warning.countsAsFailure {
                row.consecutiveFailures += 1
            }
            // Only a real network attempt starts the cooldown clock.
            if warning.wasAttempt {
                row.lastAttemptedAt = date
            }
            try context.save()
        } catch {
            log.error("recordWarning failed for \(sourceID, privacy: .public): \(error)")
        }
    }
}
