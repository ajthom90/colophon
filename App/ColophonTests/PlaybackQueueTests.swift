import Testing
import Foundation
@testable import Colophon

/// Pure, audio-free proof for `PlaybackQueue` (Task 8) — the up-next queue's mutations and, most
/// importantly, the `peekNextPlayable(validConnectionIDs:)` ADVANCE DECISION (return the front, drop
/// entries whose connection is gone). No `PlaybackController`, no network — the queue is the whole
/// unit under test. `AppState`'s wiring of this decision to real playback is proven separately in
/// `AppStateTests` (the `advanceToNext*` tests).
@MainActor
struct PlaybackQueueTests {

    private func entry(_ item: String, connection: String = "C1", title: String? = nil) -> QueueEntry {
        QueueEntry(itemID: item, connectionID: connection, title: title ?? "Title \(item)", author: "Author")
    }

    // MARK: - Insert order

    @Test func playNextInsertsFront_addToQueueAppends() {
        let queue = PlaybackQueue()

        queue.addToQueue(entry("A"))          // [A]
        queue.addToQueue(entry("B"))          // [A, B]
        queue.playNext(entry("C"))            // [C, A, B]  ← jumps the front

        #expect(queue.entries.map(\.itemID) == ["C", "A", "B"])

        queue.playNext(entry("D"))            // [D, C, A, B]
        #expect(queue.entries.map(\.itemID) == ["D", "C", "A", "B"])
    }

    // MARK: - Reorder + remove

    @Test func reorderAndRemoveMutateQueueCorrectly() {
        let queue = PlaybackQueue()
        for id in ["A", "B", "C", "D"] { queue.addToQueue(entry(id)) }   // [A, B, C, D]

        // Move A (index 0) to the end → [B, C, D, A].
        queue.move(from: IndexSet(integer: 0), to: 4)
        #expect(queue.entries.map(\.itemID) == ["B", "C", "D", "A"])

        // Remove index 1 (C) → [B, D, A].
        queue.remove(at: IndexSet(integer: 1))
        #expect(queue.entries.map(\.itemID) == ["B", "D", "A"])

        queue.clear()
        #expect(queue.isEmpty)
    }

    // MARK: - The advance decision (peekNextPlayable — peek-then-commit)

    /// Peek returns the front playable entry but LEAVES it in the queue (peek-then-commit); it's
    /// only removed once the caller has actually started it via `remove(_:)`.
    @Test func peekReturnsFrontWithoutConsuming_commitRemovesIt() {
        let queue = PlaybackQueue()
        queue.addToQueue(entry("A"))
        queue.addToQueue(entry("B"))

        let next = queue.peekNextPlayable(validConnectionIDs: ["C1"])
        #expect(next?.itemID == "A")
        #expect(queue.entries.map(\.itemID) == ["A", "B"])   // NOT consumed by the peek

        // A repeated peek (e.g. a superseded advance) still returns A — it wasn't lost.
        #expect(queue.peekNextPlayable(validConnectionIDs: ["C1"])?.itemID == "A")

        // The commit — only after the caller actually started A — drops it.
        queue.remove(next!)
        #expect(queue.entries.map(\.itemID) == ["B"])
    }

    @Test func peekReturnsNilWhenEmpty() {
        let queue = PlaybackQueue()
        #expect(queue.peekNextPlayable(validConnectionIDs: ["C1"]) == nil)
    }

    /// The removed-connection guard: leading entries whose connection isn't in the valid set are
    /// DROPPED (unreachable), and the first entry from a still-playable connection is returned —
    /// but NOT consumed (it stays until committed). If nothing playable remains, returns nil.
    @Test func queuedItemFromRemovedConnectionIsSkippedOrDropped() {
        let queue = PlaybackQueue()
        queue.addToQueue(entry("A", connection: "GONE"))    // owning connection removed
        queue.addToQueue(entry("B", connection: "GONE"))    // ditto
        queue.addToQueue(entry("C", connection: "C1"))      // still valid

        // Only C1 is valid → A and B are dropped, C is returned (left in place).
        let next = queue.peekNextPlayable(validConnectionIDs: ["C1"])
        #expect(next?.itemID == "C")
        #expect(queue.entries.map(\.itemID) == ["C"])        // A, B dropped; C peeked, not consumed

        // A queue of ONLY dead entries yields nil (→ the caller stops) and drains them.
        let deadOnly = PlaybackQueue()
        deadOnly.addToQueue(entry("X", connection: "GONE"))
        #expect(deadOnly.peekNextPlayable(validConnectionIDs: ["C1"]) == nil)
        #expect(deadOnly.isEmpty)
    }

    @Test func removeEntriesDropsOnlyThatConnection() {
        let queue = PlaybackQueue()
        queue.addToQueue(entry("A", connection: "C1"))
        queue.addToQueue(entry("B", connection: "C2"))
        queue.addToQueue(entry("C", connection: "C1"))

        queue.removeEntries(connectionID: "C1")
        #expect(queue.entries.map(\.itemID) == ["B"])       // only C2's entry survives
    }

    // MARK: - Duplicate identity

    /// The SAME book queued twice is two DISTINCT rows (per-entry UUID identity), so removing one
    /// leaves the other — the reorderable List stays stable across duplicates.
    @Test func sameItemQueuedTwiceAreDistinctRows() {
        let queue = PlaybackQueue()
        queue.addToQueue(entry("A"))
        queue.addToQueue(entry("A"))
        #expect(queue.entries.count == 2)
        #expect(queue.entries[0].id != queue.entries[1].id)

        queue.remove(at: IndexSet(integer: 0))
        #expect(queue.entries.count == 1)                   // the other A survives
    }
}
