import Foundation
import DownloadManager

/// Deterministic `DownloadSession` test double: drives progress + terminal outcomes with no
/// network. Scripting methods (`emitProgress`, `complete`, `fail`) push events into the stream
/// returned by `start`. Lock-guarded rather than an actor so `start` can register a continuation
/// synchronously — no ordering hazard between `start` returning and a scripted event.
///
/// Mirrors `FakePlayerBackend` (PlayerEngine) / `MockTransport` (ABSKit): a scripted seam double.
final class FakeDownloadSession: DownloadSession, @unchecked Sendable {
    struct Start: Equatable, Sendable {
        let id: String
        let resumeData: Data?
    }

    private let lock = NSLock()
    private var _starts: [Start] = []
    private var _cancelled: [String] = []
    private var _continuations: [String: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var _outstanding: [String] = []
    private var _backgroundHandler: (@Sendable () -> Void)?
    /// Resume data the fake hands back from `cancelProducingResumeData`.
    private var _resumeData = Data("resume-token".utf8)

    init() {}

    /// Every `start` call, in order — lets tests assert the resume-data round-trip.
    var starts: [Start] { lock.withLock { _starts } }
    var cancelledIDs: [String] { lock.withLock { _cancelled } }

    // MARK: - DownloadSession

    func start(id: String, request: URLRequest, resumeData: Data?) -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadEvent.self, bufferingPolicy: .bufferingNewest(64)
        )
        lock.withLock {
            // Supersede contract: a re-`start` for a live id finishes the prior (single-consumer)
            // stream before handing back a fresh one — a faithful mirror of the real session.
            _continuations[id]?.finish()
            _starts.append(Start(id: id, resumeData: resumeData))
            _continuations[id] = continuation
        }
        return stream
    }

    func cancel(id: String) async {
        let continuation = lock.withLock { () -> AsyncStream<DownloadEvent>.Continuation? in
            _cancelled.append(id)
            return _continuations.removeValue(forKey: id)
        }
        continuation?.yield(.cancelled(resumeData: nil))
        continuation?.finish()
    }

    func cancelProducingResumeData(id: String) async -> Data? {
        let (continuation, data) = lock.withLock {
            () -> (AsyncStream<DownloadEvent>.Continuation?, Data) in
            _cancelled.append(id)
            return (_continuations.removeValue(forKey: id), _resumeData)
        }
        continuation?.yield(.cancelled(resumeData: data))
        continuation?.finish()
        return data
    }

    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { _backgroundHandler = handler }
    }

    /// Transfers the fake still "tracks" after a simulated relaunch — seed via `outstanding`.
    func reattachOutstandingTransfers() async -> [String] {
        lock.withLock { _outstanding }
    }

    /// Re-attach a fresh stream for an outstanding id, mirroring the real session: buffered events
    /// scripted afterwards (progress/complete/fail) flow to it.
    func attach(id: String) -> AsyncStream<DownloadEvent>? {
        lock.withLock {
            guard _outstanding.contains(id) else { return nil }
            let (stream, continuation) = AsyncStream.makeStream(
                of: DownloadEvent.self, bufferingPolicy: .bufferingNewest(64)
            )
            _continuations[id] = continuation
            return stream
        }
    }

    /// Seed the ids `reattachOutstandingTransfers` reports (a simulated post-relaunch outstanding set).
    func setOutstanding(_ ids: [String]) { lock.withLock { _outstanding = ids } }

    // MARK: - Scripting

    func emitProgress(id: String, bytesWritten: Int64, totalBytesExpected: Int64) {
        continuation(id)?.yield(.progress(bytesWritten: bytesWritten, totalBytesExpected: totalBytesExpected))
    }

    func complete(id: String, temporaryURL: URL) {
        let continuation = lock.withLock { _continuations.removeValue(forKey: id) }
        continuation?.yield(.finished(temporaryURL: temporaryURL))
        continuation?.finish()
    }

    func fail(id: String, error: any Error & Sendable, resumeData: Data? = nil) {
        let continuation = lock.withLock { _continuations.removeValue(forKey: id) }
        continuation?.yield(.failed(error, resumeData: resumeData))
        continuation?.finish()
    }

    /// Simulate the background session finishing its event replay after a relaunch.
    func finishBackgroundEvents() {
        let handler = lock.withLock { _backgroundHandler }
        handler?()
    }

    private func continuation(_ id: String) -> AsyncStream<DownloadEvent>.Continuation? {
        lock.withLock { _continuations[id] }
    }
}

/// A tiny thread-safe boolean flag for asserting a `@Sendable` callback fired.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func raise() { lock.withLock { _value = true } }
}
