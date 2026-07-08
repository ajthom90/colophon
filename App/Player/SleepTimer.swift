import Foundation
import ABSKit
import PlayerEngine

/// The engine surface `SleepTimer` fires against — narrowed to exactly what the timer needs so the
/// fire logic is testable against a trivial fake instead of a full `PlaybackController`/AVFoundation
/// stack. `PlaybackController` conforms as-is (it already exposes `isPlaying`/`globalTime`, and
/// Task 5 added `fadeOutAndPause`).
@MainActor
protocol SleepTimerHost: AnyObject {
    var isPlaying: Bool { get }
    /// Current position in GLOBAL book seconds — drives the End-of-Chapter fire check.
    var globalTime: TimeInterval { get }
    /// Fade the volume to 0 over `duration` seconds, then pause (see `PlaybackController`).
    func fadeOutAndPause(over duration: TimeInterval)
}

extension PlaybackController: SleepTimerHost {
    func fadeOutAndPause(over duration: TimeInterval) { fadeOutAndPause(over: duration, steps: 20) }
}

/// The audiobook sleep timer — presets, an End-of-Chapter mode, and a live countdown, firing a
/// gentle fade-out + pause on the shared `PlaybackController` when it reaches its deadline.
///
/// Owned by `AppState` (NOT recreated per view body) so an armed timer survives the player being
/// dismissed and keeps counting while you listen. The player's `SleepTimerView` reads/arms it.
///
/// ## Testability (the deliverable's proof)
/// The FIRE LOGIC is decoupled from wall-clock time and AVFoundation: an injected `now` closure
/// supplies the clock, the `SleepTimerHost` seam stands in for the controller, and `tick()` is the
/// single place a deadline is evaluated. Production drives `tick()` from a 1 Hz `Task` loop
/// (`autoTick`); unit tests advance the injected clock and call `tick()` directly — NO real sleeps.
///
/// ## Countdown semantics (HIG decision — documented per the task)
/// - **Presets** count down against *listening* time: the remaining budget is decremented by
///   elapsed wall time ONLY while the book is playing. Pausing the book pauses the countdown (the
///   audiobook idiom — Apple Books / Audiobookshelf both do this), so a paused book never fades
///   itself out from under you, and resuming picks the countdown back up.
/// - **End of Chapter** is inherently position-based: it fires when playback reaches the current
///   chapter's end (global seconds), so it too is naturally paused-aware.
/// - **Background:** the app keeps playing audio in the background (M1a). The 1 Hz ticker may be
///   throttled while suspended, but because the preset budget is decremented by *elapsed* wall time
///   whenever a tick does land, background listening still drains the budget and the timer fires
///   (possibly a few seconds late) on the next delivered tick. Precise sub-second background firing
///   is not guaranteed — an acceptable limitation for a sleep timer.
@Observable
@MainActor
final class SleepTimer {
    /// The armed mode. `.off` means idle; `.preset` counts down `minutes`; `.endOfChapter` fires at
    /// the current chapter boundary.
    enum Mode: Equatable {
        case off
        case preset(minutes: Int)
        case endOfChapter
    }

    /// Preset durations surfaced by the menu (minutes).
    static let presetMinutes = [5, 10, 15, 30, 45, 60]

    private(set) var mode: Mode = .off
    /// Seconds until fire, updated ~1/sec while armed; `nil` when off. Drives the countdown label.
    private(set) var remaining: TimeInterval?

    /// The current book's chapters (GLOBAL seconds), pushed by `AppState` on `startPlayback` and
    /// cleared on retire — the source for End-of-Chapter's boundary.
    var chapters: [Chapter] = []

    private weak var host: SleepTimerHost?
    private let now: () -> Date
    private let fadeDuration: TimeInterval
    private let autoTick: Bool

    // Preset accounting: a listening-time budget decremented only while playing.
    private var budget: TimeInterval = 0
    private var lastTick: Date = .distantPast
    // End-of-Chapter target in global seconds.
    private var chapterEndTarget: TimeInterval?

    private var ticker: Task<Void, Never>?

