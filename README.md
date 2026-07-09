# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M1c-c full podcast support — Colophon now handles podcasts end
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

Built on M1c-b's full in-app player (every browse surface pushes into a
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
`v3` remain frozen. Offline downloads are M2. Spikes for socket.io
handshake, macOS grid performance, and the OIDC cookie/redirect walk are
documented in `docs/superpowers/spikes/`. CarPlay entitlement application:
pending user filing (will be recorded in docs/superpowers/carplay-entitlement.md).

## Development

Requirements: Xcode 26.6, XcodeGen (`brew install xcodegen`), Docker.

    make gen          # generate Colophon.xcodeproj
    make server-up    # start dev Audiobookshelf + Dex (OIDC) at localhost:13378 / :5556
    make seed         # root/colophon-dev + a LibriVox test book + a seeded 2-episode
                      #   podcast (local RSS fixture) + OIDC (Dex) config
    make test         # package unit tests (ABSKit, PlayerEngine, LibraryCache)
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
