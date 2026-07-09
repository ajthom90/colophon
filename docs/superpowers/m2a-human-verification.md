# M2a — Human Verification Checklist (Offline downloads + offline playback + sync-back)

These are the checks the automated E2E **cannot** cover — the sandboxed/headless runs are always
muted (`COLOPHON_AUTO_MUTE=1`), never touch real audio output, can't background or force-quit the
app the way a real device does, can't wait out a real >1h background-URLSession token expiry, and
— per every M2a task report — Mac live click-through was environment-blocked (no Accessibility
permission in the agent's shell), so the Downloads sidebar entry and download buttons on macOS were
only build-verified, never driven live. Run these on a **real device / Mac** against a **real
Audiobookshelf library** (≥ 2.26.0), with the app built **unmuted** (do NOT set
`COLOPHON_AUTO_MUTE`).

Legend: **Do** = the action to perform · **Expect** = the pass criterion.

---

## Dev-fixture limitations (read this first)

The dev-seeded fixture (`make seed`) is small and short by design:

- **One audiobook** ("The Art of War", LibriVox) and **one podcast** with **2 episodes** — fine
  for confirming a download completes and offline playback/sync-back work end to end, but too
  small to meaningfully test storage accounting at scale or a large multi-file book's per-track
  progress.
- Audio is **short clips** (the book and both episodes are on the order of minutes, not hours) —
  a real >1h background-token-expiry test (item **d** below) genuinely needs either a much longer
  download (a real large audiobook) or a way to artificially delay/interrupt a transfer past the
  token's ~1h server expiry; don't expect the dev fixture alone to produce that condition without
  deliberately stalling the transfer (e.g., airplane mode mid-download, wait over an hour, then
  restore network).
- The dev server runs in Docker on the same Mac as the simulator/host — background-download
  behavior in the **simulator** is documented as unreliable for verifying true OS-level background
  continuation; items **a** and **b** below explicitly call for a **real device**, not the
  simulator.

---

## a. Background download CONTINUES when the app is backgrounded

- **Do:** On a real device, start downloading a book (item detail → Download button). Immediately
  background the app (press the Home button / swipe up, do NOT force-quit) while the transfer is
  still in progress (queued/downloading, not yet finished).
- **Expect:** Return to the app after 15-30 seconds (or check the Downloads tab after
  re-foregrounding). The download has **progressed** (received bytes increased, or it has reached
  `.downloaded`) — the transfer is a genuine background `URLSession`, not one that pauses/stalls the
  moment the app leaves the foreground.

## b. Background download RESUMES/reconciles after the app is KILLED mid-download and relaunched

- **Do:** Start downloading a book (ideally one large enough that it won't finish in a few
  seconds). While it's still downloading, **force-quit** the app (swipe it away in the app
  switcher — not just background it). Wait a bit (long enough for the OS to plausibly keep
  transferring in its background daemon, or for the transfer to actually finish server-side),
  then relaunch the app.
- **Expect:** On relaunch, the Downloads tab reflects the CORRECT state of that download — either
  still `.downloading` (with progress continuing to update) if it wasn't done yet, or
  `.downloaded` if the OS finished the transfer while the app was dead. It must NOT be stuck
  showing a stale `.downloading` state forever, and it must NOT silently vanish/reset to
  not-downloaded. This exercises the reattach/relaunch-reconcile path (`DownloadCoordinator`
  rebuilding `fileID → destination` from the cache and re-subscribing to the background session).

## c. Offline playback works across an app RELAUNCH

- **Do:** Download a book fully (wait for `.downloaded`). Force-quit the app. Turn on Airplane
  Mode (or otherwise take the device fully offline). Relaunch the app. Open the downloaded book
  and tap Play/Resume.
