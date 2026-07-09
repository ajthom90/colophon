import Foundation
import Testing
@testable import DownloadManager

// MARK: - Fixtures

private enum TestError: Error, Sendable, Equatable { case boom }

private let request = URLRequest(url: URL(string: "https://example.com/item/file")!)

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeTempFile(bytes: Int, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("src-\(UUID().uuidString).bin")
    try Data(repeating: 0xAB, count: bytes).write(to: url)
    return url
}

/// Collect states from a per-file update stream until (and including) the terminal one.
private func drain(_ stream: AsyncStream<DownloadUpdate>) async -> [DownloadState] {
    var states: [DownloadState] = []
    for await update in stream {
        states.append(update.state)
        if update.state.isTerminal { break }
    }
    return states
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// MARK: - Tests

@Test func enqueueMovesTempFileToDestinationAndReportsDownloaded() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("books/li1/track1.m4b")

    let stream = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    fake.emitProgress(id: "f1", bytesWritten: 30, totalBytesExpected: 100)
    fake.emitProgress(id: "f1", bytesWritten: 100, totalBytesExpected: 100)
    let source = try makeTempFile(bytes: 100, in: dir)
    fake.complete(id: "f1", temporaryURL: source)

    let states = await drain(stream)

    #expect(states.contains(.downloading(receivedBytes: 30, totalBytes: 100)))
    #expect(states.last == .downloaded)
    #expect(exists(destination))                       // temp file moved to destination
    #expect(!exists(source))                           // and consumed from its temp location
    #expect(await manager.state(for: "f1") == .downloaded)
}

@Test func cancelMidFlightReportsCancelledAndLeavesNoFile() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("track.m4b")

    let stream = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    fake.emitProgress(id: "f1", bytesWritten: 40, totalBytesExpected: 100)
    await manager.cancel(fileID: "f1")

    let states = await drain(stream)

    #expect(states.last == .cancelled)
    #expect(fake.cancelledIDs == ["f1"])
    #expect(!exists(destination))
    #expect(await manager.state(for: "f1") == .cancelled)
}

@Test func failureReportsFailedAndLeavesNoPartialFile() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("track.m4b")

    let stream = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    fake.emitProgress(id: "f1", bytesWritten: 10, totalBytesExpected: 100)
    fake.fail(id: "f1", error: TestError.boom)

    let states = await drain(stream)

    #expect(states.last == .failed(TestError.boom))
    #expect(!exists(destination))
    #expect(await manager.state(for: "f1") == .failed(TestError.boom))
}

@Test func concurrentEnqueuesAreIndependent() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destA = dir.appendingPathComponent("a.m4b")
    let destB = dir.appendingPathComponent("b.m4b")

    let streamA = await manager.enqueue(fileID: "a", request: request, destination: destA)
    let streamB = await manager.enqueue(fileID: "b", request: request, destination: destB)
    let sourceA = try makeTempFile(bytes: 10, in: dir)
    let sourceB = try makeTempFile(bytes: 20, in: dir)

    fake.emitProgress(id: "a", bytesWritten: 5, totalBytesExpected: 10)
    fake.emitProgress(id: "b", bytesWritten: 10, totalBytesExpected: 20)
    fake.complete(id: "a", temporaryURL: sourceA)
    fake.complete(id: "b", temporaryURL: sourceB)

    let statesA = await drain(streamA)
    let statesB = await drain(streamB)

    #expect(statesA.last == .downloaded)
    #expect(statesB.last == .downloaded)
    #expect(exists(destA))
    #expect(exists(destB))
    #expect(try Data(contentsOf: destA).count == 10)
    #expect(try Data(contentsOf: destB).count == 20)
}

@Test func resumeDataRoundTripsThroughPauseAndReEnqueue() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("track.m4b")

    let first = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    fake.emitProgress(id: "f1", bytesWritten: 40, totalBytesExpected: 100)
    let resumeData = await manager.pause(fileID: "f1")
    _ = await drain(first)                             // drains to `.cancelled`, clearing the transfer

    #expect(resumeData == Data("resume-token".utf8))

    let second = await manager.enqueue(
        fileID: "f1", request: request, destination: destination, resumeData: resumeData
    )
    let source = try makeTempFile(bytes: 100, in: dir)
    fake.complete(id: "f1", temporaryURL: source)
    let states = await drain(second)

    #expect(states.last == .downloaded)
    #expect(exists(destination))
    // The resume data flowed through: first start had none, the second carried it.
    #expect(fake.starts.map(\.resumeData) == [nil, resumeData])
}

