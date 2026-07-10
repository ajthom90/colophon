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

    // MARK: - Artwork thumbnails (container files)

    private var artworkDirectoryURL: URL {
        containerURL.appending(path: Self.artworkDirectoryName, directoryHint: .isDirectory)
    }

    /// Write cover-thumbnail `data` under a filename derived from `key`, returning the path RELATIVE
    /// to the container (what the snapshot stores). `nil` on write failure.
    @discardableResult
    public func writeArtwork(_ data: Data, forKey key: String) -> String? {
        ensureContainer()
        try? FileManager.default.createDirectory(at: artworkDirectoryURL, withIntermediateDirectories: true)
        let fileName = Self.artworkFileName(forKey: key)
        let url = artworkDirectoryURL.appending(path: fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return Self.artworkDirectoryName + "/" + fileName
    }

    /// The absolute URL for a container-relative artwork path (for `UIImage(contentsOfFile:)` etc.).
    public func artworkURL(forRelativePath relativePath: String) -> URL {
        containerURL.appending(path: relativePath)
    }

    /// Read the raw thumbnail bytes at a container-relative path, or `nil` when absent.
    public func readArtwork(atRelativePath relativePath: String) -> Data? {
        try? Data(contentsOf: artworkURL(forRelativePath: relativePath))
    }

    // MARK: - Helpers

    private func ensureContainer() {
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    }

    /// A filesystem-safe, deterministic filename for `key` (alphanumerics kept; everything else → `_`).
    /// Item/episode ids are alphanumeric-ish, so collisions across distinct keys are not a concern.
    static func artworkFileName(forKey key: String) -> String {
        let safe = String(key.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return safe + ".img"
    }
}
