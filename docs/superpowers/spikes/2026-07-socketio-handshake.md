# Spike: socket.io-client-swift v16 handshake against ABS Socket.IO 4.5.x

**Date:** 2026-07-06
**Task:** M0 Task 13 — go/no-go for M1's real-time layer
**Code:** `Tools/SocketSpike/` (throwaway, never imported by the app)

## Verdict: ADOPT

`socket.io-client-swift` v16 connects to the dev ABS server (v2.35.1, Socket.IO
server 4.5.x) over websockets, completes the app-level auth handshake
(`connect` → emit `auth` with the JWT access token → receive `init`), and
recovers automatically after a server-side connection drop, re-emitting `auth`
without any special-cased reconnect logic. No protocol mismatch, no need to
fall back to HTTP polling for M1.

## Environment

- Swift: `swift-driver version 1.148.6`, Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), target `arm64-apple-macosx26.0`
- Package platform: `.macOS(.v26)` (per brief — this is a macOS CLI spike, not the iOS app target)
- Dependency resolution: `socket.io-client-swift` requested `from: "16.1.0"` → resolved **16.1.1**; transitive `Starscream` resolved **4.0.8**
- Server: dev ABS container `colophon-abs`, v2.35.1, at `http://localhost:13378`, user `root`/`colophon-dev`

## Working SocketManager config

Exactly the config in the brief — no fallback needed, `.version(.three)` worked on the first successful run:

```swift
let manager = SocketManager(socketURL: url, config: [
    .log(true), .forceWebsockets(true), .version(.three), .compress,
])
let socket = manager.defaultSocket
```

Handshake sequence observed on the wire (via `.log(true)`):
1. Engine.IO GET handshake → `0{"sid":"...","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}`
2. Immediate websocket upgrade (forced, no polling fallback attempted)
3. Engine.IO `40{"sid":"..."}` (Socket.IO CONNECT ack) → library fires `clientEvent: .connect`
4. Spike code emits `2["auth","<JWT>"]` (Socket.IO EVENT packet) in the `.connect` handler
5. Server replies with `user_online` then `init`

First run: `CONNECTED — emitting auth` → `INIT RECEIVED` in **~28ms**, process exited 0.

## Deviations required to build (Swift 6 strict concurrency)

The brief's exact `main.swift` did not compile as-is under swift-tools-version
6.2 / Swift 6.3.3. Two mechanical fixes were needed; neither changes the
tested handshake/config semantics:

1. `exit(outcome)` — `outcome: Int`, but `exit(_:)` wants `Int32`. Fixed with
   `exit(Int32(outcome))`.
2. The brief's `.connect` handler logic, when factored into a standalone
   top-level `func emitAuth()`, failed with *"main actor-isolated let 'socket'
   can not be referenced from a nonisolated context"* — `SocketIOClient` in
   this version is `@MainActor`-isolated, and a free top-level function isn't
   implicitly isolated the way the top-level script context is. Fixed by
   inlining the `print` + `socket.emit("auth", token)` directly in the
   `.connect` trailing closure, matching the brief's original shape.

## Instrumentation added beyond the brief (in scope per task)

- `.disconnect`, `.reconnect`, `.statusChange` client-event handlers for
  observability during the reconnect probe.
- Two env-var knobs so the default (no env vars) run is identical to the
  brief's single-shot behavior:
  - `SPIKE_WINDOW=<seconds>` — RunLoop window (default 15, used 60 for the
    reconnect probe)
  - `SPIKE_KEEP_ALIVE=1` — don't `exit(0)` on the first `init`; keep running
    so a mid-connection container restart can be observed

No dedicated "re-emit auth on reconnect" handler was needed or added — see
below.

## `init` payload

Confirmed to include `userId` (top-level) plus `username` and a `usersOnline`
array (each entry: `id`, `username`, `type`, `session`, `lastSeen`,
`createdAt`, `connections`):

```
INIT RECEIVED: [{
    userId = "6bccb7b1-9b4a-4819-bae5-02e7537c2311";
    username = root;
    usersOnline = ( { connections = 1; createdAt = ...; id = "6bccb7b1-..."; lastSeen = ...; session = {...}; type = root; username = root; } );
}]
```

