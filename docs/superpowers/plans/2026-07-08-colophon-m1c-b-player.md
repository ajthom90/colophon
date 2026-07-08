# Colophon M1c-b — Item Detail & Full Audiobook Player

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn M1c-a's browse surfaces into a real listening experience — a native item-detail view and a full-screen Liquid Glass audiobook player with chapters, configurable transport, sleep timer, bookmarks, per-book speed persistence, and an up-next queue — built on the existing PlayerEngine and proven on the audiobook content type before podcasts (M1c-c) extend it.

**Architecture:** The `PlayerEngine` package (PlaybackController, BookTimeline, AVQueuePlayerBackend, SessionSyncController, NowPlayingUpdater) already drives global-time↔track playback and session sync. M1c-b adds (1) an item-detail view feeding the player, (2) a `PlayerModel`/full-player UI layer bound to `AppState.playback`, (3) four feature modules (sleep timer, bookmarks, per-book speed, queue) that extend the controller and a small persistence surface, and (4) per-platform presentation (iPhone fullScreenCover, iPad sheet/inspector, Mac dedicated Window + menu commands). Glass stays on the transport/control chrome only.

**Tech Stack:** Swift 6.2, SwiftUI OS 26 Liquid Glass (backgroundExtensionEffect behind cover art, GlassEffectContainer transport cluster, glassEffectID morph mini→full, .buttonStyle(.glass/.glassProminent), presentationDetents), AVFoundation (AVQueuePlayer HLS), GRDB (v3 migration for per-book prefs), existing ABSKit/PlayerEngine/LibraryCache.

## Global Constraints

- All M0/M1a/M1b/M1c-a constraints bind: Swift 6.2 strict concurrency (complete), default-MainActor; targets iOS/macOS 26.0; Xcode 26.6; bundle `com.andrewthom.colophon` (team `LL334G7KP2`); server ≥ 2.26.0; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **UI MANDATE (non-negotiable, a review criterion):** native-first, **Liquid Glass**, HIG-idiomatic **per platform**. Glass ONLY on the floating transport/control chrome, never on artwork/metadata/chapter rows/text; never glass-on-glass; at most one tinted `.glassProminent` primary (play/pause) per surface; cluster transport + the sleep/bookmark/speed/queue controls in a `GlassEffectContainer`. The full player is **presented natively per platform** — iPhone `.fullScreenCover`, iPad `.sheet(.large)`/inspector, **Mac a dedicated `Window` (or a large sheet on the detail column), NOT an iOS-style full-window takeover**. Time/countdown labels use `.monospacedDigit()`. Serif titles via the root fontDesign toggle; SF for transport/time via a scoped `.fontDesign(.default)`.
- **AUDIO SAFETY (mandatory for every E2E):** `COLOPHON_AUTO_MUTE=1` on every headless/idb run, and ALWAYS terminate the app afterward — audio routes to the Mac speakers otherwise. Cap idb screenshots at ≤3 per E2E; stop after 2 idb failures (document, fall back to code review — do not loop).
- Schema: v1+v2 FROZEN. Per-book prefs land in a new `registerMigration("v3")` (additive). Keep the `#if DEBUG eraseDatabaseOnSchemaChange` flag.
- The full player must reuse the existing `PlaybackController` public surface (isPlaying, globalTime, totalDuration, togglePlayPause(), skip(_:), setRate/rate, seek(to:)) — do NOT fork playback logic. Extend the controller where a feature needs engine cooperation (sleep-timer pause, queue advance), with tests.

## Verified endpoint reference (live ABS 2.35.1, this milestone)

```
POST /api/items/:id/play  {deviceInfo:{clientName,deviceId},forceDirectPlay,forceTranscode}
   -> { id(SESSION id), audioTracks[{index,startOffset,duration,contentUrl,mimeType}], chapters[{id,start,end,title}],
        currentTime, startTime, duration, playMethod, serverVersion, libraryItem, ... }
   playMethod 2 (HLS): audioTracks[0].contentUrl = "/hls/{SESSION-id}/output.m3u8"  (SESSION id, NOT item id),
        mimeType "application/vnd.apple.mpegurl" — AVPlayer plays natively.
   playMethod 0 (forceDirectPlay): per-file contentUrl "/api/items/:id/file/:ino" (multi-track sequencing).
GET  /api/items/:id?expanded=1&include=progress -> media.metadata (full), media.chapters[{id,start,end,title}] GLOBAL secs,
        media.tracks[...], userMediaProgress{currentTime,progress,duration,isFinished}
POST /api/session/:id/sync  {currentTime,timeListened,duration}   (existing SessionSyncController path)
POST /api/session/:id/close                                        (existing retire path)
Bookmarks (VERIFIED live this milestone; shape {libraryItemId,time,title,createdAt}):
   POST   /api/me/item/:id/bookmark        {time,title}          -> the created bookmark
   PATCH  /api/me/item/:id/bookmark        {time,title}          -> updated bookmark (keyed by time)
   DELETE /api/me/item/:id/bookmark/:time                        -> 200
   GET    /api/me  -> bookmarks[]  (and mediaProgress[])
Chapters are GLOBAL book seconds; BookTimeline already maps global-time↔track. Cover: public /api/items/:id/cover?width=.
```

