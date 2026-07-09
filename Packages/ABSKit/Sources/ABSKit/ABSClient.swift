import Foundation

public final class ABSClient: Sendable {
    let baseURL: URL
    let transport: Transport
    let auth: AuthManager

    public init(baseURL: URL, transport: Transport, auth: AuthManager) {
        self.baseURL = baseURL; self.transport = transport; self.auth = auth
    }

    public static func status(baseURL: URL, transport: Transport) async throws -> ServerStatus {
        try await ABSAPI.send(ABSAPI.statusRequest(baseURL: baseURL), as: ServerStatus.self, via: transport)
    }

    public func libraries() async throws -> [Library] {
        try await authorizedSend(get("api/libraries"), as: LibrariesResponse.self).libraries
    }

    /// Probes the stored credentials against `POST /api/authorize` (Bearer). Returns normally
    /// when the token is valid — or was silently refreshed by `authorizedData`'s 401 machinery.
    /// A 401 whose refresh also fails surfaces as `ABSError.reauthRequired`; a dead host throws
    /// the transport's underlying error. Used by `AppState.activateConnection` to decide between
    /// online mode, a "needs sign-in" re-auth prompt, and staying in cached-only offline mode.
    public func authorize() async throws {
        var req = get("api/authorize")
        req.httpMethod = "POST"
        _ = try await authorizedData(req)
    }

    /// `GET /api/libraries/:id/items` (minified) with the browse sort/order/filter the grid drives.
    /// `sort` is a verified ABS sort key (`media.metadata.title` | `media.metadata.authorName` |
    /// `addedAt` | `media.metadata.publishedYear` | `progress`); `desc` maps to `desc=1|0`; `filter`,
    /// when present, is the pre-built `<group>.<base64url(value)>` string (the caller owns the
    /// base64url encoding — see `AppState.LibraryFilter`). Defaults reproduce the previous
    /// title-ascending, unfiltered behavior so existing callers (the `refreshItems` pager and the
    /// debug auto-connect hook) are unchanged.
    public func items(
        libraryID: String,
        limit: Int,
        page: Int,
        sort: String = "media.metadata.title",
        desc: Bool = false,
        filter: String? = nil
    ) async throws -> ItemsPage {
        var comps = URLComponents(url: baseURL.appending(path: "api/libraries/\(libraryID)/items"),
                                  resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            .init(name: "limit", value: String(limit)),
            .init(name: "page", value: String(page)),
            .init(name: "minified", value: "1"),
            .init(name: "sort", value: sort),
            .init(name: "desc", value: desc ? "1" : "0"),
        ]
        if let filter { query.append(.init(name: "filter", value: filter)) }
        comps.queryItems = query
        return try await authorizedSend(URLRequest(url: comps.url!), as: ItemsPage.self)
    }

    /// Fetches one item's expanded detail (`?expanded=1&include=progress` — full metadata incl.
    /// the server-computed `authorName`/`narratorName`/`seriesName`, chapters, and the caller's
    /// `userMediaProgress`). Used by `AppState`'s per-item socket patch (`apply(.itemChanged)`/
    /// `apply(.itemsChanged)`, Task 3) in place of a coarse full-library re-page, and by M1c-b's
    /// `ItemDetailView`. `include=progress` is harmless to the socket-patch path (it only reads
    /// id/library/title/author/duration) and load-bearing for the detail view's Resume state.
    public func item(id: String) async throws -> LibraryItemDetail {
        try await authorizedSend(itemDetailRequest(id: id), as: LibraryItemDetail.self)
    }

    /// Fetches the SAME `GET /api/items/:id?expanded=1&include=progress` endpoint as `item(id:)`
    /// (identical request-building — no duplicated fetch), decoded against the podcast-shaped
    /// `PodcastDetail` instead of the book-shaped `LibraryItemDetail`: a podcast's `media.metadata`
    /// is a different shape from a book's, and only a podcast's `media` carries `episodes[]`.
    /// Callers pick this vs. `item(id:)` based on the library's/item's `mediaType`.
    public func podcastItem(id: String) async throws -> PodcastDetail {
        try await authorizedSend(itemDetailRequest(id: id), as: PodcastDetail.self)
    }

