# Colophon M1c-c — Podcasts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Colophon from audiobooks-only to full podcast support — podcast library browse, episode lists (season grouping, sort, finished state), episode detail, and episode playback through the SAME player — reusing the M1c-a/M1c-b browse, cache, and player machinery rather than building a parallel stack.

**Architecture:** Podcasts are an *extension*, not a rebuild. The v2 `cachedEpisode` table (M1c-a) already exists; the 3-part `cachedProgress` PK (`connectionID/itemID/episodeID`) already keys per-episode progress; the player (`PlayerEngine`/`FullPlayerView`) already plays a session — episodes just open a session via `/play/:episodeId`. M1c-c adds the podcast-specific ABSKit endpoints + DTOs (grounded against a real seeded podcast), the episode-list + episode-detail views, episode playback wiring, podcast home shelves (episode-typed personalized shelves), and the deferred podcast search buckets.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI OS 26 Liquid Glass, GRDB (v2 episodes table — no new migration expected), AVFoundation (existing player), existing ABSKit/PlayerEngine/LibraryCache. Reuses `HTMLText` (M1c-b) for episode descriptions.

## Global Constraints

- All prior constraints bind: Swift 6.2 strict concurrency (complete), default-MainActor; targets iOS/macOS 26.0; bundle `com.andrewthom.colophon` (team LL334G7KP2); server ≥ 2.26.0; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **UI MANDATE (review criterion):** native-first Liquid Glass, HIG-idiomatic per platform (à la Apple Podcasts). Glass ONLY on transport/nav chrome; episode rows/artwork/description opaque; one tinted `.glassProminent` primary per surface.
- **macOS gotchas (both real-Mac-only, build-invisible — learned M1c-a/b):** (1) in `SplitShell` register `navigationDestination` INSIDE the column's `NavigationStack` on its root content; (2) every `.sheet` needs `#if os(macOS) .frame(minWidth:minHeight:) #endif` — `.presentationDetents` is iOS-only. Any new podcast sheet (episode list, episode actions) MUST follow both.
- **AUDIO SAFETY:** `COLOPHON_AUTO_MUTE=1` on every E2E; ALWAYS terminate the app after; cap idb screenshots at ≤3 and stop after 2 idb failures.
- Schema: v1/v2/v3 FROZEN. Episodes use the existing v2 `cachedEpisode` table; per-episode progress uses the existing 3-part `cachedProgress` PK. NO new migration expected — if one is truly needed it's `registerMigration("v4")`, additive.
- **HTML descriptions:** episode/podcast descriptions are HTML — render via the existing `HTMLText` helper (safe, network-free), NOT raw `Text`.
- Reuse the player: episode playback goes through the existing `PlayerEngine`/`AppState.startPlayback` path, extended for `episodeId`. Do NOT fork playback.

## Source-verified endpoint reference (ABS 2.35.1 — Task 1 CONFIRMS/CORRECTS live)

These come from the M1c research (advplyr/audiobookshelf v2.35.1 source) and the M1c-a source-only DTOs. **Task 1 seeds a real podcast and verifies/corrects every shape below** — later tasks depend on Task 1's live fixtures, not on this block alone.

```
Podcast library /personalized shelves (LibraryItem.js): continue-listening(type episode),
   newest-episodes(type episode), recently-added(type = library.mediaType), listen-again(type episode).
Podcast item: GET /api/items/:id?expanded=1 -> media.metadata {title,author,description(HTML),
   feedUrl,...}, media.episodes[] (PodcastEpisode).
PodcastEpisode (toOldJSON/toOldJSONExpanded): id, index, season, episode, episodeType, title, subtitle,
   description(HTML), enclosure{url,type,length}, guid, pubDate, publishedAt, audioFile, audioTrack,
   chapters, size, duration.
Episode playback: POST /api/items/:id/play/:episodeId  (same envelope shape as book /play — session id,
   audioTracks, chapters, currentTime; the HLS/direct rules from M1c-b apply).
Per-episode progress: user.mediaProgress[] entries carry episodeId (non-empty for episodes); GET /api/me
   + socket progress. cachedProgress 3-part PK already stores it ("" = book, episodeId = episode).
Search (podcast library): GET /api/libraries/:id/search?q= -> {podcast[{libraryItem}], episodes[...],
   tags, genres} (M1c-a Task 10 deferred the podcast + episodes buckets).
Cover: public /api/items/:id/cover (podcast) + per-episode artwork if present.
```

## File Structure (M1c-c new/changed)

