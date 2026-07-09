import Foundation
import ABSKit
import LibraryCache
import DownloadManager

/// Orchestrates OFFLINE DOWNLOADS: it integrates the three seams M2a built — `ABSClient`
/// (`fileDownloadURL`/`item`/`podcastItem`), `LibraryCacheStore` (v4 download records + pinned
/// detail), and `DownloadManager` (background per-file transfer) — into the app-level flow the UI
/// drives. AppState owns it; the Downloads tab / affordances (Tasks 7-8) read/observe the cache and
/// call `download`/`delete` here.
///
/// **Responsibilities**
/// - `download(itemID:episodeID:)` — pin the item's detail (so it's browsable offline), enumerate
///   its audio files, enqueue each to a stable on-disk destination, and aggregate per-file progress
///   into the parent `CachedDownload`'s state/bytes as the `DownloadManager` reports it.
/// - `delete(itemID:episodeID:)` — cancel any in-flight transfers, remove the on-disk files, and
///   delete the cache records (parent + files). No partial state is left.
/// - storage totals (`totalDownloadedBytes`) straight from the store.
/// - `reattachOnLaunch()` — reconcile the background session's surviving state with the cache after
///   a relaunch: an in-flight transfer keeps reporting, and one that FINISHED while the app was dead
///   is detected and marked `.downloaded`.
///
/// **NOT here:** offline PLAYBACK (Task 5). This type only produces downloaded files + cache rows;
/// it never touches the player.
///
/// Reconciliation runs through ONE path — a subscription to `DownloadManager.updates()` (the merged
/// per-file stream) — shared by `download`-time progress and `reattach`-time replayed events, so
/// there is no forked download-vs-reattach bookkeeping. `@Observable` + default-MainActor, matching
/// `AppState`.
@Observable
final class DownloadCoordinator {
    /// The `CachedDownload`/`CachedDownloadFile` `state` string values (the store keeps `state` a
    /// plain string; this type owns their meaning — see `CachedDownload`'s doc).
    enum State {
        static let queued = "queued"
        static let downloading = "downloading"
        static let downloaded = "downloaded"
        static let failed = "failed"
    }

    private let cache: LibraryCacheStore
    /// The root every download destination lives under; `CachedDownloadFile.localRelativePath` is
    /// stored RELATIVE to this so an app-container move across launches never invalidates a path.
    let downloadsRoot: URL
    /// Built lazily on first use (a real `DownloadManager` stands up a background `URLSession`,
    /// which must NOT happen merely by constructing `AppState` in a unit test that never downloads).
    private let managerProvider: @MainActor () -> any DownloadManaging
    private var _manager: (any DownloadManaging)?

    /// The active connection's client + id, supplied live by `AppState` (they change on connection
    /// switch/sign-out). `download` needs the client to re-derive download URLs; `delete`/`reattach`
    /// need only the connection id (they work offline).
    var clientProvider: @MainActor () -> ABSClient? = { nil }
    var connectionIDProvider: @MainActor () -> String? = { nil }

    private var updatesTask: Task<Void, Never>?

    init(
        cache: LibraryCacheStore,
        downloadsRoot: URL,
        managerProvider: @escaping @MainActor () -> any DownloadManaging
    ) {
        self.cache = cache
        self.downloadsRoot = downloadsRoot
        self.managerProvider = managerProvider
    }

    private func manager() -> any DownloadManaging {
        if let _manager { return _manager }
        let m = managerProvider()
        _manager = m
        return m
    }

    // MARK: - Subscription (single reconcile path)

    /// Start draining `DownloadManager.updates()` into the cache. Idempotent, and `async` so the
    /// observer is REGISTERED before this returns — an event emitted right after (a scripted test
    /// tick, a real progress callback) is then buffered by the stream, never dropped in a race
    /// between registration and emission.
    func start() async {
        guard updatesTask == nil else { return }
        let stream = await manager().updates()
        updatesTask = Task { @MainActor [weak self] in
            for await update in stream {
                guard let self else { break }
                self.apply(update)
            }
        }
    }

