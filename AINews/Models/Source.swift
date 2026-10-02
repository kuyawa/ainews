import Foundation
import SwiftData

/// A news source.
///
/// Editorial fields (name, url, feedURL, status, note, rank, isInactive) come
/// from the bundled sources.json and are authoritative there. Operational
/// fields (cooldowns, failure counters, timestamps) are owned by this app and
/// are never overwritten by a re-import.
@Model
final class Source {
    #Unique<Source>([\.id])

    var id: String
    var name: String
    /// The publisher's homepage. In v1 this is for display and click-through
    /// only; it is the future target for the scrape strategy.
    var url: URL
    /// The only thing v1 fetches. nil means scrape-only.
    var feedURL: URL?
    var status: String
    var isInactive: Bool
    var note: String
    var rank: Int

    var cooldownMinutes: Int
    /// Reserved for the scrape strategy. Always nil in v1.
    var headlineSelector: String?

    var consecutiveFailures: Int
    var lastFetchedAt: Date?
    var lastAttemptedAt: Date?
    var lastWarning: String?
    var lastWarningAt: Date?
    var deactivatedAt: Date?
    var deactivationReason: String?

    init(
        id: String,
        name: String,
        url: URL,
        feedURL: URL?,
        status: String,
        isInactive: Bool,
        note: String,
        rank: Int,
        cooldownMinutes: Int = 60,
        headlineSelector: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.feedURL = feedURL
        self.status = status
        self.isInactive = isInactive
        self.note = note
        self.rank = rank
        self.cooldownMinutes = cooldownMinutes
        self.headlineSelector = headlineSelector
        self.consecutiveFailures = 0
    }

    /// The value type the fetch layer is allowed to see.
    var snapshot: SourceSnapshot {
        SourceSnapshot(
            id: id,
            name: name,
            url: url,
            feedURL: feedURL,
            rank: rank,
            cooldownMinutes: cooldownMinutes,
            isInactive: isInactive,
            headlineSelector: headlineSelector,
            lastAttemptedAt: lastAttemptedAt,
            lastFetchedAt: lastFetchedAt
        )
    }
}
