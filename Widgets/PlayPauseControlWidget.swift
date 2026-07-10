#if os(iOS)
import AppIntents
import ColophonShared
import SwiftUI
import WidgetKit

/// The Control Center / Lock Screen play-pause control (M2b Task 3, iOS 18+). A `ControlWidgetToggle`
/// whose on/off state REFLECTS the app's live `isPlaying` — read from the `NowPlayingSnapshot` the app
/// publishes into the App Group (this control runs in a SEPARATE process and can't see the app's
/// in-memory state) — and whose toggle invokes `SetPlaybackIntent`, reaching the running app's LIVE
/// `PlaybackController` via the App Intents `@Dependency` bridge.
///
/// This is the NEW Control-Center-gallery toggle. It is ADDITIVE to the existing `MPRemoteCommandCenter`
/// now-playing media controls (`NowPlayingUpdater`), which are untouched. iOS-only: it lives in the
/// iOS-only `ColophonWidgets` extension and is additionally `#if os(iOS)`-gated so the macOS build never
/// sees it.
struct PlayPauseControlWidget: ControlWidget {
    static let kind = "com.andrewthom.colophon.control.playpause"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isPlaying in
            ControlWidgetToggle(
                "Now Playing",
                isOn: isPlaying,
                action: SetPlaybackIntent()
            ) { playing in
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Play/Pause")
        .description("Play or pause the current audiobook.")
    }

    /// Feeds the control its on/off state: `isPlaying` from the app-published now-playing snapshot in
    /// the App Group. The app pushes `ControlCenter.shared.reloadAllControls()` on every snapshot change
    /// (`SnapshotPublisher`) so this re-reads promptly when playback starts/pauses.
    struct Provider: ControlValueProvider {
        let previewValue = false

        func currentValue() async throws -> Bool {
            SharedStore(appGroupID: ColophonAppGroup.identifier).readNowPlaying()?.isPlaying ?? false
        }
    }
}
#endif
