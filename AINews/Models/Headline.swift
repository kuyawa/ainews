import Foundation
import SwiftData

/// One headline, deduplicated globally by URL.
///
/// The URL is the identity, not the title: publishers routinely fix a typo in
/// a headline after publishing, and a title-keyed store would duplicate it.
@Model
final class Headline {
    #Unique<Headline>([\.url])

    var url: URL
    var title: String
    var sourceID: String
    /// From the feed, when the feed supplies a usable date. Optional by design:
    /// many feeds omit it or emit something unparseable.
    var publishedAt: Date?
    var fetchedAt: Date
    var lastSeenAt: Date
    var isRead: Bool

    // MARK: - Translation
    //
    // The original title is never overwritten. Machine translation of
    // headlines is imperfect by nature (compressed phrasing, puns, dense
    // proper nouns), so the source text has to stay available.

    /// The English headline, when a translation was actually produced.
    var translatedTitle: String?
    /// nil means "not processed yet". Otherwise one of TranslationState.
    /// Held as a String because SwiftData predicates handle optionals more
    /// predictably than a raw enum value.
    var translationState: String?
    /// What the framework detected, for debugging a bad translation.
    var detectedLanguage: String?

    init(
        url: URL,
        title: String,
        sourceID: String,
        publishedAt: Date?,
        fetchedAt: Date,
        lastSeenAt: Date,
        isRead: Bool = false,
        translatedTitle: String? = nil,
        translationState: String? = nil,
        detectedLanguage: String? = nil
    ) {
        self.url = url
        self.title = title
        self.sourceID = sourceID
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.lastSeenAt = lastSeenAt
        self.isRead = isRead
        self.translatedTitle = translatedTitle
        self.translationState = translationState
        self.detectedLanguage = detectedLanguage
    }

    /// What the list shows, falling back to the original.
    var displayTitle: String { translatedTitle ?? title }

    /// True when there is a translation worth showing alongside the original.
    var hasTranslation: Bool { translatedTitle != nil && translatedTitle != title }

    /// The date a headline is ordered by, and the one retention keeps the
    /// newest of: the publisher's own date where the feed supplies one,
    /// otherwise when this app first saw it.
    ///
    /// Note this is NOT lastSeenAt. Upsert refreshes that for every headline
    /// still present in a feed, so it collapses onto the run timestamps and
    /// carries no ordering information at all.
    var orderingDate: Date { publishedAt ?? fetchedAt }
}

/// Terminal and in-flight states for a headline's translation.
enum TranslationState {
    /// Skipped because the text is already in the target language, or the
    /// language pair is unsupported. Terminal: never retried.
    static let skipped = "skipped"
    /// Translation succeeded; translatedTitle holds the result.
    static let done = "done"
    /// An error occurred. Terminal for now, so a flaky run cannot loop
    /// forever retranslating the same batch.
    static let failed = "failed"
}
