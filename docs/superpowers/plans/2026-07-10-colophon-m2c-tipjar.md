# Colophon M2c — Tip jar (StoreKit 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Support the app" tip jar — StoreKit 2 **consumable** in-app purchases in Settings, with a thank-you state — for a free, no-feature-gates app.

**Architecture:** A `TipStore` (`@Observable`) loads the tip products and drives purchases through a small **`TipProviding` seam** (a StoreKit-free protocol) so the state machine (loading → loaded → purchasing → thanks/failed) is unit-testable without hitting StoreKit; a real `StoreKitTipProvider` wraps `Product`/`Transaction`. A committed `Products.storekit` config makes the flow testable in the Simulator with no App Store Connect round-trip. Consumables: verify each `Transaction`, `finish()` it, no entitlement/restore. UI is a native `TipJarView` reached from `SettingsView`'s new "Support the app" section.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI, StoreKit 2 (`Product`, `Transaction`, `Product.PurchaseResult`, `VerificationResult`), a `Products.storekit` StoreKit-Testing configuration. No server, no credentials, no analytics.

## Global Constraints

- All prior constraints bind: Swift 6.2 strict concurrency (complete), default-MainActor; bundle prefix `com.andrewthom` (team LL334G7KP2); commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Business model (spec §, VERBATIM):** "Free app, all features free. Tip jar: StoreKit 2 consumable IAPs (e.g., $1.99 / $4.99 / $9.99) in Settings → 'Support the app', with a thank-you state (no feature gates, no subscriptions, no badge requirements from review perspective). No ads, no tracking, no analytics beyond StoreKit's own." — the tips unlock NOTHING; they are pure support.
- **CarPlay is NOT in M2c** — the `com.apple.developer.carplay-audio` entitlement is still pending (docs/superpowers/carplay-entitlement.md, confirmed 2026-07-10); CarPlay UI is a follow-on milestone once granted.
- **UI MANDATE:** native, HIG-idiomatic (like Apple's own / well-regarded tip jars — Overcast/Ivory). Localized prices come from `Product.displayPrice` (NEVER hardcode "$1.99"). Respect the serif toggle + Dynamic Type.
- **Product IDs:** `com.andrewthom.colophon.tip.small` / `.tip.medium` / `.tip.large` (consumables). These must match the `Products.storekit` config now and App Store Connect at submission time (a human-verification/submission note — the code + local .storekit are what M2c delivers).
- **No new schema/migration, no app-group change, no server call.** Purely local + StoreKit.
- Both platforms build green (StoreKit 2 is cross-platform; the tip jar works on iOS + macOS). Gate anything platform-specific.

## Verified reference

```
StoreKit 2: Product.products(for: ids) -> [Product]; product.purchase() -> Product.PurchaseResult
  (.success(VerificationResult<Transaction>) / .userCancelled / .pending); verify -> Transaction; transaction.finish()
Consumables: NOT restorable, NO Transaction.currentEntitlements membership — finish() and forget. No "Restore Purchases" button needed.
Transaction.updates: an async sequence to observe purchases made outside the flow (e.g. Ask-to-Buy approval) — finish() them too.
Local testing: a Products.storekit StoreKit-Testing config (3 consumables, prices $1.99/$4.99/$9.99) set as the scheme's StoreKit configuration so the Simulator serves fake products with no App Store Connect.
Prices: product.displayPrice (already locale/currency-formatted). displayName/description from the config (or App Store Connect).
```

## File Structure (M2c new/changed)

```
Products.storekit                                  NEW  StoreKit-Testing config: 3 consumables (.tip.small/.medium/.large, $1.99/$4.99/$9.99)
project.yml                                        MOD  reference Products.storekit as the scheme's StoreKit config (for sim testing); include the file
App/Tips/TipStore.swift                            NEW  @Observable state machine + TipProviding seam + StoreKitTipProvider + FakeTipProvider(test)
App/Tips/TipProduct.swift (or in TipStore)         NEW  a StoreKit-free tip descriptor (id, displayName, displayPrice, tier) the UI renders + tests use
App/Views/{TipJarView,SettingsView}.swift          NEW/MOD  TipJarView (native tip UI + thank-you); SettingsView gains a "Support the app" section/row → TipJarView
README.md ; docs/superpowers/m2c-human-verification.md  MOD/NEW
```

---

### Task 1: TipStore (StoreKit 2) + Products.storekit + testable seam

**Files:** Create `App/Tips/TipStore.swift` (+ a small StoreKit-free `TipProduct` descriptor); `Products.storekit`; `project.yml` (register the file + set it as the scheme's StoreKit configuration).

Create the tip-jar core:
- **`Products.storekit`** StoreKit-Testing config with 3 **consumable** products: `com.andrewthom.colophon.tip.small` ($1.99), `.tip.medium` ($4.99), `.tip.large` ($9.99), with friendly display names ("Leave a tip" / "Generous tip" / "Amazing tip" — or similar) + short descriptions. Wire it in project.yml as the scheme's StoreKit configuration so the Simulator serves them.
- **`TipProviding` seam** (StoreKit-free protocol): `func tipProducts() async throws -> [TipProduct]` (sorted by price) and `func purchase(_ id: String) async throws -> TipPurchaseOutcome` (.success / .userCancelled / .pending / .failed) — plus a way to observe `Transaction.updates`. `TipProduct` = a plain descriptor (id, displayName, displayPrice String, tier) the UI + tests use without importing StoreKit.
- **`StoreKitTipProvider`** — the real impl: `Product.products(for:)` → map to `TipProduct` (using `displayPrice`); `product.purchase()` → verify the `VerificationResult`, `transaction.finish()`, map to the outcome; a task draining `Transaction.updates` finishing any consumable transactions (Ask-to-Buy). Consumables: no entitlement, no restore.
- **`TipStore`** (`@Observable`, `@MainActor`): state machine — `.idle → .loading → .loaded([TipProduct]) / .loadFailed`; `purchase(id)` → `.purchasing(id) → .thankYou / .idle(userCancelled) / .purchaseFailed`; `load()` on appear. Injects a `TipProviding` (real by default; a `FakeTipProvider` for tests).

- [ ] TDD: `FakeTipProvider` drives `TipStore` — load success lists 3 sorted products; load failure → loadFailed; purchase success → thankYou (+ a "did tip" flag for the thank-you state); userCancelled → back to loaded (no thanks); pending → a pending state; failure → purchaseFailed with retry. `make test-app` (the TipStore tests) `&& make build-ios && make build-mac`. Commit `feat(tips): TipStore (StoreKit 2) + Products.storekit + testable seam`.

---

### Task 2: "Support the app" tip jar UI

**Files:** Create `App/Views/TipJarView.swift`; modify `App/Views/SettingsView.swift`.

A native tip jar reached from Settings:
- **SettingsView:** a new `Section` (e.g. "Support") with a "Support the app" `NavigationLink`/row → `TipJarView` (heart/gift SF Symbol; a warm one-liner). Keep it unobtrusive, below the existing prefs.
- **TipJarView:** a warm, native tip screen — a short "Colophon is free; if you'd like to support development…" blurb, the 3 tip tiers as buttons showing `displayName` + `displayPrice` (localized — from the store, never hardcoded), a `.loading` ProgressView, a `.loadFailed` retry, an in-flight `.purchasing` state (disable buttons + spinner on the tapped tier), and a **thank-you state** on success (a heartfelt confirmation; tips can repeat — no permanent lock). `userCancelled` returns silently. HIG: one prominent action per tier; no dark patterns; respect Dynamic Type + serif. Bind to a `TipStore`.

- [ ] Build both; native-UI review; a CAPPED MUTED E2E is OPTIONAL (the .storekit sim purchase flow can be idb-driven if feasible — tap a tier → StoreKit sheet → the thank-you state; else the build + the Task-1 unit tests + the human-verification checklist cover it). Screenshot the tip jar + thank-you if E2E'd. Commit `feat(tips): Support-the-app tip jar UI`.

---

### Task 3: Wrap-up + human-verification + final review

**Files:** `README.md`; `docs/superpowers/m2c-human-verification.md`; contract-block refresh.

- [ ] README → M2c reality (a Support-the-app tip jar; free app, no feature gates; CarPlay still deferred pending the entitlement). Human-verification checklist: a REAL sandbox purchase needs App Store Connect products (`com.andrewthom.colophon.tip.{small,medium,large}` created as consumables) + a sandbox Apple ID on a device — verify each tier purchases, the thank-you state shows, a tip can be repeated, cancel is graceful, prices display in the device locale; the .storekit local flow verifies the code in the Simulator meanwhile. Note the App-Store-Connect-products-at-submission requirement. Full cold-start sweep `make test && make test-app && make build-ios && make build-mac` green, zero warnings. Commit `docs: M2c status`. Then the whole-branch adversarial review before merge.

---

## Self-review notes (plan-writing time)

- **Coverage vs spec business model:** consumable IAPs $1.99/$4.99/$9.99 (T1 Products.storekit), Settings → "Support the app" + thank-you (T2), NO feature gates / subscriptions / analytics (enforced — tips unlock nothing), localized `displayPrice` (T2). CarPlay explicitly deferred (still-pending entitlement).
- **Testable despite StoreKit:** the `TipProviding` seam + `FakeTipProvider` make the TipStore state machine unit-testable without a StoreKit host; the `Products.storekit` config covers the real StoreKit path in the Simulator; a true sandbox purchase is the device-only human-verification item (needs App Store Connect products).
- **No feature gates:** the review criterion — a tip must unlock nothing, set no `@AppStorage` that changes behavior; only a transient thank-you. Guard against accidentally gating anything.
- **Deferred beyond M2c:** CarPlay UI (follow-on, on entitlement grant); after M2c, M2 (Offline + companions) is complete → M3 Mac flagship polish.
