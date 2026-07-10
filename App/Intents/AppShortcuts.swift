import AppIntents

/// Registers Colophon's Siri/Shortcuts phrases (M2b Task 5): Resume / Open / Search. Every phrase
/// includes `\(.applicationName)` (required by App Intents). These surface in the Shortcuts app and
/// as Siri phrases; the ACTUAL Siri-utterance verification is a device-only Task-6 human-checklist
/// item (the simulator can't exercise "Hey Siri"). Compiles on macOS too (App Intents is
/// cross-platform).
struct ColophonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeIntent(),
            phrases: [
                "Resume my audiobook in \(.applicationName)",
                "Continue my audiobook in \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume Audiobook",
            systemImageName: "play.fill")
        AppShortcut(
            intent: OpenColophonIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Colophon",
            systemImageName: "books.vertical.fill")
        AppShortcut(
            intent: SearchColophonIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my library in \(.applicationName)",
            ],
            shortTitle: "Search Colophon",
            systemImageName: "magnifyingglass")
    }
}