- **Expect:** Audio plays from the local file immediately — no spinner, no error, no attempt to
  reach the network. The mini-bar/full player behave exactly as they do for a streamed book
  (scrubber, chapters, sleep timer, skip, speed). Progress advances and is retained locally
  (`cachedProgress` updates with no network calls). This confirms the local-file playback path
  survives a cold relaunch, not just a same-session play.

## d. OFFLINE→ONLINE progress reconcile with NO double-count

- **Do:** With a book fully downloaded, go offline (Airplane Mode) and play it for a **known**
  duration — e.g. exactly 5 minutes by the clock, noting the book's elapsed time in the player
  before and after. Stop playback, come back online (disable Airplane Mode), and give the app a
  moment to reconnect and sync (reconnect reconcile is automatic — no manual action should be
  needed).
- **Expect:** After reconnecting, the server's progress for that book (check via the official web
  app, or re-open on another device/session, or just confirm the app's own displayed progress
  after a fresh `/api/me`-backed refresh) has advanced by **approximately the same ~5 minutes** —
  not roughly 10 minutes (double-counted) and not 0 additional minutes (lost). The local and
  server progress should agree (within normal sync-tick granularity) once reconciled.
- **Do (repeat once):** Play a little more offline, then reconnect, then IMMEDIATELY play a little
  more again right as reconnection happens (try to catch the reconcile in the act, e.g. by
  toggling Airplane Mode off and tapping play again within a second or two).
- **Expect:** Still no double-count and no lost time — a tick landing near the reconcile boundary
  must not be dropped or duplicated. (This mirrors the adversarial concurrency tests already run
  in CI — `tickLandingMidReconcileIsNeitherLostNorDuplicated` — this is the real-world analog.)

## e. The >1h background-token-expiry case: an interrupted download lands `.failed`, Retry re-downloads

> The embedded download URL's token expires in ~1 hour server-side. This item needs a download
> that is deliberately stalled past that window — not achievable with the dev fixture's short
> clips without artificially delaying the transfer.

- **Do:** Start a download, then interrupt it in a way that stalls the transfer for **over an
  hour** without completing (e.g., start a large download, then leave the device offline —
  Airplane Mode — for more than an hour before restoring connectivity, or use a large-enough item
  that a single ~1h window elapses naturally over a slow connection).
- **Expect:** Once the elapsed time exceeds the ~1h token window, the stalled file(s) surface as
  `.failed` in the Downloads tab / on the item's download badge (not stuck `.downloading` forever).
