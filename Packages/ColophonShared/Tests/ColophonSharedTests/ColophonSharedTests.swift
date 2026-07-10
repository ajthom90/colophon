import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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

/// The M2b Task 5 `connectionID` (the publishing connection) round-trips through the store — the field
/// `resume` gates on so it never starts a foreign server's item.
@Test func continueListeningSnapshotCarriesConnectionIDThroughFile() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    let snapshot = ContinueListeningSnapshot(
        entries: [.init(itemID: "li_1", title: "Book One", author: "Author One", progress: 0.25)],
        connectionID: "conn-1")
    store.writeContinueListening(snapshot)

    let read = try #require(store.readContinueListening())
    #expect(read.connectionID == "conn-1")
    #expect(read == snapshot)
}

/// A pre-Task-5 blob has no `connectionID` key — it must decode with a nil connectionID (never crash),
/// so a legacy snapshot is simply treated as non-matching by `resume`.
@Test func continueListeningSnapshotDecodesLegacyBlobWithoutConnectionID() throws {
    let json = #"{"entries":[{"itemID":"li_1","title":"T","author":"A","progress":0.2}]}"#
    let snapshot = try JSONDecoder().decode(ContinueListeningSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.connectionID == nil)
    #expect(snapshot.entries.count == 1)
}

/// `clearContinueListening()` removes the blob (sign-out / connection removal) — `read` returns nil.
@Test func clearContinueListeningRemovesTheBlob() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    store.writeContinueListening(ContinueListeningSnapshot(
        entries: [.init(itemID: "li_1", title: "T", author: "A", progress: 0.2)], connectionID: "conn-1"))
    #expect(store.readContinueListening() != nil)

    store.clearContinueListening()
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

// MARK: - Typeface preference mirror (App Group suite)

@Test func typefacePreferenceRoundTrips() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }

    store.writeTypefacePreference("default")
    #expect(store.readTypefacePreference() == "default")
}

@Test func typefacePreferenceDefaultsToSerifWhenUnset() throws {
    let (store, suite, container) = try makeStore()
    defer { tearDown(suite: suite, container: container) }
    #expect(store.readTypefacePreference() == "serif")
}

// MARK: - ArtworkThumbnail (pure Data -> Data? downscale)

/// A solid-color 500x500 PNG — big enough that downscaling to a small `maxPixelSize` is
/// meaningful, small enough to stay fast in a unit test.
private func makeTestImageData(sideLength: Int = 500) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: sideLength, height: sideLength, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: sideLength, height: sideLength))
    let cgImage = context.makeImage()!

    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

@Test func downscaleShrinksALargeImageToMaxPixelSize() throws {
    let original = makeTestImageData(sideLength: 500)
    let thumbnail = try #require(ArtworkThumbnail.downscale(original, maxPixelSize: 100))

    let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width <= 100)
    #expect(image.height <= 100)
    #expect(thumbnail.count < original.count)
}

@Test func downscaleReturnsNilForUndecodableData() {
    #expect(ArtworkThumbnail.downscale(Data([0x00, 0x01, 0x02]), maxPixelSize: 200) == nil)
}

@Test func downscaleReturnsNilForEmptyData() {
    #expect(ArtworkThumbnail.downscale(Data(), maxPixelSize: 200) == nil)
}

// MARK: - ContinueListeningSnapshot -> widget items (pure mapping, no widget host)

@Test func widgetItemsMapsEntriesInOrderCappedAtLimit() {
    let snapshot = ContinueListeningSnapshot(entries: [
        .init(itemID: "li_1", title: "Book One", author: "Author One", progress: 0.1,
              artworkThumbnailPath: "artwork/li_1.img"),
        .init(itemID: "li_2", episodeID: "ep_2", title: "Episode Two", author: "Show Two",
              progress: 0.5),
        .init(itemID: "li_3", title: "Book Three", author: "Author Three", progress: 0.9),
        .init(itemID: "li_4", title: "Book Four", author: "Author Four", progress: 0.0),
    ])

    let small = snapshot.widgetItems(limit: 1)
    #expect(small.count == 1)
    #expect(small[0].itemID == "li_1")
    #expect(small[0].artworkThumbnailPath == "artwork/li_1.img")

    let medium = snapshot.widgetItems(limit: ContinueListeningSnapshot.maxWidgetDisplayCount)
    #expect(medium.map(\.itemID) == ["li_1", "li_2", "li_3"])
    #expect(medium[1].episodeID == "ep_2")
}

@Test func widgetItemsOnEmptySnapshotReturnsEmpty() {
    #expect(ContinueListeningSnapshot().widgetItems().isEmpty)
}

@Test func widgetItemDeepLinkMatchesColophonDeepLinkForBothBookAndEpisode() {
    let book = ContinueListeningWidgetItem(itemID: "li_book", title: "T", author: "A", progress: 0)
    #expect(book.deepLinkURL == ColophonDeepLink.item(id: "li_book", episodeID: nil).url)

    let episode = ContinueListeningWidgetItem(
        itemID: "li_pod", episodeID: "ep_9", title: "T", author: "A", progress: 0)
    #expect(episode.deepLinkURL == ColophonDeepLink.item(id: "li_pod", episodeID: "ep_9").url)
}
