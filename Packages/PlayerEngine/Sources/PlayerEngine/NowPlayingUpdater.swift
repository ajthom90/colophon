import Foundation
import MediaPlayer

@MainActor
final class NowPlayingUpdater {
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
        // Read once, up front: `controller.skipInterval` is set by `AppState.startPlayback`
        // BEFORE `PlaybackController.load()` calls this method, so both the advertised
        // interval and the handler's jump distance always agree with the Settings preference
        // (10/15/30/45) in effect for this playback session.
        let skipInterval = controller.skipInterval
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipForwardCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.skip(Double(skipInterval)) }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.addTarget { [weak controller] _ in
            Task { @MainActor in controller?.skip(-Double(skipInterval)) }; return .success
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
            MPMediaItemPropertyPlaybackDuration: controller.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.globalTime,
            MPNowPlayingInfoPropertyPlaybackRate: controller.isPlaying ? controller.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: controller.rate,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // Required on macOS or media keys / Control Center ignore the app.
        MPNowPlayingInfoCenter.default().playbackState = controller.isPlaying ? .playing : .paused
        #endif
    }

    func updateElapsed(controller: PlaybackController) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.globalTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = controller.isPlaying ? controller.rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