    /// Reconcile one per-file `DownloadUpdate` into the cache: update that file's row, then
    /// re-aggregate its parent `CachedDownload`. Ignores updates for files with no cache row (a
    /// stray/deleted download) and `.cancelled` (owned by `delete`/supersede, which manage rows
    /// directly — writing here would race a concurrent delete).
    private func apply(_ update: DownloadUpdate) {
        guard let ref = FileRef(fileID: update.fileID),
              let existing = try? cache.download(
                connectionID: ref.connectionID, itemID: ref.itemID, episodeID: ref.episodeID),
              var file = existing.files.first(where: { $0.trackIndex == ref.trackIndex })
        else { return }

        switch update.state {
        case let .downloading(received, total):
            file.state = State.downloading
            file.receivedBytes = Int(max(0, received))
            if total > 0 { file.totalBytes = Int(total) }   // -1 = server sent no content length
        case .downloaded:
            file.state = State.downloaded
            if file.totalBytes > 0 { file.receivedBytes = file.totalBytes }
        case .failed:
            file.state = State.failed
        case .cancelled:
            return
        }
        try? cache.upsertDownloadFile(file)
        reaggregate(connectionID: ref.connectionID, itemID: ref.itemID, episodeID: ref.episodeID)
    }

    /// Recompute a parent `CachedDownload`'s aggregate state + byte counts from its file rows:
    /// `.failed` if ANY file failed, `.downloaded` only when EVERY file is downloaded, else
    /// `.downloading`/`.queued`.
    private func reaggregate(connectionID: String, itemID: String, episodeID: String) {
        guard let wf = try? cache.download(
            connectionID: connectionID, itemID: itemID, episodeID: episodeID) else { return }
        let files = wf.files
        let state: String
        if files.contains(where: { $0.state == State.failed }) {
            state = State.failed
        } else if !files.isEmpty && files.allSatisfy({ $0.state == State.downloaded }) {
            state = State.downloaded
        } else if files.contains(where: { $0.state == State.downloading }) {
            state = State.downloading
        } else {
            state = State.queued
        }
        var parent = wf.download
        parent.state = state
        parent.receivedBytes = files.reduce(0) { $0 + $1.receivedBytes }
        parent.totalBytes = files.reduce(0) { $0 + $1.totalBytes }
        parent.updatedAt = Self.nowMillis()
        try? cache.upsertDownload(parent)
    }

    // MARK: - Download

    /// Download a book (`episodeID == nil`) or a single podcast episode. Pins the item's detail so
    /// it's browsable offline, enumerates its audio files, and enqueues each per-file transfer to a
    /// stable destination; per-file progress aggregates into the parent `CachedDownload` via the
    /// `updates()` subscription. A best-effort no-op when there's no active connection/client.
    func download(itemID: String, episodeID: String? = nil) async {
        await start()
        guard let client = clientProvider(), let connectionID = connectionIDProvider() else { return }
        let episode = episodeID ?? ""

        // Enumerate the item's files + pin its detail. A fetch failure surfaces a `.failed` parent
        // (never a silent drop) so the UI can offer a retry.
        let enumerated: [PlannedFile]
        do {
            enumerated = try await enumerateAndPin(client: client, connectionID: connectionID,
                                                   itemID: itemID, episodeID: episode)
        } catch {
            markParentFailed(connectionID: connectionID, itemID: itemID, episodeID: episode)
            return
        }
        guard !enumerated.isEmpty else {
            markParentFailed(connectionID: connectionID, itemID: itemID, episodeID: episode)
            return
        }

        // Write the parent + per-file rows BEFORE enqueuing, so the `updates()` reconcile always
        // finds a row to update when the first progress tick lands.
        let now = Self.nowMillis()
        let plannedTotal = enumerated.reduce(0) { $0 + $1.size }
        try? cache.upsertDownload(CachedDownload(
            connectionID: connectionID, itemID: itemID, episodeID: episode,
            state: State.downloading, receivedBytes: 0, totalBytes: plannedTotal, updatedAt: now))
        for planned in enumerated {
            try? cache.upsertDownloadFile(CachedDownloadFile(
                connectionID: connectionID, itemID: itemID, episodeID: episode,
                trackIndex: planned.trackIndex, ino: planned.ino,
                localRelativePath: planned.relativePath, receivedBytes: 0, totalBytes: planned.size,
                state: State.downloading, mimeType: planned.mimeType))
        }

        // Enqueue each file. The download URL is RE-DERIVED here (its token is bearer-equivalent and
        // ~1h-lived) and is NEVER logged. A per-file URL failure marks just that file failed.
        for planned in enumerated {
            let fileID = FileRef(connectionID: connectionID, itemID: itemID,
                                 episodeID: episode, trackIndex: planned.trackIndex).fileID
            do {
                let url = try await client.fileDownloadURL(itemID: itemID, ino: planned.ino)
                await manager().enqueue(fileID: fileID, request: URLRequest(url: url),
                                        destination: downloadsRoot.appending(path: planned.relativePath))
            } catch {
                if var f = try? cache.download(connectionID: connectionID, itemID: itemID, episodeID: episode)?
                    .files.first(where: { $0.trackIndex == planned.trackIndex }) {
                    f.state = State.failed
                    try? cache.upsertDownloadFile(f)
                }
            }
        }
        reaggregate(connectionID: connectionID, itemID: itemID, episodeID: episode)
    }