- **Do:** From the Downloads tab (or the item/episode detail's download button), tap **Retry** on
  the failed download.
- **Expect:** Retry re-derives a fresh download URL (new token) and the download completes
  successfully — no manual workaround needed, no leftover partial file confusion.

## f. Storage accounting is accurate

- **Do:** Download 2-3 items (a book and both podcast episodes, if using the dev fixture). Note
  the Downloads tab's total storage figure. Separately, inspect the actual on-disk bytes if you
  have the means (e.g., a debug build with access to the app's container, or simply cross-check
  against each item's known file size from the server).
- **Expect:** The Downloads tab's storage total is **approximately equal to** the sum of the
  downloaded files' actual on-disk sizes (allowing for `ByteCountFormatter` rounding) — not
  wildly off, not stuck at zero, not double-counting a retried/re-downloaded file.
- **Do:** Delete one downloaded item.
- **Expect:** The storage total decreases by approximately that item's size, and the on-disk files
  for that item are actually gone (not just the cache row).

## g. Podcast auto-delete-after-finish (opt-in) — including the fixed CRITICAL mass-delete case

- **Do:** In Settings, toggle **ON** "delete after finished" (or the equivalent labeled toggle) for
  podcast episodes. Download a podcast episode you have NOT yet finished, then play it to
  completion (or seek near the end and let it finish).
- **Expect:** Once the episode is marked finished, its downloaded files are **automatically
  removed** shortly after (the Downloads tab / episode badge reverts to not-downloaded) — with the
  toggle ON. This should also work if the "finish" happens purely offline (no reconnect needed
  immediately) — the episode should get cleaned up once the finish is recognized (either
  immediately on local playback completion, or shortly after the next server sync/reconnect).
- **Do (the fixed CRITICAL regression check):** Turn the toggle **OFF**. Download 1-2 podcast
  episodes that are **already fully finished** (played to completion previously, so the server
  already reports them as finished) and leave them downloaded. Now toggle "delete after finished"
  **ON**.
- **Expect:** Nothing happens to those already-finished, already-downloaded episodes — they stay
  downloaded. (An earlier version of this feature had a CRITICAL bug where flipping the toggle ON
  would immediately mass-delete every already-finished downloaded episode the next time progress
  was reprocessed — e.g. on a Home refresh or pull-to-refresh. That was fixed to only trigger on a
  freshly-**witnessed** not-finished→finished transition, never a replay of history. This step is
  the direct human-facing confirmation that the fix holds.)
- **Do (currently-playing guard):** Start playing a downloaded, not-yet-finished episode. While
  it's still playing, trigger a server-side "mark finished" for that same episode from another
  device/session (or the official web app), with the toggle ON.
  - **Expect:** The file is NOT yanked out from under the still-playing episode. It should only be
    cleaned up once *this* device's playback actually reaches the end (or a later finished
    signal after playback has moved on).

## h. Mac: Downloads sidebar entry + download buttons are reachable and work

> Flagged explicitly because Mac live click-through was **environment-blocked** in every M2a
> automated task (no Accessibility permission to script the window in the agent's shell) — Mac
> Downloads support was only build-verified (`make build-mac` → BUILD SUCCEEDED with the new
> `SidebarItem.downloads` case and sidebar `Label`), never driven live. This is the single most
> important item in this checklist to actually run by hand.

- **Do:** On a Mac, open the app and locate the **Downloads** entry in the sidebar (alongside
  Home/Search).
- **Expect:** Clicking it shows the Downloads list in the detail column — no dead-end (blank
  detail pane), no crash. If nothing is downloaded yet, the native empty state ("No Downloads
  Yet") plus a storage-total footer ("Zero KB" or similar) should render correctly.
- **Do:** From a book's detail page and a podcast episode's detail page on the Mac, click the
  Download button.
- **Expect:** The button drives through download → progress → downloaded exactly as on iPhone; the
  Downloads sidebar list updates to reflect the new download; the item's cover/row shows the
  download-state badge. Delete via the Downloads list (or the detail page's now-checkmark button)
  removes it cleanly.
- **Do:** With the item downloaded and the Mac offline (disconnect Wi-Fi / turn off networking),
  play it.
- **Expect:** It plays from the local file exactly as described in item **c**, with the Mac's
  dedicated Now Playing window and `Playback` menu working normally against the local session.

---

### Notes for the tester

- Build **unmuted** for these checks. The automated E2E is muted by design and terminates the app
  afterward; these human checks are the audible/real-system-UI counterpart.
- Items **a** and **b** (background continuation/resume) are the checks most likely to behave
  differently on a real device vs. the simulator — iOS aggressively throttles/suspends simulator
  background execution in ways it does not on hardware. Don't treat a simulator-only pass on these
  two as sufficient.
- The offline↔online reconcile (item **d**) reuses the exact `AppState.reconcileOnReconnect()` /
  `syncLocalSessions` / `progressReconcileView` machinery that already has adversarial concurrency
  unit tests in CI (a tick landing mid-reconcile; two rapid reconnect transitions racing each
  other) — this checklist item is the real-world sanity check on top of that, not a replacement
  for it.
- The auto-delete mass-deletion scenario in item **g** was a real CRITICAL bug caught and fixed in
  review during Task 8 (fix round 2) — it is included here as a load-bearing regression check, not
  a hypothetical edge case.
- If audio does NOT route as expected on the Mac, confirm the app was not launched with
  `COLOPHON_AUTO_MUTE=1` in its environment.
