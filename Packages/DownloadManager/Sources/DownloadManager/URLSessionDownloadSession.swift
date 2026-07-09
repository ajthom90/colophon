import Foundation

/// Production `DownloadSession` backed by `URLSession(configuration: .background(withIdentifier:))`.
///
/// A background session survives the app being suspended or killed: the system continues transfers
/// and, on relaunch, re-attaches to the SAME identifier and replays delegate callbacks. This type
/// bridges those delegate callbacks —
/// `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`,
/// `urlSession(_:downloadTask:didFinishDownloadingTo:)`, and
/// `urlSession(_:task:didCompleteWithError:)` — into the seam's `AsyncStream<DownloadEvent>` surface.
///
/// **Routing:** event channels are keyed by `URLSessionTask.taskIdentifier` (unique per task within
/// the session), NOT by `fileID`. This is what makes the `start` supersede contract safe: when a
/// re-`start` for a live `fileID` cancels the prior task, that prior task's late `didCompleteWithError`
/// closes ITS OWN (old) channel and cannot clobber the new transfer's stream. A `fileID → task` map
/// (via `taskDescription`, which the system preserves across relaunch) backs the caller-facing
/// `cancel`/`pause`/`attach` lookups.
///
/// The completed temp file handed to `didFinishDownloadingTo` is valid only until that method
/// returns, so it is moved into a stable staging directory synchronously before the `.finished`
/// event is yielded.
///
/// Not unit-tested (it requires a real `URLSession`); the manager's behavior is verified against
/// `FakeDownloadSession`. This mirrors `AVQueuePlayerBackend` vs `FakePlayerBackend` in PlayerEngine.
public final class URLSessionDownloadSession: NSObject, DownloadSession, @unchecked Sendable {
    public let identifier: String

    private let lock = NSLock()
    private let fileManager: FileManager
    private let stagingDirectory: URL

    private var session: URLSession!
    /// Channels keyed by `taskIdentifier`.
    private var streamsByTask: [Int: AsyncStream<DownloadEvent>] = [:]
    private var continuationsByTask: [Int: AsyncStream<DownloadEvent>.Continuation] = [:]
    /// The current task for each `fileID` — backs caller-facing `cancel`/`pause`/`attach`.
    private var taskByID: [String: URLSessionDownloadTask] = [:]
    private var backgroundCompletionHandler: (@Sendable () -> Void)?

    public init(identifier: String, fileManager: FileManager = .default) {
        self.identifier = identifier
        self.fileManager = fileManager
        self.stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DownloadManager-staging", isDirectory: true)
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - DownloadSession

    public func start(id: String, request: URLRequest, resumeData: Data?) -> AsyncStream<DownloadEvent> {
        // Supersede any live transfer for `id`. Cancelling the prior task lets IT close its own
        // channel (keyed by its taskIdentifier) via `didCompleteWithError` — the new task below
        // gets a fresh taskIdentifier and channel, so there is no clobber and no leaked task.
        let prior = lock.withLock { taskByID[id] }
        prior?.cancel()

        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)
        task.taskDescription = id
        let stream = lock.withLock { () -> AsyncStream<DownloadEvent> in
            taskByID[id] = task
            return channelLocked(taskID: task.taskIdentifier)
        }
        task.resume()
        return stream
    }

    public func cancel(id: String) async {
        let task = lock.withLock { taskByID[id] }
        task?.cancel()
        // `didCompleteWithError` fires with a cancellation error → `.cancelled(nil)`.
    }

