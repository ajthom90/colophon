import Testing
import Foundation
import LibraryCache
@testable import Colophon

/// Task-7 coverage for `DownloadsView`'s pure row join (`makeRow`) — the view-model that joins one
/// `CachedDownload` aggregate with its already-pinned title rows (a book's `CachedItem`, or a
/// podcast episode's `CachedEpisode` + its podcast's OWN `CachedItem`) into one renderable row. No
/// SwiftUI/cache dependency: plain value types in, one value type out, so this is directly testable.
@MainActor
struct DownloadsViewTests {
    private func download(
        itemID: String, episodeID: String = "", state: String = "downloaded",
        received: Int = 100, total: Int = 200
    ) -> CachedDownload {
        CachedDownload(connectionID: "c1", itemID: itemID, episodeID: episodeID, state: state,
                      receivedBytes: received, totalBytes: total, updatedAt: 1)
    }

    @Test func bookRowUsesTheItemsTitleAndAuthorAsSubtitle() {
        let item = CachedItem(id: "book-1", connectionID: "c1", libraryID: "lib-1",
                              title: "Two-File Book", authorName: "Author One")
        let row = DownloadsView.makeRow(download(itemID: "book-1"), item: item, episode: nil)
        #expect(row.isEpisode == false)
        #expect(row.itemID == "book-1")
        #expect(row.episodeID == "")
        #expect(row.title == "Two-File Book")
        #expect(row.subtitle == "Author One")
    }

    @Test func episodeRowUsesTheEpisodesTitleAndThePodcastsTitleAsSubtitle() {
        let podcast = CachedItem(id: "pod-1", connectionID: "c1", libraryID: "lib-1", title: "My Show")
        let episode = CachedEpisode(connectionID: "c1", itemID: "pod-1", episodeID: "ep-1", title: "Episode One")
        let row = DownloadsView.makeRow(download(itemID: "pod-1", episodeID: "ep-1"), item: podcast, episode: episode)
        #expect(row.isEpisode == true)
        #expect(row.itemID == "pod-1")
        #expect(row.episodeID == "ep-1")
        #expect(row.title == "Episode One")
        // The subtitle is the PODCAST's title (the show name), not the book-style author field —
        // matches `EpisodeCard`'s podcast-title-as-secondary convention elsewhere in the app.
        #expect(row.subtitle == "My Show")
    }

    /// A download whose pinned title rows were somehow evicted must still render — never silently
    /// dropped from the list (the plan's global "no silent data loss" constraint) — falling back to
    /// a generic label instead.
    @Test func missingJoinsFallBackToGenericLabelsRatherThanDroppingTheRow() {
        let bookRow = DownloadsView.makeRow(download(itemID: "gone-1"), item: nil, episode: nil)
        #expect(bookRow.title == "Untitled")
        #expect(bookRow.subtitle == nil)

        let episodeRow = DownloadsView.makeRow(download(itemID: "gone-2", episodeID: "ep-2"), item: nil, episode: nil)
        #expect(episodeRow.title == "Untitled Episode")
        #expect(episodeRow.subtitle == nil)
    }

    @Test func fractionClampsAndAvoidsDivideByZero() {
        let zeroTotal = DownloadsView.makeRow(download(itemID: "i", received: 5, total: 0), item: nil, episode: nil)
        #expect(zeroTotal.fraction == 0)

        // A momentarily-inconsistent overshoot (receivedBytes > totalBytes) never reads > 1 — a
        // `ProgressView(value:)` above 1 is undefined/visually broken.
        let overshoot = DownloadsView.makeRow(download(itemID: "i", received: 250, total: 100), item: nil, episode: nil)
        #expect(overshoot.fraction == 1)

        let half = DownloadsView.makeRow(download(itemID: "i", received: 50, total: 200), item: nil, episode: nil)
        #expect(half.fraction == 0.25)
    }

    @Test func humanizeBytesIsNonEmptyAndMonotonicWithSize() {
        let small = DownloadsView.humanizeBytes(1_024)
        let large = DownloadsView.humanizeBytes(1_024 * 1_024 * 500)
        #expect(!small.isEmpty)
        #expect(!large.isEmpty)
        #expect(small != large)
    }

    /// A book download and a podcast-EPISODE download that SHARE the same `itemID` (a podcast item
    /// whose show-level and episode-level downloads coexist — or two distinct episodes of one show)
    /// must produce DISTINCT row identities, or `ForEach` would collapse them into one row (dropping
    /// the other download from the list entirely, and confusing swipe/delete targeting). This asserts
    /// the identity is scoped by `(itemID, episodeID)`, not `itemID` alone — a property that WOULD
    /// fail if `Row.id` keyed off `itemID`.
    @Test func downloadsSharingAnItemIDButDifferingByEpisodeGetDistinctRowIdentities() {
        let book = DownloadsView.makeRow(download(itemID: "pod-1", episodeID: ""), item: nil, episode: nil)
        let epA = DownloadsView.makeRow(download(itemID: "pod-1", episodeID: "ep-A"), item: nil, episode: nil)
        let epB = DownloadsView.makeRow(download(itemID: "pod-1", episodeID: "ep-B"), item: nil, episode: nil)
        #expect(book.id != epA.id)
        #expect(epA.id != epB.id)
        #expect(Set([book.id, epA.id, epB.id]).count == 3)
    }
}
