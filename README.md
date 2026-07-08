# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M1c-a browse & search foundation — a native, per-platform Liquid
Glass navigation shell (iPhone `TabView` with a `tabViewBottomAccessory`
mini-player; iPad/Mac `NavigationSplitView` with a hand-built bottom-docked
Mac transport bar and a `Playback` command menu) fronts personalized home
shelves (Continue Listening / Recently Added / Newest Authors, each cover
carrying a progress pill joined from `/api/me`), a library cover grid with
native sort and a filterdata-driven filter sheet, series & authors browse,
and a blended local-FTS5 + server search (instant on-device results, enriched
in place as the server responds). Underneath: a `v2` GRDB schema (an
item-detail table plus a podcast episodes table, ahead of M1c-c), a
connection-epoch refactor unifying every connection-mutating flow under one
guard, uncapped reconciliation (arbitrarily large libraries page through to
completion instead of stopping at 20 pages), and a per-item socket patch (a
changed item updates its one row instead of re-paging the whole library).
Built on M1b's sign-in & connections UX (OIDC single sign-on via
`ASWebAuthenticationSession` alongside password auth, multi-connection
management with cached-first offline activation, a Settings scene for
typeface/speed/skip, live deletion reconciliation) and the M0/M1a walking
skeleton (library browse, multi-file streaming playback with server progress
sync, live Socket.IO updates, on iOS + macOS). The full in-app player
(chapters, sleep timer, bookmarks, speed, queue) is M1c-b; podcast episode
browse/playback is M1c-c; offline downloads are M2. Spikes for socket.io
handshake, macOS grid performance, and the OIDC cookie/redirect walk are
documented in `docs/superpowers/spikes/`. CarPlay entitlement application:
pending user filing (will be recorded in
docs/superpowers/carplay-entitlement.md).

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
