#if os(iOS)
import ActivityKit
import ColophonShared
import Foundation

/// The real ActivityKit-backed `ActivityManaging` (M2b Task 4, iOS-only). Wraps AT MOST ONE
/// `Activity<NowPlayingActivityAttributes>` and translates the cross-platform `LiveActivityState` into
/// ActivityKit's attributes + content. The start/update/end ORDERING (and the "exactly one" invariant)
/// is decided by `LiveActivityController`; this type just performs each op.
///
/// Concurrency: `Activity.update`/`end` are async and fired off the retained handle. `start` is
/// DEFERRED behind two things so a new Activity is never requested while another is (briefly) live:
///   1. Any prior-run Activity teardown (`cleanupTask`) — the app was killed while one was live, and
///      `init` ends it asynchronously; a start must wait for that to finish (else a fast
///      cold-launch → play could request a NEW Activity while the stale one is still ending, a
///      transient "two live" violation).
///   2. The synchronous start→update pair the app emits on every playback start (`load()` publishes a
///      paused snapshot, then `play()` a playing one). Deferring the request by one MainActor hop lets
///      the immediate `update` fold into `pendingContent` FIRST, so the Activity is requested directly
///      in its final (playing) state instead of flashing paused→playing.
/// `isStarting` reports the Activity as active the instant `start` is called (before the async request
/// lands), so `LiveActivityController`'s bookkeeping stays consistent. All ActivityKit calls are MainActor.
@MainActor
final class LiveActivityManager: ActivityManaging {
    private var activity: Activity<NowPlayingActivityAttributes>?
    /// Prior-run Activity teardown kicked off in `init`; a first `start` awaits it before requesting a
    /// new Activity. Cleared once awaited.
    private var cleanupTask: Task<Void, Never>?
    /// True between `start` being called and its async `Activity.request` landing (or being cancelled),
    /// so `isActive` reports live immediately.
    private var isStarting = false
    /// The latest content for the in-flight start — an `update` arriving before the request lands folds
    /// into this, so the request goes out with the newest state.
    private var pendingContent: ActivityContent<NowPlayingActivityAttributes.ContentState>?

    /// On launch, end any Activity left over from a PRIOR run (the app was killed while one was live).
    /// Nothing is playing yet on a fresh launch, so a lingering Activity would be stale/leaked — clear
    /// it (and make a first `start` wait for that teardown) so the only Activity that ever shows is one
    /// this run started.
    init() {
        let stale = Activity<NowPlayingActivityAttributes>.activities
        guard !stale.isEmpty else { return }
        cleanupTask = Task { @MainActor in
            for activity in stale {
                // `Activity` is a non-Sendable class whose async `end` is nonetheless internally
                // thread-safe; `nonisolated(unsafe)` is the documented escape for such an SDK-annotation
                // gap so the handle can be awaited here.
                nonisolated(unsafe) let handle = activity
                await handle.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isActive: Bool { activity != nil || isStarting }

    func start(_ state: LiveActivityState) {
        guard !isActive else { return }
        isStarting = true
        let attributes = NowPlayingActivityAttributes(state: state)
        pendingContent = ActivityContent(
            state: NowPlayingActivityAttributes.ContentState(state: state), staleDate: nil)
        Task { @MainActor in
            // Wait out any prior-run Activity teardown before requesting a new one (nil → no wait).
            await self.cleanupTask?.value
            self.cleanupTask = nil
            // A racing `end` (isStarting flipped false) — or an already-landed request — cancels this;
            // `pendingContent` carries any `update` that arrived while we were deferred.
            guard self.isStarting, self.activity == nil, let content = self.pendingContent else { return }
            self.activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            self.isStarting = false
            self.pendingContent = nil
        }
    }

    func update(_ state: LiveActivityState) {
        let content = ActivityContent(
            state: NowPlayingActivityAttributes.ContentState(state: state), staleDate: nil)
        guard let activity else {
            // The start request hasn't landed yet — fold the newer content into it.
            if isStarting { pendingContent = content }
            return
        }
        // `Activity` is non-Sendable but thread-safe — cross it into the Task via a `nonisolated(unsafe)`
        // handle.
        nonisolated(unsafe) let handle = activity
        Task { @MainActor in await handle.update(content) }
    }

    func end() {
        guard isActive else { return }
        // Cancel a start that hasn't requested yet (its deferred Task then no-ops), so a stop during the
        // start window never leaks an Activity.
        isStarting = false
        pendingContent = nil
        guard let activity else { return }
        // Drop the reference synchronously (so `isActive` is false at once) and fire the async end off
        // the captured handle.
        self.activity = nil
        nonisolated(unsafe) let handle = activity
        Task { @MainActor in await handle.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
