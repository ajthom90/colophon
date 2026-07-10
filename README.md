# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M2c tip jar — a "Support the app" section at the bottom of
Settings (below every real preference, since it unlocks nothing) opens a
native tip jar: three StoreKit 2 **consumable** in-app purchases ("Leave a
Tip" $1.99, "Generous Tip" $4.99, "Amazing Tip" $9.99), each showing a
store-localized price (`Product.displayPrice`, never a hardcoded string)
and, on purchase, a warm thank-you state. Tips can repeat freely — there is
deliberately no lock-out and no "Restore Purchases" button, since
consumables carry no entitlement to restore. Colophon remains a **free app
with every feature included**: a `TipStore` state machine (`@Observable`,
driven through a StoreKit-free `TipProviding` seam and unit-tested end to
end against a `FakeTipProvider` — load success/failure, purchase success/
cancel/pending/failure, a repeat-tip case — with no StoreKit host needed)
only ever transitions its own transient state; it writes no `@AppStorage`/
`UserDefaults` key and gates nothing, confirmed both by test and by grep.
The real path is `StoreKitTipProvider` (`Product`/`Transaction`/
`VerificationResult`, verifying and `finish()`ing every transaction —
including ones arriving via `Transaction.updates` for Ask-to-Buy), backed
by a committed `Products.storekit` StoreKit-Testing config wired into the
scheme's Run action, so the full render-tiers → purchase → thank-you flow
is testable with no App Store Connect round-trip — but only when **Xcode
itself** launches the app (a bare simulator install bypasses StoreKit
Testing entirely). A real sandbox purchase additionally needs the 3
consumable products created in App Store Connect
(`com.andrewthom.colophon.tip.{small,medium,large}`) at submission time,
which has **not** happened yet — this milestone ships the code and the
local `.storekit` config, not live App Store products. **CarPlay remains
DEFERRED** — the `com.apple.developer.carplay-audio` entitlement is still
pending (docs/superpowers/carplay-entitlement.md). See
docs/superpowers/m2c-human-verification.md for the Xcode/device-only
checklist (the local StoreKit Testing flow now, a real sandbox purchase
once App Store Connect products exist, and confirming no feature is ever
gated behind a tip) the automated, always-muted E2E can't cover.

Built on M2b's companion surfaces — Colophon's now-playing and
continue-listening state now surfaces outside the app itself, all reading
a small Codable snapshot (titles, ids, progress, artwork thumbnail paths —
never tokens or
credentials, which stay device-local in the Keychain) that the app
publishes into a new App Group (`group.com.andrewthom.colophon`) via
`ColophonShared` (the 5th local SwiftPM package), shared with a new
`ColophonWidgets` extension target. No new GRDB migration — LibraryCache
stays frozen at v5; the snapshot is a separate App-Group surface, not the
local cache. A continue-listening home-screen **Widget** (small shows the
single most-recent book with a cover, progress ring, title, author; medium
shows up to three, each its own tap target) deep-links straight to that
item through the app's existing `colophon://` routing. A now-playing
**Live Activity** appears on the Lock Screen and in the Dynamic Island
(compact and expanded) with cover, title/chapter, a progress bar, and
play/pause/skip buttons; its start/update/end lifecycle is unit-tested
against a fake ActivityKit seam to guarantee exactly one live Activity
across a book switch or connection change — never leaked or duplicated. A
**Control Center / Lock Screen** play-pause control (the Controls
gallery, iOS 18+) toggles playback through a new `AudioPlaybackIntent`
family; review caught that without the intents also conforming to the
`AudioPlaybackIntent` marker protocol, the toggle would silently resolve
against the widget extension's inert fallback instead of the running app
once it suspended (a paused audio app does within ~30s) — fixed, and
locked in by a compile-time conformance test, so resuming playback from a
suspended app actually works. **Siri/Shortcuts** gained three phrases via
an `AppShortcutsProvider` — "Resume my audiobook in Colophon," "Open
Colophon," "Search Colophon" — and library items are indexed into system
**Spotlight** (Core Spotlight, per-connection, de-indexed on sign-out so
one server's books never surface under another's search); both route back
into the app through the same deep-link handling. The existing
`MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` Now Playing/Control
Center integration (M1c-b) is untouched — every companion surface here is
additive to it, reusing the existing `AppState`/`PlayerEngine` rather than
a parallel player. **Platform scope:** the `ColophonWidgets` extension
(the Home Screen widget, the Live Activity, and the Control Center
control) is iOS/iPadOS-only this milestone — no Mac widget shipped; the
App Intents (Siri/Shortcuts) and Spotlight indexing build and function on
macOS too. See `docs/superpowers/m2b-human-verification.md` for the
device-only checklist (adding the widget, the Dynamic Island/Lock Screen
Live Activity, the Control Center toggle after the app has been
suspended, Siri phrases, Spotlight search) the automated, always-muted
E2E/sim can't cover — the Dynamic Island in particular needs a real,
supported iPhone.

Built on M2a's offline downloads — a book or podcast episode can be downloaded via a
background `URLSession` (a new `DownloadManager` package — the 4th local
SwiftPM package — behind a testable `DownloadSession` seam, so transfers are
unit-tested with a `FakeDownloadSession` and never touch the network in CI),
played with **no network** from the local files through the SAME
`PlayerEngine`/`startPlayback` path used for streaming (never a parallel
player), and its offline progress reconciles cleanly with the server on
reconnect with no double-counted listen time. A **Downloads** tab (iPhone's
4th tab; a Mac/iPad sidebar entry) lists every downloaded book and episode
with live per-download state (queued/downloading/downloaded/failed with a
one-tap Retry), a running storage total, and swipe/context delete; matching
download buttons and compact state badges appear on item detail, episode
detail, episode rows, and cover/episode cards everywhere in the app
(download → progress ring → downloaded checkmark → delete — a plain
control, never glass; glass stays on transport chrome per the UI mandate).
A fully-downloaded item (every one of its files present on disk) prefers
its local `file://` tracks over streaming — chapters/timeline from the
pinned offline item detail, resume position from cached progress — and
falls back to streaming automatically for anything partial, not
downloaded, or missing a cached duration. Offline listening writes local
`PlaybackSession` rows (client-generated UUID, `playMethod: local`); an
`NWPathMonitor`-backed reachability signal (composed with the existing
server/auth probe, so a healthy launch's connection probe is never
mistaken for "offline") drives an offline-aware browse — Home/Library/
Search fall back to cache instead of hanging, behind a small "Offline —
showing cached content" banner and a request-timeout backstop for a
reachable-but-unresponsive host — and, on reconnect, a `GET /api/me`
reconcile (newer **server** progress wins locally) followed by a `POST
/api/session/local-all` batch sync and a prune of only the sessions that
both synced successfully and weren't touched again in the meantime. That
offline↔online seam is the highest-risk correctness surface in this
milestone and is covered by adversarial concurrency tests (a live tick
landing mid-reconcile; two rapid reconnect transitions racing each other).
Podcast episodes gained an opt-in "delete after finished" setting (default
off) that removes a downloaded episode's files only on a **witnessed**
not-finished→finished transition — deliberately not on every server
progress push, after an early version was found (in review) to mass-delete
every already-finished downloaded episode the first time a full progress
history was reprocessed; that was fixed before this shipped. The on-disk
schema is now at **v5**: v4 added the download records (`cachedDownload` +
a per-file `cachedDownloadFile` child table, keyed like `cachedProgress`'s
3-part `(connectionID, itemID, episodeID)` convention), v5 added a pending
local-sessions table for the sync-back queue — both purely additive; `v1`–
`v3` remain frozen. See `docs/superpowers/m2a-human-verification.md` for
the device-only checklist (background download continuing/resuming across
a backgrounded or killed-and-relaunched app, offline playback surviving an
app relaunch, the offline→online reconcile no-double-count check, the >1h
background-token-expiry retry path, storage accounting, podcast
auto-delete, and Mac click-through) the automated, always-muted E2E/sim
can't fully cover.

Built on M1c-c's full podcast support — Colophon handles podcasts end
to end, reusing the M1c-a/M1c-b browse, cache, and player machinery rather
than a parallel stack. A podcast library browses as a native cover grid
(Series/Authors — book-only concepts — are gated off for podcast libraries,
in both the Mac/iPad sidebar and the iPhone "Browse by" menu); tapping a
podcast pushes a native, Apple-Podcasts-style detail: opaque cover, serif
title/author, an HTML description (via `HTMLText`, expandable), and an
episode list grouped by **season** (a `Section` per season once the feed
has more than one, otherwise a flat list) with a **sort** menu (Newest
First/Oldest First/By Season) and per-episode finished/in-progress state (a
checkmark, or a progress bar with "…left") sourced from the same 3-part
`cachedProgress` key the book player uses. Each episode has its own detail
page (title, podcast, pubDate/duration, HTML description, a
`.glassProminent` Play/Resume, Add to Queue) and plays through the SAME
full player — `startPlayback` gained an `episodeId:` path that posts to
`/play/:episodeId`, syncs per-episode progress distinctly from any book
progress on the same item, and surfaces the episode title with the podcast
as the secondary now-playing line everywhere (mini-bar, full player,
lock-screen/Control Center, Mac Now Playing menu); the up-next queue and
sleep timer work for episodes too, and speed persists per-podcast rather
than per-episode (a documented tradeoff of reusing the per-item speed key).
Home's personalized shelves render real episode cards (cover, episode
title, podcast caption, progress pill) for continue-listening/newest
episodes, and search adds an Episodes section alongside podcast results
merged into Titles. See `docs/superpowers/m1c-c-human-verification.md` for
the on-device/Mac checklist (audible episode playback, per-episode progress
surviving an app relaunch, multi-season rendering, Mac click-through) the
automated, always-muted E2E can't fully cover — the dev fixture seeds only
one podcast, two episodes, one season.

