import Foundation

/// Read/write bridge over the App Group container shared by the app and its extensions.
///
/// Layout:
///   - `NowPlayingSnapshot` → a JSON blob in `UserDefaults(suiteName:)` (small, frequently rewritten).
///   - `ContinueListeningSnapshot` → a JSON file in the container (a list; slightly larger).
///   - Cover thumbnails → files under `artwork/` in the container, referenced by a RELATIVE path
///     stored on the snapshots.
///
/// SECURITY: this type exposes NO surface for tokens/credentials — only display snapshots and cover
/// thumbnails. Auth material stays device-local in the Keychain and never enters the App Group.
///
/// `Sendable`: holds only value types (`suiteName`, `containerURL`); it constructs the
/// (non-`Sendable`) `UserDefaults`/`FileManager` handles on demand inside each call.
public struct SharedStore: Sendable {
    private let suiteName: String
    private let containerURL: URL

    private static let nowPlayingDefaultsKey = "colophon.snapshot.nowPlaying"
    private static let continueListeningFileName = "continue-listening.json"
    private static let artworkDirectoryName = "artwork"
    /// SAME key as the app's `@AppStorage("colophon.typeface")` (`ColophonApp.swift`) — the
    /// standard `UserDefaults` suite the app-group suite mirrors it into (see
    /// `writeTypefacePreference`), so widgets/Live Activity can match the app's typography.
    private static let typefaceDefaultsKey = "colophon.typeface"

    /// Production initializer: resolves the shared `UserDefaults` suite and file container from the
    /// App Group id. Falls back to a temp directory if the container can't be resolved (no
    /// entitlement) so a misconfigured build degrades to a harmless no-op rather than crashing.
    public init(appGroupID: String) {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.temporaryDirectory.appending(path: appGroupID, directoryHint: .isDirectory)
        self.init(suiteName: appGroupID, containerURL: container)
    }

    /// Test seam: an explicit `UserDefaults` suite name + container directory, so a unit test can
    /// round-trip snapshots through a temp suite/dir WITHOUT a provisioned App Group container.
    public init(suiteName: String, containerURL: URL) {
        self.suiteName = suiteName
        self.containerURL = containerURL
    }

    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    // MARK: - Now playing (UserDefaults JSON)

    public func writeNowPlaying(_ snapshot: NowPlayingSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: Self.nowPlayingDefaultsKey)
    }

    public func readNowPlaying() -> NowPlayingSnapshot? {
        guard let data = defaults?.data(forKey: Self.nowPlayingDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    public func clearNowPlaying() {
        defaults?.removeObject(forKey: Self.nowPlayingDefaultsKey)
    }

    // MARK: - Continue listening (container file)

    private var continueListeningURL: URL {
        containerURL.appending(path: Self.continueListeningFileName)
    }

    public func writeContinueListening(_ snapshot: ContinueListeningSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        ensureContainer()
        try? data.write(to: continueListeningURL, options: .atomic)
    }

    public func readContinueListening() -> ContinueListeningSnapshot? {
        guard let data = try? Data(contentsOf: continueListeningURL) else { return nil }
        return try? JSONDecoder().decode(ContinueListeningSnapshot.self, from: data)
    }

    /// Remove the continue-listening blob entirely (M2b Task 5) — called on sign-out / connection
    /// removal so a signed-out connection's shelf never lingers for the widget or `resume`. A missing
    /// file is a no-op. `readContinueListening()` reads nil afterwards.
    public func clearContinueListening() {
        try? FileManager.default.removeItem(at: continueListeningURL)
    }

    // MARK: - Artwork thumbnails (container files)

    private var artworkDirectoryURL: URL {
        containerURL.appending(path: Self.artworkDirectoryName, directoryHint: .isDirectory)
    }

    /// The per-connection artwork subdirectory. Thumbnails are SCOPED by connection (M2b review #6)
    /// so a removed/signed-out server's covers can be pruned wholesale (`clearArtwork(connectionID:)`)
    /// and never linger in the persisted, extension-readable container after sign-out.
    private func artworkDirectoryURL(forConnection connectionID: String) -> URL {
        artworkDirectoryURL.appending(path: Self.pathComponent(forKey: connectionID), directoryHint: .isDirectory)
    }

    /// Write cover-thumbnail `data` under a filename derived from `key`, SCOPED to `connectionID`,
    /// returning the path RELATIVE to the container (what the snapshot stores). `nil` on write failure.
    /// The returned path (`artwork/<connection>/<key>.img`) is what the widget / Live Activity reads
    /// back via `readArtwork(atRelativePath:)`, so the read side needs no change to be connection-scoped.
    @discardableResult
    public func writeArtwork(_ data: Data, forKey key: String, connectionID: String) -> String? {
        ensureContainer()
        let directory = artworkDirectoryURL(forConnection: connectionID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = Self.artworkFileName(forKey: key)
        let url = directory.appending(path: fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return Self.artworkDirectoryName + "/" + Self.pathComponent(forKey: connectionID) + "/" + fileName
    }

    /// Delete ALL cover thumbnails for `connectionID` (sign-out / connection removal) so a signed-out
    /// server's covers never linger in the persisted, extension-readable container — mirrors
    /// `clearContinueListening()` + the Spotlight de-index (M2b review #6). A missing directory is a no-op.
    public func clearArtwork(connectionID: String) {
        try? FileManager.default.removeItem(at: artworkDirectoryURL(forConnection: connectionID))
    }

    /// The absolute URL for a container-relative artwork path (for `UIImage(contentsOfFile:)` etc.).
    public func artworkURL(forRelativePath relativePath: String) -> URL {
        containerURL.appending(path: relativePath)
    }

    /// Read the raw thumbnail bytes at a container-relative path, or `nil` when absent.
    public func readArtwork(atRelativePath relativePath: String) -> Data? {
        try? Data(contentsOf: artworkURL(forRelativePath: relativePath))
    }

    // MARK: - Typeface preference (mirrored so companion surfaces can match the app's typography)

    /// Mirrors the app's serif/default typeface preference into the shared suite. NOT sensitive
    /// (no token/credential concern applies) — companion surfaces (widgets, Live Activity) run in
    /// a separate process with their OWN standard `UserDefaults`, so they can't read the app's
    /// `@AppStorage("colophon.typeface")` directly; this is the bridge.
    public func writeTypefacePreference(_ typeface: String) {
        defaults?.set(typeface, forKey: Self.typefaceDefaultsKey)
    }

    /// Reads the mirrored typeface preference, defaulting to `"serif"` — the app's own
    /// `@AppStorage` default — when nothing has been mirrored yet (e.g. before the app's first
    /// snapshot publish).
    public func readTypefacePreference() -> String {
        defaults?.string(forKey: Self.typefaceDefaultsKey) ?? "serif"
    }

    // MARK: - Helpers

    private func ensureContainer() {
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    }

    /// A filesystem-safe path component for `key` (alphanumerics kept; everything else → `_`). Used for
    /// both artwork filenames and the per-connection subdirectory name. Item/episode/connection ids are
    /// alphanumeric-ish, so collisions across distinct keys are not a concern.
    static func pathComponent(forKey key: String) -> String {
        String(key.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// A filesystem-safe, deterministic filename for `key` (alphanumerics kept; everything else → `_`).
    static func artworkFileName(forKey key: String) -> String {
        pathComponent(forKey: key) + ".img"
    }
}
