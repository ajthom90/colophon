import Foundation

/// A progress or terminal event for a single download, delivered over an `AsyncStream`.
/// A stream yields zero or more `progress` events, then exactly one terminal event
/// (`finished`, `failed`, or `cancelled`), then finishes.
public enum DownloadEvent: Sendable {
    /// Byte-count progress. `totalBytesExpected` is `NSURLSessionTransferSizeUnknown` (-1) when
    /// the server did not advertise a content length.
    case progress(bytesWritten: Int64, totalBytesExpected: Int64)
    /// The transfer finished. `temporaryURL` is a file the receiver must move/consume; the real
    /// session first stages it OFF the OS-owned scratch location (which is reclaimed the moment
    /// the delegate returns) so the manager can move it at its leisure.
    case finished(temporaryURL: URL)
    /// The transfer failed. `resumeData`, when present, can restart the transfer where it stopped.
    case failed(any Error & Sendable, resumeData: Data?)
    /// The transfer was cancelled. `resumeData`, when present, can resume the transfer.
    case cancelled(resumeData: Data?)
}

/// The subset of `URLSession` download behavior `DownloadManager` needs, abstracted so the
/// manager is unit-testable with a `FakeDownloadSession` (no network). `URLSessionDownloadSession`
/// is the production implementation backed by a background `URLSession`.
///
/// This is the package's core seam — mirroring `ABSKit.Transport`/`MockTransport` and
/// `PlayerEngine.PlayerBackend`/`FakePlayerBackend`.
public protocol DownloadSession: Sendable {
    /// Start (or, when `resumeData` is non-nil, resume) a download for `request`, keyed by the
    /// opaque `id`. Returns a stream of progress events terminated by exactly one terminal event.
    func start(id: String, request: URLRequest, resumeData: Data?) -> AsyncStream<DownloadEvent>
    /// Cancel the download for `id`, discarding partial data. The stream ends with `.cancelled(nil)`.
    func cancel(id: String) async
    /// Cancel the download for `id`, returning opaque resume data (or `nil` if the transfer could
    /// not produce any). The stream ends with `.cancelled(resumeData:)`.
    func cancelProducingResumeData(id: String) async -> Data?
    /// Store the system completion handler delivered to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. The session invokes
    /// it once it has finished delivering background events after an app relaunch.
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void)
}

/// A `Sendable` box for a transfer failure whose underlying `Error` (e.g. a bridged `NSError`)
/// is not itself `Sendable`. Already-`Sendable` errors (like `URLError`) flow through unwrapped.
public struct DownloadTransferError: Error, Sendable, Equatable {
    public let domain: String
    public let code: Int
    public let message: String
    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }
}

extension DownloadTransferError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Coerce an arbitrary `Error` into a `Sendable` box preserving its domain/code/message. Shared by
/// the manager (file-move failures) and the real session (delegate errors) — both origins are
/// Foundation errors that bridge cleanly to `NSError`.
func asSendableError(_ error: any Error) -> any Error & Sendable {
    let ns = error as NSError
    return DownloadTransferError(domain: ns.domain, code: ns.code, message: ns.localizedDescription)
}