    /// - Parameters:
    ///   - host: the playback surface to fade/pause and read position from (nil-safe; `weak`).
    ///   - now: injected clock (tests supply a controllable one; production uses `Date`).
    ///   - fadeDuration: seconds of fade-out on fire (~5s; injectable so tests needn't wait).
    ///   - autoTick: production spins a 1 Hz ticker on arm; tests pass `false` and drive `tick()`.
    init(host: SleepTimerHost?,
         now: @escaping () -> Date = Date.init,
         fadeDuration: TimeInterval = 5,
         autoTick: Bool = true) {
        self.host = host
        self.now = now
        self.fadeDuration = fadeDuration
        self.autoTick = autoTick
    }

    // MARK: - Derived UI state

    var isArmed: Bool { mode != .off }

    /// The active preset's minutes, for a menu checkmark; nil unless a preset is armed.
    var activePresetMinutes: Int? {
        if case .preset(let m) = mode { return m }
        return nil
    }

    var isEndOfChapter: Bool { mode == .endOfChapter }

    /// Countdown string for the glass control (pair with `.monospacedDigit()`); nil when off.
    var remainingLabel: String? { remaining.map { PlayerModel.timeString($0) } }

    // MARK: - Arming / editing

    func arm(_ newMode: Mode) {
        switch newMode {
        case .off:
            turnOff()
        case .preset(let minutes):
            mode = .preset(minutes: minutes)
            budget = Double(minutes) * 60
            lastTick = now()
            chapterEndTarget = nil
            remaining = budget
            startTicking()
        case .endOfChapter:
            // Fire at the END of the chapter the book is currently in. Reuses PlayerModel's
            // (tested) chapter derivation — no duplicated boundary math.
            let t = host?.globalTime ?? 0
            guard let end = Self.endOfChapterFireTime(chapters: chapters, at: t), end > t else {
                // No chapters (or already at/past the last boundary): nothing to arm against.
                turnOff()
                return
            }
            mode = .endOfChapter
            chapterEndTarget = end
            budget = 0
            remaining = max(end - t, 0)
            startTicking()
        }
    }

    /// "Add time" / extend. For a preset this grows the remaining listening budget; for
    /// End-of-Chapter it pushes the fire boundary out. No-op when off.
    func addTime(minutes: Int) {
        guard isArmed else { return }
        let delta = Double(minutes) * 60
        switch mode {
        case .off:
            return
        case .preset(let current):
            // Keep the mode's label sensible by folding the extension into the nominal minutes.
            mode = .preset(minutes: current + minutes)
            budget += delta
            remaining = max(budget, 0)
        case .endOfChapter:
            let base = chapterEndTarget ?? (host?.globalTime ?? 0)
            chapterEndTarget = base + delta
            remaining = max(base + delta - (host?.globalTime ?? 0), 0)
        }
    }

    /// Cancel — disarm and stop the ticker. The book keeps playing.
    func turnOff() {
        mode = .off
        remaining = nil
        budget = 0
        chapterEndTarget = nil
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Tick / fire (the injected-clock unit-test seam)

    /// Evaluate the deadline once. Production calls this ~1/sec; tests call it after advancing the
    /// injected clock (or the host's `globalTime`). Fires exactly once when the deadline is reached.
    func tick() {
        switch mode {
        case .off:
            return
        case .preset:
            let t = now()
            if host?.isPlaying == true {
                budget -= t.timeIntervalSince(lastTick)
            }
            lastTick = t
            remaining = max(budget, 0)
            if budget <= 0 { fire() }
        case .endOfChapter:
            let target = chapterEndTarget ?? (host?.globalTime ?? 0)
            let current = host?.globalTime ?? 0
            remaining = max(target - current, 0)
            if current >= target { fire() }
        }
    }

    private func fire() {
        let host = self.host
        turnOff()                                 // disarm FIRST, so we never double-fire
        host?.fadeOutAndPause(over: fadeDuration)  // then fade + pause the book
    }

    private func startTicking() {
        ticker?.cancel()
        guard autoTick else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    // MARK: - Shared boundary helper

    /// The global-seconds time End-of-Chapter should fire at for a position `time`: the END of the
    /// chapter that contains `time`. Delegates to `PlayerModel.chapter(at:in:)` (the single, tested
    /// chapter-containment derivation the scrubber/chapter-list also use) so there's no duplicated
    /// boundary logic. Returns nil for an empty chapter list.
    static func endOfChapterFireTime(chapters: [Chapter], at time: TimeInterval) -> TimeInterval? {
        PlayerModel.chapter(at: time, in: chapters)?.end
    }
}