    private func itemDetailRequest(id: String) -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: "api/items/\(id)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "expanded", value: "1"), .init(name: "include", value: "progress")]
        return URLRequest(url: comps.url!)
    }

    /// `GET /api/libraries/:id/personalized?limit=` — home-screen shelves (Continue Listening,
    /// Recently Added, Newest Authors on a book library; podcast libraries add episode shelves).
    public func personalizedShelves(libraryID: String, limit: Int = 10) async throws -> [Shelf] {
        var comps = URLComponents(url: baseURL.appending(path: "api/libraries/\(libraryID)/personalized"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "limit", value: String(limit))]
        return try await authorizedSend(URLRequest(url: comps.url!), as: [Shelf].self)
    }

    /// `GET /api/libraries/:id/filterdata` — facet values + counts for the library's sort/filter UI.
    public func filterData(libraryID: String) async throws -> FilterData {
        try await authorizedSend(get("api/libraries/\(libraryID)/filterdata"), as: FilterData.self)
    }

    /// `GET /api/libraries/:id/series?limit=`. The server accepts an omitted `limit` (returns
    /// HTTP 200 with `limit:0` and no results — verified live, NOT a 400), so `limit` is a
    /// required *parameter here* purely because a call is only useful with an explicit positive
    /// value: `limit:0` yields an empty `results`. Pass the page size you actually want.
    public func series(libraryID: String, limit: Int) async throws -> [SeriesSummary] {
        var comps = URLComponents(url: baseURL.appending(path: "api/libraries/\(libraryID)/series"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "limit", value: String(limit))]
        return try await authorizedSend(URLRequest(url: comps.url!), as: SeriesListResponse.self).results
    }

    /// `GET /api/libraries/:id/authors` — all authors in the library (browse list).
    public func authors(libraryID: String) async throws -> [AuthorSummary] {
        try await authorizedSend(get("api/libraries/\(libraryID)/authors"), as: AuthorsResponse.self).authors
    }

    /// `GET /api/authors/:id?include=items` — one author's detail. `include: "items"` (the
    /// default here) also populates `libraryItems` with that author's books.
    public func author(id: String, include: String? = "items") async throws -> AuthorDetail {
        var comps = URLComponents(url: baseURL.appending(path: "api/authors/\(id)"), resolvingAgainstBaseURL: false)!
        if let include { comps.queryItems = [.init(name: "include", value: include)] }
        return try await authorizedSend(URLRequest(url: comps.url!), as: AuthorDetail.self)
    }

    /// `GET /api/libraries/:id/search?q=&limit=` — per-library search.
    ///
    /// **Caller contract:** never call with an empty query, and treat sub-2-character queries as
    /// not worth sending — the server 400s on an empty/missing `q` (verified live) and match
    /// quality is poor below ~2 characters. Guard client-side; this method does not.
    ///
    /// **Match-bucket behavior (verified live):** the `book` bucket matches
    /// title/subtitle/isbn/asin ONLY — NOT author name. A query that only matches an author
    /// (e.g. "sun" → "Sun Tzu") returns an EMPTY `book` bucket; the hit surfaces instead in the
    /// `authors` bucket. Render both.
    public func searchLibrary(libraryID: String, query: String, limit: Int = 12) async throws -> SearchResults {
        var comps = URLComponents(url: baseURL.appending(path: "api/libraries/\(libraryID)/search"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "q", value: query), .init(name: "limit", value: String(limit))]
        return try await authorizedSend(URLRequest(url: comps.url!), as: SearchResults.self)
    }

    /// `GET /api/me` — the progress-join source (`mediaProgress[]`, since shelf entities carry no
    /// progress — verified live) and bookmarks for the M1c-b player.
    public func me() async throws -> MeUser {
        try await authorizedSend(get("api/me"), as: MeUser.self)
    }

    /// A typed, keyed view over `me()`'s `mediaProgress[]` for last-write-wins reconcile
    /// (Task 6): callers look up a pending local session's server-side counterpart by
    /// `(libraryItemId, episodeId)` and compare `MediaProgressEntry.lastUpdate` against the local
    /// session's `updatedAt` — newer SERVER progress wins locally (spec §3); otherwise the local
    /// session is what still needs pushing via `syncLocalSessions`. Built from a SINGLE `me()`
    /// call — `me()` already exists and already carries everything needed, so this never
    /// refetches redundantly.
    public func progressReconcileView() async throws -> ProgressReconcileView {
        ProgressReconcileView(entries: try await me().mediaProgress ?? [])
    }

    public func coverURL(itemID: String, width: Int, updatedAt: Int?) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "api/items/\(itemID)/cover"),
                                  resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [.init(name: "width", value: String(width))]
        if let updatedAt { query.append(.init(name: "ts", value: String(updatedAt))) }
        comps.queryItems = query
        return comps.url!
    }

    /// `GET /api/authors/:id/image?width=` — an author's photo (present only when
    /// `AuthorSummary`/`AuthorDetail.imagePath != nil`). **PUBLIC, no auth needed — verified both
    /// ways this milestone:** (1) source: ABS `Auth.js` lists `^/(api/)?authors/[^/]+/image$`
    /// alongside `^/(api/)?items/[^/]+/cover$` in its `ignorePatterns` GET-auth-bypass list — the
    /// exact same allowlist as the cover endpoint; (2) live against this dev server: the seeded
    /// author's `imagePath` is null (no file on disk) so both an unauthenticated and a
    /// Bearer-authed request 404 IDENTICALLY (same status either way is what proves auth isn't
    /// the deciding factor — a genuinely gated endpoint would 401 without the token). So, like
    /// `coverURL`, this is a plain unauthenticated URL — no Bearer header, no token query param.
    public func authorImageURL(authorID: String, width: Int) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "api/authors/\(authorID)/image"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "width", value: String(width))]
        return comps.url!
    }

    /// `GET /api/items/:id/file/:ino/download?token=<accessToken>` — the per-file download route
    /// (NEVER the zip endpoint; range/resume is server-supported via Express `sendFile`).
    /// Downloads run in a background `URLSession` OUTSIDE this client's authorized-request
    /// machinery (Task 4's `DownloadCoordinator`/`DownloadManager` — no shared session, no
    /// Bearer-header 401-refresh loop reachable from a background delegate callback), so the
    /// token travels as a plain `token` query parameter instead of an `Authorization` header —
    /// unlike `coverURL`/`authorImageURL` (genuinely unauthenticated), this endpoint IS gated, so
    /// the token is required. `async throws` (not a plain URL builder) because it needs a live
    /// access token (`auth.currentAccessToken()`) — the SAME auth source every other
    /// authenticated call uses, just carried differently for this one background-session caller.
    /// `URLComponents.queryItems` percent-encodes the token correctly (it may contain JWT
    /// characters like `.`/`-`/`_`); `URL.appending(path:)` does the same for `itemID`/`ino`.
    ///
    /// **Credential handling (Task 4 MUST honor):** the embedded `token` is the live access token
    /// — a Bearer-EQUIVALENT credential that grants full API access, and one that EXPIRES (~1h
    /// server-side). So a returned URL is short-lived and secret: Task 4 must re-derive it (call
    /// this again) immediately before each (re)transfer or resume — a URL captured earlier can
    /// carry a stale/expired token and 401 — and must NEVER log, persist, or surface the full URL
    /// (it embeds the credential in the query string). Log the item/ino, not the URL.
    public func fileDownloadURL(itemID: String, ino: String) async throws -> URL {
        let token = try await auth.currentAccessToken()
        var comps = URLComponents(url: baseURL.appending(path: "api/items/\(itemID)/file/\(ino)/download"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "token", value: token)]
        return comps.url!
    }

    // MARK: - Internals

    func get(_ path: String) -> URLRequest { URLRequest(url: baseURL.appending(path: path)) }

    func authorizedSend<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await authorizedData(request)
        return try ABSAPI.decoder.decode(T.self, from: data)
    }

    func authorizedData(_ request: URLRequest) async throws -> Data {
        let token = try await auth.currentAccessToken()
        var authed = request
        authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(authed)
        if response.statusCode == 401 {
            let fresh = try await auth.refreshAfterAuthFailure(staleToken: token)
            var retry = request
            retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            let second = try await transport.send(retry)
            guard (200..<300).contains(second.statusCode) else { throw ABSError.http(status: second.statusCode) }
            return second.data
        }
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
        return response.data
    }
}

