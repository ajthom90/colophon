import Testing
import Foundation
@testable import Colophon

/// State-machine coverage for `TipStore` (M2c Task 1) — every test drives it through a
/// `FakeTipProvider`, with no StoreKit host, matching the codebase's existing seam+Fake
/// convention (`AppStateTests`/`DownloadCoordinatorTests`).
@MainActor
struct TipStoreTests {
    // MARK: - load()

    /// A successful load lists all 3 tip tiers, sorted ascending by price (`Tier` order) even
    /// though `FakeTipProvider.defaultProducts` are scripted out of order.
    @Test func loadSuccessListsThreeSortedProducts() async throws {
        let store = TipStore(provider: FakeTipProvider())
        await store.load()

        guard case .loaded(let products) = store.state else {
            Issue.record("Expected .loaded, got \(store.state)")
            return
        }
        #expect(products.map(\.id) == [TipProductID.small, TipProductID.medium, TipProductID.large])
        #expect(products.map(\.tier) == [.small, .medium, .large])
        #expect(store.products.map(\.id) == [TipProductID.small, TipProductID.medium, TipProductID.large])
    }

    /// A failed load surfaces `.loadFailed` (a retry-able message), and never populates `products`.
    @Test func loadFailureSurfacesLoadFailed() async throws {
        let provider = FakeTipProvider(productsError: FakeTipError())
        let store = TipStore(provider: provider)
        await store.load()

        guard case .loadFailed = store.state else {
            Issue.record("Expected .loadFailed, got \(store.state)")
            return
        }
        #expect(store.products.isEmpty)
    }

    // MARK: - purchase(_:)

    /// A successful purchase transitions `.purchasing(id) → .thankYou`.
    @Test func purchaseSuccessTransitionsToThankYou() async throws {
        let provider = FakeTipProvider()
        let store = TipStore(provider: provider)
        await store.load()

        await store.purchase(TipProductID.small)

        #expect(store.state == .thankYou)
        let calls = await provider.purchaseCalls
        #expect(calls == [TipProductID.small])
        // Thank-you is transient — the products list is still there, ready to tip again.
        #expect(store.products.count == 3)
    }

    /// A user-cancelled purchase returns to `.loaded` with the SAME products — no thank-you, no
    /// error, and no lock-out (tips unlock nothing; a user can simply try again).
    @Test func userCancelledReturnsToLoadedWithNoThanks() async throws {
        let provider = FakeTipProvider()
        await provider.setPurchaseOutcome(.userCancelled, for: TipProductID.medium)
        let store = TipStore(provider: provider)
        await store.load()

        await store.purchase(TipProductID.medium)

        guard case .loaded(let products) = store.state else {
            Issue.record("Expected .loaded, got \(store.state)")
            return
        }
        #expect(products.count == 3)
    }

    /// A pending purchase (Ask-to-Buy / Family Sharing approval) surfaces its own `.pending` state
    /// — distinct from both success and failure.
    @Test func pendingPurchaseSurfacesPendingState() async throws {
        let provider = FakeTipProvider()
        await provider.setPurchaseOutcome(.pending, for: TipProductID.large)
        let store = TipStore(provider: provider)
        await store.load()

        await store.purchase(TipProductID.large)

        #expect(store.state == .pending)
    }

    /// A failed purchase surfaces `.purchaseFailed` carrying a retry-able message.
    @Test func failedPurchaseSurfacesPurchaseFailedWithMessage() async throws {
        let provider = FakeTipProvider()
        await provider.setPurchaseOutcome(.failed("Payment declined"), for: TipProductID.small)
        let store = TipStore(provider: provider)
        await store.load()

        await store.purchase(TipProductID.small)

        #expect(store.state == .purchaseFailed("Payment declined"))
    }

    /// A purchase that throws (rather than returning `.failed`) is ALSO surfaced as
    /// `.purchaseFailed`, so a genuine StoreKit-layer error degrades the same way a modeled
    /// failure does — the UI has exactly one failure state to render.
    @Test func throwingPurchaseSurfacesPurchaseFailed() async throws {
        let provider = FakeTipProvider()
        await provider.setPurchaseError(FakeTipError())
        let store = TipStore(provider: provider)
        await store.load()

        await store.purchase(TipProductID.small)

        guard case .purchaseFailed = store.state else {
            Issue.record("Expected .purchaseFailed, got \(store.state)")
            return
        }
    }

    /// Tips repeat — a thank-you is not a lock-out. Purchasing the SAME tier twice in a row
    /// succeeds twice, and `products` still lists all 3 tiers after both.
    @Test func purchaseCanRepeatAfterThankYou() async throws {
        let provider = FakeTipProvider()
        let store = TipStore(provider: provider)
        await store.load()

        await store.purchase(TipProductID.small)
        #expect(store.state == .thankYou)

        await store.purchase(TipProductID.small)
        #expect(store.state == .thankYou)

        let calls = await provider.purchaseCalls
        #expect(calls == [TipProductID.small, TipProductID.small])
        #expect(store.products.count == 3)
    }
}