## File Structure (M1c-b new/changed)

```
App/Views/ItemDetailView.swift                 NEW  metadata/description/series/chapters/actions
App/Player/PlayerModel.swift                   NEW  @Observable full-player VM over AppState.playback
App/Player/FullPlayerView.swift                NEW  ZStack cover+backgroundExtensionEffect, scrubber, transport
App/Player/ChapterListView.swift               NEW  chapter sheet (media.chapters), tap-to-seek
App/Player/PlayerPresentation.swift            NEW  per-platform presentation (fullScreenCover/sheet/Window)
App/Player/SleepTimerView.swift + SleepTimer.swift   NEW  presets + end-of-chapter + fade
App/Player/BookmarksView.swift                 NEW  list/create/rename/delete, seek-to
App/Player/SpeedControl.swift                  NEW  rate menu + per-book persistence binding
App/Player/QueueView.swift + PlaybackQueue.swift     NEW  up-next queue model + UI
Packages/PlayerEngine/Sources/PlayerEngine/PlaybackController.swift   MOD  sleep-timer hook, queue advance, setRate persistence hook
Packages/ABSKit/Sources/ABSKit/ABSClient.swift + Models.swift        MOD  bookmark create/update/delete, item detail (reuse item(id:))
Packages/LibraryCache/Sources/LibraryCache/{Schema,Records,LibraryCacheStore}.swift  MOD  v3 per-book prefs (speed) + bookmarks cache
App/Shell/{PhoneShell,SplitShell,MiniPlayerBar}.swift   MOD  tap mini-bar → present full player (morph); Mac window command
App/ColophonApp.swift                          MOD  player Window scene (Mac); account-menu-on-all-tabs (M1c-a carry)
```

---

### Task 1: M1c-a carry-forwards (account menu on all tabs) + ABSKit bookmark endpoints

**Files:** `App/Shell/PhoneShell.swift`; `Packages/ABSKit/Sources/ABSKit/ABSClient.swift`, `Models.swift`; fixtures + `Tests/ABSKitTests`.

**Interfaces / requirements:**
- **Carry-forward (M1c-a final review):** the iPhone account/settings menu currently hangs only off the Home tab. Attach `.accountMenu()` (or the toolbar item) to Library/Search/Downloads tabs too, so Connections/Settings are reachable from every tab. Verify it doesn't double-present.
- **Bookmark endpoints** (grounded in the verified reference): `ABSClient.createBookmark(itemID:time:title:) async throws -> Bookmark`; `updateBookmark(itemID:time:title:) async throws -> Bookmark`; `deleteBookmark(itemID:time:) async throws`. `Bookmark` DTO `{libraryItemId, time, title, createdAt}` (tolerant decode). Doc-comment DELETE takes the integer `time` in the path.

- [ ] Captured-fixture decode test for the bookmark create/list shape (grab a real POST response from the live server); RED → implement → GREEN. `cd Packages/ABSKit && swift test`. Then `make build-ios && make build-mac && make test-app`. Commit `feat(ABSKit): bookmark create/update/delete + account menu on all tabs`.

---

### Task 2: Item detail view

**Files:** Create `App/Views/ItemDetailView.swift`; wire tap-through from CoverCard/shelves/grid/author-detail/search (replace the current tap→startPlayback with tap→ItemDetailView, keeping a prominent Play action IN the detail). `ABSClient.item(id:)` (exists) → expanded detail incl. chapters.

