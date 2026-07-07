import Foundation
import ABSKit

/// A FIFO-queue `Transport` test double shared by ABSKit's own test target and downstream
/// consumers (e.g. the app's test bundle) that need to stub HTTP responses without a real
/// server.
public actor MockTransport: Transport {
    private var queue: [HTTPResponse] = []
    public private(set) var recorded: [URLRequest] = []

    public init() {}

    public func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        queue.append(HTTPResponse(statusCode: status, data: Data(json.utf8), headers: headers))
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        guard !queue.isEmpty else { throw ABSError.invalidResponse }
        return queue.removeFirst()
    }

    public func requestCount() -> Int { recorded.count }
}
