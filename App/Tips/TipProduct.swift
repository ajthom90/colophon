import Foundation

/// The three tip-jar product identifiers (M2c). MUST stay in sync with `Products.storekit`
/// (Simulator testing config, repo root) and the consumables created in App Store Connect at
/// submission time (docs/superpowers/m2c-human-verification.md) — same literal strings in all
/// three places.
///
/// `nonisolated` (like `AppState.swift`'s `LibrarySort`/`LibraryFilter`): this project's
/// default-MainActor setting would otherwise isolate these plain value types to the main actor,
/// but `FakeTipProvider` (an `actor`, so it can serialize scripting against `TipStore`'s calls with
/// no manual locking) and `StoreKitTipProvider` (explicitly `Sendable`, so its StoreKit calls can
/// run off the main actor like any other StoreKit code) both need to use them from a non-MainActor
/// context.
nonisolated enum TipProductID {
    static let small = "com.andrewthom.colophon.tip.small"
    static let medium = "com.andrewthom.colophon.tip.medium"
    static let large = "com.andrewthom.colophon.tip.large"
    /// Requested from StoreKit in this order; `StoreKitTipProvider`/`TipStore` don't rely on the
    /// response preserving it — everything downstream sorts by `TipProduct.Tier` instead.
    static let all: [String] = [small, medium, large]
}

/// A StoreKit-FREE descriptor for one tip-jar product. `TipJarView` (Task 2) and every test in
/// this file's suite consume ONLY this type — never `StoreKit.Product` directly — so the tip
/// jar's UI and state machine (`TipStore`) can be built and unit-tested with zero StoreKit
/// dependency. `StoreKitTipProvider` builds these from a live `Product`; `FakeTipProvider` (test
/// target) constructs them by hand.
///
/// Tips are CONSUMABLE and unlock NOTHING (Global Constraint) — this type carries no
/// entitlement/feature-flag semantics, only display data.
///
/// `nonisolated` — see `TipProductID`'s doc comment for why.
nonisolated struct TipProduct: Sendable, Equatable, Identifiable {
    /// The small/medium/large family AND the sort key. Ascending `Tier` order corresponds to
    /// ascending price by construction (`small` = $1.99 < `medium` = $4.99 < `large` = $9.99), so
    /// `StoreKitTipProvider`/`FakeTipProvider` sort tip lists by this rather than parsing the
    /// locale-formatted `displayPrice` string (which can't be reliably compared as a number across
    /// currencies/locales).
    nonisolated enum Tier: Int, Sendable, Comparable, CaseIterable {
        case small, medium, large

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The StoreKit product identifier — one of `TipProductID`'s three constants.
    let id: String
    /// The buyer-facing name. Real: `Product.displayName` (from `Products.storekit`/App Store
    /// Connect). Fake: scripted by the test. NEVER hardcoded by a caller.
    let displayName: String
    /// The locale-formatted price string. Real: `Product.displayPrice` (already currency/locale
    /// formatted by StoreKit). Fake: scripted by the test. NEVER hardcode a literal price (e.g.
    /// "$1.99") anywhere this is rendered — see the Global Constraints' localized-price mandate.
    let displayPrice: String
    let tier: Tier
}

extension TipProduct.Tier {
    /// Maps a StoreKit product identifier to its tier. `nil` for an unrecognized id — defensive:
    /// a product `StoreKitTipProvider.tipProducts()` doesn't recognize is skipped rather than
    /// crashing (see its call site).
    init?(productID: String) {
        switch productID {
        case TipProductID.small: self = .small
        case TipProductID.medium: self = .medium
        case TipProductID.large: self = .large
        default: return nil
        }
    }
}