@Test func updatesObserverReceivesEveryFileUpdate() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("track.m4b")

    let observer = await manager.updates()
    let stream = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    fake.emitProgress(id: "f1", bytesWritten: 50, totalBytesExpected: 100)
    let source = try makeTempFile(bytes: 100, in: dir)
    fake.complete(id: "f1", temporaryURL: source)
    _ = await drain(stream)

    var observed: [DownloadState] = []
    for await update in observer where update.fileID == "f1" {
        observed.append(update.state)
        if update.state.isTerminal { break }
    }

    #expect(observed.contains(.downloading(receivedBytes: 50, totalBytes: 100)))
    #expect(observed.last == .downloaded)
}

@Test func setBackgroundCompletionHandlerForwardsToSession() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let flag = Flag()

    await manager.setBackgroundCompletionHandler { flag.raise() }
    #expect(!flag.value)
    fake.finishBackgroundEvents()
    #expect(flag.value)
}

@Test func reEnqueueOfInFlightFileSupersedesPriorTransfer() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("track.m4b")

    let first = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    fake.emitProgress(id: "f1", bytesWritten: 20, totalBytesExpected: 100)

    // Re-enqueue the SAME in-flight id → the prior transfer is cancelled/superseded and the new
    // one becomes the tracked transfer with a fresh stream.
    let second = await manager.enqueue(fileID: "f1", request: request, destination: destination)

    #expect(fake.cancelledIDs == ["f1"])        // prior task was cancelled before restart
    #expect(fake.starts.count == 2)             // exactly one restart

    // The first (superseded) stream terminates without ever reaching `.downloaded`.
    let firstStates = await drain(first)
    #expect(firstStates.last != .downloaded)

    // Completing "f1" now drives the NEW transfer to downloaded on the fresh stream only.
    let source = try makeTempFile(bytes: 100, in: dir)
    fake.complete(id: "f1", temporaryURL: source)
    let secondStates = await drain(second)

    #expect(secondStates.last == .downloaded)
    #expect(exists(destination))
    #expect(await manager.state(for: "f1") == .downloaded)
}

@Test func moveFailureReportsFailedAndCleansUp() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    // A FILE where the destination's parent directory must be → `createDirectory` (inside the
    // atomic move) throws, exercising the manager's own move-failure catch branch.
    let blocker = dir.appendingPathComponent("parent-is-a-file")
    try Data("x".utf8).write(to: blocker)
    let destination = blocker.appendingPathComponent("track.m4b")

    let stream = await manager.enqueue(fileID: "f1", request: request, destination: destination)
    let source = try makeTempFile(bytes: 100, in: dir)
    fake.complete(id: "f1", temporaryURL: source)

    let states = await drain(stream)

    guard case .failed = states.last else {
        Issue.record("expected terminal .failed, got \(String(describing: states.last))")
        return
    }
    #expect(!exists(source))            // staged temp cleaned up
    #expect(!exists(destination))       // no partial file left behind
}

@Test func reattachResumesOutstandingTransferAndReportsTerminalEvent() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    let dir = try makeTempDir()
    let destination = dir.appendingPathComponent("books/li1/track1.m4b")

    // Simulate a relaunch: the background session still tracks "f1", and the manager has no
    // in-memory transfer for it (fresh process). The caller (a coordinator) supplies the
    // destination it rebuilt from its own records.
    fake.setOutstanding(["f1"])
    let observer = await manager.updates()
    await manager.reattach(destinations: ["f1": destination])

    // A transfer that FINISHED while the app was dead now delivers its terminal event on the
    // re-attached stream → the manager moves the staged file into place and reports downloaded.
    let source = try makeTempFile(bytes: 100, in: dir)
    fake.complete(id: "f1", temporaryURL: source)

    var observed: [DownloadState] = []
    for await update in observer where update.fileID == "f1" {
        observed.append(update.state)
        if update.state.isTerminal { break }
    }

    #expect(observed.last == .downloaded)
    #expect(exists(destination))
    #expect(await manager.state(for: "f1") == .downloaded)
}

@Test func reattachSkipsTransfersWithNoSuppliedDestination() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    fake.setOutstanding(["f1"])
    // No destination for "f1" → the manager can't place a finished file, so it skips it entirely.
    await manager.reattach(destinations: [:])
    #expect(await manager.state(for: "f1") == nil)
}

@Test func cancelUnknownFileIsANoOp() async throws {
    let fake = FakeDownloadSession()
    let manager = DownloadManager(session: fake)
    await manager.cancel(fileID: "nope")
    #expect(await manager.pause(fileID: "nope") == nil)
    #expect(fake.cancelledIDs.isEmpty)
    #expect(await manager.state(for: "nope") == nil)
}
