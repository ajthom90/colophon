#if os(iOS)
import ActivityKit
import ColophonShared
import Foundation

/// The real ActivityKit-backed `ActivityManaging` (M2b Task 4, iOS-only). Wraps AT MOST ONE
/// `Activity<NowPlayingActivityAttributes>` and translates the cross-platform `LiveActivityState` into
/// ActivityKit's attributes + content. The start/update/end ORDERING (and the "exactly one" invariant)
/// is decided by `LiveActivityController`; this type just performs each op.
///
/// Concurrency: `Activity.request` is SYNCHRONOUS, so `isActive` flips at once — keeping the
/// controller's "exactly one" reasoning race-free — while `update`/`end` are async and fired in a
/// detached `Task` off the retained activity handle. All ActivityKit calls are MainActor.
@MainActor
final class LiveActivityManager: ActivityManaging {
    private var activity: Activity<NowPlayingActivityAttributes>?

    /// On launch, end any Activity left over from a PRIOR run (the app was killed while one was live).
    /// Nothing is playing yet on a fresh launch, so a lingering Activity would be stale/leaked — clear
    /// it so the only Activity that ever shows is one this run started.
    init() {
        for stale in Activity<NowPlayingActivityAttributes>.activities {
            // `Activity` is a non-Sendable class whose async `end` is nonetheless internally thread-safe;
            // `nonisolated(unsafe)` is the documented escape for such an SDK-annotation gap so the handle
            // can cross into the fire-and-forget `Task`.
            nonisolated(unsafe) let handle = stale
            Task { await handle.end(nil, dismissalPolicy: .immediate) }
        }
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isActive: Bool { activity != nil }

    func start(_ state: LiveActivityState) {
        guard activity == nil else { return }
        let attributes = NowPlayingActivityAttributes(state: state)
        let content = ActivityContent(
            state: NowPlayingActivityAttributes.ContentState(state: state), staleDate: nil)
        activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func update(_ state: LiveActivityState) {
        guard let activity else { return }
        let content = ActivityContent(
            state: NowPlayingActivityAttributes.ContentState(state: state), staleDate: nil)
        // See `init`: `Activity` is non-Sendable but thread-safe — cross it into the Task via a
        // `nonisolated(unsafe)` handle.
        nonisolated(unsafe) let handle = activity
        Task { await handle.update(content) }
    }

    func end() {
        guard let activity else { return }
        // Drop the reference synchronously (so `isActive` is false at once) and fire the async end off
        // the captured handle.
        self.activity = nil
        nonisolated(unsafe) let handle = activity
        Task { await handle.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