Also built on M1c-b's full in-app player (every browse surface pushes into a
native item-detail view — cover, serif title/author/narrator, series,
description, a metadata row, and a chapters-count preview — with a
`.glassProminent` Play/Resume primary reading live progress from
`/api/me`; play opens a full-screen Liquid Glass player: a chapter-aware
scrubber and chapter list working in global book-seconds, a sleep timer
(5/10/15/30/45/60-minute presets plus End-of-Chapter, with a
fade-then-pause on fire), bookmarks (create/rename/delete/seek-to,
round-tripped through the live bookmark endpoints and reconciled from
`/api/me`), per-book playback speed that persists device-locally and
resumes automatically, and an up-next queue (play-next/add-to-queue,
book-finished auto-advance, reorderable); presentation is native per
platform — iPhone `.fullScreenCover`, iPad a large detented `.sheet`, and a
dedicated Mac `Window("Now Playing")` (never a takeover) — with a
`Playback` command menu and Now Playing/lock-screen/Control Center
integration; a configurable skip interval (10/15/30/45/60s) applies
everywhere transport appears; see `docs/superpowers/m1c-b-human-verification.md`
for its own device checklist), M1c-a's browse & search foundation (a
native, per-platform Liquid Glass navigation shell — iPhone `TabView` with
a `tabViewBottomAccessory` mini-player; iPad/Mac `NavigationSplitView` with
a hand-built bottom-docked Mac transport bar — fronting personalized home
shelves, a library cover grid with native sort/filter, series & authors
browse, and a blended local-FTS5 + server search; a `v2` GRDB schema, a
connection-epoch refactor, uncapped reconciliation, and a per-item socket
patch), M1b's sign-in & connections UX (OIDC single sign-on via
`ASWebAuthenticationSession` alongside password auth, multi-connection
management with cached-first offline activation, a Settings scene for
typeface/speed/skip, live deletion reconciliation), and the M0/M1a walking
skeleton (library browse, multi-file streaming playback with server
progress sync, live Socket.IO updates, on iOS + macOS). Underneath M1c-c:
no new GRDB migration — the v2 `cachedEpisode` table and the 3-part
`cachedProgress` PK (both from M1c-a) already modeled episodes; `v1`/`v2`/
`v3` remain frozen (offline downloads landed in M2a — see the schema note
above); M2b's companion surfaces (widgets, Live Activity, Control Center,
Siri/Spotlight) added no migration either — they read a separate
App-Group snapshot, never the GRDB cache directly. Spikes for socket.io
handshake, macOS grid performance, and the
OIDC cookie/redirect walk are documented in `docs/superpowers/spikes/`.
CarPlay entitlement application: pending user filing (will be recorded in
docs/superpowers/carplay-entitlement.md).

