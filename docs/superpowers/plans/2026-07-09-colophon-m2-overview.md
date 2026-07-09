# Colophon Milestone 2 — Overview & Decomposition

Milestone 2 ("Offline + companions", spec §9) is decomposed into three sequential
sub-plans, mirroring M1's a/b/c rhythm. Each produces working, testable software on
its own and gets its own detailed plan when its turn comes, so later plans absorb what
earlier execution teaches.

**Inputs:** spec (docs/superpowers/specs/2026-07-06-audiobookshelf-apple-client-design.md
§3 offline/downloads/session, §7 companions, §9 milestones), M1 shipped reality
(.superpowers/sdd/progress.md — M1a/b/c merged; the cache/player/session spine offline
builds on).

**Decisions (user, 2026-07-09):** full M2 decomposition, offline core first. **CarPlay:
entitlement still SUBMITTED/pending (docs/superpowers/carplay-entitlement.md) → CarPlay UI
is CONDITIONAL/DEFERRED in M2c; it slots in when the grant email arrives and does not
block anything else.**

## M2a — Offline downloads + offline playback + sync-back (plan next)

The load-bearing core. Everything in M2b/M2c surfaces or depends on offline state, so it
goes first (same rationale M1a had). Deliverable: a book/episode can be downloaded via a
background URLSession, played with no network from local files, and its offline progress
reconciles cleanly with the server on reconnect.

- **DownloadManager package** (new, 4th local package): background `URLSession`
  (`background(withIdentifier:)`, app-relaunch completion-handler handling), per-file
  downloads (`GET /api/items/:id/file/:ino/download?token=` — NEVER the zip endpoint),
  range/resume, progress, cancel/delete, storage accounting.
- **LibraryCache v4 (additive):** download records (item/episode → state
  queued/downloading/downloaded/failed, received/total bytes, local file URLs, the
  audioTrack→file mapping), and pinned item-detail snapshots so downloaded items are fully
  browsable offline. `DatabasePool` WAL already supports concurrent reads during
  background-download writes.
- **Offline playback:** `PlayerEngine.load(trackURLs:)` already accepts arbitrary URLs —
  feed `file://` URLs for downloaded items (`playMethod: local`, no HLS session for the
  stream). Chapters/timeline from the cached detail.
- **Local-session sync-back:** local `PlaybackSession` rows (client UUID,
  `playMethod: local`); `POST /api/session/local` per tick while online; on reconnect pull
  `GET /api/me`, reconcile by `lastUpdate` (newer server wins locally), `POST
  /api/session/local-all {sessions, deviceInfo}`, prune synced. Extends the existing
  `/api/session/local` plumbing (M1a) + `SessionSyncController`.
- **Offline awareness:** an `NWPathMonitor`-backed reachability signal; browse falls back
  to cache/downloads when offline; a Downloads tab (iPhone/iPad) + Mac equivalent; download
  state badges on covers/detail; download/delete affordances on item + episode detail;
  podcast episode download + auto-delete-after-finish option (v1 downloads existing
  episodes only — server-side episode fetch is admin-only, out of scope).

## M2b — Companion surfaces (planned after M2a ships)

Widgets (continue-listening), Live Activity (now-playing), Control Center `ControlWidget`
(play/pause via `AudioPlaybackIntent`), App Intents ("Resume my audiobook", open/search) +
Siri + Spotlight `IndexedEntity` for library items. Shared infrastructure: an app group
(share the cache/now-playing snapshot with extensions), extension targets in project.yml,
and a small "now-playing snapshot" surface the widgets/Live Activity read. Much of this is
device-only to verify (checklist carried to the milestone's human-verification doc).

## M2c — Tip jar + CarPlay (planned after M2b ships)

- **Tip jar:** StoreKit 2 consumable IAP (free app, spec §business model), a Settings
  "leave a tip" surface, transaction handling. Independent of everything else.
- **CarPlay (CONDITIONAL on the entitlement grant):** `CPTabBarTemplate` (read
  `maximumTabCount` at runtime) — Continue / Library / Downloads + `CPNowPlayingTemplate.shared`;
  works with the phone locked. Add `com.apple.developer.carplay-audio` to
  `Colophon.entitlements` ONLY when this work starts; test via Simulator → I/O → External
  Displays → CarPlay. **If still ungranted when M2c arrives, ship the tip jar and defer
  CarPlay to a follow-on** — nothing else depends on it.

## Sequencing rationale

Offline first because the companions (M2b) show download/now-playing state and the tip
jar/CarPlay (M2c) are independent or blocked on an external grant — building the offline
core first means the surfaces have real state to display and we never block on Apple.
Within M2a: the DownloadManager + cache schema before playback before sync-back before UI,
so each layer is unit-testable (FakeURLSession / in-memory store) before the UI piles on.

## Spikes / risks

- **Background URLSession relaunch** (app killed mid-download → relaunched to finish):
  wire the `handleEventsForBackgroundURLSession` app-delegate hook + completion handler
  early; verify on device (simulator background-download behavior is unreliable).
- **Offline↔online transitions** are the highest-risk correctness surface (last-write-wins
  reconcile, no double-count of `timeListened`); adversarial concurrency tests, like M1c-b's
  queue race.
- **Storage/eviction** honesty: never silently drop a download; surface storage use.
- **Device-only verification:** background downloads, offline playback continuity across
  app-relaunch, and Live Activity/Widgets (M2b) need a real device — carried to each
  milestone's human-verification checklist.
