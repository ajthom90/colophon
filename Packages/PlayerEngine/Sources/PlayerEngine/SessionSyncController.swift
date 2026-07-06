import Foundation

public struct SyncPayload: Equatable, Sendable {
    public let currentTime: Double
    public let timeListened: Double
    public init(currentTime: Double, timeListened: Double) {
        self.currentTime = currentTime; self.timeListened = timeListened
    }
}

/// Accumulates listened-time deltas and decides when a session sync is due.
/// `timeListened` semantics per ABS server: seconds listened SINCE LAST SUCCESSFUL sync.
public struct SessionSyncController: Sendable {
    private let interval: TimeInterval
    private var accumulatedListened: Double = 0
    private var lastEmission: Date?
    private var pendingEmission: Double = 0

    public init(interval: TimeInterval = 15) {
        self.interval = interval
    }

    /// First payload emits once ≥ interval seconds of listened time accumulate; thereafter a payload emits when ≥ interval wall-clock seconds have passed since the last emission.
    public mutating func noteProgress(currentTime: TimeInterval, listenedDelta: TimeInterval, now: Date) -> SyncPayload? {
        accumulatedListened += max(0, listenedDelta)
        let due = lastEmission.map { now.timeIntervalSince($0) >= interval } ?? (accumulatedListened >= interval)
        guard due else { return nil }
        lastEmission = now
        pendingEmission = accumulatedListened
        return SyncPayload(currentTime: currentTime, timeListened: accumulatedListened)
    }

    /// Consume ONLY the amount carried by the last emitted/flushed payload —
    /// seconds accrued while that sync was in flight stay accumulated.
    public mutating func didSync() {
        accumulatedListened = max(0, accumulatedListened - pendingEmission)
        pendingEmission = 0
    }

    public mutating func flush(currentTime: TimeInterval) -> SyncPayload? {
        guard accumulatedListened > 0 else { return nil }
        pendingEmission = accumulatedListened
        return SyncPayload(currentTime: currentTime, timeListened: accumulatedListened)
    }
}