## Development

Requirements: Xcode 26.6, XcodeGen (`brew install xcodegen`), Docker.

    make gen          # generate Colophon.xcodeproj
    make server-up    # start dev Audiobookshelf + Dex (OIDC) at localhost:13378 / :5556
    make seed         # root/colophon-dev + a LibriVox test book + a seeded 2-episode
                      #   podcast (local RSS fixture) + OIDC (Dex) config
    make test         # package unit tests (ABSKit, PlayerEngine, LibraryCache, DownloadManager, ColophonShared)
    make test-app     # ColophonTests: AppState state-machine unit tests (hosted bundle)
    make build-ios build-mac

OIDC sign-in test user (Dex, static password DB): `oidc@colophon.dev` /
`colophon-oidc`. Dex's issuer is `http://host.docker.internal:5556/dex` so
both the ABS container and the host/simulator browser resolve it identically
— the host needs `host.docker.internal` mapped locally: check
`grep host.docker.internal /etc/hosts` and, if absent, add it with
`echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts`.
OIDC dev testing is simulator-only: physical devices can't resolve
`host.docker.internal` and would need the Mac's LAN IP (see `devserver/README.md`).

Contract tests (from `Packages/ABSKit`, after `make server-up && make seed`):

    ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests
    ABS_CONTRACT_URL=http://localhost:13378 swift test --filter OIDCContractTests

Design spec: `docs/superpowers/specs/2026-07-06-audiobookshelf-apple-client-design.md`
