import Testing
import Foundation
import ABSKit
import ABSKitTestSupport
import LibraryCache
import DownloadManager
@testable import Colophon

/// Task-4 coverage for `DownloadCoordinator` — the download/delete/storage/relaunch-reconcile
/// orchestrator. Every test runs fully offline: an in-memory `FakeDownloadManaging`, a temp-dir
/// `LibraryCacheStore`, and (where a fetch is needed) a real `ABSClient` over a `MockTransport` with
/// a seeded token so `fileDownloadURL` derives a URL without any network.
@MainActor
struct DownloadCoordinatorTests {
    // MARK: - Fixtures

    /// A 2-file book's expanded item detail (`GET /api/items/:id`) — two `audioFiles` with distinct
    /// `ino`/`ext`/`size` so the coordinator enumerates two per-file transfers.
    private let twoFileBookJSON = """
    {"id":"book-1","libraryId":"lib-1","media":{
      "metadata":{"title":"Two-File Book","description":"A test book."},
      "chapters":[{"id":0,"start":0,"end":100,"title":"One"}],
      "audioFiles":[
        {"index":1,"ino":"1975","mimeType":"audio/mpeg","metadata":{"ext":".mp3","size":100}},
        {"index":2,"ino":"1976","mimeType":"audio/mp4","metadata":{"ext":".m4b","size":200}}
      ]}}
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore() throws -> LibraryCacheStore {
        try LibraryCacheStore(databaseURL: makeTempDir().appending(path: "cache.sqlite"))
    }

    private func makeClient(_ transport: MockTransport, connectionID: String) async -> ABSClient {
        let store = InMemoryTokenStore()
        try? await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: connectionID)
        let url = URL(string: "http://s:13378")!
        let auth = AuthManager(baseURL: url, connectionID: connectionID, transport: transport, store: store)
        return ABSClient(baseURL: url, transport: transport, auth: auth)
    }

    private func makeCoordinator(
        store: LibraryCacheStore, manager: FakeDownloadManaging, root: URL,
        client: ABSClient?, connectionID: String
    ) -> DownloadCoordinator {
        let coord = DownloadCoordinator(cache: store, downloadsRoot: root, managerProvider: { manager })
        coord.clientProvider = { client }
        coord.connectionIDProvider = { connectionID }
        return coord
    }

    /// Poll `condition` (the cache is written asynchronously by the coordinator's `updates()`
    /// subscription) until it holds or a short deadline passes.
    private func until(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func parentState(_ store: LibraryCacheStore, _ itemID: String, _ episodeID: String = "") -> String? {
        ((try? store.download(connectionID: "conn1", itemID: itemID, episodeID: episodeID)) ?? nil)?.download.state
    }

    // MARK: - Download

    /// A multi-file book: per-file progress aggregates into the parent → `.downloaded` once ALL
    /// files finish, the item's detail is pinned (browsable offline), each file's RELATIVE path is
    /// written, and the storage total reflects the received bytes.
    @Test func downloadBookAggregatesToDownloadedWithPinnedDetail() async throws {
        let store = try makeStore()
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: twoFileBookJSON)
        let client = await makeClient(transport, connectionID: "conn1")
        let manager = FakeDownloadManaging()
        let root = try makeTempDir()
        let coord = makeCoordinator(store: store, manager: manager, root: root,
                                    client: client, connectionID: "conn1")

        await coord.start()
        await coord.download(itemID: "book-1")

        let f0 = "conn1/book-1//0"
        let f1 = "conn1/book-1//1"
        #expect(Set(manager.enqueuedFileIDs) == [f0, f1])

        // Per-file progress + completion, interleaved.
        manager.emitProgress(fileID: f0, received: 100, total: 100)
        manager.emitProgress(fileID: f1, received: 200, total: 200)
        manager.complete(fileID: f0)
        manager.complete(fileID: f1)

        await until { parentState(store, "book-1") == DownloadCoordinator.State.downloaded }

        let wf = try #require((try store.download(connectionID: "conn1", itemID: "book-1")))
        #expect(wf.download.state == "downloaded")
        #expect(wf.files.count == 2)
        #expect(wf.files.allSatisfy { $0.state == "downloaded" })
        // RELATIVE paths (never absolute), "_" episode segment for a book.
        #expect(wf.files[0].localRelativePath == "conn1/book-1/_/track-0.mp3")
        #expect(wf.files[1].localRelativePath == "conn1/book-1/_/track-1.m4b")
        // Detail pinned so the item stays browsable with no network.
        #expect((try store.itemDetail(connectionID: "conn1", itemID: "book-1")) != nil)
        // Storage total = sum of received bytes across files.
        #expect(coord.totalDownloadedBytes() == 300)
    }

    /// A failed file marks the parent `.failed`; the other file's state stays correct
    /// (`.downloaded`), and no partial file is left on disk for the failed track.
    @Test func failedFileMarksParentFailedNoPartial() async throws {
        let store = try makeStore()
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: twoFileBookJSON)
        let client = await makeClient(transport, connectionID: "conn1")
        let manager = FakeDownloadManaging()
        let coord = makeCoordinator(store: store, manager: manager, root: try makeTempDir(),
                                    client: client, connectionID: "conn1")

        await coord.start()
        await coord.download(itemID: "book-1")
        let f0 = "conn1/book-1//0"
        let f1 = "conn1/book-1//1"

        manager.emitProgress(fileID: f0, received: 100, total: 100)
        manager.complete(fileID: f0)             // file 0 completes
        manager.fail(fileID: f1)                  // file 1 fails

        await until { parentState(store, "book-1") == DownloadCoordinator.State.failed }

        let wf = try #require((try store.download(connectionID: "conn1", itemID: "book-1")))
        #expect(wf.download.state == "failed")
        #expect(wf.files.first { $0.trackIndex == 0 }?.state == "downloaded")
        #expect(wf.files.first { $0.trackIndex == 1 }?.state == "failed")
        // No partial file left behind for the failed track.
        let failed = try #require(wf.files.first { $0.trackIndex == 1 })
        #expect(!FileManager.default.fileExists(atPath: coord.localURL(for: failed).path))
    }

    // MARK: - Delete

    /// Delete cancels every in-flight transfer, removes the on-disk files, and deletes the records —
    /// leaving nothing (`store.download(...)` returns nil after).
    @Test func deleteCancelsRemovesFilesAndRecords() async throws {
        let store = try makeStore()
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: twoFileBookJSON)
        let client = await makeClient(transport, connectionID: "conn1")
        let manager = FakeDownloadManaging()
        let coord = makeCoordinator(store: store, manager: manager, root: try makeTempDir(),
                                    client: client, connectionID: "conn1")

        await coord.start()
        await coord.download(itemID: "book-1")
        let f0 = "conn1/book-1//0"
        let f1 = "conn1/book-1//1"
        manager.emitProgress(fileID: f0, received: 100, total: 100)
        manager.complete(fileID: f0)
        manager.emitProgress(fileID: f1, received: 200, total: 200)
        manager.complete(fileID: f1)
        await until { parentState(store, "book-1") == DownloadCoordinator.State.downloaded }

        // Simulate the manager having placed the completed files on disk.
        let wf = try #require((try store.download(connectionID: "conn1", itemID: "book-1")))
        for file in wf.files {
            let url = coord.localURL(for: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: url)
        }
        #expect(wf.files.allSatisfy { FileManager.default.fileExists(atPath: coord.localURL(for: $0).path) })

        await coord.delete(itemID: "book-1")

        #expect(Set(manager.cancelledFileIDs) == [f0, f1])
        for file in wf.files {
            #expect(!FileManager.default.fileExists(atPath: coord.localURL(for: file).path))
        }
        #expect((try store.download(connectionID: "conn1", itemID: "book-1")) == nil)
    }

    // MARK: - Relaunch reconcile

    /// A download that FINISHED while the app was dead — the cache still shows `.downloading`, and on
    /// launch the (re-created) background session reports the transfer as finished. `reattachOnLaunch`
    /// must detect it and mark the download `.downloaded`, writing the received bytes.
    @Test func reattachMarksBackgroundFinishedDownloadDownloaded() async throws {
        let store = try makeStore()
        let manager = FakeDownloadManaging()
        // No client needed — reattach works offline off the cache.
        let coord = makeCoordinator(store: store, manager: manager, root: try makeTempDir(),
                                    client: nil, connectionID: "conn1")

        // Seed a download interrupted mid-flight (parent + one file both still "downloading").
        try store.upsertDownload(CachedDownload(
            connectionID: "conn1", itemID: "book-1", episodeID: "", state: "downloading",
            receivedBytes: 0, totalBytes: 100, updatedAt: 1))
        try store.upsertDownloadFile(CachedDownloadFile(
            connectionID: "conn1", itemID: "book-1", episodeID: "", trackIndex: 0, ino: "1975",
            localRelativePath: "conn1/book-1/_/track-0.mp3", receivedBytes: 0, totalBytes: 100,
            state: "downloading", mimeType: "audio/mpeg"))

        // The background session finished this file while the app was dead.
        let f0 = "conn1/book-1//0"
        manager.scheduleReattachFinished(fileID: f0)

        await coord.start()
        await coord.reattachOnLaunch()

        await until { parentState(store, "book-1") == DownloadCoordinator.State.downloaded }

        let wf = try #require((try store.download(connectionID: "conn1", itemID: "book-1")))
        #expect(wf.download.state == "downloaded")
        #expect(wf.files[0].state == "downloaded")
        #expect(wf.files[0].receivedBytes == 100)      // set to totalBytes on the terminal event
    }
}