**Interfaces / design:** native detail — cover (opaque, `backgroundExtensionEffect` optional hero), serif title/subtitle/author/narrator, series, a `Play`/`Resume` primary (`.buttonStyle(.glassProminent)` — the one prominent), progress indicator, description (native `Text`, expandable), a chapters preview (count → opens ChapterListView), and metadata rows (genres, published, publisher, duration). Loading/error native. Reads `userMediaProgress` for Resume position. Tap Play → starts playback (existing `AppState.startPlayback`) AND presents the full player (Task 4 presentation). Cache the detail via `upsertItemDetail` (v2 table) for offline re-open.

- [ ] Build; `make build-ios && make build-mac && make test-app`; native-UI review criterion; CAPPED live E2E (open a book → detail renders metadata + chapters count + Resume at the real progress; screenshot). Commit `feat(app): item detail view`.

---

### Task 3: Full player scaffold + chapter-aware scrubber + chapter list

**Files:** Create `App/Player/{PlayerModel,FullPlayerView,ChapterListView}.swift`. Bind to `AppState.playback` (PlaybackController) + the item's `media.chapters`.

**Interfaces / design:**
- `PlayerModel` (@Observable @MainActor): derives from PlaybackController — `currentTime`, `duration`, `isPlaying`, `currentChapter` (from chapters + globalTime), `chapterProgress`, elapsed/remaining strings (`.monospacedDigit()`). Exposes `seek(to globalTime:)`, `seekToChapter(_:)`, `togglePlayPause()`, `skip(±interval)`.
- `FullPlayerView`: `ZStack` — (a) cover `Image` with `.backgroundExtensionEffect()` filling the top/safe area as an immersive mirror-blur backdrop; (b) large artwork; (c) serif title/author; (d) a **chapter-aware `Slider`** bound to `PlayerModel.currentTime` over `0...duration`, with chapter tick marks and current-chapter label; elapsed / -remaining labels; (e) transport row (skip-back / play / skip-forward) in ONE `GlassEffectContainer` — play/pause `.glassProminent`, skips `.glass`.
- `ChapterListView`: `List` of `media.chapters` (title, start `.monospacedDigit()`), current chapter highlighted; tap → `seekToChapter`. Presented via `.sheet([.medium,.large])`.
- The scrubber maps chapter `start`/`end` (global seconds) via the existing `BookTimeline`; dragging seeks global time.

- [ ] Build; native-UI review; CAPPED MUTED E2E (play a book → full player shows artwork + chapter-aware scrubber tracking the current chapter; open chapter list → tap chapter 3 → seeks; screenshot). Terminate. Commit `feat(app): full player scaffold with chapter-aware scrubber`.

---

### Task 4: Per-platform presentation + configurable skip + Mac window/commands

**Files:** Create `App/Player/PlayerPresentation.swift`; modify `App/Shell/{PhoneShell,SplitShell,MiniPlayerBar}.swift`, `App/ColophonApp.swift`, `Packages/PlayerEngine` skip interval.

