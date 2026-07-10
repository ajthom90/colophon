import AppIntents
import ColophonShared
import SwiftUI
import WidgetKit

/// The widget extension's `@main` entry point. `ContinueListeningWidget` (M2b Task 2) is the home
/// widget; `PlayPauseControlWidget` (M2b Task 3, iOS-only) is the Control Center / Lock Screen
/// play-pause control; `NowPlayingLiveActivity` (M2b Task 4, iOS-only) is the now-playing Live
/// Activity (Lock Screen + Dynamic Island).
@main
struct ColophonWidgetsBundle: WidgetBundle {
    init() {
        #if os(iOS)
        // Fallback so a playback intent that (rarely) performs in THIS extension process resolves its
        // `@Dependency` to an inert handler instead of trapping on an unregistered dependency. The
        // meaningful path is the intent running in the APP process, where the LIVE provider is
        // registered (`AudioPlaybackIntentBridge`); the extension can't reach the live player across
        // the process boundary.
        let provider = PlaybackControlProvider(handler: NoOpPlaybackCommanding())
        AppDependencyManager.shared.add(dependency: provider)
        #endif
    }

    @WidgetBundleBuilder
    var body: some Widget {
        ContinueListeningWidget()
        #if os(iOS)
        PlayPauseControlWidget()
        NowPlayingLiveActivity()
        #endif
    }
}
