import SwiftUI
import SwiftData

@main
struct AINewsApp: App {
    private let container: ModelContainer
    @State private var store: AggregatorStore

    /// Bound here so the View-menu commands can drive it. Every view reads the
    /// same key, so one shortcut moves the whole reading surface.
    @AppStorage(FontScale.defaultsKey) private var fontScale = FontScale.defaultValue

    init() {
        // Registered before anything reads them: bool(forKey:) returns false
        // for an absent key, which would silently disable translation and
        // native-feeling defaults on a fresh install.
        UserDefaults.standard.register(defaults: [
            "translateHeadlines": true,
            "showOriginalTitles": false,
            "cooldownMinutes": 60,
            "jitterLowerSeconds": 5.0,
            "jitterUpperSeconds": 10.0,
            FontScale.defaultsKey: FontScale.defaultValue,
            "headlinesPerSource": 100,
            "retainedPerSource": 200,
        ])

        let schema = Schema([Source.self, Headline.self])
        let configuration = ModelConfiguration(schema: schema, url: Self.storeURL)

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A store that cannot be opened is not recoverable at runtime, and
            // silently continuing would look like data loss.
            fatalError("Could not open the SwiftData store: \(error)")
        }
        self.container = container

        let store = AggregatorStore(context: container.mainContext)
        store.jitterLowerSeconds = UserDefaults.standard.object(forKey: "jitterLowerSeconds") as? Double ?? 5
        store.jitterUpperSeconds = UserDefaults.standard.object(forKey: "jitterUpperSeconds") as? Double ?? 10
        // sources.json seeds a fresh install and then becomes reference
        // material. It is NOT reapplied on every launch: the importer drops any
        // source absent from the file, along with that source's headlines, so
        // auto-importing makes an edited or truncated file destructive. After
        // the first run the store is authoritative, and re-syncing is a
        // deliberate act via Reload Sources.
        if store.sourceCount() == 0 {
            store.reloadSources()
        }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Sources") { store.reloadSources() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // In the View menu, where macOS users expect text size controls.
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") {
                    fontScale = FontScale.adjusted(fontScale, by: FontScale.step)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(fontScale >= FontScale.range.upperBound)

                Button("Smaller Text") {
                    fontScale = FontScale.adjusted(fontScale, by: -FontScale.step)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontScale <= FontScale.range.lowerBound)

                Button("Actual Size") {
                    fontScale = FontScale.defaultValue
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(fontScale == FontScale.defaultValue)

                Divider()

                Text("Text Size: \(FontScale.label(for: fontScale))")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .modelContainer(container)
        }
    }

    /// The store lives in Application Support, never inside the app bundle,
    /// which may be read-only or replaced on rebuild.
    private static var storeURL: URL {
        let base = URL.applicationSupportDirectory.appending(
            path: "AINews", directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base.appending(path: "AINews.store")
    }
}