```
devserver/seed.sh                                    MOD  seed a podcast library + a small public feed (or fixture)
Packages/ABSKit/Sources/ABSKit/ABSClient.swift + Models.swift  MOD  podcast episodes fetch, playEpisode, tightened episode/podcast DTOs
Packages/ABSKit/Tests/ABSKitTests/Fixtures/         MOD  live podcast fixtures (personalized-podcast, podcast-item, episodes, search-podcast, me-with-episode-progress)
Packages/LibraryCache/.../LibraryCacheStore.swift   (episodes upsert/observe already exist from M1c-a T2 — wire them)
App/AppState.swift                                   MOD  startPlayback(episodeId:), episode progress join, podcast shelves
App/Views/PodcastDetailView.swift                    NEW  episode list (season grouping, sort, finished state)
App/Views/EpisodeDetailView.swift                    NEW  episode metadata + HTML description + play/queue
App/Views/EpisodeRow.swift                           NEW  episode row (title/date/duration/progress/finished)
App/Views/HomeView.swift + ShelfRow/CoverCard        MOD  episode-typed shelves render episode cards
App/Search/SearchModel.swift + SearchView.swift      MOD  podcast + episodes search buckets
App/Shell/SplitShell.swift + PhoneShell.swift        MOD  podcast library routing to PodcastDetailView (mediaType == podcast)
```

---

### Task 1: Podcast dev fixture + live endpoint grounding + DTO tightening

**Files:** `devserver/seed.sh`; `Packages/ABSKit/.../Models.swift` (tighten source-only DTOs); `Tests/ABSKitTests/Fixtures/*` + decode tests.

**The grounding task — everything else depends on it.** The dev stack currently has only an audiobook library. Seed a **podcast library with a few episodes** so podcasts are testable live:
- Add a podcast library (mediaType `podcast`) to the dev stack. Prefer a **local RSS/enclosure fixture** committed under `devserver/data/podcasts/` (a tiny hand-authored feed + 1-2 short public-domain audio clips) added via the ABS API, so seeding is deterministic and network-independent. If a local feed can't be ingested, fall back to adding a small stable public-domain feed by URL (document the network dependency). Update `seed.sh` idempotently (like the existing audiobook seed).
- With the podcast seeded, CAPTURE live fixtures + verify the source-verified shapes above, correcting any discrepancy: `/api/libraries/:podcastLib/personalized` (the episode-typed shelves + their entity shape), the podcast item (`?expanded=1` → media.metadata + media.episodes[] fields), an episode `/play/:episodeId` envelope, `/api/me` with an episode progress entry (episodeId populated), `/api/libraries/:podcastLib/search?q=` (podcast + episodes buckets).
- **Tighten the M1c-a source-only DTOs against these live fixtures:** `ShelfEpisodeEntity` (M1c-a Task 5 — the episode shelf-entity variant), `SearchEpisodeHit` / the `podcast`+`episodes` buckets in `SearchResults` (M1c-a Task 5/10), and confirm the `cachedEpisode` columns (M1c-a Task 2) match the real `PodcastEpisode` fields. Fix names/optionality; add decode tests bound to the captured fixtures.

- [ ] Seed + capture; decode tests RED→GREEN; `cd Packages/ABSKit && swift test`. Report every source-vs-live correction. Commit `feat(devserver,ABSKit): podcast dev fixture + live-verified episode DTOs`.

---

### Task 2: ABSKit podcast endpoints

**Files:** `ABSClient.swift`, `Models.swift`; fixtures + tests.

**Interfaces (grounded in Task 1):** `func podcastItem(id:) async throws -> PodcastDetail` (media.metadata + episodes[]); `func playEpisode(itemID:episodeId:deviceInfo:) async throws -> PlaybackSessionEnvelope` (POST /api/items/:id/play/:episodeId — reuse the existing envelope type from M1c-b); episode progress flows through the existing `me()` + socket. Tolerant decode. The book `item(id:)` already exists — add the podcast/episodes accessors without duplicating.

- [ ] Captured-fixture decode tests + an opt-in ContractTests live check (play an episode, leave the session clean). Commit `feat(ABSKit): podcast item + episode playback endpoints`.

---

### Task 3: Episode cache wiring (v2 table)

**Files:** `App/AppState.swift`, `LibraryCacheStore` (upsertEpisodes/episodes already exist from M1c-a T2).

Wire the fetched episodes into the v2 `cachedEpisode` table (`upsertEpisodes` on podcast-detail load, `observe`/`episodes` for instant paint), and per-episode progress into `cachedProgress` (3-part PK, episodeId populated) from the `me()` join + socket. NO new migration.

