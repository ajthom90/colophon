import Foundation

/// One item queued to play AFTER the current book — the minimal display payload the queue List and
/// the advance logic need, captured at enqueue time from the browse row (so the sheet paints
/// instantly without a fetch). `connectionID` records which server the item belongs to, so
/// `PlaybackQueue.nextPlayable(validConnectionIDs:)` can DROP an entry whose connection was later
/// signed out / removed rather than trying to play something unreachable.
///
/// Identity is a per-entry `UUID` (not the item id) so the SAME book queued twice is two distinct,
/// independently-reorderable/removable rows, and SwiftUI's `List(onMove:)`/`onDelete:` stay stable.
/// `coverItemID` is just the item id (covers are `/api/items/:id/cover`), surfaced as a named
/// accessor so call sites read intention-first.
struct QueueEntry: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let itemID: String
    let connectionID: String
    let title: String
    let author: String?

    init(id: UUID = UUID(), itemID: String, connectionID: String, title: String, author: String?) {
        self.id = id
        self.itemID = itemID
        self.connectionID = connectionID
        self.title = title
        self.author = author
    }

    /// The item whose cover art represents this entry (covers are keyed by item id).
    var coverItemID: String { itemID }
}

/// The up-next queue (Task 8): an ordered list of books to play AFTER the current one, owned by
/// `AppState` (NOT recreated per view body) so it survives the player/queue sheet being dismissed.
///
/// IN-MEMORY for v1 — persistence and Handoff/Continuity of the queue are explicitly post-v1 (see
/// the milestone plan's deferred list). The player's `QueueView` reads/reorders it; browse surfaces
/// (`ItemDetailView`, `CoverCard`) enqueue into it via `AppState.playNext`/`addToQueue`; and
/// `AppState.advanceToNext` consumes its front when a book finishes or the user presses Next.
///
/// ## The advance decision (the deliverable's proof, unit-tested)
/// `nextPlayable(validConnectionIDs:)` is the pure, audio-free core: it pops the front entry,
/// skipping (and dropping) any leading entries whose connection is no longer valid, and returns the
/// next PLAYABLE entry or `nil` (→ stop). `AppState.advanceToNext` wires that decision to real
/// playback; the mutation itself is proven directly in `PlaybackQueueTests` with no `PlaybackController`.
@Observable
@MainActor
final class PlaybackQueue {
    /// The queued entries, in play order (index 0 plays next). Read by `QueueView`.
    private(set) var entries: [QueueEntry] = []

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Mutations

    /// Jump an item to the FRONT of the queue (plays immediately after the current book).
    func playNext(_ entry: QueueEntry) { entries.insert(entry, at: 0) }

    /// Append an item to the END of the queue.
    func addToQueue(_ entry: QueueEntry) { entries.append(entry) }

    /// Remove entries at `offsets` — the `List(onDelete:)` / swipe-to-remove hook.
    func remove(at offsets: IndexSet) { entries.remove(atOffsets: offsets) }

    /// Reorder — the `List(onMove:)` hook.
    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Empty the whole queue (the "Clear" action).
    func clear() { entries.removeAll() }

    /// Drop every queued entry belonging to `connectionID` — called when that connection is signed
    /// out or removed, so its now-unreachable items don't linger in the queue (defense-in-depth
    /// alongside `nextPlayable`'s valid-connection guard).
    func removeEntries(connectionID: String) {
        entries.removeAll { $0.connectionID == connectionID }
    }

    // MARK: - The advance decision (pure, unit-tested)

    /// Pop and return the next PLAYABLE entry: dequeues from the front, DROPPING any leading entry
    /// whose `connectionID` isn't in `validConnectionIDs` (its owning connection was signed out /
    /// removed), and returns the first entry that survives — or `nil` when the queue empties without
    /// a playable one (the caller then stops). Mutates the queue (removes the returned entry AND any
    /// dead entries it skipped over). NO audio / no controller — this is the whole advance decision.
    func nextPlayable(validConnectionIDs: Set<String>) -> QueueEntry? {
        while !entries.isEmpty {
            let candidate = entries.removeFirst()
            if validConnectionIDs.contains(candidate.connectionID) {
                return candidate
            }
            // else: the entry's connection is gone — drop it and keep looking.
        }
        return nil
    }
}
