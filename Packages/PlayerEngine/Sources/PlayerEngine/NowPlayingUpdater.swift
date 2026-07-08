import Foundation
import MediaPlayer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class NowPlayingUpdater {
    /// The last-built cover artwork and the exact bytes it was built from, so `update()` (called on
    /// every play/pause/seek/rate change) reuses the same `MPMediaItemArtwork` instead of re-decoding
    /// the image each time. Rebuilt only when `controller.artworkData` actually changes (including to
    /// `nil` on a fresh book), keyed by `Data` equality.
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkData: Data?

    func configure(controller: PlaybackController) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        // Remote-command handlers are NOT guaranteed to arrive on the main thread,
        // so hop onto the MainActor with Task rather than assuming isolation.
        center.playCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.play() }; return .success
        }
        center.pauseCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.togglePlayPause() }; return .success
        }
        // The ADVERTISED interval is seeded from the value in force at `load()` time
        // (`AppState.startPlayback` sets `controller.skipInterval` before `load()` calls this). The
        // HANDLERS read `controller.skipInterval` LIVE, not a captured copy, so a mid-session
        // Settings change updates the jump distance immediately; `refreshSkipInterval(controller:)`
        // then re-advertises the new `preferredIntervals` (Task 9 follow-up A) so the OS-displayed
        // skip glyph (e.g. "15"/"30") tracks it too, without reloading the session.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: controller.skipInterval)]
        center.skipForwardCommand.addTarget { [weak controller] _ in
            Task { @MainActor in
                guard let controller else { return }
                controller.skip(Double(controller.skipInterval))
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: controller.skipInterval)]
        center.skipBackwardCommand.addTarget { [weak controller] _ in
            Task { @MainActor in
                guard let controller else { return }
                controller.skip(-Double(controller.skipInterval))
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak controller] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in controller?.seek(toGlobal: target) }
            return .success
        }
        update(controller: controller)
    }

    func update(controller: PlaybackController) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: controller.title,
            MPMediaItemPropertyArtist: controller.author,
            // The book title as the "album" too, so the current CHAPTER can take the prominent title
            // slot below (Apple Books' audiobook convention) while the book stays identifiable.
            MPMediaItemPropertyAlbumTitle: controller.title,
            MPMediaItemPropertyPlaybackDuration: controller.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.globalTime,
            MPNowPlayingInfoPropertyPlaybackRate: controller.isPlaying ? controller.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: controller.rate,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        // Current CHAPTER (Task 9): reflect the book's chapter position on the lock screen /
        // Control Center / Now Playing menu via the API's dedicated chapter fields, and surface the
        // chapter's TITLE as the prominent now-playing title (book title is preserved as the album
        // above). No chapters → the book title stays the title and the chapter fields are omitted.
        if let index = chapterIndex(for: controller) {
            info[MPNowPlayingInfoPropertyChapterNumber] = NSNumber(value: index)
            info[MPNowPlayingInfoPropertyChapterCount] = NSNumber(value: controller.chapters.count)
            if let chapterTitle = controller.chapters[index].title, !chapterTitle.isEmpty {
                info[MPMediaItemPropertyTitle] = chapterTitle
            }
        }
        // Cover artwork (Task 9): built from the bytes AppState hands the controller via
        // `setNowPlayingArtwork`, cached so this hot path doesn't re-decode the image each call.
        if let artwork = artwork(for: controller) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // Required on macOS or media keys / Control Center ignore the app.
        MPNowPlayingInfoCenter.default().playbackState = controller.isPlaying ? .playing : .paused
        #endif
    }

    /// Re-advertise the controller's CURRENT `skipInterval` to the remote-command center's
    /// skip-forward/back `preferredIntervals` WITHOUT reconfiguring the whole command set — for a
    /// live Settings change mid-session (see `PlaybackController.refreshRemoteSkipInterval`). The
    /// skip handlers already read `controller.skipInterval` live, so the jump distance follows the
    /// setting immediately; this keeps the interval the OS DISPLAYS on the skip buttons in sync too.
    func refreshSkipInterval(controller: PlaybackController) {
        let center = MPRemoteCommandCenter.shared()
        let interval = NSNumber(value: controller.skipInterval)
        center.skipForwardCommand.preferredIntervals = [interval]
        center.skipBackwardCommand.preferredIntervals = [interval]
    }

    /// Index of the chapter containing the current global time (`start ≤ t`), or `nil` when the book
    /// has no chapters. Chapters arrive from the server in start order (global seconds).
    private func chapterIndex(for controller: PlaybackController) -> Int? {
        let chapters = controller.chapters
        guard !chapters.isEmpty else { return nil }
        let t = controller.globalTime
        return chapters.lastIndex { $0.start <= t } ?? 0
    }

    /// The cover artwork for the current book, rebuilt only when `controller.artworkData` changes
    /// (keyed by `Data` equality — both-nil reuses the nil result). The cache bookkeeping stays on
    /// the MainActor; the actual `MPMediaItemArtwork` is built by the `nonisolated` helper below.
    private func artwork(for controller: PlaybackController) -> MPMediaItemArtwork? {
        let data = controller.artworkData
        if data == cachedArtworkData { return cachedArtwork }
        cachedArtworkData = data
        cachedArtwork = data.flatMap(Self.makeArtwork(from:))
        return cachedArtwork
    }

    /// Builds `MPMediaItemArtwork` in a NONISOLATED context on purpose: MediaPlayer renders artwork
    /// LAZILY and calls the `requestHandler` on its OWN background queue (`*/accessQueue`). A handler
    /// closure formed inside this `@MainActor` class inherits MainActor isolation, so Swift 6 injects
    /// an executor assertion into it — which trips when MediaPlayer invokes it off-main and CRASHES
    /// the app (verified: `EXC_BREAKPOINT` in `_swift_task_checkIsolatedSwift`). Forming the closure
    /// here, with no isolation, is what makes the lazy off-main render safe. Cross-platform: `NSImage`
    /// on macOS, `UIImage` elsewhere.
    private nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        #else
        guard let image = UIImage(data: data) else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func updateElapsed(controller: PlaybackController) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.globalTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = controller.isPlaying ? controller.rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
