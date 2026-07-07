import Foundation
import ABSKit

/// A `TokenStore` test double (local to the app test bundle, mirroring `GatedTransport`) that can
/// *hang* `tokens(for:)` until the test calls `openGate()`. This lets a test deterministically
/// park `activateConnection`'s synchronous section mid-flight — at its one real suspension point,
/// the actor-hop into the token store — so a racing second activation can be driven into the
/// `activatingConnectionID` reentrancy guard without any wall-clock timing.
actor GatedTokenStore: TokenStore {
    private var storage: [String: TokenPair] = [:]
    private var gateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Number of `tokens(for:)` calls currently parked on the gate — the test polls this to know
    /// the first activation has reached (and is suspended at) the gate before firing the second.
    private(set) var waitingCount = 0

    func save(_ tokens: TokenPair, for connectionID: String) {
        storage[connectionID] = tokens
    }

    func clear(for connectionID: String) {
        storage[connectionID] = nil
    }

    /// Release any call currently parked on the gate and stop gating future ones.
    func openGate() {
        gateOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func tokens(for connectionID: String) async -> TokenPair? {
        if !gateOpen {
            waitingCount += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        return storage[connectionID]
    }
}
