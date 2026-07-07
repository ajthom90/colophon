import Foundation

/// Disk-backed cover art cache, keyed by connection and item so covers from different
/// servers/users never collide. Layout: `<directory>/<connectionID>/<itemID>-<updatedAt ?? 0>.img`.
/// A hit reads the exact-timestamp file straight off disk without invoking `fetch`; a miss
/// fetches, writes the new file, and deletes any other `<itemID>-*.img` for that item so a
/// stale (pre-update) cover never lingers alongside the fresh one.
///
/// Concurrent misses for the SAME `(connectionID, itemID, updatedAt)` key share a single
/// in-flight `fetch()` rather than each firing their own network request — M1c's shelves and
/// grid can render the same cover from multiple views at once. The in-flight `Task` is held
/// in an actor-private map keyed by that same identity, checked/inserted with no `await` in
/// between (actor isolation makes that atomic), and removed once the task finishes, whether
/// it succeeds or throws — so a failing shared fetch propagates to every awaiter and a later
/// request for that key retries from scratch.
public actor CoverStore {
    private struct Key: Hashable {
        let connectionID: String
        let itemID: String
        let updatedAt: Int
    }

    private let directory: URL
    private var inFlight: [Key: Task<Data, Error>] = [:]

    public init(directory: URL) { self.directory = directory }

    public func coverData(
        connectionID: String, itemID: String, updatedAt: Int?,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let ts = updatedAt ?? 0
        let connDir = directory.appending(path: connectionID)
        let file = connDir.appending(path: "\(itemID)-\(ts).img")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }

        let key = Key(connectionID: connectionID, itemID: itemID, updatedAt: ts)
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> {
            let data = try await fetch()
            try FileManager.default.createDirectory(at: connDir, withIntermediateDirectories: true)
            // Write the new file BEFORE sweeping stale ones (excluding the fresh file from
            // the sweep) so a crash mid-sequence never leaves an item with zero cached covers.
            try data.write(to: file, options: .atomic)
            if let stale = try? FileManager.default.contentsOfDirectory(atPath: connDir.path) {
                for name in stale where name.hasPrefix("\(itemID)-") && name != file.lastPathComponent {
                    try? FileManager.default.removeItem(at: connDir.appending(path: name))
                }
            }
            return data
        }
        inFlight[key] = task
        // The creating call owns clearing the map: `defer` runs when THIS invocation resumes
        // after the awaited task settles (success or throw) — back on the actor, no extra
        // `await` needed to mutate `inFlight`. That makes the clear deterministic (no
        // fire-and-forget lag) so a request issued right after this one returns never attaches
        // to a stale, already-finished/failed task.
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }

    /// Removes every cached cover for a connection by deleting its `<directory>/<connectionID>`
    /// folder. Called by `AppState.removeConnection` alongside the SQLite cache purge so a
    /// forgotten server leaves no cover art on disk. A missing folder is a no-op.
    public func deleteConnection(connectionID: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: connectionID))
    }
}
