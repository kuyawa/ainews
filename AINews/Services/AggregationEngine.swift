import Foundation
import OSLog

/// Where the engine's decisions are written down.
///
/// The engine must not know about SwiftData: ModelContext is not Sendable, and
/// a run happens off the main actor. This protocol is the seam. It also lets
/// the engine be tested with an in-memory recorder and no database at all.
protocol AggregationPersisting: Sendable {
    /// Stores new headlines and returns how many were genuinely new.
    func upsert(items: [ParsedItem], sourceID: String, at date: Date) async throws -> Int
    func recordSuccess(sourceID: String, newCount: Int, at date: Date) async
    func recordWarning(sourceID: String, warning: AggregationEngine.Warning, at date: Date) async
}

/// The run loop. Knows about routing, pacing, cooldowns and the failure policy.
/// Knows nothing about SwiftUI, SwiftData, RSS, or HTML.
actor AggregationEngine {

    // MARK: - Vocabulary

    enum SkipReason: Sendable, Equatable {
        case inactive
        case cooldown(remaining: TimeInterval)

        var text: String {
            switch self {
            case .inactive: return "inactive"
            case .cooldown(let remaining): return "cooldown (\(Int(remaining))s left)"
            }
        }
    }

    /// A problem that does not stop the run.
    ///
    /// v1 warns and moves on. It never deactivates a source: while HTML
    /// scraping does not exist, an unreadable source is unsupported, not dead,
    /// and marking it inactive would be a premature judgement about a source
    /// that may work perfectly once scraping lands.
    enum Warning: Sendable, Equatable {
        case noSource(String)
        case blocked(Int)
        case serverError(Int)
        case unreachable(String)
        case emptyFeed
        case notImplemented(String)

        var text: String {
            switch self {
            case .noSource(let reason): return "no source (\(reason))"
            case .blocked(let code): return "blocked (HTTP \(code))"
            case .serverError(let code): return "server error (HTTP \(code))"
            case .unreachable(let detail): return "unreachable (\(detail))"
            case .emptyFeed: return "empty feed (format change?)"
            case .notImplemented(let detail): return "not implemented (\(detail))"
            }
        }

        /// True when the app actually tried to reach the network. Routing
        /// warnings are not attempts and must not start a cooldown.
        var wasAttempt: Bool {
            switch self {
            case .noSource, .notImplemented: return false
            default: return true
            }
        }

        /// True when this represents the source failing rather than simply
        /// being unsupported. Only real failures move the counter.
        var countsAsFailure: Bool { wasAttempt }
    }

    enum Event: Sendable {
        case willFetch(sourceID: String, index: Int, total: Int)
        case fetched(sourceID: String, newCount: Int, totalInFeed: Int)
        case skipped(sourceID: String, reason: SkipReason)
        case warned(sourceID: String, warning: Warning)
        /// Emitted before the politeness pause so the UI can show a real
        /// countdown rather than guessing at one.
        case pausing(seconds: Double)
        case finished(Summary)
    }

    struct Summary: Sendable, Equatable {
        var checked = 0
        var skipped = 0
        var failed = 0
        var newHeadlines = 0

        var text: String {
            "\(checked) checked · \(skipped) skipped · \(failed) failed · \(newHeadlines) new"
        }
    }

    // MARK: - Dependencies

    private let fetcher: any SourceFetching
    private let persistence: any AggregationPersisting
    private let jitter: ClosedRange<Int>
    private let log = Logger(subsystem: "net.kuyawa.ainews", category: "engine")

    /// - Parameter jitter: politeness pause between sources, in milliseconds.
    init(
        fetcher: any SourceFetching,
        persistence: any AggregationPersisting,
        jitter: ClosedRange<Int> = 5_000...10_000
    ) {
        self.fetcher = fetcher
        self.persistence = persistence
        self.jitter = jitter
    }

    // MARK: - Run

    func run(
        _ sources: [SourceSnapshot],
        emit: @Sendable (Event) async -> Void
    ) async {
        var summary = Summary()
        let total = sources.count

        for (offset, source) in sources.enumerated() {
            if Task.isCancelled { break }

            summary.checked += 1
            await emit(.willFetch(sourceID: source.id, index: offset + 1, total: total))

            // 1. Parked by the user, or by a sources.json edit.
            if source.isInactive {
                summary.skipped += 1
                await emit(.skipped(sourceID: source.id, reason: .inactive))
                continue
            }

            // 2. Which strategy can read this source at all?
            switch FetchRouter.route(source) {
            case .none(let reason):
                summary.skipped += 1
                await warn(.noSource(reason), for: source, emit: emit)
                continue

            case .scrape:
                // Routed but unimplemented. Reported loudly rather than hidden,
                // so the feed-less sources are visibly unsupported instead of
                // looking like failures.
                summary.skipped += 1
                await warn(
                    .notImplemented("HTML scraping is not implemented yet"),
                    for: source,
                    emit: emit
                )
                continue

            case .feed:
                break
            }

            // 3. Cooldown, against the last ATTEMPT and before any network work.
            //    Keyed on attempts, not successes, or a source that fails every
            //    single time would be hammered on every run.
            if let remaining = Self.cooldownRemaining(for: source) {
                summary.skipped += 1
                await emit(.skipped(sourceID: source.id, reason: .cooldown(remaining: remaining)))
                continue
            }

            // 4. Fetch, store, and record the outcome.
            do {
                let items = try await fetcher.items(for: source)
                let newCount = try await persistence.upsert(
                    items: items, sourceID: source.id, at: .now
                )
                await persistence.recordSuccess(sourceID: source.id, newCount: newCount, at: .now)
                summary.newHeadlines += newCount
                await emit(
                    .fetched(sourceID: source.id, newCount: newCount, totalInFeed: items.count)
                )
                log.info(
                    "fetch source=\(source.id, privacy: .public) status=200 new=\(newCount) total=\(items.count)"
                )
            } catch is CancellationError {
                // Stop was pressed. Cancellation is not a failure and must not
                // count against the source or start a fresh cooldown.
                log.info("cancelled during source=\(source.id, privacy: .public)")
                break
            } catch {
                let warning = Self.warning(from: error)
                summary.failed += 1
                await warn(warning, for: source, emit: emit)
                log.info(
                    "fetch source=\(source.id, privacy: .public) problem=\(warning.text, privacy: .public)"
                )
            }

            // 5. Politeness pause.
            if offset < total - 1 {
                let pauseMS = Int.random(in: jitter)
                await emit(.pausing(seconds: Double(pauseMS) / 1000))
                do {
                    try await Task.sleep(for: .milliseconds(pauseMS))
                } catch {
                    break
                }
            }
        }

        await emit(.finished(summary))
    }

    private func warn(
        _ warning: Warning,
        for source: SourceSnapshot,
        emit: @Sendable (Event) async -> Void
    ) async {
        await emit(.warned(sourceID: source.id, warning: warning))
        await persistence.recordWarning(sourceID: source.id, warning: warning, at: .now)
    }

    // MARK: - Policy

    static func cooldownRemaining(
        for source: SourceSnapshot,
        now: Date = .now
    ) -> TimeInterval? {
        guard source.cooldownMinutes > 0, let last = source.lastAttemptedAt else { return nil }
        let window = TimeInterval(source.cooldownMinutes) * 60
        let elapsed = now.timeIntervalSince(last)
        return elapsed < window ? window - elapsed : nil
    }

    static func warning(from error: Error) -> Warning {
        guard let feedError = error as? FeedError else {
            return .unreachable(error.localizedDescription)
        }
        switch feedError {
        case .http(let code) where code == 403 || code == 429:
            return .blocked(code)
        case .http(let code) where (500...599).contains(code):
            return .serverError(code)
        case .http(let code):
            return .unreachable("HTTP \(code)")
        case .timedOut:
            return .unreachable("timed out")
        case .transport(let detail):
            return .unreachable(detail)
        case .parseFailed(let detail):
            return .unreachable("parse failed: \(detail)")
        case .emptyFeed:
            return .emptyFeed
        }
    }
}
