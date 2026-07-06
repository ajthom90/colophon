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
}
