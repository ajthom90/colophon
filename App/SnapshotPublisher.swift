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

    /// Persist a cover thumbnail into the container, returning its container-relative path.
    @discardableResult
    func writeArtwork(_ data: Data, forKey key: String) -> String? {
        store.writeArtwork(data, forKey: key)
    }

    private func reloadWidgets() {
        #if os(iOS)
        // Live Activity + Control Center are iOS-only; the home widget also lives on iOS first.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
