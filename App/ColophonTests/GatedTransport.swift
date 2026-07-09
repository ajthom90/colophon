import Foundation
import ABSKit

/// A `Transport` test double (local to the app test bundle — deliberately NOT added to the
/// shared `ABSKitTestSupport`) that can *hang* a request whose path contains `gatePath` until
/// the test calls `openGate()`. This makes concurrency guards deterministically testable:
/// hold the first `/status` (or `/play`) in-flight, fire the racing second call, and assert
/// exactly one request was recorded — no `Task.sleep`, no wall-clock timing.
actor GatedTransport: Transport {
    private var responses: [HTTPResponse] = []
    private var recorded: [URLRequest] = []
    private let gatePath: String
    private var gateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(gatePath: String) {
        self.gatePath = gatePath
    }

    func enqueue(status: Int, json: String) {
        responses.append(HTTPResponse(statusCode: status, data: Data(json.utf8)))
    }

    /// Release any request currently parked on the gate and stop gating future ones.
    func openGate() {
        gateOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// Number of recorded requests whose URL path contains `substring`.
    func requestCount(pathContains substring: String) -> Int {
        recorded.filter { ($0.url?.path ?? "").contains(substring) }.count
    }

    /// Recorded requests whose URL path contains `substring`, in order — for asserting a POST's
    /// `httpBody` (e.g. the `local-all` batch's session payloads).
    func recordedRequests(pathContains substring: String) -> [URLRequest] {
        recorded.filter { ($0.url?.path ?? "").contains(substring) }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        if !gateOpen, (request.url?.path ?? "").contains(gatePath) {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard !responses.isEmpty else { throw ABSError.invalidResponse }
        return responses.removeFirst()
    }
}
