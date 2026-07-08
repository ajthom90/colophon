# Colophon M1c-a — Hardening, v2 Data, Browse & Search Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the M1b carry-forward correctness fixes, a v2 GRDB schema for richer item detail + podcasts, and a native, Liquid-Glass browse experience — home shelves, library browse with sort/filter, series/authors, and search — the surfaces the M1c-b player and M1c-c podcasts hang off.

**Architecture:** Three layers. (1) **Correctness:** replace M1b's ad-hoc connection generation-guard with a clean per-flow epoch; resolve the 20-page reconciliation cap; per-item socket patch; cover fetch dedup. (2) **Data:** a `v2` migration adding item-detail columns + a podcast episodes table; new store reads (shelves, filterdata, series, authors, search). (3) **Native UI:** a per-platform Liquid Glass navigation shell (iPhone `TabView` + bottom-accessory mini-player, iPad/Mac `NavigationSplitView`, Mac hand-built docked transport) filled with home shelves, a cover grid with sort/filter, series/authors browse, and a local-FTS5 ⨯ server-search blend.

**Tech Stack:** Swift 6.2, GRDB 7.11.1, SwiftUI OS 26 Liquid Glass (`glassEffect`, `GlassEffectContainer`, `backgroundExtensionEffect`, `scrollEdgeEffectStyle`, `.buttonStyle(.glass/.glassProminent)`, `tabViewBottomAccessory`, `tabBarMinimizeBehavior`), Swift Testing, existing ABSKit/PlayerEngine/LibraryCache/ABSRealtime packages.

## Global Constraints

