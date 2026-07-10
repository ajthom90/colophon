# CarPlay Audio Entitlement — Tracking Record

- **Status:** SUBMITTED (awaiting Apple review) — still PENDING as of 2026-07-10 (user confirmed no grant email yet).
- **Submitted:** 2026-07-07 by the account holder via https://developer.apple.com/contact/carplay/
- **Entitlement:** `com.apple.developer.carplay-audio` (CarPlay Audio App)
- **Bundle ID:** `com.andrewthom.colophon` (team LL334G7KP2)
- **Expected turnaround:** days to a few weeks, case-by-case, no published SLA; decision arrives by email.
- **M2c consequence (2026-07-10):** CarPlay UI is DEFERRED out of M2c — M2c ships the tip jar only. CarPlay lands as a follow-on milestone once this grant arrives (see "When approved" below).

## When approved
1. Update this file (status → GRANTED + date).
2. "CarPlay Audio App" capability appears on the App ID in the developer portal; automatic signing regenerates profiles on next build.
3. Add `com.apple.developer.carplay-audio` to `App/Colophon.entitlements` ONLY when the CarPlay feature work starts (currently scheduled: M2, conditional on this grant).
4. Development/testing: iOS Simulator → I/O → External Displays → CarPlay (no vehicle hardware needed; user currently has none — final in-car polish deferred until hardware is available).

## If rejected
Record the stated reason here; the audio category is the natural fit for an audiobook/podcast player, so a rejection likely means the description needs clarification — revise and refile.
