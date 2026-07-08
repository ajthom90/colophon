# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M1c-b full in-app player — every browse surface now pushes into a
native item-detail view (cover, serif title/author/narrator, series,
description, a metadata row, and a chapters-count preview) with a
`.glassProminent` Play/Resume primary that reads live progress from
`/api/me`. Play opens a full-screen Liquid Glass player built on the
existing `PlayerEngine`: a chapter-aware scrubber and chapter list working
in global book-seconds, a sleep timer (5/10/15/30/45/60-minute presets plus
End-of-Chapter, with a fade-then-pause on fire), bookmarks (create/rename/
delete/seek-to, round-tripped through the live bookmark endpoints and
reconciled from `/api/me`), per-book playback speed that persists
device-locally and resumes automatically, and an up-next queue (play-next/
add-to-queue, book-finished auto-advance, reorderable). Presentation is
native per platform — iPhone `.fullScreenCover`, iPad a large detented
`.sheet`, and a dedicated Mac `Window("Now Playing")` (never a takeover) —
with a `Playback` command menu (skip, next/prev chapter, speed; all
non-Space shortcuts) and Now Playing/lock-screen/Control Center integration
that keeps cover art, chapter, and elapsed time live across skip-interval
changes and chapter boundaries, and clears itself when a session retires. A
configurable skip interval (10/15/30/45/60s) applies everywhere transport
appears. Underneath: a `v3` GRDB migration (additive per-book playback-rate
prefs, `v1`/`v2` frozen and preserved). See
`docs/superpowers/m1c-b-human-verification.md` for the on-device checklist
(audible playback, lock-screen/media keys, Mac window) the automated,
always-muted E2E suite can't cover.

Built on M1c-a's browse & search foundation (a native, per-platform Liquid
Glass navigation shell — iPhone `TabView` with a `tabViewBottomAccessory`
mini-player; iPad/Mac `NavigationSplitView` with a hand-built bottom-docked
Mac transport bar — fronting personalized home shelves, a library cover
grid with native sort/filter, series & authors browse, and a blended
local-FTS5 + server search; a `v2` GRDB schema, a connection-epoch refactor,
uncapped reconciliation, and a per-item socket patch), M1b's sign-in &
connections UX (OIDC single sign-on via `ASWebAuthenticationSession`
alongside password auth, multi-connection management with cached-first
offline activation, a Settings scene for typeface/speed/skip, live deletion
reconciliation), and the M0/M1a walking skeleton (library browse, multi-file
streaming playback with server progress sync, live Socket.IO updates, on
iOS + macOS). Podcast episode browse/playback (reusing this same player) is
M1c-c; offline downloads are M2. Spikes for socket.io handshake, macOS grid
performance, and the OIDC cookie/redirect walk are documented in
`docs/superpowers/spikes/`. CarPlay entitlement application: pending user
filing (will be recorded in docs/superpowers/carplay-entitlement.md).

## Development

Requirements: Xcode 26.6, XcodeGen (`brew install xcodegen`), Docker.

    make gen          # generate Colophon.xcodeproj
    make server-up    # start dev Audiobookshelf + Dex (OIDC) at localhost:13378 / :5556
    make seed         # root/colophon-dev + a LibriVox test book + OIDC (Dex) config
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
