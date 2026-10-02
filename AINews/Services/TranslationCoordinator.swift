import Foundation
import SwiftData
// @preconcurrency: Translation ships without full Swift 6 Sendable
// annotations, so TranslationSession is not marked Sendable even though the
// framework is safe to drive from one isolation domain at a time. We do
// exactly that: one session, used serially, never shared.
@preconcurrency import Translation
import Observation
import OSLog

/// A translation outcome, detached from the framework's Response type so the
/// decision logic can be unit tested without a TranslationSession.
struct TranslationOutcome: Sendable, Equatable {
    let clientIdentifier: String?
    let sourceLanguageCode: String?
    let targetText: String
}

enum TranslationDecision: Sendable, Equatable {
    case store(String)
    case skip
    case ignore
}

/// Localises headlines into English using Apple's on-device Translation.
///
/// Nothing leaves the Mac: there is no service, no key, and no network call.
/// That is the whole reason this uses the system framework rather than a cloud
/// API — routing headlines through a third party would defeat the point of
/// reading the publishers directly.
///
/// The framework only hands out a TranslationSession through SwiftUI's
/// translationTask modifier, so this type is split in two halves:
///
///   - schedule() is callable from anywhere and flags that work exists
///   - drain(using:) is called by the view that carries .translationTask
///
/// Translation runs on the main actor while the engine is sleeping between
/// sources, so it costs no wall-clock time the run was not already spending.
@MainActor
@Observable
final class TranslationCoordinator {

    /// English is the target. Sources are detected per batch.
    ///
    /// nonisolated because it is immutable and the pure helpers below are
    /// usable from anywhere, including tests.
    nonisolated static let targetLanguage = Locale.Language(identifier: "en")

    /// Headlines per fetch from the store. Bounds one session's workload.
    static let batchLimit = 200

    /// Drives .translationTask. Non-nil means "there may be work".
    private(set) var configuration: TranslationSession.Configuration?
    private(set) var isTranslating = false
    private(set) var lastError: String?

    private let context: ModelContext
    private let log = Logger(subsystem: "net.kuyawa.ainews", category: "translate")

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Scheduling

    /// Flags that headlines may need translating.
    ///
    /// Setting the configuration the first time starts the SwiftUI task;
    /// afterwards invalidate() restarts it, which is how new work is picked up
    /// once the previous batch has drained.
    func schedule() {
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: nil,           // detect per batch
                target: Self.targetLanguage
            )
        } else {
            configuration?.invalidate()
        }
    }

    // MARK: - Work

    /// Processes every pending headline, one source at a time.
    ///
    /// Grouped by source so each batch is monolingual: a batch mixing Chinese
    /// and Japanese would leave the framework guessing which language applies.
    func drain(using session: TranslationSession) async {
        guard !isTranslating else { return }
        isTranslating = true
        defer { isTranslating = false }

        var totalTranslated = 0

        while true {
            let pending = pendingHeadlines(limit: Self.batchLimit)
            guard !pending.isEmpty else { break }

            var progressed = false
            for (_, group) in Dictionary(grouping: pending, by: \.sourceID) {
                // Titles that are pure ASCII are already English in every case
                // this app sees; skipping them avoids pointless sessions for
                // the English-language sources.
                let obvious = group.filter { Self.isProbablyEnglish($0.title) }
                for headline in obvious {
                    headline.translationState = TranslationState.skipped
                    progressed = true
                }

                let candidates = group.filter { !Self.isProbablyEnglish($0.title) }
                guard !candidates.isEmpty else { continue }

                // TranslationSession.Request is not annotated Sendable by the
                // framework either. The array is built here, handed straight to
                // the session, and never referenced again, so nothing is
                // actually shared across isolation domains; this only tells the
                // compiler what is already true.
                nonisolated(unsafe) let requests = candidates.map {
                    TranslationSession.Request(
                        sourceText: $0.title,
                        clientIdentifier: $0.url.absoluteString
                    )
                }

                do {
                    let responses = try await session.translations(from: requests)
                    totalTranslated += apply(
                        responses.map(Self.outcome(from:)),
                        to: candidates
                    )
                    progressed = true
                } catch is CancellationError {
                    try? context.save()
                    return
                } catch {
                    lastError = "Translation failed: \(error.localizedDescription)"
                    log.error("batch failed: \(error)")
                    // Terminal, so a persistent failure cannot spin forever.
                    for headline in candidates {
                        headline.translationState = TranslationState.failed
                    }
                    progressed = true
                }
            }

            try? context.save()
            if !progressed { break }
        }

        if totalTranslated > 0 {
            log.info("translated \(totalTranslated) headlines")
        }
    }

    // MARK: - Applying results

    /// Writes decisions back onto the headlines. Returns how many were stored.
    @discardableResult
    func apply(_ outcomes: [TranslationOutcome], to headlines: [Headline]) -> Int {
        let byURL = Dictionary(
            headlines.map { ($0.url.absoluteString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var stored = 0

        for outcome in outcomes {
            guard let key = outcome.clientIdentifier, let headline = byURL[key] else { continue }
            switch Self.decide(
                sourceLanguageCode: outcome.sourceLanguageCode,
                targetText: outcome.targetText,
                targetLanguageCode: Self.targetLanguage.languageCode?.identifier ?? "en"
            ) {
            case .store(let text):
                headline.translatedTitle = text
                headline.translationState = TranslationState.done
                headline.detectedLanguage = outcome.sourceLanguageCode
                stored += 1
            case .skip:
                headline.translatedTitle = nil
                headline.translationState = TranslationState.skipped
                headline.detectedLanguage = outcome.sourceLanguageCode
            case .ignore:
                headline.translationState = TranslationState.failed
            }
        }
        return stored
    }

    // MARK: - Pure helpers (unit tested)

    /// The whole policy, with no framework types involved.
    nonisolated static func decide(
        sourceLanguageCode: String?,
        targetText: String,
        targetLanguageCode: String
    ) -> TranslationDecision {
        let trimmed = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignore }
        // The text was already in the target language; nothing to show.
        if let source = sourceLanguageCode, source == targetLanguageCode { return .skip }
        return .store(trimmed)
    }

    /// Cheap pre-filter. Not a correctness check: the framework's own
    /// detection is what decides, this only avoids obvious wasted work.
    nonisolated static func isProbablyEnglish(_ text: String) -> Bool {
        !text.unicodeScalars.contains { !$0.isASCII }
    }

    nonisolated static func outcome(from response: TranslationSession.Response) -> TranslationOutcome {
        TranslationOutcome(
            clientIdentifier: response.clientIdentifier,
            sourceLanguageCode: response.sourceLanguage.languageCode?.identifier,
            targetText: response.targetText
        )
    }

    // MARK: - Store access

    /// Headlines never yet processed, newest first.
    func pendingHeadlines(limit: Int) -> [Headline] {
        var descriptor = FetchDescriptor<Headline>(
            predicate: #Predicate<Headline> { $0.translationState == nil },
            sortBy: [SortDescriptor(\Headline.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func pendingCount() -> Int {
        let descriptor = FetchDescriptor<Headline>(
            predicate: #Predicate<Headline> { $0.translationState == nil }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
