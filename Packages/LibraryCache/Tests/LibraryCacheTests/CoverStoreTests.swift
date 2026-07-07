import Foundation
import Testing
@testable import LibraryCache

@Suite struct CoverStoreTests {
    private func makeSUT() throws -> (CoverStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (CoverStore(directory: dir), dir)
    }

    @Test func fetchesOnceThenServesFromDisk() async throws {
        let (store, _) = try makeSUT()
        nonisolated(unsafe) var fetchCount = 0
        let fetch: @Sendable () async throws -> Data = { fetchCount += 1; return Data([1, 2, 3]) }
        let first = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 100, fetch: fetch)
        let second = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 100, fetch: fetch)
        #expect(first == Data([1, 2, 3]) && second == Data([1, 2, 3]))
        #expect(fetchCount == 1)
    }

    @Test func newerTimestampInvalidatesOldFile() async throws {
        let (store, dir) = try makeSUT()
        _ = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 100) { Data([1]) }
        _ = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 200) { Data([2]) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "C1").path)
        #expect(files == ["i1-200.img"])
        let cached = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 200) { Data([9]) }
        #expect(cached == Data([2]))
    }

    @Test func fetchErrorPropagatesAndCachesNothing() async throws {
        let (store, dir) = try makeSUT()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 1) { throw Boom() }
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "C1").path))?.isEmpty ?? true)
    }

    @Test func concurrentMissesShareOneFetch() async throws {
        let (store, _) = try makeSUT()
        let counter = Counter()
        let gate = Gate()
        let fetch: @Sendable () async throws -> Data = {
            await counter.increment()
            await gate.wait()
            return Data([7, 7, 7])
        }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await store.coverData(connectionID: "C1", itemID: "shared", updatedAt: 1, fetch: fetch)
                }
            }
            // Give every task a chance to reach the actor and observe the miss/in-flight
            // state before releasing the shared fetch.
            try await Task.sleep(nanoseconds: 50_000_000)
            await gate.open()
            var results: [Data] = []
            for try await data in group { results.append(data) }
            #expect(results.count == 10)
            #expect(results.allSatisfy { $0 == Data([7, 7, 7]) })
        }
        let count = await counter.value
        #expect(count == 1)
    }

    @Test func differentKeysDoNotShareFetch() async throws {
        let (store, _) = try makeSUT()
        let counter = Counter()
        async let first = store.coverData(connectionID: "C1", itemID: "a", updatedAt: 1) {
            await counter.increment()
            return Data([1])
        }
        async let second = store.coverData(connectionID: "C1", itemID: "b", updatedAt: 1) {
            await counter.increment()
            return Data([2])
        }
        let (a, b) = try await (first, second)
        #expect(a == Data([1]) && b == Data([2]))
        let count = await counter.value
        #expect(count == 2)
    }

    @Test func sharedFetchFailurePropagatesAndClears() async throws {
        let (store, _) = try makeSUT()
        struct Boom: Error {}
        let counter = Counter()
        let gate = Gate()
        let failingFetch: @Sendable () async throws -> Data = {
            await counter.increment()
            await gate.wait()
            throw Boom()
        }
        await #expect(throws: Boom.self) {
            try await withThrowingTaskGroup(of: Data.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        try await store.coverData(connectionID: "C1", itemID: "fails", updatedAt: 1, fetch: failingFetch)
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                await gate.open()
                for try await _ in group {}
            }
        }
        let countAfterFailure = await counter.value
        #expect(countAfterFailure == 1)

        // A subsequent call for the same key retries because the failed entry was cleared.
        let retryData = try await store.coverData(connectionID: "C1", itemID: "fails", updatedAt: 1) {
            await counter.increment()
            return Data([9])
        }
        #expect(retryData == Data([9]))
        let finalCount = await counter.value
        #expect(finalCount == 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
