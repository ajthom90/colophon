# Colophon Milestone 1 — Overview & Decomposition

Milestone 1 ("Streaming core", spec §9) is decomposed into three sequential sub-plans.
Each produces working, testable software on its own; each gets its own detailed plan
document when its turn comes, so later plans absorb what earlier execution teaches.

**Inputs:** spec (docs/superpowers/specs/2026-07-06-audiobookshelf-apple-client-design.md),
M0 final-review carry-forwards (.superpowers/sdd/progress.md). CarPlay is deferred
entirely (user decision 2026-07-06) — nothing in M1 or M2 depends on it anymore.

## M1a — Foundation & correctness (plan: 2026-07-06-colophon-m1a-foundation.md)

The load-bearing carry-forwards plus the persistence/realtime spine everything else
sits on. Deliverable: the walking skeleton upgraded to a correct, cache-backed,
live-updating client with a fully unit-testable player core.

1. Dev-infra: cover fixture in seed, compose restart policy, cover contract test → 200.
2. SessionSyncController consume-semantics (in-flight accrual survives didSync).
3. Typed errors: LocalizedError conformances, ServerVersion gate (≥ 2.26.0).
4. PlayerBackend protocol seam + FakePlayerBackend + PlaybackController unit tests
   (boundary, seek, rate, cadence, book-end) — before M1c piles features on the player.
5. PlaybackSessionHandle: session close/flush lifecycle (final-review Important #1),
   sync-404 recovery via POST /api/session/local, scene-phase flush/close.
6. LibraryCache package (GRDB 7): connections/libraries/items/progress schema, FTS5,
   ValueObservation; views observe the cache, network writes into it (spec §3 inversion).
7. Cache-backed browse + stable connection UUIDs + keychain migration + retry UX.
8. CoverStore disk cache (ts-keyed, spec §3 ABSKit block).
9. Auth housekeeping: tokenUpdates AsyncStream, logout test, kSecUseDataProtectionKeychain,
   Info.plist version vars, clientVersion from bundle.
10. ABSRealtime SocketService (socket.io-client-swift 16.1.1, adopt-verdict config,
    tuned reconnect, re-auth on token updates) + ServerEvent decoding.
11. Socket → cache wiring: live progress/item updates flow into the UI.
12. Wrap-up sweep + tag `m1a-foundation`.

## M1b — Sign-in & connections UX (planned after M1a ships)

- OIDC: Dex IdP in the dev compose stack; the deferred cookie-behavior spike; the
  ASWebAuthenticationSession PKCE flow (`colophon://oauth`), driven by /status
  authFormData (custom button text, auto-launch).
- Connection management UI: add/edit/remove/switch servers, per-connection sign-in
  states, first-run experience.
- Settings scene skeleton + the serif (New York) / San Francisco typeface toggle
  (spec §2 locked decision) + default playback speed / skip-interval prefs.

## M1c — Browse & player experience (planned after M1b ships)

- Personalized home shelves (continue-listening etc.), library sort/filter, series/
  authors browse, search (server + local FTS5).
- Item detail view; full-screen player: chapter list/scrubber, sleep timer (incl.
  end-of-chapter), bookmarks, per-book speed override, queue behavior.
- iPad NavigationSplitView shell; interim Mac niceties that can't wait for M3
  (keyboard shortcuts for transport, basic menu commands).
- Human-verification checklist rerun on a real library at the end (M0's checklist
  passed 2026-07-06 against the user's personal server).

## Sequencing rationale

M1a first because every later feature reads through the cache, plays through the
player core, and syncs through the session handle — retrofitting any of those under
shipped UI would repeat M0's most expensive review findings at 10× the surface. M1b
before M1c because real-library browsing (M1c) is far more pleasant to build and test
once multi-server sign-in is trivial and settings exist to toggle.
