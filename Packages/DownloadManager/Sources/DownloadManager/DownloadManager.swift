import Foundation

/// Per-file download state surfaced by `DownloadManager`. `failed` carries the transfer error.
public enum DownloadState: Sendable {
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case downloaded
    case failed(any Error & Sendable)
    case cancelled
}

public extension DownloadState {
    /// True for `downloaded`, `failed`, and `cancelled` — the states that end a transfer's stream.
    var isTerminal: Bool {
        switch self {
        case .downloading: false
        case .downloaded, .failed, .cancelled: true
        }
    }
}

extension DownloadState: Equatable {
    /// `failed` compares by the error's textual description (errors aren't `Equatable`), which is
    /// enough for tests to assert a specific failure while keeping the associated value general.
    public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        switch (lhs, rhs) {
        case let (.downloading(a, b), .downloading(c, d)): a == c && b == d
        case (.downloaded, .downloaded): true
        case let (.failed(e1), .failed(e2)): String(describing: e1) == String(describing: e2)
        case (.cancelled, .cancelled): true
        default: false
        }
    }
}

/// A per-file state update: which `fileID` changed, and its new `state`.
public struct DownloadUpdate: Sendable, Equatable {
    public let fileID: String
    public let state: DownloadState
    public init(fileID: String, state: DownloadState) {
        self.fileID = fileID
        self.state = state
    }
}

/// The download-orchestration surface. `DownloadManager` is the production actor; abstracting it
/// behind a protocol lets downstream unit tests inject a fake (matching the package seams'
/// idiom — `Transport`, `PlayerBackend`, `RealtimeSocketProtocol`).
public protocol DownloadManaging: Sendable {
    @discardableResult
    func enqueue(fileID: String, request: URLRequest, destination: URL, resumeData: Data?) async -> AsyncStream<DownloadUpdate>
    func cancel(fileID: String) async
    /// Cancel producing resume data (a "pause"); the returned `Data` re-`enqueue`s the transfer.
    func pause(fileID: String) async -> Data?
    func state(for fileID: String) async -> DownloadState?
    /// A merged stream of every file's updates — for aggregate observers (e.g. a coordinator).
    func updates() async -> AsyncStream<DownloadUpdate>
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) async
}

public extension DownloadManaging {
    /// Convenience: enqueue a fresh transfer with no resume data.
    @discardableResult
    func enqueue(fileID: String, request: URLRequest, destination: URL) async -> AsyncStream<DownloadUpdate> {
        await enqueue(fileID: fileID, request: request, destination: destination, resumeData: nil)
    }
}

/// Orchestrates background per-file transfers over a `DownloadSession`. **Pure transfer**: keyed
/// by an opaque `fileID`, with NO knowledge of library items, episodes, or the cache. On success
/// it moves the session's staged temp file to `destination`; on failure or cancel it leaves
/// `destination` untouched (no partial file is ever left behind).
public actor DownloadManager: DownloadManaging {
    private let session: any DownloadSession
    private let fileManager: FileManager

    /// Bookkeeping for one in-flight transfer. `token` distinguishes generations of the same
    /// `fileID`: a stale consumer from a superseded transfer is ignored in `handle`.
    private struct Transfer {
        let token: UUID
        let destination: URL
        let continuation: AsyncStream<DownloadUpdate>.Continuation
        var consumer: Task<Void, Never>?
    }

    private var transfers: [String: Transfer] = [:]
    /// Last known state per file — survives after a transfer completes, so `state(for:)` still
    /// answers for finished/failed/cancelled files.
    private var lastState: [String: DownloadState] = [:]
    private var observers: [UUID: AsyncStream<DownloadUpdate>.Continuation] = [:]

    public init(session: any DownloadSession, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    @discardableResult
    public func enqueue(
        fileID: String,
        request: URLRequest,
        destination: URL,
        resumeData: Data?
    ) async -> AsyncStream<DownloadUpdate> {
        // Replace any prior in-flight transfer for this id: stop consuming + finish the old stream,
        // then `session.cancel(id:)` so the underlying (background) task is torn down and does NOT
        // keep running untracked. See the `DownloadSession.start` supersede contract.
        if let existing = transfers.removeValue(forKey: fileID) {
            existing.consumer?.cancel()
            existing.continuation.finish()
            await session.cancel(id: fileID)
        }

        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadUpdate.self, bufferingPolicy: .bufferingNewest(64)
        )
        let events = session.start(id: fileID, request: request, resumeData: resumeData)
        transfers[fileID] = Transfer(
            token: token, destination: destination, continuation: continuation, consumer: nil
        )
        lastState[fileID] = .downloading(receivedBytes: 0, totalBytes: 0)

        let consumer = Task { [weak self] in
            for await event in events {
                await self?.handle(event: event, fileID: fileID, token: token)
            }
        }
        transfers[fileID]?.consumer = consumer
        return stream
    }

    public func cancel(fileID: String) async {
        guard transfers[fileID] != nil else { return }
        await session.cancel(id: fileID)
        // The session yields `.cancelled` on the transfer's stream, which `handle` turns into the
        // terminal `.cancelled` update.
    }

    public func pause(fileID: String) async -> Data? {
        guard transfers[fileID] != nil else { return nil }
        return await session.cancelProducingResumeData(id: fileID)
    }

    public func state(for fileID: String) -> DownloadState? { lastState[fileID] }

    public func updates() -> AsyncStream<DownloadUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadUpdate.self, bufferingPolicy: .bufferingNewest(256)
        )
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        session.setBackgroundCompletionHandler(handler)
    }

    // MARK: - Event handling

    private func handle(event: DownloadEvent, fileID: String, token: UUID) {
        // Ignore events from a superseded transfer generation (a re-enqueue replaced this one).
        guard let transfer = transfers[fileID], transfer.token == token else { return }
        switch event {
        case let .progress(written, total):
            emit(fileID: fileID, state: .downloading(receivedBytes: written, totalBytes: total))
        case let .finished(tempURL):
            do {
                try moveIntoPlace(from: tempURL, to: transfer.destination)
                finish(fileID: fileID, state: .downloaded)
            } catch {
                // Leave nothing behind: drop the staged temp and any half-written destination.
                try? fileManager.removeItem(at: tempURL)
                try? fileManager.removeItem(at: transfer.destination)
                finish(fileID: fileID, state: .failed(asSendableError(error)))
            }
        case let .failed(error, _):
            finish(fileID: fileID, state: .failed(error))
        case .cancelled:
            finish(fileID: fileID, state: .cancelled)
        }
    }

    /// Atomically place the completed temp file at `destination`, creating parent directories and
    /// replacing any existing file.
    private func moveIntoPlace(from tempURL: URL, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    private func emit(fileID: String, state: DownloadState) {
        lastState[fileID] = state
        let update = DownloadUpdate(fileID: fileID, state: state)
        transfers[fileID]?.continuation.yield(update)
        for observer in observers.values { observer.yield(update) }
    }

    private func finish(fileID: String, state: DownloadState) {
        emit(fileID: fileID, state: state)
        if let transfer = transfers.removeValue(forKey: fileID) {
            transfer.continuation.finish()
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
