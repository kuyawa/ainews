import Foundation
import SwiftData
import Observation
import AppKit
import OSLog

/// UI-facing state and the owner of the running task.
///
/// It never fetches anything itself: it builds snapshots, hands them to the
/// engine, and republishes the engine's events as observable state.
@MainActor
@Observable
final class AggregatorStore {

    // MARK: - Observable state

    private(set) var isRunning = false
    private(set) var currentSourceID: String?
    private(set) var progressIndex = 0
    private(set) var progressTotal = 0
    private(set) var lastSummary: AggregationEngine.Summary?
    /// Seconds remaining in the politeness pause, or nil when not pausing.
    private(set) var pauseRemaining: Double?
    /// Set when a run could not start at all.
    var lastError: String?

    /// Configurable from Settings. Clamped so the app can never be configured
    /// into hammering a publisher.
    var jitterLowerSeconds: Double = 5
    var jitterUpperSeconds: Double = 10

    // MARK: - Dependencies

    private let context: ModelContext
    private var runTask: Task<Void, Never>?
    private let log = Logger(subsystem: "net.kuyawa.ainews", category: "store")

    /// On-device translation of headlines into English.
    let translator: TranslationCoordinator

    /// Whether to translate at all. Read from UserDefaults rather than
    /// @AppStorage because this type is not a View.
    var translationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "translateHeadlines")
    }

    init(context: ModelContext) {
        self.context = context
        self.translator = TranslationCoordinator(context: context)
    }

    // MARK: - Run control

    func start() {
        guard !isRunning else { return }

        let snapshots: [SourceSnapshot]
        do {
            let descriptor = FetchDescriptor<Source>(
                sortBy: [SortDescriptor(\Source.rank, order: .forward)]
            )
            // Inactive sources are filtered in the engine too, but excluding
            // them here keeps the progress total honest.
            snapshots = try context.fetch(descriptor)
                .filter { !$0.isInactive }
                .map(\.snapshot)
        } catch {
            lastError = "Could not read sources: \(error.localizedDescription)"
            return
        }

        guard !snapshots.isEmpty else {
            lastError = "No active sources to fetch."
            return
        }

        lastError = nil
        lastSummary = nil
        pauseRemaining = nil
        progressIndex = 0
        progressTotal = snapshots.count
        isRunning = true

        let low = max(1, min(jitterLowerSeconds, jitterUpperSeconds))
        let high = max(low, jitterUpperSeconds)
        let range = Int(low * 1000)...Int(high * 1000)

        let engine = AggregationEngine(
            fetcher: FeedFetcher(),
            persistence: SwiftDataPersistence(context: context),
            jitter: range
        )

        runTask = Task { [weak self] in
            // Bind the weak reference to an immutable local before it is
            // captured: a captured var cannot be referenced from the
            // concurrently-executing emit closure under Swift 6.
            guard let store = self else { return }
            await engine.run(snapshots) { event in
                await store.handle(event)
            }
            // The Task inherits MainActor isolation from start(), so this
            // call is already on the right actor and needs no await.
            store.finishRun()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        pauseRemaining = nil
    }

    private func finishRun() {
        isRunning = false
        currentSourceID = nil
        pauseRemaining = nil
        runTask = nil
    }

    private func handle(_ event: AggregationEngine.Event) {
        switch event {
        case .willFetch(let sourceID, let index, let total):
            currentSourceID = sourceID
            progressIndex = index
            progressTotal = total
            pauseRemaining = nil

        case .fetched, .warned:
            pauseRemaining = nil
            // Translate what was just fetched while the engine sleeps between
            // sources, so localisation costs no extra wall-clock time. The
            // work runs on the main actor, in parallel with the politesleep.
            if translationsEnabled {
                translator.schedule()
            }

        case .skipped:
            break

        case .pausing(let seconds):
            pauseRemaining = seconds

        case .finished(let summary):
            lastSummary = summary
            pauseRemaining = nil
        }
    }

    // MARK: - Sources

    /// Called at launch: translates anything a previous run left pending,
    /// including every headline fetched before translation existed.
    func scheduleTranslationIfNeeded() {
        guard translationsEnabled else { return }
        guard translator.pendingCount() > 0 else { return }
        translator.schedule()
    }

    /// How many sources the store holds. Zero means a fresh install, which is
    /// the only time sources.json is applied automatically.
    func sourceCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<Source>())) ?? 0
    }

    @discardableResult
    func reloadSources() -> SourceImporter.Outcome? {
        do {
            let outcome = try SourceImporter.load(into: context)
            lastError = nil
            return outcome
        } catch {
            lastError = "Reload failed: \(error.localizedDescription)"
            log.error("reload failed: \(error)")
            return nil
        }
    }

    /// The only writer of isInactive in the app.
    func setInactive(_ source: Source, _ inactive: Bool) {
        source.isInactive = inactive
        if inactive {
            source.deactivatedAt = .now
            source.deactivationReason = "manual: disabled by user"
        } else {
            source.deactivatedAt = nil
            source.deactivationReason = nil
            // Give a re-enabled source a clean slate rather than leaving it
            // one failure away from any future auto-deactivation.
            source.consecutiveFailures = 0
            source.lastWarning = nil
            source.lastWarningAt = nil
        }
        try? context.save()
    }

    /// Marks headlines read, scoped to one source when the sidebar has a
    /// selection.
    ///
    /// Scoped rather than always global because the button sits beside a list
    /// the reader has narrowed on purpose: clearing the source they are working
    /// through must not silently clear the other 29. With nothing selected it
    /// still means everything, which is what it says.
    func markAllRead(sourceID: String? = nil) {
        // Two descriptors rather than one predicate comparing an optional:
        // SwiftData predicates handle the optional badly, and this keeps each
        // case literal.
        let descriptor: FetchDescriptor<Headline>
        if let sourceID {
            descriptor = FetchDescriptor<Headline>(
                predicate: #Predicate<Headline> { !$0.isRead && $0.sourceID == sourceID }
            )
        } else {
            descriptor = FetchDescriptor<Headline>(
                predicate: #Predicate<Headline> { !$0.isRead }
            )
        }

        guard let unread = try? context.fetch(descriptor) else { return }
        for headline in unread { headline.isRead = true }
        try? context.save()
    }

    // MARK: - Links

    /// Opens the publisher's own page in the user's default browser. The app
    /// deliberately has no in-app web view: reading happens on their site,
    /// with the user's own extensions, password manager and cookie jar.
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
