import Foundation
import ColophonShared
#if os(iOS)
import WidgetKit
#endif

/// Publishes the app's now-playing + continue-listening snapshots into the App Group container so the
/// companion extensions (widgets / Live Activity / Control Center — separate processes that can't
/// read the app's in-memory `@Observable` state) can render them, then nudges WidgetKit to reload.
///
/// SECURITY: writes ONLY display snapshots + cover thumbnails through `SharedStore`. Tokens and
/// credentials never touch the App Group — they stay device-local in the Keychain.
@MainActor
struct SnapshotPublisher {
    let store: SharedStore

    init(store: SharedStore = SharedStore(appGroupID: ColophonAppGroup.identifier)) {
        self.store = store
    }

    /// Write (or, for `nil`, clear) the now-playing snapshot, then reload widget timelines.
    func publishNowPlaying(_ snapshot: NowPlayingSnapshot?) {
        if let snapshot {
            store.writeNowPlaying(snapshot)
        } else {
            store.clearNowPlaying()
        }
        reloadWidgets()
    }

    /// Write the continue-listening snapshot, then reload widget timelines.
    func publishContinueListening(_ snapshot: ContinueListeningSnapshot) {
        store.writeContinueListening(snapshot)
        reloadWidgets()
    }

    /// Clear the continue-listening snapshot (sign-out / connection removal), then reload widget
    /// timelines so the home widget drops the signed-out connection's shelf (M2b Task 5).
    func clearContinueListening() {
        store.clearContinueListening()
        reloadWidgets()
    }

    /// Persist a cover thumbnail into the container, returning its container-relative path.
    @discardableResult
    func writeArtwork(_ data: Data, forKey key: String) -> String? {
        store.writeArtwork(data, forKey: key)
    }

    private func reloadWidgets() {
        #if os(iOS)
        // Mirror the serif/default typeface preference (`@AppStorage("colophon.typeface")`,
        // `ColophonApp.swift`) into the App Group so the (separate-process) widget can match the
        // app's typography — piggybacked here since this already runs on every relevant snapshot
        // change, so no dedicated `onChange` observation is needed.
        store.writeTypefacePreference(UserDefaults.standard.string(forKey: "colophon.typeface") ?? "serif")
        // Live Activity + Control Center are iOS-only; the home widget also lives on iOS first.
        WidgetCenter.shared.reloadAllTimelines()
        // The Control Center / Lock Screen play-pause control (M2b Task 3) reads `isPlaying` from the
        // now-playing snapshot via its `ControlValueProvider`; `reloadAllTimelines()` does NOT refresh
        // controls, so nudge them too so the toggle reflects the new play/pause state promptly.
        ControlCenter.shared.reloadAllControls()
        #endif
    }
}
