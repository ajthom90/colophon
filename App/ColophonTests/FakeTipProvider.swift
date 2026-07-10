import Foundation
@testable import Colophon

/// A scripted `TipProviding` test double — the seam `TipStore` consumes — so its state machine is
/// unit-tested with NO StoreKit host, mirroring `FakeDownloadManaging`/`MockTransport`'s role for
/// their respective seams. An `actor` (like `MockTransport`/`AuthManager`/`InMemoryTokenStore`
/// elsewhere in this codebase) rather than a lock-guarded class: its own isolation serializes
/// scripting (`setPurchaseOutcome`) against the async `tipProducts()`/`purchase(_:)` calls
/// `TipStore` makes, with no manual locking needed.
actor FakeTipProvider: TipProviding {
    private var products: [TipProduct]
    private var productsError: (any Error)?
    private var purchaseOutcomes: [String: TipPurchaseOutcome] = [:]
    private var purchaseError: (any Error)?
    private(set) var purchaseCalls: [String] = []

    /// Three tiers in the SAME order `Products.storekit`/App Store Connect define them, but
    /// deliberately shuffled from ascending-price order by default — `tipProducts()` sorts by
    /// `TipProduct.Tier`, so a test that never reorders these still exercises the sort.
    static let defaultProducts: [TipProduct] = [
        TipProduct(id: TipProductID.large, displayName: "Amazing Tip", displayPrice: "$9.99", tier: .large),
        TipProduct(id: TipProductID.small, displayName: "Leave a Tip", displayPrice: "$1.99", tier: .small),
        TipProduct(id: TipProductID.medium, displayName: "Generous Tip", displayPrice: "$4.99", tier: .medium),
    ]

    init(products: [TipProduct] = FakeTipProvider.defaultProducts, productsError: (any Error)? = nil) {
        self.products = products
        self.productsError = productsError
    }

    func tipProducts() async throws -> [TipProduct] {
        if let productsError { throw productsError }
        return products.sorted { $0.tier < $1.tier }
    }

    func purchase(_ id: String) async throws -> TipPurchaseOutcome {
        purchaseCalls.append(id)
        if let purchaseError { throw purchaseError }
        return purchaseOutcomes[id] ?? .success
    }

    // MARK: - Scripting

    func setPurchaseOutcome(_ outcome: TipPurchaseOutcome, for id: String) {
        purchaseOutcomes[id] = outcome
    }

    func setPurchaseError(_ error: (any Error)?) {
        purchaseError = error
    }

    func setProductsError(_ error: (any Error)?) {
        productsError = error
    }
}

/// A minimal `Sendable` error for scripting a failed load/purchase, mirroring
/// `FakeDownloadError`'s role for `FakeDownloadManaging`.
struct FakeTipError: Error, Sendable, Equatable {}
