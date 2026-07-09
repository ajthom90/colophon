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
/// Downloads are routed by `taskDescription` (set to the caller's `fileID`) rather than the
/// process-local `taskIdentifier`, so routing keeps working after a relaunch reconstructs the tasks.
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
    private var streams: [String: AsyncStream<DownloadEvent>] = [:]
    private var continuations: [String: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
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
        let stream = lock.withLock { channelLocked(id: id) }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)
        task.taskDescription = id
        lock.withLock { tasks[id] = task }
        task.resume()
        return stream
    }

    public func cancel(id: String) async {
        let task = lock.withLock { tasks[id] }
        task?.cancel()
        // `didCompleteWithError` fires with a cancellation error → `.cancelled(nil)`.
    }

    public func cancelProducingResumeData(id: String) async -> Data? {
        guard let task = lock.withLock({ tasks[id] }) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            task.cancel(byProducingResumeData: { cont.resume(returning: $0) })
        }
        // `didCompleteWithError` also fires with a cancellation error carrying the same resume
        // data in `userInfo` → `.cancelled(resumeData:)` on the stream.
    }

    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletionHandler = handler }
    }

    /// Re-attach to transfers the background session is still tracking after an app relaunch,
    /// repopulating the id→task map so `cancel`/`pause` continue to work. Returns the `fileID`s of
    /// the outstanding downloads. Only Sendable `String`s cross the continuation boundary.
    public func reattachOutstandingTasks() async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            session.getAllTasks { tasks in
                let ids = self.lock.withLock { () -> [String] in
                    var ids: [String] = []
                    for task in tasks {
                        guard let download = task as? URLSessionDownloadTask,
                              let id = task.taskDescription else { continue }
                        self.tasks[id] = download
                        ids.append(id)
                    }
                    return ids
                }
                cont.resume(returning: ids)
            }
        }
    }

    /// Attach a fresh event stream to an already-outstanding transfer (e.g. after a relaunch)
    /// without starting a new task. Buffered events emitted before the attach are preserved.
    public func attach(id: String) -> AsyncStream<DownloadEvent> {
        lock.withLock { channelLocked(id: id) }
    }

    // MARK: - Channels (caller must hold `lock`)

    private func channelLocked(id: String) -> AsyncStream<DownloadEvent> {
        if let existing = streams[id] { return existing }
        let (stream, continuation) = AsyncStream.makeStream(
            of: DownloadEvent.self, bufferingPolicy: .bufferingNewest(64)
        )
        streams[id] = stream
        continuations[id] = continuation
        return stream
    }

    /// Get (creating if needed) the continuation for `id`, so delegate events that arrive before a
    /// consumer attaches are still buffered rather than dropped.
    private func continuation(for id: String) -> AsyncStream<DownloadEvent>.Continuation {
        lock.withLock {
            _ = channelLocked(id: id)
            return continuations[id]!
        }
    }

    private func closeChannel(id: String) {
        lock.withLock {
            continuations[id]?.finish()
            continuations[id] = nil
            streams[id] = nil
            tasks[id] = nil
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
        guard let id = downloadTask.taskDescription else { return }
        continuation(for: id).yield(
            .progress(bytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }
        // The temp file is reclaimed the instant this method returns — stage it synchronously.
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.moveItem(at: location, to: staged)
            continuation(for: id).yield(.finished(temporaryURL: staged))
        } catch {
            continuation(for: id).yield(.failed(asSendableError(error), resumeData: nil))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let id = task.taskDescription else { return }
        if let error {
            let resumeData = (error as NSError)
                .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if (error as NSError).code == NSURLErrorCancelled {
                continuation(for: id).yield(.cancelled(resumeData: resumeData))
            } else {
                continuation(for: id).yield(.failed(asSendableError(error), resumeData: resumeData))
            }
        }
        // On success the `.finished` event was already yielded in `didFinishDownloadingTo`.
        closeChannel(id: id)
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
