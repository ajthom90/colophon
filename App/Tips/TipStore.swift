import Foundation
import StoreKit

/// The outcome of one `TipProviding.purchase(_:)` call — a StoreKit-free mirror of
/// `Product.PurchaseResult` (`StoreKitTipProvider` maps every case; `FakeTipProvider` scripts one
/// directly). `.failed`'s associated `String?` is an optional human-readable message (`nil` for a
/// generic failure with nothing more specific to say).
///
/// `nonisolated` (like `TipProduct`/`TipProductID` in `TipProduct.swift` — see that file's doc
/// comment): this plain value type crosses from `FakeTipProvider` (an `actor`) and
/// `StoreKitTipProvider` (explicitly `Sendable`, runs off the main actor) into `TipStore` (main
/// actor), so it must not be pinned to the main actor by this project's default isolation.
nonisolated enum TipPurchaseOutcome: Sendable, Equatable {
    case success
    case userCancelled
    case pending
    case failed(String?)
}

/// The StoreKit-FREE seam `TipStore` drives — a real `StoreKitTipProvider` wraps `Product`/
/// `Transaction` in production; a `FakeTipProvider` (test target) scripts products/outcomes with
/// no StoreKit host, making the whole `TipStore` state machine unit-testable (Task 1's TDD
/// requirement). `Sendable` so it can be held by a `@MainActor` `TipStore` while its async methods
/// (potentially) run off the main actor.
protocol TipProviding: Sendable {
    /// The tip tiers to display, sorted ascending by price (`TipProduct.Tier` order).
    func tipProducts() async throws -> [TipProduct]
    /// Purchase the product with this id, returning the outcome. Consumable: a `.success` means
    /// the transaction was verified and `finish()`ed — there is nothing further to grant (tips
    /// unlock nothing) and nothing to restore.
    func purchase(_ id: String) async throws -> TipPurchaseOutcome
}

/// The real `TipProviding` — the ONLY type in the tip jar that imports StoreKit. Wraps
/// `Product.products(for:)` / `Product.purchase()` (StoreKit 2) for the three CONSUMABLE tip
/// products (`TipProductID`).
///
/// Consumables are never restorable and carry no entitlement (Global Constraint: tips unlock
/// nothing) — so unlike a typical StoreKit integration there is NO `Transaction
/// .currentEntitlements` check and NO "Restore Purchases" affordance. The only housekeeping a
/// consumable needs is `finish()`ing every transaction — including ones that land OUTSIDE an
/// explicit `purchase()` call (Ask-to-Buy / Family Sharing approval arriving later, via
/// `Transaction.updates`) — so `init` starts a task draining that stream for this provider's
/// lifetime; there's nothing to grant on receipt, purely bookkeeping so StoreKit stops
/// redelivering an unfinished transaction.
///
/// Explicitly `Sendable` (no mutable state — `productIDs` and `updatesTask` are both `let`), which
/// also exempts it from this project's default-MainActor inference (matching
/// `FakeDownloadManaging`'s same explicit-Sendable convention) — its async methods can run off the
/// main actor like any other StoreKit call.
final class StoreKitTipProvider: TipProviding, Sendable {
    private let productIDs: [String]
    private let updatesTask: Task<Void, Never>

    init(productIDs: [String] = TipProductID.all) {
        self.productIDs = productIDs
        updatesTask = Task {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        updatesTask.cancel()
    }

    func tipProducts() async throws -> [TipProduct] {
        let products = try await Product.products(for: productIDs)
        return products
            .compactMap { product -> TipProduct? in
                guard let tier = TipProduct.Tier(productID: product.id) else { return nil }
                return TipProduct(
                    id: product.id,
                    displayName: product.displayName,
                    displayPrice: product.displayPrice,
                    tier: tier)
            }
            .sorted { $0.tier < $1.tier }
    }

    func purchase(_ id: String) async throws -> TipPurchaseOutcome {
        guard let product = try await Product.products(for: [id]).first else {
            return .failed("This tip is no longer available.")
        }
        switch try await product.purchase() {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                return .success
            case .unverified(let transaction, let error):
                // Still finish() — an unfinished transaction keeps redelivering via
                // Transaction.updates — but report failure: a tip unlocks nothing, so there is no
                // reason to thank the user for a purchase StoreKit couldn't verify.
                await transaction.finish()
                return .failed(String(describing: error))
            }
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .failed(nil)
        }
    }
}

/// The tip jar's state machine (M2c Task 1) — `@Observable`, default-MainActor (this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, matching `AppState`/`DownloadCoordinator`, neither
/// of which annotates `@MainActor` explicitly either). Drives a `TipProviding` seam so it's fully
/// unit-testable against a `FakeTipProvider` with no StoreKit host.
///
/// `load()`: `.idle → .loading → .loaded([TipProduct]) / .loadFailed(message)`.
/// `purchase(_:)`: `→ .purchasing(id) → .thankYou / .loaded(products) (userCancelled, no thanks) /
/// .pending / .purchaseFailed(message)`.
///
/// Tips are CONSUMABLE and unlock NOTHING (Global Constraint): `state` is display-only — nothing
/// here sets an `@AppStorage` key or any other flag that changes app behavior, and a tip can
/// repeat any number of times (no permanent "already tipped" lock). `products` is kept around
/// separately from `state` so the UI can keep rendering all three tiers through the whole
/// purchase flow (thank-you/pending/failed) instead of reloading.
@Observable
final class TipStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded([TipProduct])
        case loadFailed(String)
        case purchasing(id: String)
        case thankYou
        case pending
        case purchaseFailed(String)
    }

    private(set) var state: State = .idle
    /// The most recently loaded products — set once by `load()` and left untouched through every
    /// later purchase-flow transition, so the UI never has to reload to keep showing the tiers.
    private(set) var products: [TipProduct] = []

    private let provider: any TipProviding
    /// Reentrancy guard for `purchase(_:)` — the same first-wins discipline as `AppState`'s
    /// `isStartingPlayback` — so a double-tap can't start two overlapping purchases for the same
    /// (or different) tier. The UI additionally disables its buttons during `.purchasing`.
    private var isPurchasing = false

    init(provider: any TipProviding = StoreKitTipProvider()) {
        self.provider = provider
    }

    func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let loaded = try await provider.tipProducts()
            products = loaded
            state = .loaded(loaded)
        } catch {
            state = .loadFailed(String(describing: error))
        }
    }

    func purchase(_ id: String) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        state = .purchasing(id: id)
        do {
            switch try await provider.purchase(id) {
            case .success:
                state = .thankYou
            case .userCancelled:
                state = .loaded(products)
            case .pending:
                state = .pending
            case .failed(let message):
                state = .purchaseFailed(message ?? "The tip couldn't go through. Please try again.")
            }
        } catch {
            state = .purchaseFailed(String(describing: error))
        }
    }
}