    /// Fetch the item's expanded detail, PIN it into the cache (so the downloaded item stays
    /// browsable with no network), and return the planned per-file transfer list (track order → ino
    /// → local relative path). Books read `media.audioFiles[]`; a podcast episode reads its single
    /// `audioFile`. Throws if the detail can't be fetched or the episode/file can't be resolved.
    private func enumerateAndPin(
        client: ABSClient, connectionID: String, itemID: String, episodeID: String
    ) async throws -> [PlannedFile] {
        if episodeID.isEmpty {
            let detail = try await client.item(id: itemID)
            let md = detail.media.metadata
            try? cache.upsertItemDetail(CachedItemDetail(
                connectionID: connectionID, itemID: itemID,
                description: md.description, publisher: md.publisher, isbn: md.isbn, asin: md.asin,
                language: md.language, explicit: md.explicit, abridged: md.abridged,
                publishedDate: md.publishedDate,
                chapters: (detail.media.chapters ?? []).map {
                    CachedChapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title)
                }))
            let files = (detail.media.audioFiles ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            return files.enumerated().map { offset, af in
                plan(connectionID: connectionID, itemID: itemID, episodeID: episodeID,
                     trackIndex: offset, audioFile: af)
            }
        } else {
            let detail = try await client.podcastItem(id: itemID)
            // Pin the podcast's episode rows (browsable offline) + a detail row for its metadata.
            let episodes = detail.media.episodes.map { ep in
                CachedEpisode(
                    connectionID: connectionID, itemID: itemID, episodeID: ep.id, idx: ep.index,
                    season: ep.season, episode: ep.episode, episodeType: ep.episodeType,
                    title: ep.title, subtitle: ep.subtitle, episodeDescription: ep.description,
                    pubDate: ep.pubDate, publishedAt: ep.publishedAt, durationSeconds: ep.duration,
                    sizeBytes: ep.size, guid: ep.guid)
            }
            try? cache.upsertEpisodes(episodes, connectionID: connectionID, itemID: itemID)
            let pm = detail.media.metadata
            try? cache.upsertItemDetail(CachedItemDetail(
                connectionID: connectionID, itemID: itemID, description: pm.description,
                language: pm.language, explicit: pm.explicit, publishedDate: pm.releaseDate))

            guard let episode = detail.media.episodes.first(where: { $0.id == episodeID }),
                  let audioFile = episode.audioFile else {
                throw DownloadCoordinatorError.noAudioFile
            }
            return [plan(connectionID: connectionID, itemID: itemID, episodeID: episodeID,
                         trackIndex: 0, audioFile: audioFile)]
        }
    }

    private func plan(
        connectionID: String, itemID: String, episodeID: String, trackIndex: Int,
        audioFile: AudioFileInfo
    ) -> PlannedFile {
        // The on-disk path segment for the episode uses "_" for a book (episodeID is "" there); the
        // fileID keeps the real (possibly empty) episodeID so its 4-component parse stays exact.
        let episodeSegment = episodeID.isEmpty ? "_" : episodeID
        let ext = audioFile.fileExtension
        let filename = ext.map { "track-\(trackIndex).\($0)" } ?? "track-\(trackIndex)"
        let relativePath = "\(connectionID)/\(itemID)/\(episodeSegment)/\(filename)"
        return PlannedFile(trackIndex: trackIndex, ino: audioFile.ino, relativePath: relativePath,
                           size: audioFile.metadata?.size ?? 0, mimeType: audioFile.mimeType)
    }

    private func markParentFailed(connectionID: String, itemID: String, episodeID: String) {
        try? cache.upsertDownload(CachedDownload(
            connectionID: connectionID, itemID: itemID, episodeID: episodeID,
            state: State.failed, receivedBytes: 0, totalBytes: 0, updatedAt: Self.nowMillis()))
    }

    // MARK: - Delete

