import Foundation
@testable import ABSKit

actor MockTransport: Transport {
    private var queue: [HTTPResponse] = []
    private(set) var recorded: [URLRequest] = []

    func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        queue.append(HTTPResponse(statusCode: status, data: Data(json.utf8), headers: headers))
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        guard !queue.isEmpty else { throw ABSError.invalidResponse }
        return queue.removeFirst()
    }

    func requestCount() -> Int { recorded.count }
}
