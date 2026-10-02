import SwiftUI

/// The always-visible status strip at the bottom of the window.
struct RunBarView: View {
    @Environment(AggregatorStore.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    store.isRunning ? store.stop() : store.start()
                } label: {
                    Label(
                        store.isRunning ? "Stop" : "Start",
                        systemImage: store.isRunning ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 64)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .help(store.isRunning ? "Cancel the run (Cmd-Return)" : "Start a fetch run (Cmd-Return)")

                if store.isRunning {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)

                    Text(statusText)
                        .scaledFont(12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                } else {
                    Text(store.lastSummary?.text ?? idleText)
                        .scaledFont(12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 2)
        }
        .background(.bar)
    }

    private var progressFraction: Double {
        guard store.progressTotal > 0 else { return 0 }
        return Double(store.progressIndex) / Double(store.progressTotal)
    }

    private var statusText: String {
        var parts = ["\(store.progressIndex) / \(store.progressTotal)"]
        if let id = store.currentSourceID { parts.append(id) }
        if let remaining = store.pauseRemaining {
            parts.append("next in \(Int(remaining.rounded()))s")
        }
        if store.translator.isTranslating {
            parts.append("translating")
        }
        return parts.joined(separator: " · ")
    }

    private var idleText: String {
        if let error = store.lastError { return error }
        return "Idle — press Start. Nothing is fetched on its own."
    }
}
