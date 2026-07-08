import Testing
import Foundation
@testable import Colophon

/// Pure, audio-free proof for `PlaybackQueue` (Task 8) — the up-next queue's mutations and, most
/// importantly, the `nextPlayable(validConnectionIDs:)` ADVANCE DECISION (dequeue the front, drop
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

    // MARK: - The advance decision (nextPlayable)

    @Test func nextPlayablePopsFrontAndReturnsIt() {
        let queue = PlaybackQueue()
        queue.addToQueue(entry("A"))
        queue.addToQueue(entry("B"))

        let next = queue.nextPlayable(validConnectionIDs: ["C1"])
        #expect(next?.itemID == "A")
        #expect(queue.entries.map(\.itemID) == ["B"])   // A popped, B remains
    }

    @Test func nextPlayableReturnsNilWhenEmpty() {
        let queue = PlaybackQueue()
        #expect(queue.nextPlayable(validConnectionIDs: ["C1"]) == nil)
    }

    /// The removed-connection guard: leading entries whose connection isn't in the valid set are
    /// DROPPED, and the first entry from a still-valid connection is returned (its dead predecessors
    /// removed from the queue). If nothing playable remains, returns nil.
    @Test func queuedItemFromRemovedConnectionIsSkippedOrDropped() {
        let queue = PlaybackQueue()
        queue.addToQueue(entry("A", connection: "GONE"))    // owning connection removed
        queue.addToQueue(entry("B", connection: "GONE"))    // ditto
        queue.addToQueue(entry("C", connection: "C1"))      // still valid

        // Only C1 is valid → A and B are dropped, C is returned.
        let next = queue.nextPlayable(validConnectionIDs: ["C1"])
        #expect(next?.itemID == "C")
        #expect(queue.isEmpty)                               // A, B dropped and C popped

        // A queue of ONLY dead entries yields nil (→ the caller stops).
        let deadOnly = PlaybackQueue()
        deadOnly.addToQueue(entry("X", connection: "GONE"))
        #expect(deadOnly.nextPlayable(validConnectionIDs: ["C1"]) == nil)
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