/// A `startPlayback` response paired with the raw bytes the server returned. The raw bytes
/// are the exact shape `api/session/local` expects for 404-recovery upserts — re-encoding the
/// decoded `PlaybackSession` would drop server fields we don't model and risk a shape mismatch.
public struct PlaybackSessionEnvelope: Sendable {
    public let session: PlaybackSession
    public let rawData: Data
    public init(session: PlaybackSession, rawData: Data) { self.session = session; self.rawData = rawData }
}

/// A keyed view over `MeUser.mediaProgress[]`, built by `ABSClient.progressReconcileView()`, so
/// the offline reconcile (Task 6) can look up a pending local session's server-side counterpart in
/// O(1) and compare `MediaProgressEntry.lastUpdate` against the local session's `updatedAt`.
///
/// **Key normalization (load-bearing):** the lookup key `episodeID` is normalized to a
/// NON-optional `String` with `""` meaning "book / no episode" — the EXACT convention
/// `LibraryCache.CachedProgress.episodeID` uses (which stores `episodeID ?? ""`). `me()`'s own
/// `episodeId` is `nil` for a book, so this maps `nil → ""` on both insert and lookup; without
/// that, a Task-6 lookup keyed by a `CachedProgress.episodeID` of `""` would never match a book's
/// `me()` entry (`Optional("") != Optional.none`) and last-write-wins would silently never fire
/// for ANY book. Call `progress(itemID:episodeID:)` with a `CachedProgress.episodeID` value
/// directly — it needs no `nil`/`""` massaging at the call site.
public struct ProgressReconcileView: Sendable {
    struct Key: Hashable, Sendable { let libraryItemId: String; let episodeID: String }
    private let byKey: [Key: MediaProgressEntry]

