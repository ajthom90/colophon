import Foundation
import Testing
@testable import ColophonShared

// MARK: - Fixtures

/// A `SharedStore` backed by a UNIQUE UserDefaults suite + a fresh temp container dir, plus the
/// suite name so a test can tear the suite domain down. Isolated per test — no App Group needed.
private func makeStore() throws -> (store: SharedStore, suite: String, container: URL) {
    let suite = "colophon.tests.\(UUID().uuidString)"
    let container = FileManager.default.temporaryDirectory
        .appending(path: "colophon-shared-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    return (SharedStore(suiteName: suite, containerURL: container), suite, container)
}

private func tearDown(suite: String, container: URL) {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: container)
}

// MARK: - NowPlayingSnapshot round-trip (UserDefaults suite)

@Test func nowPlayingSnapshotRoundTripsThroughSharedStore() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    let snapshot = NowPlayingSnapshot(
        itemID: "li_book_42",
        episodeID: nil,
        title: "The Left Hand of Darkness",
        author: "Ursula K. Le Guin",
        chapterTitle: "Chapter 3",
        progress: 0.42,
        isPlaying: true,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        artworkThumbnailPath: "artwork/li_book_42.img")

    store.writeNowPlaying(snapshot)
    let read = store.readNowPlaying()

    #expect(read == snapshot)
}

@Test func episodeNowPlayingSnapshotRoundTrips() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    let snapshot = NowPlayingSnapshot(
        itemID: "li_podcast_1",
        episodeID: "ep_9",
        title: "Episode 9",
        author: "The Show",
        chapterTitle: nil,
        progress: 0,
        isPlaying: false,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
        artworkThumbnailPath: nil)

    store.writeNowPlaying(snapshot)
    #expect(store.readNowPlaying() == snapshot)
}

@Test func clearNowPlayingRemovesTheSnapshot() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    store.writeNowPlaying(NowPlayingSnapshot(
        itemID: "x", title: "T", author: "A", progress: 0.1, isPlaying: true,
        updatedAt: Date(timeIntervalSince1970: 1)))
    #expect(store.readNowPlaying() != nil)

    store.clearNowPlaying()
    #expect(store.readNowPlaying() == nil)
}

@Test func readNowPlayingReturnsNilWhenNothingWritten() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }
    #expect(store.readNowPlaying() == nil)
}

// MARK: - ContinueListeningSnapshot round-trip (container file)

@Test func continueListeningSnapshotRoundTripsThroughFile() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    let snapshot = ContinueListeningSnapshot(entries: [
        .init(itemID: "li_1", episodeID: nil, title: "Book One", author: "Author One",
              progress: 0.25, artworkThumbnailPath: "artwork/li_1.img"),
        .init(itemID: "li_pod", episodeID: "ep_2", title: "Episode Two", author: "A Show",
              progress: 0.75, artworkThumbnailPath: nil),
    ])

    store.writeContinueListening(snapshot)
    #expect(store.readContinueListening() == snapshot)
}

@Test func readContinueListeningReturnsNilWhenNothingWritten() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }
    #expect(store.readContinueListening() == nil)
}

// MARK: - Artwork thumbnails (container files)

@Test func artworkWriteReturnsRelativePathAndReadsBack() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
    let relativePath = try #require(store.writeArtwork(bytes, forKey: "li_1/"))

    #expect(relativePath.hasPrefix("artwork/"))
    #expect(store.readArtwork(atRelativePath: relativePath) == bytes)
    #expect(FileManager.default.fileExists(atPath: store.artworkURL(forRelativePath: relativePath).path))
}

// MARK: - Deep-link build + parse round-trips

@Test func itemDeepLinkRoundTrips() {
    let link = ColophonDeepLink.item(id: "li_abc123", episodeID: nil)
    let url = link.url
    #expect(url.absoluteString == "colophon://item/li_abc123")
    #expect(ColophonDeepLink(url: url) == link)
}

@Test func episodeDeepLinkRoundTrips() {
    let link = ColophonDeepLink.item(id: "li_pod", episodeID: "ep_7")
    let url = link.url
    #expect(url.scheme == "colophon")
    #expect(url.host == "item")
    #expect(url.absoluteString.contains("episode=ep_7"))
    #expect(ColophonDeepLink(url: url) == link)
}

@Test func resumeDeepLinkRoundTrips() {
    let link = ColophonDeepLink.resume
    #expect(link.url.absoluteString == "colophon://resume")
    #expect(ColophonDeepLink(url: link.url) == link)
}

@Test func parsingRejectsForeignSchemesAndUnknownHosts() {
    #expect(ColophonDeepLink(url: URL(string: "https://item/x")!) == nil)
    #expect(ColophonDeepLink(url: URL(string: "colophon://library/x")!) == nil)
    #expect(ColophonDeepLink(url: URL(string: "colophon://item/")!) == nil)
}

@Test func emptyEpisodeQueryParsesAsBook() {
    // A built item link with no episode must not resurface as an episode with an empty id.
    let url = ColophonDeepLink.item(id: "li_x", episodeID: "").url
    #expect(ColophonDeepLink(url: url) == .item(id: "li_x", episodeID: nil))
}