**Interfaces / design:**
- Presentation seam: iPhone `.fullScreenCover`; iPad `.sheet(.large)` (or the inspector column); **Mac a dedicated `Window`** (WindowGroup id "player") or a large sheet on the detail column — NOT a full-window takeover. Tapping the mini-bar/transport presents it; the mini→full transition uses `glassEffectID(_:in:)` + `@Namespace` morph where the platform supports it (compile-confirm; fall back to a standard present if the modifier doesn't resolve).
- **Configurable skip interval**: a user setting (default 30s back / 30s fwd, options 10/15/30/45/60) persisted via `@AppStorage` and applied to `PlaybackController.skipInterval`. Transport buttons show the chosen interval (e.g. `gobackward.30`).
- Mac: `CommandMenu("Playback")` (from M1c-a) gains the full set — play/pause (menu action, NO bare Space — the M1c-a fix stands), skip ±, next/prev chapter, speed — with non-Space `.keyboardShortcut`s (e.g. `⌘→`/`⌘←` skip, `⇧⌘.`/`⇧⌘,` speed), guarded on an active session.

- [ ] Build both platforms; native-UI review (per-platform presentation correct; Mac NOT a takeover; morph or graceful fallback); CAPPED MUTED E2E (iPhone fullScreenCover presents/dismisses; skip interval setting changes the button + jump). Terminate. Commit `feat(app): per-platform player presentation and configurable skip`.

---

### Task 5: Sleep timer

**Files:** Create `App/Player/{SleepTimer,SleepTimerView}.swift`; modify `PlaybackController` (a pause-at hook + fade).

**Interfaces / design:** `SleepTimer` (@Observable): presets (5/10/15/30/45/60 min), **end-of-chapter**, and Off; a live countdown (`.monospacedDigit()`); on fire → fade volume over ~5s then pause (via a controller hook `fadeOutAndPause()`); "shake/tap to extend" optional. `SleepTimerView`: a glass control (`.buttonStyle(.glass)`) in the player's secondary cluster + a Menu of presets; shows remaining time when armed. End-of-chapter uses the chapters + globalTime to compute the fire time and re-arms per chapter if chosen. Controller gets a small, TESTED addition: an injected timer/clock so the fire logic is unit-testable (no real sleeps) — `sleepTimerFiresAtDeadlineAndPauses`, `endOfChapterComputesNextBoundary`.

- [ ] TDD the timer/fire logic (injected clock) in PlayerEngine tests; build the UI; native-UI review; CAPPED MUTED E2E (arm a 5-min timer → countdown shows; set end-of-chapter → computes to the chapter end). Terminate. Commit `feat(app): sleep timer with end-of-chapter and fade`.

---

### Task 6: Bookmarks

**Files:** Create `App/Player/BookmarksView.swift`; modify `LibraryCacheStore` (bookmarks cache — reuse a small table or cache on the item), AppState (bookmark actions calling ABSClient from Task 1), reconcile from `/api/me`.

**Interfaces / design:** `BookmarksView`: a `List` of the current book's bookmarks (title + time `.monospacedDigit()`), tap → `seek(to: time)`; create-at-current-time (`+` in the player, prompts title, default "Bookmark at MM:SS"); swipe/context to rename (PATCH) and delete (DELETE). Optimistic local update + server call (Task 1 endpoints); reconcile from `me()` on connect (M1c-a already joins mediaProgress; extend to bookmarks). A glass bookmark button in the player cluster. Bookmarks cached (v2/v3 or a `cachedBookmark` table) for offline view.

- [ ] Store/actions tested (create/rename/delete round-trip + reconcile); build; native-UI review; CAPPED MUTED E2E against the live server (create a bookmark at the current time → appears in /api/me; rename; delete → gone; seek from a bookmark). Terminate. Commit `feat(app): bookmarks (create/rename/delete, seek-to)`.

---

### Task 7: Per-book speed persistence (v3 migration)

**Files:** `Packages/LibraryCache` Schema (`registerMigration("v3")`), Records, Store; `App/Player/SpeedControl.swift`; modify `PlaybackController` rate application.

**Interfaces / design:** v3 adds a `cachedItemPref` table (PK connectionID,itemID; `playbackRate DOUBLE`, room for future per-book prefs) — additive, v1/v2 frozen, migration test that a v2 DB upgrades preserving rows. `SpeedControl`: a Menu (0.5×–3.0× in 0.1 steps + common presets) in the player cluster; selecting sets `PlaybackController.rate` AND persists per (connectionID,itemID); on starting playback of a book, the controller reads the stored rate (default 1.0×). A global default speed setting (@AppStorage) applies when a book has no stored rate. (Per the spec, per-book speed is device-local for now; iCloud-sync of prefs is post-v1.)

- [ ] TDD store (v3 migration + rate round-trip) + the read-on-play wiring; build; native-UI review; CAPPED MUTED E2E (set a book to 1.5× → persists; leave + reopen → resumes at 1.5×; a different book stays 1.0×). Terminate. Commit `feat(app): per-book speed persistence (v3)`.

---

### Task 8: Up-next queue

**Files:** Create `App/Player/{PlaybackQueue,QueueView}.swift`; modify `PlaybackController`/backend for queue advance (AVQueuePlayer already sequences tracks WITHIN a book — this is a BOOK-level queue).

**Interfaces / design:** `PlaybackQueue` (@Observable): an ordered list of items queued after the current book; "Play Next"/"Add to Queue" actions from item detail / shelves / grid context menus; on a book finishing (or user Next), the controller retires the current session and starts the next queued item (new /play session). `QueueView`: a reorderable `List` (`.onMove`), remove, "Playing next" header; presented from the player. The controller gets a tested `advanceToNext()` that closes the current session and hands the next item back to `AppState.startPlayback`. Queue is in-memory for v1 (note: persistence/Continuity is post-v1) unless cheap to persist.

- [ ] TDD `advanceToNext` (mock backend: finishing → next session opened, previous closed); build; native-UI review; CAPPED MUTED E2E (queue a 2nd item → Next → 2nd starts, mini-bar updates; reorder). Terminate. Commit `feat(app): up-next queue`.

---

### Task 9: Mac polish + human-verification pass

**Files:** `App/ColophonApp.swift` (player Window scene), `App/Shell/SplitShell.swift`, NowPlaying/lock-screen wiring check.

**Interfaces / design:** Finalize the Mac player Window + all Playback commands/shortcuts; confirm `NowPlayingUpdater` (M1a) reflects the current book/chapter/artwork on the lock screen + Control Center + media keys (iOS) and the Now Playing menu (Mac). This task's deliverable includes a **documented human-verification checklist** (the spec's M1c-b human pass): on a REAL library — audio actually plays and is audible when NOT muted; chapters seek correctly; sleep timer fires and fades; lock-screen controls + media keys work; Mac window + menu commands + keyboard shortcuts; per-book speed resumes. (Automated E2E stays muted; this checklist is for the user/human to run on-device.)

