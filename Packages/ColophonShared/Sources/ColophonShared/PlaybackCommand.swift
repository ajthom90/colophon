import Foundation

/// A discrete playback command a companion surface (the Control Center / Lock Screen control, a Live
/// Activity button, a Siri/Shortcuts phrase) asks the RUNNING app to perform. The command VOCABULARY
/// lives in `ColophonShared` so a single definition is shared by the App Intents (which produce a
/// command) and the app (which applies it to the live `PlaybackController`). Deliberately tiny +
/// `Sendable`: it carries no player reference, only the intent of the action.
public enum PlaybackCommand: Sendable, Equatable {
    case play
    case pause
    case togglePlayPause
    case skipForward
    case skipBackward
}

/// The minimal MainActor surface a `PlaybackCommand` is applied against — exactly the subset of
/// `PlayerEngine.PlaybackController` the companion controls need. The app conforms its LIVE controller
/// to this with a retroactive, empty-body conformance (the controller already has every member), so an
/// App Intent resolved in the running-app process reaches the real player. A test conforms a fake to
/// assert `applyPlaybackCommand` without a live player OR a live intent host.
@MainActor
public protocol PlaybackCommanding: AnyObject {
    var isPlaying: Bool { get }
    /// Seconds a single skip-forward/back jumps (the Settings-driven interval); a skip command reads
    /// it LIVE so Control Center's skip matches the in-app / lock-screen skip distance.
    var skipInterval: Int { get }
    func play()
    func pause()
    func togglePlayPause()
    func skip(_ seconds: Double)
}

/// The command → player step, factored out as a small PURE function so the mapping (which command
/// calls which player method, and that a skip reads the live `skipInterval`) is unit-testable against
/// a fake `PlaybackCommanding` WITHOUT a live intent host or a real audio session. Every playback
/// intent's `perform()` funnels through here (via `PlaybackControlProvider`), so the tested mapping is
/// the exact one that runs in production.
@MainActor
public func applyPlaybackCommand(_ command: PlaybackCommand, to handler: any PlaybackCommanding) {
    switch command {
    case .play: handler.play()
    case .pause: handler.pause()
    case .togglePlayPause: handler.togglePlayPause()
    case .skipForward: handler.skip(Double(handler.skipInterval))
    case .skipBackward: handler.skip(-Double(handler.skipInterval))
    }
}

/// The App Intents dependency the app registers at launch (`AppDependencyManager.shared.add`) and
/// every playback intent resolves via `@Dependency`. It wraps the app's LIVE `PlaybackCommanding`
/// (the running `PlaybackController`) so an intent's `perform()`, when it runs in the app process,
/// reaches the real player. `isPlaying` is exposed for symmetry/testing; the Control Center control
/// reads its on/off state from the published `NowPlayingSnapshot` instead (it runs in a separate
/// process and cannot see the app's in-memory state).
@MainActor
public final class PlaybackControlProvider {
    private let handler: any PlaybackCommanding
    public init(handler: any PlaybackCommanding) { self.handler = handler }
    public var isPlaying: Bool { handler.isPlaying }
    public func perform(_ command: PlaybackCommand) { applyPlaybackCommand(command, to: handler) }
}

/// A no-op `PlaybackCommanding` the widget extension registers as its `@Dependency` fallback: if the
/// system ever runs a playback intent in the EXTENSION process (rather than the app), resolving the
/// dependency there returns this instead of trapping on an unregistered dependency. It can't reach the
/// live player across the process boundary — the meaningful path is the intent running IN the app,
/// where the live provider is registered — so here the command is intentionally inert.
@MainActor
public final class NoOpPlaybackCommanding: PlaybackCommanding {
    public init() {}
    public var isPlaying: Bool { false }
    public var skipInterval: Int { 30 }
    public func play() {}
    public func pause() {}
    public func togglePlayPause() {}
    public func skip(_ seconds: Double) {}
}
