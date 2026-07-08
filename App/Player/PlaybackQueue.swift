import Foundation

/// One item queued to play AFTER the current book — the minimal display payload the queue List and
/// the advance logic need, captured at enqueue time from the browse row (so the sheet paints
/// instantly without a fetch). `connectionID` records which server the item belongs to, so
/// `PlaybackQueue.peekNextPlayable(validConnectionIDs:)` can DROP an entry whose connection was later
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
    /// The podcast episode this entry plays, or `nil` for a book. When set, `AppState.advanceToNext`
    /// opens it through the episode path (`startPlayback(itemID:episodeId:)` → `client.playEpisode`)
    /// rather than the book path — the ONE field that makes an entry episode-scoped. For an episode
    /// entry, `title` is the EPISODE title and `author` is the PODCAST title (the show name), so the
    /// queue list renders it natively and `advanceToNext` can pass the podcast title straight through.
    let episodeId: String?

    init(id: UUID = UUID(), itemID: String, connectionID: String, title: String,
         author: String?, episodeId: String? = nil) {
        self.id = id
        self.itemID = itemID
        self.connectionID = connectionID
        self.title = title
        self.author = author
        self.episodeId = episodeId
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
/// `peekNextPlayable(validConnectionIDs:)` is the pure, audio-free core: it drops any leading
/// entries whose connection is no longer playable and RETURNS (without consuming) the next PLAYABLE
/// entry or `nil` (→ stop) — peek-then-commit, so `AppState.advanceToNext` only `remove(_:)`s it once
/// playback actually started. That decision is proven directly in `PlaybackQueueTests` with no
/// `PlaybackController`.
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

    /// Remove one entry by identity (per-entry UUID) — the COMMIT half of peek-then-commit: the
    /// caller `peekNextPlayable`s, actually starts the item, and only THEN removes it, so an advance
    /// that bails before starting never drops the entry. No-op if it's already gone.
    func remove(_ entry: QueueEntry) { entries.removeAll { $0.id == entry.id } }

    /// Reorder — the `List(onMove:)` hook.
    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Empty the whole queue (the "Clear" action).
    func clear() { entries.removeAll() }

    /// Drop every queued entry belonging to `connectionID` — called when that connection is signed
    /// out or removed, so its now-unreachable items don't linger in the queue (defense-in-depth
    /// alongside `peekNextPlayable`'s valid-connection guard).
    func removeEntries(connectionID: String) {
        entries.removeAll { $0.connectionID == connectionID }
    }

    // MARK: - The advance decision (pure, unit-tested)

    /// PEEK the next PLAYABLE entry without consuming it: drops any leading entries whose
    /// `connectionID` isn't in `validConnectionIDs` (owning connection signed out / removed → the
    /// item is unreachable), then RETURNS — but does NOT remove — the first surviving entry, or
    /// `nil` when the queue empties without a playable one (the caller then stops).
    ///
    /// Peek-then-commit is deliberate (the concurrency fix): the returned entry stays at the front
    /// until the caller has actually STARTED it and calls `remove(_:)`. So a concurrent/duplicate
    /// advance whose `startPlayback` is dropped by the first-tap-wins guard — or a `startPlayback`
    /// that bails (unplayable connection) — leaves the entry queued rather than silently losing it.
    /// Only the leading DEAD entries are mutated away (they can never be played). NO audio / no
    /// controller — this is the whole advance decision.
    func peekNextPlayable(validConnectionIDs: Set<String>) -> QueueEntry? {
        while let candidate = entries.first {
            if validConnectionIDs.contains(candidate.connectionID) {
                return candidate               // leave it in place — caller commits via remove(_:)
            }
            entries.removeFirst()              // dead connection → drop it and keep looking
        }
        return nil
    }
}