- [ ] Build both; native-UI review; CAPPED MUTED automated E2E for what's scriptable; WRITE the human-verification checklist to `docs/superpowers/m1c-b-human-verification.md` (the items the sandbox/mute can't cover). Commit `feat(app): Mac player window, commands, and now-playing polish`.

---

### Task 10: M1c-b wrap-up

**Files:** `README.md`; ledger/contract-block refresh.

- [ ] README Status → M1c-b reality (item detail + full player with chapters, sleep timer, bookmarks, per-book speed, queue; per-platform presentation; Mac window + commands). Full cold-start sweep: `make test && make test-app && make build-ios && make build-mac` green, zero warnings. Append the M1c-b shipped-reality + deferred (podcasts → M1c-c; offline → M2; queue persistence/Continuity, iCloud prefs → post-v1). Commit `docs: M1c-b status`. NO tag (controller tags after the whole-branch review).

---

## Self-review notes (plan-writing time)

- **Coverage vs M1c overview §M1c-b:** item detail (T2); full-screen player with backgroundExtensionEffect + chapter list + chapter-aware scrubber (T3); transport + configurable skip (T4); sleep timer presets + end-of-chapter + fade (T5); bookmarks create/list/delete (T6); per-book speed persistence (T7); up-next queue (T8); per-platform surfaces + Mac menu Commands/keyboard shortcuts (T4, T9); human-verification pass on a real library (T9). Plus the M1c-a carry-forward (account menu on all tabs) folded into T1.
- **Grounded:** /play session-id HLS URL, chapters {id,start,end,title} global seconds, and bookmark POST/PATCH/DELETE are ALL live-verified (this session) and cited in the endpoint reference — not guessed. Reuses the existing PlayerEngine rather than forking playback.
- **UI mandate:** every player surface is gated by build + a native-UI/Liquid-Glass review criterion + a CAPPED muted E2E; glass confined to the transport/control cluster; per-platform presentation explicit (Mac Window, not takeover); the M1c-a bare-Space fix is preserved (T4 uses non-Space shortcuts).
- **Schema discipline:** v1/v2 frozen; per-book prefs in an additive v3 with a preserve-existing-rows migration test (same rigor as the v2 test the M1c-a reviewer sabotage-proved).
- **Audio safety baked in:** every E2E task states COLOPHON_AUTO_MUTE=1 + always-terminate + the ≤3-screenshot cap (the M1c-a Task 9 lesson).
- **Deferred to M1c-c / post-v1:** podcast episode playback + episode UI (M1c-c reuses this player); offline downloads (M2); queue persistence + Handoff/Continuity + iCloud-synced prefs (post-v1); the M1c-a source-only claims (episode DTOs, authorImageURL) get their live fixture in M1c-c.

---

## M1c-b shipped reality (Task 10 wrap-up)

All 10 tasks complete (commits 0386aad..e6015b0, base = main post-M1c-a merge 970146e). Full cold-start sweep GREEN: `make test` 164 (ABSKit 101, PlayerEngine 30, LibraryCache 33), `make test-app` 99, `make gen`, `make build-ios`, `make build-mac` — zero real compiler warnings (only the benign, non-Colophon "AppIntents.framework metadata extraction skipped" build-system notice on both platforms; the M1c-a-era PerfSpikeView warning did not recur this run).