    /// Normalizes an optional episode id (`me()`'s `nil`, or a `CachedProgress.episodeID` that is
    /// already `""` for a book) to the single `""`-for-book convention both sides share.
    private static func normalize(_ episodeID: String?) -> String {
        (episodeID?.isEmpty ?? true) ? "" : episodeID!
    }

    init(entries: [MediaProgressEntry]) {
        var map: [Key: MediaProgressEntry] = [:]
        for entry in entries {
            map[Key(libraryItemId: entry.libraryItemId, episodeID: Self.normalize(entry.episodeId))] = entry
        }
        byKey = map
    }

    /// The server's progress for this item/episode, if any — the accessor Task 6 calls with a
    /// `CachedProgress.episodeID` (a non-optional `String`, `""` = book; `nil` also accepted and
    /// treated identically). `nil` return means the server has no record — a brand-new local
    /// session with nothing to reconcile against, always safe to push.
    public func progress(itemID: String, episodeID: String? = nil) -> MediaProgressEntry? {
        byKey[Key(libraryItemId: itemID, episodeID: Self.normalize(episodeID))]
    }

    /// Convenience subscript equivalent to `progress(itemID:episodeID:)` (same `""`==book==nil
    /// normalization), kept for terse call sites and tests.
    public subscript(itemID: String, episodeID: String? = nil) -> MediaProgressEntry? {
        progress(itemID: itemID, episodeID: episodeID)
    }
}

extension ABSClient {
    /// MIME types AVPlayer direct-plays; anything else transcodes to HLS server-side.
    static let supportedMimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-m4b"]

    public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSessionEnvelope {
        let req = try playRequest(path: "api/items/\(itemID)/play", deviceInfo: deviceInfo,
                                  forceDirectPlay: false, forceTranscode: false)
        return try await sendPlayRequest(req)
    }