- [ ] Tests: episodes round-trip + observe; per-episode progress distinct from book progress (extend M1c-a's episode-progress test). Commit `feat(app): cache podcast episodes + per-episode progress`.

---

### Task 4: Podcast detail view (episode list)

**Files:** Create `App/Views/{PodcastDetailView,EpisodeRow}.swift`; route podcast-mediaType libraries/items to it (SplitShell + PhoneShell — respect the macOS nav gotcha).

Native episode list like Apple Podcasts: podcast header (cover, title, author, HTML description via `HTMLText`), episodes grouped by **season** (`Section` per season when seasons exist, else flat), **sort** (newest/oldest/season), **finished state** per episode (from `cachedProgress.isFinished`), an in-progress bar, `EpisodeRow` (title, pubDate, duration `.monospacedDigit()`, played/inprogress indicator). Tap episode → EpisodeDetailView (or play). Play affordance per row + "Play"/"Add to Queue" context actions. Loading/empty/error native.

- [ ] Build both; native-UI review; CAPPED MUTED E2E (podcast lib → detail shows episodes grouped/sorted, finished state renders). Commit `feat(app): podcast detail with episode list`.

---

### Task 5: Episode playback through the player

**Files:** `App/AppState.swift` (`startPlayback` gains an `episodeId:` path), player wiring.

Playing an episode calls `playEpisode(itemID:episodeId:)` → the SAME `PlayerEngine`/full player; the session syncs per-episode progress (the sync/close path carries episodeId); `nowPlayingItemID`/now-playing reflect the episode (episode title + podcast as author/album); the queue + sleep timer + speed + bookmarks all work for episodes (bookmarks are per-item; confirm the episode context). Per-book speed persistence keys per (connectionID,itemID) — decide episode granularity (per-podcast vs per-episode; document).

- [ ] Tests: startPlayback(episodeId:) opens the episode session + syncs episode progress (MockTransport). CAPPED MUTED E2E: play an episode → mini-bar/player reflect it → progress syncs to the server for that episode. Commit `feat(app): episode playback through the shared player`.

---

### Task 6: Episode detail view

**Files:** Create `App/Views/EpisodeDetailView.swift`.

Native episode page: title, podcast, pubDate, duration, **HTML description via `HTMLText`**, a prominent Play/Resume (one `.glassProminent`), Add-to-Queue, finished toggle (optional). Reached from EpisodeRow. macOS sheet/nav gotchas respected if presented as a sheet.

- [ ] Build both; native-UI review; CAPPED E2E. Commit `feat(app): episode detail view`.

---

### Task 7: Podcast home shelves

**Files:** `App/Views/{HomeView,ShelfRow,CoverCard}.swift`; `AppState` shelves.

The episode-typed personalized shelves (continue-listening/newest-episodes/listen-again) render episode cards (cover + episode title + podcast + progress pill from per-episode `cachedProgress`). The `ShelfEntity.episode` variant (M1c-a Task 5, live-verified in Task 1) is now rendered (M1c-a stubbed it). Tapping plays the episode / opens episode detail.

- [ ] Build; native-UI review; CAPPED E2E (Home for a podcast library / mixed shows episode shelves with progress). Commit `feat(app): podcast home shelves`.

---

### Task 8: Podcast search buckets

**Files:** `App/Search/SearchModel.swift`, `SearchView.swift`.

Implement the deferred M1c-a Task 10 podcast search: merge `results.podcast` (podcast library items) into the Titles-equivalent section and add an **Episodes** server-only section; podcast libraries were showing zero title rows (M1c-a note). Section order extended for podcasts. Unit-test the merge (fake results with podcast+episodes buckets).

- [ ] SearchModel tests (podcast/episodes buckets merge/order); CAPPED E2E (search in a podcast library → podcast + episode results). Commit `feat(app): podcast + episode search buckets`.

---

### Task 9: Wrap-up + human-verification + final review

**Files:** `README.md`; `docs/superpowers/m1c-c-human-verification.md`; contract-block refresh.

- [ ] README → M1c-c reality (podcasts: browse, episode lists w/ season grouping + finished state, episode detail, episode playback, podcast shelves + search). Human-verification checklist (episode audio audible, per-episode progress persists, season grouping, now-playing for episodes — device/Mac-only items). Full cold-start sweep `make test && make test-app && make build-ios && make build-mac` green, zero warnings. Commit `docs: M1c-c status`. Then the whole-branch adversarial review before merge.

---

## Self-review notes (plan-writing time)

- **Coverage vs M1c overview §M1c-c:** dev fixture (T1), podcast browse (T4), episode lists w/ season grouping + sort + finished (T4), episode detail (T6), episode playback via same player + per-episode progress (T3/T5), podcast home shelves (T7). Plus the recorded M1c-a/b carry-forwards: episode/podcast + search-episode DTO live-tightening (T1), podcast+episodes search buckets (T8, deferred from M1c-a T10), ShelfEpisodeEntity live-render (T7).
- **Grounding-first:** T1 seeds a real podcast + live-verifies every shape before the plan's source-verified block is trusted — the same discipline that kept the M1c-a plan bug-free. Later tasks cite T1's fixtures.
- **Reuse, not rebuild:** v2 cachedEpisode table + 3-part progress PK + PlayerEngine + HTMLText + the browse views all already exist; M1c-c wires podcasts through them. No new migration expected.
- **macOS gotchas baked into Global Constraints** (nav-destination-inside-stack + sheet-frame) so the new podcast sheets/nav don't repeat the real-Mac bugs from M1c-a/b.
- **Deferred beyond M1c-c:** server-side podcast download/auto-download management (admin, out of scope); client offline downloads (M2); ebooks (out entirely); CarPlay UI (M2, entitlement pending).