**Shipped player surfaces:**
- Item detail view (universal tap-through from every browse surface) with cache-then-refresh, Resume-from-progress, one `.glassProminent` primary, opaque metadata/description/chapters-count row.
- Full-screen player (`FullPlayerView`/`PlayerModel`): `backgroundExtensionEffect` immersive backdrop, chapter-aware `Slider` (drag-detach, seek-on-release, global book-seconds via `BookTimeline`), `ChapterListView` (tap-to-seek, current highlighted).
- Per-platform presentation (`PlayerPresentation.swift`): iPhone `.fullScreenCover`, iPad `.sheet(.large)`, Mac dedicated `Window("Now Playing", id: "player")` via `openWindow` — never a takeover. Configurable skip interval (10/15/30/45/60s, `AppState.defaultSkipInterval`) live-applies to the transport glyph and `PlaybackController.skipInterval`, including on the lock screen/Control Center without reopening the book.
- Mac `Playback` command menu: prev/next chapter (⌥⌘←/→), speed (⇧⌘,/.), skip (⌘←/→), Show Player (⌘0) — all non-Space, session-guarded, preserving the M1c-a bare-Space fix (play/pause stays menu-click-only).
- Sleep timer: Off/5/10/15/30/45/60-min presets + End-of-Chapter, live countdown, `fadeOutAndPause(over:steps:)` (volume ramp → pause, mute-aware, cancel-safe on session retire).
- Bookmarks: create-at-current-time/rename/delete/seek-to, optimistic + generation-guarded reconcile from `/api/me`, fractional-time round-trip.
- Per-book speed: `v3` GRDB migration (`cachedItemPref`, PK connectionID+itemID, additive, `v1`/`v2` byte-frozen and preserved), read-on-play, persists across relaunch.
- Up-next queue: play-next/add-to-queue/reorder/remove, book-finished auto-advance (peek-then-commit, race-safe), dropped entries on connection removal.
- Now Playing/lock-screen/Control Center: artwork (off-main-safe), chapter title that updates live on boundary crossing (not just at open), remote command mapping, clears on retire — no zombie card.
- Human-verification checklist: `docs/superpowers/m1c-b-human-verification.md` (a–h: audible playback, chapter seek by ear, sleep-timer fade, lock-screen/media-keys/Now-Playing-menu, Mac window+commands, per-book speed resume, bookmarks, queue advance), referenced from the README.

**Deferred / follow-up, grouped:**

*M1c-c (podcasts):*
- Episode playback + episode browse UI (this player is reused as-is).
- Episode/podcast DTO + `series.books` + `authorImageURL` need live fixtures (carried from the M1c-a review; still source-only claims).
- Podcast search buckets in the blended local-FTS5 + server search.

*Post-v1:*
- Up-next queue is in-memory only — no persistence, no Handoff/Continuity resume.
- Per-book playback speed and other prefs are device-local — no iCloud sync.
- Offline bookmark cache (bookmarks currently reconcile live from `/api/me`, no local cache table for offline viewing).

*PENDING HUMAN verification (checklist a–h at `docs/superpowers/m1c-b-human-verification.md`):* Mac lock-screen/Now-Playing-menu visual + audible playback + media keys are TCC/device-only and cannot be automated in the sandboxed/muted E2E harness — a human must run the full checklist on a real device/Mac against a real library, unmuted, before this ships to users.

**Small deferred code minors (carried forward, none blocking):**
- `LibraryCacheStore.setPlaybackRate` does a full-row upsert; its comment already flags that this would silently reset a future sibling per-book pref — switch to read-modify-write when one lands (no sibling pref exists yet in M1c-b, so left as-is).
- No UI to clear a book's stored rate back to "unset" (falls back to the global default) — by design for v1.
- Item detail: no truncation detection for the description's More/Show Less control (always shown); `%`/Resume labels not yet `.monospacedDigit()` (cosmetic).
- Full player: double-sort of chapters (defensive, negligible cost); `@Observable` `PlayerModel` re-created inertly per body; stacked aspectRatio/scrim slightly heavier than needed; elapsed can render `-0:00` at the very end of a book (cosmetic).
- Mac: the player Window's dismiss chevron is redundant with the native traffic-light close (harmless, flagged for a future pass); Mac `Playback` menu's bare `⌘←/→` skip shortcuts can be captured while the sidebar Search field has focus (pre-existing, much narrower than the bare-Space issue M1c-a fixed).
- Bookmarks rename is not idb-drivable (SwiftUI `TextField` limitation) — covered by unit + contract tests instead of E2E.

M1c-b: all 10 tasks complete. Ready for whole-branch review (no tag yet — controller tags after).
