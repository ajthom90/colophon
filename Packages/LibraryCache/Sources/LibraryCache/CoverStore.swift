import Foundation

/// Disk-backed cover art cache, keyed by connection and item so covers from different
/// servers/users never collide. Layout: `<directory>/<connectionID>/<itemID>-<updatedAt ?? 0>.img`.
/// A hit reads the exact-timestamp file straight off disk without invoking `fetch`; a miss
/// fetches, writes the new file, and deletes any other `<itemID>-*.img` for that item so a
/// stale (pre-update) cover never lingers alongside the fresh one.
public actor CoverStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func coverData(
        connectionID: String, itemID: String, updatedAt: Int?,
        fetch: @Sendable () async throws -> Data
    ) async throws -> Data {
        let ts = updatedAt ?? 0
        let connDir = directory.appending(path: connectionID)
        let file = connDir.appending(path: "\(itemID)-\(ts).img")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        let data = try await fetch()
        try FileManager.default.createDirectory(at: connDir, withIntermediateDirectories: true)
        // Write the new file BEFORE sweeping stale ones (excluding the fresh file from the
        // sweep) so a crash mid-sequence never leaves an item with zero cached covers.
        try data.write(to: file, options: .atomic)
        if let stale = try? FileManager.default.contentsOfDirectory(atPath: connDir.path) {
            for name in stale where name.hasPrefix("\(itemID)-") && name != file.lastPathComponent {
                try? FileManager.default.removeItem(at: connDir.appending(path: name))
            }
        }
        return data
    }
}
