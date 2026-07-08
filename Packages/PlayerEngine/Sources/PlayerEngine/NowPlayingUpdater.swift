import Foundation
import ABSKit
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

    /// The chapter index last written to the now-playing surface, so the per-tick `updateElapsed`
    /// refreshes the chapter fields ONLY when the book crosses into a new chapter (not every tick).
    /// Re-established by `update()` on every discrete action and reset by `clear()`.
    private var lastChapterIndex: Int?
    /// Test seam: how many times a TICK (`updateElapsed`) refreshed the chapter fields because the
    /// chapter index changed. Lets `NowPlayingUpdaterTests` assert a boundary crossing refreshes
    /// exactly once without reading the shared `MPNowPlayingInfoCenter` singleton. Not incremented by
    /// `update()` (the discrete-action path).
    private(set) var chapterRefreshCount = 0
    /// Test seam: how many times `clear()` ran (on `PlaybackController.unload`) — the retire path
    /// that tears down the now-playing surface. Unit-testable proxy for "nowPlayingInfo was cleared".
    private(set) var clearCount = 0

    func configure(controller: PlaybackController) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
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
        // Hardware media keys (Mac F7/F9) and BT/CarPlay remotes fire previous/next-TRACK, NOT
        // skip-forward/back — an audiobook has no "tracks" to page, so map them to the SAME
        // skip-by-interval as the skip handlers above (reading `controller.skipInterval` live).
        // `isEnabled` is toggled explicitly (enabled here, disabled in `clear()`) so the commands
        // are advertised only while a session is loaded — and so the wiring is unit-observable.
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak controller] _ in
            Task { @MainActor in
                guard let controller else { return }
                controller.skip(Double(controller.skipInterval))
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak controller] _ in
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
        // Control Center / Now Playing menu via the API's dedicated chapter fields + title. Record
        // the index so the per-tick `updateElapsed` knows when a natural playback crossing needs a
        // chapter refresh.
        let index = chapterIndex(for: controller)
        applyChapterInfo(&info, controller: controller, index: index)
        lastChapterIndex = index
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

    /// Tear down the now-playing surface when the session is retired (book finished / disconnect /
    /// account switch). Without this, `MPNowPlayingInfoCenter.nowPlayingInfo` keeps showing the
    /// retired book's cover/chapter/title on the Lock Screen / Control Center / Now Playing menu,
    /// with play/pause still wired to a torn-down backend (tapping Play would drive a dead
    /// controller). Clears the info dict AND removes the remote-command targets. Called by
    /// `PlaybackController.unload()`.
    func clear() {
        clearCount += 1
        lastChapterIndex = nil
        cachedArtwork = nil
        cachedArtworkData = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// Writes the current-chapter fields (number/count) and the now-playing title into `info` — the
    /// chapter TITLE when there is one (Apple Books' audiobook convention; the book title stays the
    /// album), else the book title, and removes the chapter fields entirely when there are no
    /// chapters. Shared by the full `update` and the per-tick chapter-change refresh so both agree.
    private func applyChapterInfo(_ info: inout [String: Any], controller: PlaybackController, index: Int?) {
        guard let index, index < controller.chapters.count else {
            info.removeValue(forKey: MPNowPlayingInfoPropertyChapterNumber)
            info.removeValue(forKey: MPNowPlayingInfoPropertyChapterCount)
            info[MPMediaItemPropertyTitle] = controller.title
            return
        }
        info[MPNowPlayingInfoPropertyChapterNumber] = NSNumber(value: index)
        info[MPNowPlayingInfoPropertyChapterCount] = NSNumber(value: controller.chapters.count)
        let chapterTitle = controller.chapters[index].title
        info[MPMediaItemPropertyTitle] = (chapterTitle?.isEmpty == false) ? chapterTitle : controller.title
    }

    /// The chapter index for the controller's current global time — the instance convenience over
    /// the pure static below.
    private func chapterIndex(for controller: PlaybackController) -> Int? {
        Self.chapterIndex(at: controller.globalTime, in: controller.chapters)
    }

    /// Index of the chapter containing `time` (`start ≤ time`), or `nil` when there are no chapters.
    /// Pure + `nonisolated` so it's directly unit-testable for boundary correctness. Chapters arrive
    /// from the server in start order (global seconds).
    nonisolated static func chapterIndex(at time: TimeInterval, in chapters: [Chapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        return chapters.lastIndex { $0.start <= time } ?? 0
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
        // A book playing straight across a chapter boundary emits no discrete action (no
        // play/pause/seek), so the chapter would freeze on the Lock Screen / Control Center at
        // whatever it was at the last action. `tick()` drives this method, so refresh the chapter
        // fields + title HERE — but ONLY when the chapter index actually changes, keeping the common
        // per-tick path just time+rate (the artwork is never rebuilt on a tick).
        let index = chapterIndex(for: controller)
        if index != lastChapterIndex {
            lastChapterIndex = index
            chapterRefreshCount += 1
            applyChapterInfo(&info, controller: controller, index: index)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