(`session` was a full active-playback object on the first connect because a
listening session was in progress from the dev seed data; it came back
`null` after the reconnect below since that session had ended.)

## Reconnect probe

Ran with `SPIKE_WINDOW=60 SPIKE_KEEP_ALIVE=1`. Sequence (all timestamps from
the library's own `.log(true)` output, which is written via NSLog and lands
in real time; our own `print()` calls to stdout are block-buffered when
redirected to a file and some were only flushed at process exit — a
test-harness artifact, not a product concern, noted for anyone reusing this
code):

| Time (local) | Event |
|---|---|
| 12:06:22.1 | Initial connect, auth emitted, `init` received (~28ms handshake) |
| 12:06:31 | `docker restart colophon-abs` issued |
| 12:06:31.562 | Client detects `"Socket Disconnected"` → fires `clientEvent: .reconnect`, immediately attempts reconnect #1 (handshake sent), and **schedules** reconnect #2 in 21.5s (default backoff) |
| 12:06:31.563–12:06:54.179 | First reconnect attempt does not complete (container mid-restart); client waits out its scheduled backoff rather than retrying sooner |
| 12:06:32.6 | Container actually back up and healthy (per `docker inspect` `StartedAt`) — i.e. the **server** was ready ~22s before the **client** tried again |
| 12:06:54.179 | Reconnect attempt #2 fires, handshake succeeds in <50ms |
| 12:06:54.227 | `clientEvent: .connect` fires again (new Engine.IO `sid`) |
| 12:06:54.228 | Spike's `.connect` handler runs unconditionally and re-emits `2["auth","<same JWT>"]` — **no dedicated reconnect-auth code needed** |
| 12:06:54.261 | Server sends `user_online` |
| 12:06:54.275 | Server sends a second `init` (confirms full re-auth + re-init round trip) |

Key findings:

- **Auth resend is automatic for free.** The library's `clientEvent: .connect`
  fires on every successful (re)connection per its own doc comment ("This is
  also called on a successful reconnection"), so the same `.connect` handler
  used for the initial auth also re-authenticates after a reconnect. No
  separate `.reconnect`-triggered re-auth was necessary.
- **Default backoff is slow relative to actual server recovery.** Defaults
  are `reconnectWait = 10`, `reconnectWaitMax = 30`, `reconnectAttempts = -1`
  (infinite) with jitter (`SocketManager.swift`). In this probe the container
  was back and accepting connections within ~1s of the restart, but the
  client didn't retry until ~23s had elapsed because its first attempt raced
  the restart and failed, and the next attempt was already scheduled per the
  jittered backoff. For M1, consider tuning `reconnectWait` down (e.g. 2–3s)
  or triggering an app-level reconnect kick on `UIApplication` foreground /
  network-reachability-restored events, rather than relying solely on the
  library's default timer for snappy recovery after a transient blip.
- Reconnection did not require re-fetching a token in this probe (same JWT
  reused); token refresh-on-reconnect is a separate concern for M1 to design
  (e.g. re-login if the access token has expired by the time a reconnect
  fires), not exercised here.

## M1 recommendation

**Adopt `socket.io-client-swift` v16** for the real-time layer, using:

```swift
SocketManager(socketURL: url, config: [
    .log(false), .forceWebsockets(true), .version(.three), .compress,
])
```

(`.log(true)` only for debugging; `.compress` and `.forceWebsockets(true)`
carried through as harmless/beneficial defaults.) Re-authenticate in the
`clientEvent: .connect` handler unconditionally — it already covers both the
initial connection and every reconnect. Budget for tuning
`reconnectWait`/`reconnectWaitMax` (or adding an app-driven reconnect trigger)
since the library's default backoff can leave the client silently
reconnecting for up to ~30s after a transient outage even though the server
recovered almost immediately. No indication of a protocol mismatch with ABS's
Socket.IO 4.5.x server — polling fallback is not needed for M1.

## Server state after the spike

`colophon-abs` was restarted once (as part of the reconnect probe) but its
data volume was untouched: `/api/libraries` still returns the seeded library
post-restart, so `make seed` was not re-run.
