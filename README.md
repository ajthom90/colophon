# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M1b sign-in & connections UX — OIDC single sign-on (PKCE via
`ASWebAuthenticationSession`, dev-tested against a Dex IdP) alongside password
auth, multi-connection management with cached-first offline activation (an
existing connection's library browses from cache immediately, even with no
live server — the app never blocks on the network to show what it already
has), a Settings scene (New York/San Francisco typeface toggle, default
playback speed, skip interval), and live deletion reconciliation (items
removed server-side disappear from the cache — and the FTS index — on the
next socket event or refresh). Built on the M1a cache/schema hardening
(composite per-connection primary keys, batched progress upserts, corrupt-db
init recovery) and the M0/M1a walking skeleton (library browse, multi-file
streaming playback with server progress sync, live Socket.IO updates, on
iOS + macOS). Spikes for socket.io handshake, macOS grid performance, and the
OIDC cookie/redirect walk are documented in `docs/superpowers/spikes/`.
CarPlay entitlement application: pending user filing (will be recorded in
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
