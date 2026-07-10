import SwiftUI

/// Colophon-wide preferences — a plain `Form` bound directly to the three `@AppStorage` keys
/// that are Colophon's settings surface (Global Constraints): `colophon.typeface`,
/// `colophon.defaultRate`, `colophon.skipInterval`. No view-local state; SwiftUI's `AppStorage`
/// property wrapper writes straight through to `UserDefaults.standard`, which is exactly what
/// `ColophonApp` (typeface, root `fontDesign`) and `AppState.startPlayback` (rate, skip interval,
/// via plain `UserDefaults` reads — `AppState` isn't a `View`) also read.
///
/// Presented several ways, same view every time: a macOS `Settings` scene (⌘,) in `ColophonApp`,
/// the account-menu sheet shared by `PhoneShell`/`SplitShell` (`RootShell.swift`), and an
/// iOS/iPadOS sheet from the gear button on `ConnectionsView`. The two sheet call sites already
/// wrap this view in their own `NavigationStack`; the macOS `Settings` scene did NOT, so the
/// "Support the app" `NavigationLink` below would dead-end there (this project's Mac
/// navigationDestination gotcha — a `NavigationLink` needs a `NavigationStack` ancestor to push
/// into) until `ColophonApp` was updated to wrap it too.
struct SettingsView: View {
    @AppStorage("colophon.typeface") private var typeface = "serif"
    @AppStorage("colophon.defaultRate") private var defaultRate = 1.0
    // Default + options come from `AppState` — the single source of truth also read by
    // `AppState.storedSkipInterval()` and the live-update `onChange` in `ColophonApp`.
    @AppStorage("colophon.skipInterval") private var skipInterval = AppState.defaultSkipInterval
    // M2a Task 8: podcast "delete after finished" — default OFF (the key literal matches
    // `AppState.deleteAfterFinishedKey`, the same plain-`UserDefaults.standard` convention as the
    // three keys above; `AppState` reads it directly since it isn't a `View`).
    @AppStorage("colophon.deleteDownloadedEpisodesAfterFinishing") private var deleteEpisodesAfterFinishing = false

    private let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let skipIntervals = AppState.skipIntervalOptions

    var body: some View {
        Form {
            Section("Colophon") {
                Picker("Typeface", selection: $typeface) {
                    Text("New York").tag("serif")
                    Text("San Francisco").tag("sans")
                }
                Picker("Default Playback Rate", selection: $defaultRate) {
                    ForEach(rates, id: \.self) { rate in
                        Text(String(format: "%g×", rate)).tag(rate)
                    }
                }
                Picker("Skip Interval", selection: $skipInterval) {
                    ForEach(skipIntervals, id: \.self) { interval in
                        Text("\(interval)s").tag(interval)
                    }
                }
            }
            Section {
                Toggle("Delete Downloaded Episodes After Finishing", isOn: $deleteEpisodesAfterFinishing)
            } footer: {
                Text("When on, a downloaded podcast episode's files are removed automatically once you finish listening to it. Books are never deleted automatically.")
            }
            // M2c Task 2: an unobtrusive final section — a tip unlocks nothing (Global Constraint),
            // so it lives below every real preference, never mixed in with them.
            Section {
                NavigationLink {
                    TipJarView()
                } label: {
                    Label {
                        Text("Support the app")
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                }
            } footer: {
                Text("Colophon is free, with every feature included. A tip is optional, and always appreciated.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 220)
        #endif
    }
}
