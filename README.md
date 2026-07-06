# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M1a foundation — password auth gated on server version, cache-backed
library browsing (GRDB + FTS5) with offline reads, a ts-keyed on-disk cover
cache, a unit-tested player core behind a `PlayerBackend` seam, full playback
session lifecycle (deterministic close-time flush plus 404 local-upsert
recovery), and live Socket.IO updates — including web-UI edits (e.g.
mark-finished) arriving via `user_updated`. Built on the M0 walking skeleton
(password login, library browse, multi-file streaming playback with server
progress sync, on iOS + macOS). Spikes for socket.io handshake and macOS grid
performance are documented in `docs/superpowers/spikes/`.
CarPlay entitlement application: pending user filing (will be recorded in
docs/superpowers/carplay-entitlement.md).

## Development

Requirements: Xcode 26.6, XcodeGen (`brew install xcodegen`), Docker.

    make gen          # generate Colophon.xcodeproj
    make server-up    # start dev Audiobookshelf at localhost:13378
    make seed         # root/colophon-dev + a LibriVox test book
    make test         # package unit tests (ABSKit, PlayerEngine, LibraryCache)
    make build-ios build-mac

Contract tests: `ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests`
(from `Packages/ABSKit`).

Design spec: `docs/superpowers/specs/2026-07-06-audiobookshelf-apple-client-design.md`
