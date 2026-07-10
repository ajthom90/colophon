# M2c — Human Verification Checklist (Tip jar / StoreKit 2)

These are the checks the automated E2E **cannot** cover. StoreKit Testing (the local
`Products.storekit` config) only activates when **Xcode itself** launches the app via its own
Run/Launch action — a bare `simctl install` + `simctl launch` (the only mechanism idb/simctl
exposes) bypasses Xcode's `LaunchAction` entirely, so no local StoreKit test session is
established and `Product.products(for:)` legitimately returns zero products (confirmed during
Task 2's E2E attempt — the StoreKit calls reached real `storekitd`, not a local test session).
A REAL sandbox purchase additionally needs products that don't exist yet (see item **b**). The
`TipStore` state machine itself IS unit-tested end to end against a `FakeTipProvider` (8 tests,
`Packages`-adjacent `App/ColophonTests/TipStoreTests.swift`) — load success/failure, purchase
success/userCancelled/pending/failure, and a repeat-tip case — but the real StoreKit plumbing
(`StoreKitTipProvider`, the actual purchase sheet, the actual App Store) only exists when driven
by a human through Xcode or a real device.

Legend: **Do** = the action to perform · **Expect** = the pass criterion.

---

## Dev-fixture limitations (read this first)

- `Products.storekit` (repo root) ships 3 **consumable** products — `com.andrewthom.colophon.tip.
  small` ($1.99, "Leave a Tip"), `.tip.medium` ($4.99, "Generous Tip"), `.tip.large` ($9.99,
  "Amazing Tip") — and is already wired as the `Colophon` scheme's StoreKit configuration
  (`project.yml` → `schemes.Colophon.run.storeKitConfiguration`). This is enough to fully verify
  the local flow (item **a**) with zero App Store Connect setup, but **only** when Xcode itself
  runs the app.
- A **real** sandbox purchase (item **b**) needs the 3 products created in App Store Connect
  first — they do not exist there yet. This milestone ships the code + the local `.storekit`
  config; creating the live products is a submission-time step, not something this checklist can
  complete ahead of time.
- Consumables are **NOT restorable** by design (StoreKit 2: no `Transaction.currentEntitlements`
  membership for consumables) — there is deliberately no "Restore Purchases" button anywhere in
  the tip jar. Don't treat its absence as a bug; it would be a bug if one were added.

---

## a. The `Products.storekit` local flow (Simulator or device, run FROM XCODE)

- **Do:** Open `Colophon.xcodeproj` in Xcode (after `make gen`) and run the `Colophon` scheme with
  Xcode's own ▶️ Run button (**not** `simctl launch`/idb — StoreKit Testing only engages under
  Xcode's `LaunchAction`). Navigate to Settings → **Support the app** (bottom section, heart icon).
- **Expect:** `TipJarView` pushes with the title "Support the App" and the blurb ("Colophon is
  free and always will be. If it's brought you good listening, you can leave a tip to support
  development…"). All **3 tiers** render — "Leave a Tip" / "Generous Tip" / "Amazing Tip" — each
  showing a real, StoreKit-supplied price ($1.99 / $4.99 / $9.99 from the `.storekit` config, via
  `displayPrice` — never a hardcoded string).
- **Do:** Tap a tier.
- **Expect:** That tier's price is replaced by a small spinner, the other two tiers become
  disabled (can't double-tap into two purchases at once), and Xcode's **StoreKit test purchase
  sheet** appears (the simulated App Store confirmation UI StoreKit Testing provides).
- **Do:** Confirm the purchase in that sheet.
- **Expect:** The view transitions to the **thank-you state** — a heart, "Thank You So Much!", and
  the reassurance text ("It doesn't unlock anything — it's just a thank-you."), plus a "Tip Again"
  button.
- **Do:** Tap "Tip Again", then tap a tier and **cancel** the StoreKit test sheet instead of
  confirming.
- **Expect:** Cancelling returns cleanly to the tier list with all 3 tiers re-enabled and no error
  shown (no dead-end, no stuck spinner, no false thank-you) — matches `TipStore`'s documented
  `userCancelled → .loaded` (no thanks) behavior.
- **Do:** Repeat a tip — tap the SAME tier a second time (or a different one) after already seeing
  one thank-you.
- **Expect:** The second tip completes and shows its **own** fresh thank-you (not a stale/"already
  dismissed" one) — tips are consumable and explicitly repeatable, never a one-time lock-out.
- **Do:** Force a load failure if feasible (e.g., temporarily rename/detach the `.storekit` config
  or run without it configured), or note this as a code-path check only if not easily forced.
- **Expect:** `.loadFailed` shows a native "Couldn't Load Tips" `ContentUnavailableView` with a
  Retry button, not a blank screen or crash.

## b. A REAL sandbox purchase (device, App Store Connect products required)

- **Do (prerequisite, one-time, done in App Store Connect — NOT part of this checklist's pass/
  fail, just the setup it depends on):** Create 3 **consumable** in-app purchase products in App
  Store Connect matching the exact IDs already used by the code and the `.storekit` config:
  `com.andrewthom.colophon.tip.small`, `com.andrewthom.colophon.tip.medium`,
  `com.andrewthom.colophon.tip.large`, priced at $1.99 / $4.99 / $9.99 (or the App-Store-Connect
  tier nearest those USD prices — `displayPrice` will render whatever price the Store actually
  returns for the buyer's storefront). Set up a **sandbox Apple ID** and sign into it on a real
  device (Settings → App Store → Sandbox Account, or the sandbox prompt at purchase time).
- **Do:** On that real device, install a build with the real App Store Connect products live (no
  `.storekit` override needed — with real products created, the production StoreKit path resolves
  them the same way it will after release), sign into a real Audiobookshelf connection, and go to
  Settings → Support the app.
- **Expect:** All 3 tiers render with prices in the **device's locale/currency** (not necessarily
  USD — `displayPrice` reflects the sandbox Apple ID's storefront region).
- **Do:** Purchase each of the 3 tiers in turn (using the sandbox Apple ID's test payment flow —
  no real money moves).
- **Expect:** Each tier purchases successfully, the real App Store purchase sheet appears (not the
  Xcode test sheet), and the thank-you state shows after each.
- **Do:** Cancel a purchase partway through (dismiss the App Store sheet without confirming).
- **Expect:** Returns gracefully to the tier list, same as the local flow — no error, no stuck
  state.
- **Do:** Tip the same tier twice.
- **Expect:** Both purchases succeed independently (consumables are NOT one-time — StoreKit sells
  them again each time) and each shows its own thank-you.
- **Do:** After tipping, force-quit and relaunch the app, browse the whole app (library, player,
  downloads, settings), and specifically check anything that could plausibly have been gated
  (podcast auto-delete toggle, download limits, playback speed options, etc.).
- **Expect (the core business-model check):** **Nothing is unlocked, nothing is gated, nothing
  changed** anywhere else in the app as a result of tipping. The only observable effect of a
  successful tip is the transient thank-you screen at the moment of purchase — no new
  `@AppStorage`/`UserDefaults` key, no persisted "has tipped" flag, no unlocked feature, no
  removed ad/nag (there were none to begin with). A tip is pure, no-strings support.

## c. No feature gated behind a tip (code-level cross-check, in addition to item b's device check)

- **Do:** Confirm (or have confirmed) that `App/Tips/TipStore.swift` and `App/Views/
  TipJarView.swift` contain no `@AppStorage`/`UserDefaults` writes outside documentation comments
  (`grep -rn "AppStorage\|UserDefaults" App/Tips/ App/Views/TipJarView.swift` — both M2c task
  reports record this grep turning up zero real usages, only doc-comment mentions of the
  constraint).
- **Expect:** The tip jar's only state is `TipStore.state`, which is transient and
  purchase-flow-scoped — it does not persist across app relaunches and gates nothing.

---

### Notes for the tester

- **Xcode-only for the local flow (item a):** this is the single most important environment note
  in this checklist — running the built app any other way (`simctl launch`, idb, a plain device
  install without Xcode attached) will show an empty tier list with no error, which is a known
  environment limitation, NOT a regression. If tiers don't render, first confirm the app was
  launched via Xcode's own Run action before treating it as a bug.
- **App Store Connect products don't exist yet (item b):** a real sandbox purchase cannot be
  attempted until the 3 consumable products are created in App Store Connect with the exact IDs
  above — this is a submission-time prerequisite, not something this milestone's code can satisfy
  on its own. Until then, item **a**'s local `.storekit` flow is the full verification available.
- **No "Restore Purchases" button is correct, not missing:** consumables carry no entitlement and
  aren't part of `Transaction.currentEntitlements`, so there is nothing to restore — don't flag its
  absence as a gap.
- **The business-model check (item b's last step) is the one that matters most:** Colophon is a
  free app with every feature included; the tip jar exists purely so a user can say thanks. If any
  future change ever makes a tip affect app behavior beyond the thank-you screen, that is a
  regression of this milestone's core constraint, not a feature.