    /// Cancel any in-flight transfers for this download's files, remove the on-disk files (and the
    /// item's now-empty download directory), and delete the cache records (parent + files) — leaving
    /// no partial state. After this, `cache.download(...)` for the key returns nil.
    func delete(itemID: String, episodeID: String? = nil) async {
        guard let connectionID = connectionIDProvider() else { return }
        let episode = episodeID ?? ""
        if let existing = try? cache.download(
            connectionID: connectionID, itemID: itemID, episodeID: episode) {
            for file in existing.files {
                let fileID = FileRef(connectionID: connectionID, itemID: itemID,
                                     episodeID: episode, trackIndex: file.trackIndex).fileID
                await manager().cancel(fileID: fileID)
                try? FileManager.default.removeItem(at: downloadsRoot.appending(path: file.localRelativePath))
            }
            // Remove the item's per-download directory (…/<connectionID>/<itemID>/<episodeSeg>).
            if let first = existing.files.first {
                let dir = downloadsRoot.appending(path: first.localRelativePath).deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
        }
        try? cache.deleteDownload(connectionID: connectionID, itemID: itemID, episodeID: episode)
    }

    // MARK: - Storage

    /// Total on-disk bytes across the active connection's downloaded files (the Downloads tab's
    /// storage figure). 0 with no active connection.
    func totalDownloadedBytes() -> Int {
        guard let connectionID = connectionIDProvider() else { return 0 }
        return (try? cache.totalDownloadedBytes(connectionID: connectionID)) ?? 0
    }

    // MARK: - Relaunch reconcile

    /// On launch, reconcile the background session with the cache. Rebuilds a `fileID → destination`
    /// map from every not-yet-`downloaded` file of every in-progress download, then asks the
    /// `DownloadManager` to re-attach: an in-flight transfer resumes reporting through the
    /// `updates()` subscription, and one the background session finished while the app was dead
    /// replays its terminal event there too — driving the file (and, once all files are done, its
    /// parent) to `.downloaded`. Best-effort no-op with no active connection.
    func reattachOnLaunch() async {
        await start()
        guard let connectionID = connectionIDProvider() else { return }
        let parents = (try? cache.downloads(connectionID: connectionID)) ?? []
        var destinations: [String: URL] = [:]
        for parent in parents where parent.state == State.downloading || parent.state == State.queued {
            guard let wf = try? cache.download(
                connectionID: connectionID, itemID: parent.itemID, episodeID: parent.episodeID)
            else { continue }
            for file in wf.files where file.state != State.downloaded {
                let fileID = FileRef(connectionID: connectionID, itemID: parent.itemID,
                                     episodeID: parent.episodeID, trackIndex: file.trackIndex).fileID
                destinations[fileID] = downloadsRoot.appending(path: file.localRelativePath)
            }
        }
        await manager().reattach(destinations: destinations)
    }

    // MARK: - Helpers

    /// Absolute on-disk URL for a cached download file, resolved against the CURRENT downloads root
    /// (paths are stored relative). Offline playback (Task 5) and the Downloads UI use this.
    func localURL(for file: CachedDownloadFile) -> URL {
        downloadsRoot.appending(path: file.localRelativePath)
    }

    /// Forward the system background-session completion handler (from
    /// `handleEventsForBackgroundURLSession`) to the manager. Wiring the app-delegate hook that
    /// supplies it is a later task; the entry point lives here.
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) async {
        await manager().setBackgroundCompletionHandler(handler)
    }

    static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}

private enum DownloadCoordinatorError: Error { case noAudioFile }

/// One planned per-file transfer (before enqueue): where the file goes and how to fetch it.
private struct PlannedFile {
    let trackIndex: Int
    let ino: String
    let relativePath: String
    let size: Int
    let mimeType: String?
}

/// The opaque per-file transfer key `"<connectionID>/<itemID>/<episodeID>/<trackIndex>"` and its
/// exact inverse — the ONE mapping between a `DownloadManager` `fileID` and a cache row. `episodeID`
/// is `""` for a book (so the key contains `//`); the 4-component split preserves that empty
/// segment, and every id (connection UUID, server item/episode ids) is slash-free, so the parse is
/// unambiguous.
struct FileRef: Equatable {
    let connectionID: String
    let itemID: String
    let episodeID: String
    let trackIndex: Int

    var fileID: String { "\(connectionID)/\(itemID)/\(episodeID)/\(trackIndex)" }

    init(connectionID: String, itemID: String, episodeID: String, trackIndex: Int) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.episodeID = episodeID
        self.trackIndex = trackIndex
    }

    init?(fileID: String) {
        let parts = fileID.components(separatedBy: "/")
        guard parts.count == 4, let trackIndex = Int(parts[3]) else { return nil }
        self.connectionID = parts[0]
        self.itemID = parts[1]
        self.episodeID = parts[2]
        self.trackIndex = trackIndex
    }
}
