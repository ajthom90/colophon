import Foundation
import DownloadManager

/// A scripted `DownloadManaging` test double — the seam `DownloadCoordinator` consumes. It fakes at
/// the MANAGER level (per-file `DownloadUpdate`s), NOT the session level, so a coordinator test needs
/// no real files or network: `enqueue` records the fileID and returns a per-file stream; scripting
/// (`emitProgress`/`complete`/`fail`) broadcasts updates to every `updates()` observer (and the
/// per-file stream); `reattach` replays a terminal `.downloaded` for any fileID pre-armed via
/// `scheduleReattachFinished` (the "finished while the app was dead" case).
///
/// Lock-guarded `@unchecked Sendable`, mirroring `FakeDownloadSession`/`FakeSocket` — registration is
/// synchronous so `updates()` returning means the observer is live, no ordering hazard with a
/// subsequent emit.
final class FakeDownloadManaging: DownloadManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _observers: [UUID: AsyncStream<DownloadUpdate>.Continuation] = [:]
    private var _perFile: [String: AsyncStream<DownloadUpdate>.Continuation] = [:]
    private var _enqueued: [String] = []
    private var _cancelled: [String] = []
    private var _lastState: [String: DownloadState] = [:]
    private var _outstanding: [String] = []
    private var _reattachFinished: Set<String> = []
    private var _backgroundHandler: (@Sendable () -> Void)?

    init() {}

    // MARK: - Test-facing observation

    var enqueuedFileIDs: [String] { lock.withLock { _enqueued } }
    var cancelledFileIDs: [String] { lock.withLock { _cancelled } }

    // MARK: - DownloadManaging

    @discardableResult
    func enqueue(
        fileID: String, request: URLRequest, destination: URL, resumeData: Data?
    ) async -> AsyncStream<DownloadUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadUpdate.self, bufferingPolicy: .bufferingNewest(64))
        lock.withLock {
            _enqueued.append(fileID)
            _perFile[fileID]?.finish()
            _perFile[fileID] = continuation
            _lastState[fileID] = .downloading(receivedBytes: 0, totalBytes: 0)
        }
        return stream
    }

    func cancel(fileID: String) async {
        let continuation = lock.withLock { () -> AsyncStream<DownloadUpdate>.Continuation? in
            _cancelled.append(fileID)
            return _perFile.removeValue(forKey: fileID)
        }
        continuation?.finish()
    }

    func pause(fileID: String) async -> Data? { nil }

    func state(for fileID: String) async -> DownloadState? { lock.withLock { _lastState[fileID] } }

    func updates() async -> AsyncStream<DownloadUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadUpdate.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        lock.withLock { _observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        return stream
    }

    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) async {
        lock.withLock { _backgroundHandler = handler }
    }

    func reattach(destinations: [String: URL]) async {
        // Replay a terminal `.downloaded` for every armed "finished while dead" fileID the caller
        // supplied a destination for — exactly what the real background session surfaces on relaunch.
        let toEmit = lock.withLock { _reattachFinished.filter { destinations[$0] != nil } }
        for fileID in toEmit { emit(DownloadUpdate(fileID: fileID, state: .downloaded)) }
    }

    // MARK: - Scripting

    func emitProgress(fileID: String, received: Int64, total: Int64) {
        emit(DownloadUpdate(fileID: fileID, state: .downloading(receivedBytes: received, totalBytes: total)))
    }

    func complete(fileID: String) {
        emit(DownloadUpdate(fileID: fileID, state: .downloaded))
    }

    func fail(fileID: String, error: any Error & Sendable = FakeDownloadError()) {
        emit(DownloadUpdate(fileID: fileID, state: .failed(error)))
    }

    /// Arm `fileID` to be reported as finished-while-dead on the next `reattach`.
    func scheduleReattachFinished(fileID: String) {
        lock.withLock { _outstanding.append(fileID); _reattachFinished.insert(fileID) }
    }

    // MARK: - Internals

    private func emit(_ update: DownloadUpdate) {
        let (perFile, observers) = lock.withLock {
            () -> (AsyncStream<DownloadUpdate>.Continuation?, [AsyncStream<DownloadUpdate>.Continuation]) in
            _lastState[update.fileID] = update.state
            return (_perFile[update.fileID], Array(_observers.values))
        }
        perFile?.yield(update)
        for observer in observers { observer.yield(update) }
    }

    private func removeObserver(_ id: UUID) { lock.withLock { _observers[id] = nil } }
}

/// A minimal `Sendable` error for scripting a failed file transfer.
struct FakeDownloadError: Error, Sendable {}
