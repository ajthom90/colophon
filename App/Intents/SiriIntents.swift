import AppIntents

// The Siri/Shortcuts App Intents (M2b Task 5), registered by `ColophonShortcuts`
// (`AppShortcutsProvider`). Unlike the playback intents (`SharedIntents/AudioPlaybackIntents.swift`,
// compiled into BOTH the app and the widget extension) these live ONLY in the app target: they
// `openAppWhenRun`, so the system launches/foregrounds the app and runs `perform()` in the app
// process — where the app registers the `AppActionProvider` @Dependency at launch
// (`AppIntentActionBridge`, called from `ColophonApp.init`). This is the same @Dependency bridge the
// playback intents use, just reaching `AppState` (resume / search) instead of the `PlaybackController`.

/// "Resume my audiobook" — resumes the most-recent continue-listening item through `AppState`.
struct ResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Audiobook"
    static let description = IntentDescription("Resume your most recent audiobook.")
    /// Open the app so playback starts audibly (and, from a cold launch, so `ColophonApp.init`
    /// registers the `AppActionProvider` @Dependency this intent resolves below).
    static let openAppWhenRun = true

    @Dependency var actions: AppActionProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        await actions.resumeTopContinueListening()
        return .result()
    }
}

/// "Open Colophon" — foregrounds the app (`openAppWhenRun`); no further action needed.
struct OpenColophonIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Colophon"
    static let description = IntentDescription("Open Colophon.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult { .result() }
}

/// "Search Colophon" — opens the app to the Search surface, seeding the query when one is supplied.
struct SearchColophonIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Colophon"
    static let description = IntentDescription("Search your Colophon library.")
    static let openAppWhenRun = true

    @Parameter(title: "Search") var query: String?

    @Dependency var actions: AppActionProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        actions.presentSearch(query: query)
        return .result()
    }
}
