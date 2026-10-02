import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AggregatorStore.self) private var store
    @Environment(\.modelContext) private var context

    @AppStorage("cooldownMinutes") private var cooldownMinutes = 60
    @AppStorage("translateHeadlines") private var translateHeadlines = true
    @AppStorage(FontScale.defaultsKey) private var fontScale = FontScale.defaultValue
    @AppStorage("headlinesPerSource") private var headlinesPerSource = 100
    @AppStorage("retainedPerSource") private var retainedPerSource = 200
    @AppStorage("jitterLowerSeconds") private var jitterLower = 5.0
    @AppStorage("jitterUpperSeconds") private var jitterUpper = 10.0

    var body: some View {
        Form {
            Section {
                Stepper(value: $cooldownMinutes, in: 5...720, step: 5) {
                    Text("Cooldown: \(cooldownMinutes) minutes")
                }
                .onChange(of: cooldownMinutes) { _, newValue in
                    applyCooldown(newValue)
                }
                Text("A source is not fetched again until this long after its last attempt. Keyed on attempts, not successes, so a failing source is not retried on every run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Fetching")
            }

            Section {
                HStack {
                    Text("Text size")
                    Spacer()
                    Text(FontScale.label(for: fontScale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("", value: $fontScale, in: FontScale.range, step: FontScale.step)
                        .labelsHidden()
                }
                Text("Also available anywhere with Cmd-+ and Cmd--, and Cmd-0 to reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Reading")
            }

            Section {
                Stepper(value: $headlinesPerSource, in: 10...500, step: 10) {
                    Text("Show \(headlinesPerSource) headlines per source")
                }
                .onChange(of: headlinesPerSource) { _, newValue in
                    // The list can never show more than is kept.
                    if retainedPerSource < newValue { retainedPerSource = newValue }
                }

                Stepper(value: $retainedPerSource, in: 50...2000, step: 50) {
                    Text("Keep \(retainedPerSource) headlines per source")
                }
                .onChange(of: retainedPerSource) { _, newValue in
                    if headlinesPerSource > newValue { headlinesPerSource = newValue }
                }

                Text("Headlines accumulate forever otherwise, and every launch loads the whole archive to draw a list nobody scrolls to the end of. Keeping more than you show means a headline that scrolls out of a feed is still remembered as seen, rather than being re-added and translated again later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Storage")
            }

            Section {
                Toggle("Translate headlines to English", isOn: $translateHeadlines)
                Text("Uses Apple's on-device translation. Nothing is sent anywhere: there is no service, no API key, and no network request. Headlines are translated once and stored, so each one is only ever translated a single time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language")
            }

            Section {
                LabeledContent("Minimum") {
                    Text("\(Int(jitterLower))s")
                }
                Slider(value: $jitterLower, in: 1...30, step: 1)
                LabeledContent("Maximum") {
                    Text("\(Int(jitterUpper))s")
                }
                Slider(value: $jitterUpper, in: 1...60, step: 1)
                Text("Random pause between sources. Runs are strictly serial and never fetch two sources at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Politeness")
            }
            .onChange(of: jitterLower) { _, _ in syncStore() }
            .onChange(of: jitterUpper) { _, _ in syncStore() }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { syncStore() }
    }

    private func syncStore() {
        store.jitterLowerSeconds = jitterLower
        store.jitterUpperSeconds = jitterUpper
    }

    private func applyCooldown(_ minutes: Int) {
        guard let all = try? context.fetch(FetchDescriptor<Source>()) else { return }
        for source in all { source.cooldownMinutes = minutes }
        try? context.save()
    }
}