    public func cancelProducingResumeData(id: String) async -> Data? {
        guard let task = lock.withLock({ taskByID[id] }) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            task.cancel(byProducingResumeData: { cont.resume(returning: $0) })
        }
        // `didCompleteWithError` also fires with a cancellation error carrying the same resume
        // data in `userInfo` → `.cancelled(resumeData:)` on the stream.
    }

    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletionHandler = handler }
    }

    /// `DownloadSession` conformance — the manager-level reattach entry point calls this; it simply
    /// delegates to `reattachOutstandingTasks()` (kept as the concrete, descriptively-named API).
    public func reattachOutstandingTransfers() async -> [String] {
        await reattachOutstandingTasks()
    }

    /// Re-attach to transfers the background session is still tracking after an app relaunch,
    /// repopulating the `fileID → task` map so `cancel`/`pause`/`attach` continue to work. Returns
    /// the `fileID`s of the outstanding downloads. Only Sendable `String`s cross the continuation
    /// boundary.
    public func reattachOutstandingTasks() async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            session.getAllTasks { tasks in
                let ids = self.lock.withLock { () -> [String] in
                    var ids: [String] = []
                    for task in tasks {
                        guard let download = task as? URLSessionDownloadTask,
                              let id = task.taskDescription else { continue }
                        self.taskByID[id] = download
                        ids.append(id)
                    }
                    return ids
                }
                cont.resume(returning: ids)
            }
        }
    }

    /// Attach a fresh event stream to an already-outstanding transfer for `id` (e.g. after a
    /// relaunch + `reattachOutstandingTasks`) without starting a new task. Buffered events emitted
    /// before the attach are preserved. Returns `nil` if no outstanding task is tracked for `id`.
    public func attach(id: String) -> AsyncStream<DownloadEvent>? {
        lock.withLock {
            guard let task = taskByID[id] else { return nil }
            return channelLocked(taskID: task.taskIdentifier)
        }
    }

    // MARK: - Channels (caller must hold `lock` for `channelLocked`)

    private func channelLocked(taskID: Int) -> AsyncStream<DownloadEvent> {
        if let existing = streamsByTask[taskID] { return existing }
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadEvent.self, bufferingPolicy: .bufferingNewest(64)
        )
        streamsByTask[taskID] = stream
        continuationsByTask[taskID] = continuation
        return stream
    }

    /// Get (creating if needed) the continuation for a task, so delegate events that arrive before
    /// a consumer attaches are buffered rather than dropped.
    private func continuation(forTask taskID: Int) -> AsyncStream<DownloadEvent>.Continuation {
        lock.withLock {
            _ = channelLocked(taskID: taskID)
            return continuationsByTask[taskID]!
        }
    }

    private func closeChannel(forTask taskID: Int, id: String?) {
        lock.withLock {
            continuationsByTask[taskID]?.finish()
            continuationsByTask[taskID] = nil
            streamsByTask[taskID] = nil
            // Only clear the id→task mapping if it still points at THIS task (a re-`start` may have
            // already repointed it at a newer task).
            if let id, taskByID[id]?.taskIdentifier == taskID { taskByID[id] = nil }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension URLSessionDownloadSession: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation(forTask: downloadTask.taskIdentifier).yield(
            .progress(bytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file is reclaimed the instant this method returns — stage it synchronously.
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.moveItem(at: location, to: staged)
            continuation(forTask: downloadTask.taskIdentifier).yield(.finished(temporaryURL: staged))
        } catch {
            continuation(forTask: downloadTask.taskIdentifier)
                .yield(.failed(asSendableError(error), resumeData: nil))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            let resumeData = (error as NSError)
                .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if (error as NSError).code == NSURLErrorCancelled {
                continuation(forTask: task.taskIdentifier).yield(.cancelled(resumeData: resumeData))
            } else {
                continuation(forTask: task.taskIdentifier)
                    .yield(.failed(asSendableError(error), resumeData: resumeData))
            }
        }
        // On success the `.finished` event was already yielded in `didFinishDownloadingTo`.
        closeChannel(forTask: task.taskIdentifier, id: task.taskDescription)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            let h = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return h
        }
        // Apple requires the stored completion handler be invoked on the main thread.
        guard let handler else { return }
        Task { @MainActor in handler() }
    }
}
