# Colophon Milestone 1c — Overview & Decomposition

Milestone 1c ("Browse & player experience", spec §9 M3-adjacent browse/player scope) turns M1a/M1b's plumbing into the experience people actually use. Per user decisions (2026-07-07): **podcasts are IN M1c**, the milestone is **split into sub-plans**, and **all four player features** (sleep timer, bookmarks, per-book speed persistence, up-next queue) are in scope.

**Binding UI mandate (user directive 2026-07-07):** native-first, **Liquid Glass**, HIG-idiomatic **per platform** — not a shared lowest-common-denominator layout. This is the project's reason to exist (the Mac gap). Every M1c surface is held to it, and it is a Global Constraint in each sub-plan plus a task-scoped review criterion (a non-native surface is a finding). Detail synthesized from the M1c research/design workflow (endpoint verification against the live server + a concrete Liquid Glass design system for iPhone/iPad/Mac).

**Inputs:** spec (docs/superpowers/specs/2026-07-06-audiobookshelf-apple-client-design.md); M1b final-review carry-forwards (.superpowers/sdd/progress.md, M1b section); the M1c research/design workflow output.

## Sequencing rationale

Hardening + data + browse first (M1c-a) because every player and podcast surface reads through the cache and the v2 schema, and the recorded connection-epoch/20-page-cap fixes must land before more UI composes on top of them (same discipline that made M1a precede M1b). The full audiobook player (M1c-b) before podcasts (M1c-c) so the player is proven on the simpler content type, then extended to episodes — podcasts reuse the same player, detail, and cache machinery, so they're an extension, not a parallel build.

## M1c-a — Hardening, v2 data, browse & search foundation (plan: 2026-07-07-colophon-m1c-a-foundation.md)

The correctness carry-forwards plus the data + browse layer for BOTH books and podcasts. Deliverable: a native, Liquid-Glass browse experience over cached + live data with search, home shelves, and library/series/authors browsing — the surfaces the player and podcasts hang off.

1. **Connection-epoch refactor** (M1b final-review Important, recorded as M1c's first commit): replace the ad-hoc generation-guard asymmetry with a clean per-flow epoch captured at entry + re-checked after every await; signOut/removeConnection tail guards; move connect's bump below URL validation; scope so unrelated probes aren't over-invalidated.
2. **v2 GRDB migration** (the freeze note's first v2): item-detail columns (description, narrator, series, genres, publishedYear…) and a **podcast episodes table** (using the existing 3-part progress PK convention). Frozen v1 stays; this is a new registerMigration("v2").
3. **20-page-cap resolution** (before search/browse ships): capped page-throughs never reconcile → ghost accretion. Raise/remove the cap or reconcile per-page-window; per-item patch for `itemChanged` socket events (replace coarse re-page).
4. **Cover in-flight fetch dedup** (M1a carry — shelves multiply concurrent renders).
5. **Home shelves**: GET /api/libraries/:id/personalized → native horizontally-scrolling cover shelves (continue-listening, recently-added, discover…), lazy + prefetching, Liquid Glass headers.
6. **Library browse**: sort/filter (filterdata-driven) over the cover grid; series and authors browse.
7. **Search**: server search + local FTS5 blend (instant local, richer server buckets), the native search surface.
8. **Per-platform navigation shell v1**: iPhone TabView + now-playing mini-bar; iPad NavigationSplitView; Mac sidebar + docked transport bar stub — the Liquid Glass shell the rest of M1c fills in.
9. Refresh the shipped-reality contract block; test-robustness carry-forwards (bounded liveness loops, shared test fixtures, multi-destination test-app if Mac UI grows).

## M1c-b — Item detail & full audiobook player (planned after M1c-a ships)

- Item detail view (metadata, description, series, chapters, actions) — native, Liquid Glass.
- Full-screen player: artwork with backgroundExtensionEffect, chapter list + chapter-aware scrubber, transport with configurable skip, **sleep timer** (presets + end-of-chapter + fade), **bookmarks** (create/list/delete), **per-book speed persistence**, **up-next queue**.
- Player surfaces per platform (sheet/cover/window), Mac menu-bar Commands + keyboard shortcuts for transport (interim Mac niceties that can't wait for M3).
- Human-verification pass on a real library (audio, chapters, sleep timer, lock screen, media keys).

## M1c-c — Podcasts (planned after M1c-b ships)

- Dev-stack podcast fixture (seed a podcast library + episodes so it's testable live — the research names what's needed).
- Podcast library browse; episode lists with season grouping, sort/filter, finished state; episode detail.
- Episode playback through the SAME player (per-episode progress via the /:episodeId endpoints; the v2 episodes table).
- Podcast home shelves (newest-episodes, continue-listening for episodes).

## Deferred beyond M1c (recorded, not in scope)

Server-side podcast download/auto-download management (admin-only); client offline downloads (that's M2); ebooks (out of scope entirely); simultaneous multi-server browsing; AppleScript/MCP on Mac (post-v1). CarPlay UI (M2, conditional on the submitted entitlement).
