import SwiftUI
import SwiftData

struct HeadlineListView: View {
    /// A binding rather than a value, so the Clear button can drop the source
    /// filter — the discoverable alternative to Cmd-clicking the row.
    @Binding var sourceID: String?

    @Environment(AggregatorStore.self) private var store
    @Query(sort: [SortDescriptor(\Source.rank, order: .forward)]) private var sources: [Source]
    // Ordered by fetchedAt, which is written once when a headline is first
    // seen. lastSeenAt was used here and is actively wrong: upsert refreshes it
    // for every item still present in a feed, so after a second run ~100 items
    // share one timestamp and their order collapses to whatever the store
    // happens to return.
    @Query(sort: [SortDescriptor(\Headline.fetchedAt, order: .reverse)]) private var headlines: [Headline]

    @State private var search = ""
    @State private var unreadOnly = false
    /// Flips the list between English and the publisher's own words.
    @AppStorage("showOriginalTitles") private var showOriginals = false
    /// How many headlines to show per source. The store keeps more than this;
    /// see SwiftDataPersistence.retainedPerSource.
    @AppStorage("headlinesPerSource") private var headlinesPerSource = 100

    private var visible: [Headline] {
        headlines
            .filter { headline in
                if let sourceID, headline.sourceID != sourceID { return false }
                if unreadOnly && headline.isRead { return false }
                return Self.matches(headline, query: search)
            }
            // Newest first. orderingDate is the publisher's own date where the
            // feed supplies one, and only falls back to first-seen for feeds
            // that carry no dates at all.
            .sorted {
                if $0.orderingDate != $1.orderingDate { return $0.orderingDate > $1.orderingDate }
                // A scraped homepage yields a whole page of headlines sharing
                // one fetchedAt and carrying no publishedAt, so the date alone
                // leaves their order arbitrary and it changes between launches.
                // Falling back to the URL is arbitrary but stable.
                return $0.url.absoluteString > $1.url.absoluteString
            }
    }

    /// Whether a headline matches the search field.
    ///
    /// Both languages are searched. Matching only the original meant an English
    /// query found nothing on a translated headline, which is most of the list:
    /// a row reading "Cambricon founder..." would not match "cambricon". Search
    /// stays usable in the original script at the same time.
    nonisolated static func matches(_ headline: Headline, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if headline.title.localizedCaseInsensitiveContains(trimmed) { return true }
        if let translated = headline.translatedTitle,
           translated.localizedCaseInsensitiveContains(trimmed) { return true }
        return false
    }

    /// True when anything is narrowing the list, so Clear has something to do.
    private var hasActiveFilters: Bool {
        sourceID != nil || !search.isEmpty || unreadOnly
    }

    /// Grouped in ranked source order, which is the editorial ordering from
    /// sources.json and the reason the list is worth reading top to bottom.
    private var groups: [(source: Source, items: [Headline], hiddenOlder: Int)] {
        let bySource = Dictionary(grouping: visible, by: \.sourceID)
        return sources.compactMap { source in
            guard let items = bySource[source.id], !items.isEmpty else { return nil }
            // Already newest first, so a prefix is the newest slice. The list
            // is capped because it is a news list, not an archive: at a few
            // hundred new headlines a day an uncapped list becomes unreadable
            // long before it becomes slow. What is hidden is reported rather
            // than silently dropped.
            let shown = Array(items.prefix(max(1, headlinesPerSource)))
            return (source, shown, max(0, items.count - shown.count))
        }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groups, id: \.source.id) { group in
                        Section {
                            ForEach(group.items) { headline in
                                HeadlineRow(headline: headline, showOriginal: showOriginals) {
                                    headline.isRead = true
                                    store.open(headline.url)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.source.name)
                                    .scaledFont(11, weight: .semibold)
                                Spacer()
                                Text(group.hiddenOlder > 0
                                     ? "\(group.items.count) of \(group.items.count + group.hiddenOlder)"
                                     : "\(group.items.count)")
                                    .scaledFont(11)
                                    .foregroundStyle(.tertiary)
                                    .help(group.hiddenOlder > 0
                                          ? "Showing the newest \(group.items.count). \(group.hiddenOlder) older headlines are stored but not shown."
                                          : "All stored headlines for this source")
                            }
                            .scaledPadding(6.5, .vertical)
                        }
                    }
                }
                // Same reasoning as the sidebar: the system draws these, and
                // it offers no app-side colour or width control.
                .scrollIndicators(.never)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter headlines")
        .toolbar {
            // Sits with the search field, and does what Cmd-clicking the
            // selected row does plus more: clears every filter at once.
            ToolbarItem {
                Button {
                    search = ""
                    sourceID = nil
                    unreadOnly = false
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
                .disabled(!hasActiveFilters)
                .help("Show every headline: clears the source, the search and the unread filter")
            }

            ToolbarItem {
                Toggle(isOn: $unreadOnly) {
                    Label("Unread Only", systemImage: "circle.fill")
                }
                .help("Show only unread headlines")
            }

            ToolbarItem {
                Toggle(isOn: $showOriginals) {
                    Label("Originals", systemImage: "character.book.closed")
                }
                .help("Show the publisher's original headline instead of the translation")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Headlines Yet", systemImage: "newspaper")
        } description: {
            Text(headlines.isEmpty
                 ? "Press Start to fetch. Sources without a feed are skipped and reported, not hidden."
                 : "Nothing matches the current filter.")
        }
    }
}