    /// `POST /api/items/:id/play/:episodeId` — episode playback through the SAME envelope shape
    /// as book `startPlayback` (session id, audioTracks, chapters, currentTime — verified live,
    /// M1c-c Task 1's `episode-play.json`). Mirrors `startPlayback`'s request-building exactly
    /// (deviceInfo body, header, decode), just against the episode-scoped path, and threads
    /// `forceDirectPlay`/`forceTranscode` through for the HLS/direct-play rules.
    public func playEpisode(
        itemID: String,
        episodeId: String,
        deviceInfo: DeviceInfo,
        forceDirectPlay: Bool = false,
        forceTranscode: Bool = false
    ) async throws -> PlaybackSessionEnvelope {
        let req = try playRequest(path: "api/items/\(itemID)/play/\(episodeId)", deviceInfo: deviceInfo,
                                  forceDirectPlay: forceDirectPlay, forceTranscode: forceTranscode)
        return try await sendPlayRequest(req)
    }

    private struct PlayRequest: Encodable {
        let deviceInfo: DeviceInfo
        let mediaPlayer: String
        let supportedMimeTypes: [String]
        let forceDirectPlay: Bool
        let forceTranscode: Bool
    }

    private func playRequest(
        path: String, deviceInfo: DeviceInfo, forceDirectPlay: Bool, forceTranscode: Bool
    ) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(PlayRequest(
            deviceInfo: deviceInfo, mediaPlayer: "AVPlayer",
            supportedMimeTypes: Self.supportedMimeTypes,
            forceDirectPlay: forceDirectPlay, forceTranscode: forceTranscode))
        return req
    }

    private func sendPlayRequest(_ req: URLRequest) async throws -> PlaybackSessionEnvelope {
        let data = try await authorizedData(req)
        let session = try ABSAPI.decoder.decode(PlaybackSession.self, from: data)
        return PlaybackSessionEnvelope(session: session, rawData: data)
    }

    /// Recovery path when the server has restarted and lost the in-memory session (sync/close
    /// then 404): resubmits the original `startPlayback` JSON with progress fields overwritten,
    /// which the server accepts as a local-progress upsert independent of session lifecycle.
    public func postLocalSession(rawData: Data, currentTime: Double, totalListened: Double) async throws {
        guard var object = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw ABSError.invalidResponse
        }
        object["currentTime"] = currentTime
        object["timeListening"] = totalListened
        object["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
        var req = URLRequest(url: baseURL.appending(path: "api/session/local"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: object)
        _ = try await authorizedData(req)
    }

    /// `POST /api/session/local-all` `{sessions, deviceInfo}` — batch counterpart to
    /// `postLocalSession`'s single-session upsert, for reconciling many offline-accrued local
    /// sessions in one round trip after a reconnect (Task 6). Returns the server's PER-SESSION
    /// results — this is load-bearing, NOT cosmetic: `POST /api/session/local-all` always answers
    /// HTTP 200 even when INDIVIDUAL sessions are rejected (e.g. the source item was deleted or
    /// moved on the server while the device was offline → `"Media item not found"`), so a bare
    /// "didn't throw" would make a permanently-rejected session indistinguishable from a synced
    /// one. Task 6 MUST prune only the sessions whose `LocalSessionSyncResult.success == true`,
    /// re-queueing (or surfacing) the rest, so their offline listening time is never silently
    /// lost. Verified against ABS `PlaybackSessionManager.syncLocalSessionsRequest`/
    /// `syncLocalSession`: the server responds `{results: [{id, success, error?}, …]}`.
    ///
    /// Body shape: the server builds `new PlaybackSession(sessionJson)` per array element and, on
    /// FIRST INSERT of a session id ONLY, sets `session.deviceInfo = deviceInfo` from the
    /// TOP-LEVEL batch `deviceInfo` (a sibling of `sessions`, not each session's own nested
    /// field); a resync of an already-persisted id updates only `currentTime`/`timeListening`/
    /// `updatedAt` and leaves the stored `deviceInfo` untouched. Every session queued by this app
    /// instance shares one device, so this derives that top-level `deviceInfo` from the batch's
    /// first session rather than taking a redundant separate parameter. An empty `sessions` array
    /// is a no-op returning `[]` — nothing to reconcile, and no `deviceInfo` to report.
    @discardableResult
    public func syncLocalSessions(_ sessions: [LocalPlaybackSession]) async throws -> [LocalSessionSyncResult] {
        guard let deviceInfo = sessions.first?.deviceInfo else { return [] }
        struct Body: Encodable { let sessions: [LocalPlaybackSession]; let deviceInfo: DeviceInfo }
        var req = URLRequest(url: baseURL.appending(path: "api/session/local-all"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(Body(sessions: sessions, deviceInfo: deviceInfo))
        let data = try await authorizedData(req)
        return try ABSAPI.decoder.decode(LocalSessionSyncResponse.self, from: data).results
    }

    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/sync",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    public func closeSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/close",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    /// Verified against a live ABS 2.35.1 server (see ContractTests.fullPlaybackLifecycle):
    /// pass the audio track's own 1-indexed `AudioTrack.index` value directly as `trackIndex`,
    /// not its position in the `audioTracks` array — the server resolves the URL by that field
    /// and serves the correct bytes. Range requests are honored (206 + exact byte count).
    public func publicTrackURL(sessionID: String, trackIndex: Int) -> URL {
        baseURL.appending(path: "public/session/\(sessionID)/track/\(trackIndex)")
    }

    /// `POST /api/me/item/:id/bookmark` `{time,title}` — creates a bookmark at `time` (fractional
    /// SECONDS — playback positions are fractional) with `title`; returns the created `Bookmark`
    /// (verified live this session, incl. `Tests/ABSKitTests/Fixtures/bookmark.json`, a real
    /// captured-then-deleted server response). `time` is a `Double` so a bookmark created at the
    /// exact current position round-trips: the server keys bookmarks by `time`, and truncating a
    /// fractional value to an Int makes the matching PATCH/DELETE 404 (see `updateBookmark`/
    /// `deleteBookmark`).
    public func createBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark {
        try await sendBookmarkMutation(method: "POST", itemID: itemID, time: time, title: title)
    }

    /// `PATCH /api/me/item/:id/bookmark` `{time,title}` — the server matches the bookmark to
    /// rename by its `time` value (there is no separate id — verified live); returns the updated
    /// `Bookmark`. `time` must be the EXACT value the bookmark was created at: PATCH `{time:55}`
    /// against a bookmark stored at `55.7` 404s (verified live) — pass the fractional value.
    public func updateBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark {
        try await sendBookmarkMutation(method: "PATCH", itemID: itemID, time: time, title: title)
    }

    /// `DELETE /api/me/item/:id/bookmark/:time` — unlike create/update, `time` is part of the
    /// PATH here, not a JSON body (verified live). The path segment must NUMERICALLY equal the
    /// stored `time`: `DELETE /bookmark/55` against a bookmark stored at `55.7` 404s (Int
    /// truncation — verified live), while the exact `/bookmark/55.7` succeeds. A whole-second
    /// bookmark accepts either `/bookmark/55` or `/bookmark/55.0` (also verified) — this renders
    /// whole values without a trailing `.0` (`bookmarkTimePathValue`) purely for clean URLs.
    /// 200 with no body worth decoding.
    public func deleteBookmark(itemID: String, time: Double) async throws {
        let segment = Self.bookmarkTimePathValue(time)
        var req = URLRequest(url: baseURL.appending(path: "api/me/item/\(itemID)/bookmark/\(segment)"))
        req.httpMethod = "DELETE"
        _ = try await authorizedData(req)
    }

    /// Renders a bookmark `time` for the DELETE path segment: whole seconds without a trailing
    /// `.0` ("55"), fractional seconds faithfully ("55.7"). Both forms match the server's stored
    /// value numerically; this keeps whole-second URLs clean while never truncating a fractional
    /// bookmark to the wrong key.
    static func bookmarkTimePathValue(_ time: Double) -> String {
        time == time.rounded() ? String(Int(time)) : String(time)
    }

    private struct BookmarkRequest: Encodable { let time: Double; let title: String }

    private func sendBookmarkMutation(method: String, itemID: String, time: Double, title: String) async throws -> Bookmark {
        var req = URLRequest(url: baseURL.appending(path: "api/me/item/\(itemID)/bookmark"))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(BookmarkRequest(time: time, title: title))
        return try await authorizedSend(req, as: Bookmark.self)
    }

    private func postSessionPayload(path: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(
            ["currentTime": currentTime, "timeListened": timeListened, "duration": duration])
        _ = try await authorizedData(req)
    }
}