- All M0/M1a/M1b constraints bind: targets iOS/macOS 26.0; Xcode 26.6; strict concurrency; bundle `com.andrewthom.colophon` (team `LL334G7KP2`, automatic signing); server ≥ 2.26.0; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **UI mandate (user directive 2026-07-07, non-negotiable, a review criterion):** native-first, **Liquid Glass**, **HIG-idiomatic per platform** — NOT a shared lowest-common-denominator layout. Glass on the floating navigation/control layer ONLY, never on content (shelves/artwork/rows/text stay opaque); never glass-on-glass; at most one tinted `.glassProminent` primary action per screen; cluster floating controls in a `GlassEffectContainer`. A surface that is not native/HIG-idiomatic is a review finding, like a bug.
- **Verified platform fact:** `tabViewBottomAccessory(content:)` is iOS/iPadOS/**Mac Catalyst 26.0 only — NOT native macOS.** The Mac transport is hand-built via `.safeAreaInset(edge: .bottom)`, explicitly NOT a floating Music-app-style player.
- **Cover endpoint is PUBLIC** (verified live: 200 image/webp with no auth header) — `AsyncImage` → `GET {server}/api/items/{id}/cover?width=N` works directly; no Authorization needed. Default webp; `&format=jpeg` for jpeg. Keep using the existing `CoverStore` disk cache; `AsyncImage` is acceptable for shelf/grid cards where the store's dedup isn't wired.
- **Progress is NOT on shelf entities** (verified live: `/api/libraries/:id/personalized` entities carry no progress field). Source progress by joining `user.mediaProgress[]` (keyed by `libraryItemId`, shape `{libraryItemId, progress, currentTime, duration, isFinished}`, returned by `POST /login` and `GET /api/me`) into the cache's `CachedProgress`, which the UI already observes.
- Schema: v1 is FROZEN (M1b). This milestone adds `registerMigration("v2")` — never edit v1. Keep the `#if DEBUG eraseDatabaseOnSchemaChange` flag.
- Headless E2E discipline: `COLOPHON_AUTO_MUTE=1` every run; ALWAYS terminate the app afterward. Live stack: `make server-up && make seed` (ABS + Dex @ localhost:13378, root/colophon-dev).
- Contract/store tests are the deterministic proof; SwiftUI surfaces are verified by build + native-UI review + a live idb E2E per task.

## Verified endpoint reference (live ABS 2.35.1, this milestone's data)

```
GET /api/libraries/:id/personalized?limit=  -> [{ id, label, labelStringKey, type, entities[] }]
    types seen live (book lib): continue-listening(book), recently-added(book), newest-authors(authors)
    podcast libs (source-verified): continue-listening(episode), newest-episodes(episode),
                                    recently-added(mediaType), listen-again(episode)
    entity(book): { id, media:{ coverPath, duration, metadata:{title,subtitle,authorName,narratorName,seriesName,...} } }  -- NO progress
GET /api/libraries/:id/items?limit=&page=&sort=&desc=&minified=1&filter=<group>.<base64url(value)>
    sorts: media.metadata.title | addedAt | media.metadata.authorName | media.metadata.publishedYear | size | progress
    -> { results[], total, limit, page, sortBy, sortDesc }
GET /api/libraries/:id/filterdata -> { authors[{id,name}], series[{id,name}], genres[], tags[], narrators[],
                                       languages[], publishers[], publishedDecades[], bookCount, authorCount, seriesCount, ... }
GET /api/libraries/:id/series?limit=<REQUIRED>  -> { results[{ id,name,books[],... }], total }
GET /api/libraries/:id/authors -> { authors[{ id, name, numBooks, imagePath, asin, description, lastFirst }] }
GET /api/authors/:id?include=items ; GET /api/authors/:id/image?width=  (imagePath null => no image)
GET /api/libraries/:id/search?q=&limit=12  (per-library ONLY; empty q => 400; min 2 chars advised)
    book lib -> { book:[{libraryItem:<expanded>}], narrators[{name,numBooks}], tags[{name,numItems}],
                  genres[{name,numItems}], series[{series,books}], authors[{id,name,numBooks,...}] }
    book bucket matches title/subtitle/isbn/asin ONLY (NOT author -> authors surface in authors bucket)
    podcast lib -> { podcast, tags, genres, episodes }
GET /api/me  -> user incl. mediaProgress[{libraryItemId,episodeId?,progress,currentTime,duration,isFinished,...}], bookmarks[]
GET /api/items/:id?expanded=1&include=progress -> media.metadata(full), media.chapters[{id,start,end,title}] (GLOBAL secs),
                                                  userMediaProgress{currentTime,progress,duration,isFinished}
```

## File Structure (M1c-a end state; new/changed)

```
Packages/LibraryCache/Sources/LibraryCache/Schema.swift       + registerMigration("v2")
Packages/LibraryCache/Sources/LibraryCache/Records.swift      + CachedItemDetail, CachedEpisode; CachedItem gains detail cols
Packages/LibraryCache/Sources/LibraryCache/LibraryCacheStore.swift  + shelves/filterdata/series/authors reads, upsertItemDetail, episodes
Packages/ABSKit/Sources/ABSKit/ABSClient.swift                + personalized, filterdata, series, authors, searchLibrary, me
Packages/ABSKit/Sources/ABSKit/Models.swift                   + Shelf, FilterData, SeriesSummary, AuthorSummary, SearchResults, MeUser
App/AppState.swift                                            connection-epoch refactor; shelves/browse/search state; per-item patch
App/Shell/RootShell.swift            NEW  per-platform shell selector
App/Shell/PhoneShell.swift           NEW  TabView + tabViewBottomAccessory mini-player
App/Shell/SplitShell.swift           NEW  iPad/Mac NavigationSplitView (+ Mac .safeAreaInset transport + Commands)
App/Shell/MiniPlayerBar.swift        NEW  glass mini now-playing bar
App/Views/HomeView.swift             NEW  personalized shelves
App/Views/ShelfRow.swift             NEW  horizontal cover shelf
App/Views/CoverCard.swift            NEW  cover + title/author + progress pill
App/Views/LibraryGridView.swift      NEW  LazyVGrid browse + sort/filter toolbar
App/Views/FilterSheet.swift          NEW  filterdata-driven filter UI
App/Views/SeriesListView.swift / AuthorsListView.swift  NEW
App/Views/SearchView.swift           NEW  .searchable, FTS5+server blend, grouped sections
App/Search/SearchModel.swift         NEW  debounce + cancel + merge
Packages/ABSKit/Tests / LibraryCacheTests / ColophonTests     + tests per task
```

---

### Task 1: Connection-epoch refactor (M1b final-review carry-forward — FIRST commit)

**Files:** Modify `App/AppState.swift`; `App/ColophonTests/AppStateTests.swift`.

**Interfaces:** Produces a single `private var connectionEpoch = 0` + `private func beginConnectionFlow() -> Int { connectionEpoch += 1; return connectionEpoch }`; every connection-mutating flow (connect, connectWithOIDC, activateConnection, signOut, removeConnection) calls it at entry and re-checks `guard connectionEpoch == myEpoch else { return }` after every await and in every detached probe branch. Replaces the ad-hoc `connectionGeneration`/`activatingConnectionID` pair with one uniform mechanism. `signOut`/`removeConnection` also normalize `.connecting → .disconnected` (preserve the M1b fix). Removes the two M1b-recorded asymmetries: (a) move `connect()`'s epoch bump BELOW the URL-validation guard so an invalid URL doesn't stale a healthy active probe; (b) `signOut`/`removeConnection` now also GUARD their own post-await tails on their epoch (not just bump), so a newer activation started during their awaits is not stomped.

- [ ] **Step 1: Write failing tests.** Keep the M1b race/stranding tests green; add: `signOutTailDoesNotStompNewerActivation` (sign out an owning connection whose retire has awaits; mid-retire, activate another connection; assert the newer connection's active state/socket survive the signOut tail); `invalidURLConnectDoesNotStaleActiveProbe` (an active connection with an in-flight probe; a second connect() with a malformed URL returns without disturbing the probe → the active connection still comes online).
- [ ] **Step 2–4:** RED → implement the uniform epoch (mechanically replace the two guards; every await site gets `guard connectionEpoch == myEpoch`; bump-below-validation; guard signOut/remove tails) → GREEN. `make test-app` (all prior + 2 new).
- [ ] **Step 5: Commit** `refactor(app): unify connection flows under a single epoch guard`.

---

### Task 2: v2 GRDB migration — item detail columns + podcast episodes table

**Files:** Modify `Packages/LibraryCache/Sources/LibraryCache/Schema.swift`, `Records.swift`, `LibraryCacheStore.swift`; `Tests/LibraryCacheTests/LibraryCacheStoreTests.swift`.

**Interfaces:**
- `registerMigration("v2")`: `ALTER TABLE cachedItem ADD COLUMN` for `subtitle TEXT, narratorName TEXT, seriesName TEXT, genres TEXT (JSON array), publishedYear TEXT, description TEXT, mediaType already exists` — plus a new `cachedItemDetail` table (1:1 with item, holds the heavy on-demand detail: full description, publisher, isbn, asin, language, explicit, abridged, chaptersJSON) so the grid stays lean; and a `cachedEpisode` table `(connectionID, itemID, episodeID PK) + index, season, episode, episodeType, title, subtitle, description, pubDate, publishedAt, durationSeconds, sizeBytes, guid` for M1c-c. Progress for episodes already uses the 3-part `cachedProgress` PK (verified correct — no change).
- Store: `upsertItemDetail(_ CachedItemDetail)`, `itemDetail(connectionID:itemID:) -> CachedItemDetail?`; `upsertEpisodes(_ [CachedEpisode], connectionID:itemID:)`, `episodes(connectionID:itemID:) -> [CachedEpisode]` (sorted by publishedAt desc). `CachedItem` gains the new browse-facing columns (subtitle/narrator/series/genres/publishedYear) populated from the minified items payload.
- Migration safety: v2 is ALTER-only + CREATE — a v1 DB migrates forward cleanly (test: open a v1-populated store, migrate to v2, assert existing rows intact + new columns null-defaulted).

- [ ] **Step 1:** Failing tests: `v2AddsDetailColumnsPreservingV1Rows`, `itemDetailRoundTrips`, `episodesRoundTripSortedByPublishedAtDesc`, `episodeProgressStillKeyedPerEpisode`.
- [ ] **Step 2–4:** RED → implement (verify GRDB `alterTable`/`create` idioms against the pinned 7.11.1 source; record deviations) → GREEN. `make test`.
- [ ] **Step 5: Commit** `feat(LibraryCache): v2 migration — item-detail columns and episodes table`.

---

### Task 3: 20-page-cap resolution + per-item socket patch

**Files:** Modify `App/AppState.swift` (`refreshItems`, `apply(.itemChanged)`), `Packages/ABSKit/Sources/ABSKit/ABSClient.swift` (single-item fetch), `LibraryCacheStore` (single-item upsert already exists via `upsertItemsPage`); tests in `ColophonTests`.

**Interfaces:**
- `refreshItems`: remove the hard 20-page cap; page through to completion (`accumulated >= total`) with a generous safety bound (e.g. 200 pages / 10k items — `log()`/note if exceeded rather than silently truncating), THEN `replaceItems` reconciles (deletion works for arbitrarily large libraries — the ghost-accretion hazard is closed). Keep the lying-response guard (`total>0 && empty → skip`).
- `apply(.itemChanged(id))`: replace the coarse full-library `refreshItems` with a targeted `ABSClient.item(id:)` fetch → `upsertItemsPage([that item], …)` (one row, no full re-page). `apply(.itemsChanged(ids))`: fetch/patch each id (bounded; fall back to a single `refreshItems` only if the id set is very large). `apply(.itemRemoved)` stays as the Task-4/M1b deletion path.

- [ ] **Step 1:** Failing tests: `itemChangedPatchesSingleRowNotFullRefresh` (socket item_updated for one id → exactly one `/api/items/:id` request, that row updated, others untouched, NO `/items?page` full re-page); `largeLibraryReconcilesWithoutCap` (scripted 3-page library, total across pages, a stale row removed by `replaceItems` after the completed multi-page fetch).
- [ ] **Step 2–5:** RED → implement → GREEN → commit `fix(app): uncapped reconciliation and per-item socket patch`.

---

### Task 4: Cover in-flight fetch dedup (M1a carry — shelves multiply concurrent renders)

**Files:** Modify `Packages/LibraryCache/Sources/LibraryCache/CoverStore.swift`; `Tests/LibraryCacheTests/CoverStoreTests.swift`.

**Interfaces:** `CoverStore.coverData(...)` gains in-flight dedup: concurrent requests for the same `(connectionID, itemID, updatedAt)` that miss disk share ONE `fetch()` (a `[Key: Task<Data,Error>]` inside the actor; awaiters attach to the existing task; entry cleared on completion). Preserves write-before-delete and error propagation.

- [ ] **Step 1:** Failing test `concurrentMissesShareOneFetch` (10 concurrent `coverData` for the same key with a counting/slow fetch → fetch invoked exactly once, all 10 get the bytes). Keep existing 3 CoverStore tests green.
- [ ] **Step 2–5:** RED → implement (actor-held in-flight map) → GREEN → commit `perf(LibraryCache): dedupe concurrent cover fetches`.

---

### Task 5: ABSKit browse + search + me endpoints

**Files:** Modify `Packages/ABSKit/Sources/ABSKit/ABSClient.swift`, `Models.swift`; fixtures + `Tests/ABSKitTests/*`.

**Interfaces (grounded in the verified reference above):**
- `func personalizedShelves(libraryID:limit:Int=10) async throws -> [Shelf]` (Shelf `{id,label,type,entities:[ShelfEntity]}`; ShelfEntity decodes book+authors+episode entity variants tolerantly).
- `func filterData(libraryID:) async throws -> FilterData`.
- `func series(libraryID:limit:Int) async throws -> [SeriesSummary]` (limit REQUIRED).
- `func authors(libraryID:) async throws -> [AuthorSummary]`; `func author(id:) async throws -> AuthorDetail`.
- `func searchLibrary(libraryID:query:limit:Int=12) async throws -> SearchResults` (buckets book/podcast/narrators/tags/genres/series/authors/episodes, all optional; empty query is a client-side guard — never call with <2 chars).
- `func me() async throws -> MeUser` (mediaProgress[], bookmarks[]) — the progress-join source for shelves + bookmarks for the player.
- `func item(id:) async throws -> LibraryItemDetail` (expanded item detail incl. chapters — used by Task 3 patch and M1c-b).
- DTOs decode tolerantly (unknown fields ignored). Match-bucket note baked into a doc comment on `searchLibrary`: the `book` bucket does NOT include author-name matches.

- [ ] **Steps:** captured-fixture decode tests per endpoint (grab a real `/personalized`, `/filterdata`, `/authors`, `/search?q=art`, `/me` from the live server and commit as fixtures) → RED → implement → GREEN → an opt-in `ContractTests` extension hitting these live (env-gated) → commit `feat(ABSKit): browse, search, and me endpoints`.

---

### Task 6: Native Liquid Glass navigation shell (per-platform)

**Files:** Create `App/Shell/{RootShell,PhoneShell,SplitShell,MiniPlayerBar}.swift`; modify `App/ColophonApp.swift`.

**Interfaces / design (from the verified Liquid Glass inventory — all APIs 26.0):**
- `RootShell` selects by platform/size class: **iPhone → `PhoneShell`**, **iPad & Mac → `SplitShell`**.
- `PhoneShell`: `TabView` with `Tab("Home", systemImage:"house")`, `Tab("Library", systemImage:"books.vertical")`, `Tab("Search", role:.search)` (+ a Downloads tab stub for M2). Now-playing via `.tabViewBottomAccessory { MiniPlayerBar() }` (auto-sits above the tab bar, shares tab-bar glass, morphs on expand → tap presents the full player in M1c-b; here it's a tappable bar showing current title/author/artwork + play-pause). `.tabBarMinimizeBehavior(.onScrollDown)`.
- `SplitShell`: `NavigationSplitView { sidebar } detail: { … }`. Sidebar = system glass list (Home / each Library / Series / Authors / Search). **Mac transport is hand-built**: `.safeAreaInset(edge:.bottom) { TransportBar() }` (full-width bottom bar in a `GlassEffectContainer`, NOT floating) — iPad reuses `tabViewBottomAccessory` (Catalyst-valid) or the same bottom inset. Mac gains `.commands { CommandMenu("Playback") { … } }` with `Space` play/pause, skip, speed shortcuts (wired to `PlaybackController` — the menu items can be present now even though the full player UI lands in M1c-b; guard actions on an active session).
- `MiniPlayerBar` / `TransportBar`: opaque content row (artwork, serif title/author, `.monospacedDigit()` time) with a `GlassEffectContainer` transport cluster — play/pause `.buttonStyle(.glassProminent)` (the one tinted primary), skip `.buttonStyle(.glass)`. Bound to the existing `AppState.playback` (`PlaybackController`).
- Root `.fontDesign` typeface toggle already applies; keep transport labels SF via a scoped `.fontDesign(.default)`.
- Boot flow (M1b) unchanged: connections → ConnectionsView/activate → this shell once connected.

- [ ] **Steps:** build the shell scaffolding; wire the existing browse/connection views into it as placeholders where later tasks fill content. Verify: `make build-ios && make build-mac`; **native-UI review criterion** (glass only on nav/transport; Mac bottom-docked not floating; one prominent action); live idb E2E (MUTED): connect → shell renders per platform (iPhone tabs + mini-bar, Mac sidebar + bottom transport), play a book from the existing list → mini-bar/transport reflects it → terminate. Commit `feat(app): per-platform Liquid Glass navigation shell`.

---

### Task 7: Home shelves

**Files:** Create `App/Views/{HomeView,ShelfRow,CoverCard}.swift`; modify `AppState` (shelves state + refresh), `LibraryCacheStore` (optional shelf cache — or fetch-on-appear with progress joined from `CachedProgress`).

**Interfaces / design:**
- `HomeView`: vertical `ScrollView` of `ShelfRow`s from `ABSClient.personalizedShelves`; `.scrollEdgeEffectStyle(.soft, for:.top)` so cards fade under the nav glass. Section headers opaque. Refresh on appear + on socket progress events.
- `ShelfRow`: horizontal `ScrollView` + `LazyHStack` of `CoverCard`, `.scrollTargetBehavior(.viewAligned)`, prefetch on appear.
- `CoverCard`: `AsyncImage` → public cover URL (`coverURL(itemID:width:)`), serif title/author, and a **progress pill** sourced by joining `CachedProgress` (from `me()`/socket, NOT the shelf entity — verified). Tap → item detail (M1c-b) / play.
- Types: `book`/`authors`/`episode` shelf entities render appropriate cards (authors shelf → author avatars; episode shelf stubbed until M1c-c).

- [ ] **Steps:** wire `me()` progress into `CachedProgress` on connect (so pills have data); build the shelves; verify build + native-UI review + live idb E2E (MUTED: Home shows Continue Listening with the in-progress book + a progress pill matching the server; Recently Added; Newest Authors) → terminate → commit `feat(app): personalized home shelves`.

---

### Task 8: Library browse — cover grid + sort/filter

**Files:** Create `App/Views/{LibraryGridView,FilterSheet}.swift`; modify `AppState` (sort/filter state feeding `refreshItems`/observation), `ABSClient.items` (already supports sort/desc/filter — thread params), `LibraryCacheStore` (observe filtered/sorted from cache where possible; server refresh for authoritative order).

**Interfaces / design:**
- `LibraryGridView`: `ScrollView { LazyVGrid(columns:.adaptive(min:150)) }` of `CoverCard` (M0 spike confirmed LazyVGrid handles ~10k on Mac — reuse, no NSCollectionView). Observes `LibraryCacheStore.observeItems` for instant paint; a toolbar sort control (`Menu`/`Picker`: Title, Author, Added, Published, Progress + asc/desc) drives a server `items?sort=&desc=` refresh into the cache.
- `FilterSheet`: presented from a toolbar filter button; built from `ABSClient.filterData` (genres/tags/authors/series/narrators/languages/publishedDecades). Selecting a value applies `filter=<group>.<base64url(value)>` to the items request. Native `Form`/`List` sheet with `.presentationDetents`.
- Glass: toolbar is system glass; `.scrollEdgeEffectStyle(.soft, for:.top)`.

- [ ] **Steps:** build; verify build + native-UI review + live E2E (sort flips order live; a genre/author filter narrows results — seed has one author "Sun Tzu" so at least the author filter is exercisable; note thin fixture) → terminate → commit `feat(app): library cover grid with sort and filter`.

---

### Task 9: Series & authors browse

**Files:** Create `App/Views/{SeriesListView,AuthorsListView}.swift` (+ author detail, series detail as pushes); modify `ABSClient` (series/authors already in Task 5), shell wiring.

**Interfaces / design:** `SeriesListView` (from `series(libraryID:limit:)` — limit REQUIRED) → tap a series → its books grid (`GET /api/series/:id` books). `AuthorsListView` (from `authors(libraryID:)`) → author avatar (`/api/authors/:id/image?width=` when `imagePath != nil`, placeholder otherwise) → author detail (`author(id:include:items)` → their books grid). Native `List`/grid, HIG-idiomatic, opaque content.

- [ ] **Steps:** build; verify build + native-UI review + live E2E (Authors shows "Sun Tzu" → tap → their 1 book; Series is empty in the fixture — assert the empty state renders natively, note a series fixture is needed for full coverage) → terminate → commit `feat(app): series and authors browse`.

---

### Task 10: Search — local FTS5 ⨯ server blend

**Files:** Create `App/Views/SearchView.swift`, `App/Search/SearchModel.swift`; tests in `ColophonTests` (the model is unit-testable).

**Interfaces / design (from the verified search stream):**
- `SearchModel` (`@Observable`): `.searchable` query → **instant local tier** (GRDB FTS5 `searchItems`, ~5ms, painted as a "Titles" section) + **debounced server tier** (~275ms, min 2 chars, in-flight cancellation via `.task(id: debouncedQuery)`/structured concurrency) calling `searchLibrary` per active library. Merge item rows by `libraryItem.id` (server row replaces the FTS placeholder in place — richer; keep FTS-only offline rows flagged). Entity buckets (Series/Authors/Narrators/Genres/Tags; podcasts: Episodes) are **server-only sections** that appear after the response. Section order: Titles → Series → Authors → Narrators → Genres → Tags. Never call the server with empty/<2-char query (server 400s).
- `SearchView`: `.searchable` + a `List` of grouped `Section`s; tapping a title → item detail/play; series/author → their browse view.
- Unit-testable core: given a fake `searchLibrary` + fake FTS store, assert (a) local results paint before server, (b) dedup by id replaces placeholder, (c) cancellation drops superseded results, (d) empty/1-char never hits the server.

- [ ] **Steps:** TDD the `SearchModel` merge/cancel/debounce logic (deterministic, fake clock/injected search fns) → build the view → verify build + native-UI review + live E2E ("art" → book instantly + server-enriched; "sun" → book locally (FTS indexes author) AND an Authors section from the server; "zzz" → empty state) → terminate → commit `feat(app): blended local + server search`.

---

### Task 11: M1c-a wrap-up

**Files:** `README.md`; refresh the shipped-reality contract block in this plan's directory (or the M1c overview) with the M1c-a surface (M1b-review rec); test-robustness carry-forwards (bounded liveness loops in ColophonTests; shared test fixtures; make `test-app` multi-destination if any Mac-only UI logic warrants it).

- [ ] README Status → M1c-a reality (native Liquid Glass shell, home shelves, browse with sort/filter, series/authors, blended search, v2 schema, epoch refactor). Full sweep: `make test && make test-app && make build-ios && make build-mac`; cold start + contract suites (incl. the new browse/search live checks) green from factory-fresh. Commit `docs: M1c-a status`. NO tag (controller tags after the final whole-branch review).

---

## Self-review notes (plan-writing time)

- **Coverage vs M1c-a overview bullets:** epoch refactor (T1), v2 schema (T2), 20-page cap + per-item patch (T3), cover dedup (T4), home shelves (T7), library browse sort/filter (T8), series/authors (T9), search blend (T10), per-platform Liquid Glass shell (T6), contract-block/test-robustness (T11). ABSKit endpoints (T5) underpin T7–T10.
- **Grounded, not guessed:** every data task cites the live-verified endpoint reference; the critical corrections from the research (cover is public → AsyncImage direct; progress NOT on shelf entities → join `me()`/CachedProgress; book search bucket excludes author matches; `tabViewBottomAccessory` not on native macOS → hand-built Mac transport) are baked into Global Constraints and the relevant tasks.
- **UI verification model:** SwiftUI-heavy tasks (6–10) are gated by build + an explicit native-UI/Liquid-Glass review criterion + a live idb E2E, rather than pixel-exact plan code — the right altitude for UI, with the design report's concrete API names and structure as the spec.
- **Known thin-fixture gaps (recorded for E2E honesty):** the seeded library has one book, one author, no series/genres/tags/narrators, no podcasts — so filter/series/author/podcast paths are partially exercised live and flagged; M1c-c seeds podcasts, and a richer book fixture (series+genres+narrator+multi-item) would strengthen T8/T9 coverage (optional seed enhancement, noted).
- **Deferred to M1c-b/M1c-c:** item detail view, full player (chapters/sleep/bookmarks/speed/queue), podcast episode UI + playback + the podcast dev fixture, per-book speed persistence.

---

## M1c-a shipped reality (Task 11 wrap-up, 2026-07-07)

All 10 build tasks landed, each individually reviewed and approved (`opus` reviewer on most; Task 9 self-verified by a second agent after the original implementer died mid-E2E — see `.superpowers/sdd/progress.md`). Full ledger: `.superpowers/sdd/progress.md` § "M1c-a execution ledger".

### Surfaces that shipped
- **Correctness (T1, T3, T4):** connection flows unified under one `connectionEpoch`; every connection-mutating flow guards its own post-await tail (closes the M1b-carried signOut/removeConnection stomp asymmetry and the connect-bump-before-URL-validation asymmetry). Library reconciliation is uncapped (pages to completion, 200-page/10k-item safety bound, degrade-not-wipe past it) with a per-item socket patch (`itemChanged` → one `/api/items/:id` fetch, not a full re-page). `CoverStore` dedupes concurrent in-flight fetches for the same key.
- **Data (T2, T5):** `v2` GRDB migration (ALTER-only on `cachedItem` + new `cachedItemDetail`/`cachedEpisode` tables; v1 stays byte-frozen; delete paths purge the new tables atomically). `ABSKit` gained `personalizedShelves`, `filterData`, `series`, `authors`/`author`, `searchLibrary`, `me`, and single-item `item(id:)`, all fixture-decode-tested plus live contract tests.
- **Native UI (T6–T10):** per-platform Liquid Glass shell (iPhone `TabView` + `tabViewBottomAccessory` mini-player with plain controls to avoid glass-on-glass; iPad/Mac `NavigationSplitView` + hand-built bottom-docked `TransportBar` + a `Playback` command menu on Mac); personalized home shelves with progress pills joined from `/api/me` (shelf entities themselves carry no progress — verified live); a library cover grid with native sort and a filterdata-driven filter sheet (filtered refresh upserts and preserves non-matching cached rows; unfiltered refresh still fully reconciles); series & authors browse (author images public, initials-avatar fallback); blended local-FTS5 instant + debounced server search with cancel-in-flight and dedup-by-id merge.
- **Wrap-up (T11):** README Status rewritten for M1c-a reality; a `scenePhase → .active` progress refresh closes the T7-flagged staleness gap (home pill could go stale across a background→foreground cycle); the dead `PlayerBarView.swift` (superseded by the shell's own `MiniPlayerBar`/`TransportBar` since T6) deleted.

### Follow-ups deferred (tracked, non-blocking)

**To M1c-b (full player):**
- Progress-pill fraction is recomputed from shelf-entity `media.duration`, which can be nil/0 (false-negative pill); T8's grid already reads `CachedItem.duration` instead — the player surfaces should do the same, and consider persisting a server-supplied progress fraction on `CachedProgress` if the socket `progressUpdated` payload carries one (T7 follow-up).
- Item detail view; full player (chapters/sleep timer/bookmarks/speed/queue); per-book speed persistence.
- Same-id re-activation during a signOut still runs `tokenStore.clear`/`needsSignIn.insert` against a now-live connection — the global epoch can't express per-connection intent (T1 follow-up).
- Bare-`Space` Playback-menu shortcut can hijack a focused text field once real content with text fields exists — needs a guard when Search/detail views grow them (T6 follow-up).
- Account menu is only reachable from the Home tab on iPhone (T6 follow-up: add to all tabs).

**To M1c-c (podcasts):**
- Search does not yet merge `results.podcast`/`results.episodes` — podcast-library search shows zero titles until M1c-c wires the podcast/episode buckets (T10, explicitly deferred).
- `EpisodeStubCard` on Home shelves and episode/`series.books` DTOs are source-verified only — no live podcast fixture existed this milestone; tighten against a real podcast library once M1c-c seeds one (T5, T7).
- `cachedEpisode` has no index on `publishedAt` (fine at feed scale today; revisit if a feed gets large) (T2 follow-up).

**To M2 (offline downloads):** out of scope this milestone; no surface built or stubbed beyond the Downloads tab placeholder.

**Source-only / graceful-degrade claims (no fixture to prove, but designed to fail soft):**
- `authorImageURL`'s "public, no auth" claim is source-verified only (no author-image fixture); the initials-avatar fallback renders correctly if the claim is ever wrong (T9).
- Mac `SplitShell` sidebar + bottom transport visual is code-verified but was never screenshotted (TCC blocked automated `screencapture` in the sandboxed E2E environment); a human interactive Mac launch is the recommended follow-up before the whole-branch review signs off on Mac visuals (T6).

**Minor/cosmetic (no action expected):**
- `ForEach id: \.offset` (positional identity) in a couple of shelf/list views; `observeProgress` re-indexes all rows unscoped rather than per-item (T7).
- Serialized-suite fixtures in Settings tests duplicate `AppStateTests` fixtures (drift risk, carried from M1b).
- The one known, accepted build warning across the whole tree is the pre-existing `PerfSpikeView.swift:44` DEBUG-only main-actor warning (documented in M1c-a Task 6/7 verification notes; untouched by any M1c-a task).

No tag applied — the controller tags after the whole-branch review.