private struct HeadlineRow: View {
    let headline: Headline
    let showOriginal: Bool
    let open: () -> Void

    private var date: Date { headline.publishedAt ?? headline.fetchedAt }

    /// The original is never discarded: when a translation exists the source
    /// headline stays visible underneath it, because machine translation of
    /// headline text mangles company names and technical terms often enough
    /// that you need to be able to check.
    private var primary: String {
        showOriginal ? headline.title : headline.displayTitle
    }

    /// Always returns something, so every row keeps the same two-line shape.
    ///
    /// English-language sources have no translation, and rows one line shorter
    /// than their neighbours read as broken rather than as empty. So the slot
    /// falls back to the article date, and to the host when the feed supplied
    /// no usable date - nearly every feed does, but not all.
    private var secondary: String {
        if headline.hasTranslation {
            // The other language, whichever way round we are displaying it.
            return showOriginal ? (headline.translatedTitle ?? headline.title) : headline.title
        }
        if let published = headline.publishedAt {
            return published.formatted(date: .abbreviated, time: .shortened)
        }
        return articlePath
    }

    /// The article's own path, with the scheme and host stripped.
    ///
    /// The host was the repetitive part: every row under a source shares it and
    /// the list is already grouped by source, so it said nothing at all. The
    /// path varies per article, and its leading segments name the section the
    /// piece sits in ("/editor-s-picks/interview", "/business/electronics"),
    /// which is what makes it worth the space.
    ///
    /// Only Nikkei Asia reaches this branch. Its RSS 1.0 feed carries titles
    /// and links but no date elements whatsoever, so there is no date to show;
    /// every other source that has a feed either supplies dates or is not in
    /// English.
    private var articlePath: String {
        let path = headline.url.path()
        guard !path.isEmpty, path != "/" else { return hostLabel }
        return path
    }

    /// A URL reads badly wrapped, so it gets one line - tail truncation keeps
    /// the informative leading segment. Headlines and dates read fine on two.
    private var secondaryLineLimit: Int {
        headline.hasTranslation || headline.publishedAt != nil ? 2 : 1
    }

    private var hostLabel: String {
        let host = headline.url.host() ?? headline.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(headline.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(primary)
                        .scaledFont(13)
                        .foregroundStyle(headline.isRead ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

                    // The article URL is hung on a small icon rather than on
                    // the whole row. A tooltip across the row fired whenever
                    // the pointer crossed a headline, which while reading is
                    // most of the time.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        // Same tone as the text it sits beside, so the icon
                        // reads as part of the line rather than as chrome.
                        Image(systemName: "link")
                            .scaledFont(9)
                            .foregroundStyle(.tertiary)
                            .help(headline.url.absoluteString)

                        Text(secondary)
                            .scaledFont(11)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(secondaryLineLimit)
                    }
                }

                Spacer(minLength: 8)

                Text(date, format: .relative(presentation: .named))
                    .scaledFont(11)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
