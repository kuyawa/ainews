import SwiftUI
import SwiftData

struct SourceListView: View {
    @Binding var selection: String?
    @Environment(AggregatorStore.self) private var store
    @Query(sort: [SortDescriptor(\Source.rank, order: .forward)]) private var sources: [Source]

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(sources) { source in
                    SourceRow(source: source)
                        .tag(source.id)
                        .contextMenu {
                            // Enabled/disabled is owned by the app, not by
                            // sources.json, once a source exists - see
                            // SourceImporter.
                            Button(source.isInactive ? "Don't Skip This Source" : "Skip This Source") {
                                store.setInactive(source, !source.isInactive)
                            }

                            Divider()

                            Button("Open Homepage") { store.open(source.url) }
                            if let feed = source.feedURL {
                                Button("Open Feed") { store.open(feed) }
                            }
                            Button("Copy URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
                            }
                        }
                }
            } header: {
                // Half the title's own line height above and below, so it
                // breathes without looking detached from its rows.
                Text("Sources")
                    .scaledPadding(6.5, .vertical)
            }
        }
        .listStyle(.sidebar)
        // Scrollbars are drawn by the system and cannot be recoloured or
        // narrowed from an app: NSScroller.preferredScrollerStyle is readonly
        // and its width methods are getters, both derived from System Settings
        // > Appearance. Hiding them is the one lever available.
        .scrollIndicators(.never)
    }
}

private struct SourceRow: View {
    let source: Source

    private var isScrapeOnly: Bool { source.feedURL == nil }

    /// "ok · 12 new" once a count exists; plain "ok" for a source fetched
    /// before counts were recorded, never "0 new".
    static func successText(for source: Source) -> String {
        guard let count = source.lastNewCount else { return "ok" }
        return count > 0 ? "ok · \(count) new" : "ok · no new"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(source.rank)")
                .scaledFont(11, monospacedDigits: true)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .scaledFont(13)
                    .lineLimit(1)

                // Every row shows exactly one second line, so the column
                // reads evenly. A healthy source used to show nothing, which
                // made it look like an unfetched one.
                if source.isInactive {
                    Text(source.deactivationReason ?? "inactive")
                        .scaledFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let warning = source.lastWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .scaledFont(10)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if source.lastFetchedAt != nil {
                    Label(Self.successText(for: source), systemImage: "checkmark.circle")
                        .scaledFont(10)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else {
                    Text("not fetched yet")
                        .scaledFont(10)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if source.isInactive {
                Badge(text: "INACTIVE", tint: .secondary)
            } else {
                Badge(
                    text: isScrapeOnly ? "SCRAPE" : "RSS",
                    tint: isScrapeOnly ? .orange : .green
                )
            }
        }
        .opacity(source.isInactive ? 0.5 : 1)
        .help(helpText)
    }

    private var helpText: String {
        var lines = [source.note]
        if let feed = source.feedURL {
            lines.append("Feed: \(feed.absoluteString)")
        } else {
            lines.append("No feed. Needs HTML scraping, which is not implemented yet.")
        }
        if let at = source.lastFetchedAt {
            lines.append("Last fetched: \(at.formatted(date: .abbreviated, time: .shortened))")
        }
        if source.consecutiveFailures > 0 {
            lines.append("Consecutive failures: \(source.consecutiveFailures)")
        }
        return lines.joined(separator: "\n")
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .scaledFont(9, weight: .bold)
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}
