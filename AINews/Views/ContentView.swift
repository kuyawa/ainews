import SwiftUI
import SwiftData
// Required for the translationTask modifier. It lives in the
// _Translation_SwiftUI cross-import overlay, which is only pulled in when a
// file imports both SwiftUI and Translation.
import Translation

struct ContentView: View {
    @Environment(AggregatorStore.self) private var store
    @State private var selectedSourceID: String?

    var body: some View {
        // The status bar is a sibling below the split view, not a safe-area
        // inset over it. An inset lets the list scroll underneath the bar and
        // the final rows could not be scrolled clear of it; as a sibling the
        // bar occupies its own layout space, so overlap is impossible.
        VStack(spacing: 0) {
            NavigationSplitView {
                SourceListView(selection: $selectedSourceID)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 800)
            } detail: {
                HeadlineListView(sourceID: $selectedSourceID)
            }

            RunBarView()
        }
        // Apple's Translation framework only vends a session through this
        // modifier, so the window hosts it and the coordinator drains its
        // queue whenever the configuration is (in)validated.
        .translationTask(store.translator.configuration) { session in
            await store.translator.drain(using: session)
        }
        .task {
            store.scheduleTranslationIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.reloadSources()
                } label: {
                    Label("Reload Sources", systemImage: "arrow.clockwise")
                }
                .help("Re-apply sources.json. Refreshes editorial fields and ADDS or REMOVES sources to match the file — including their headlines. Fetch history for sources that remain is kept.")
                .disabled(store.isRunning)

                Button {
                    store.markAllRead()
                } label: {
                    Label("Mark All Read", systemImage: "checkmark.circle")
                }
                .help("Mark every headline as read")
            }
        }
    }
}
