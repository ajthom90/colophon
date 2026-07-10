# M2b — Human Verification Checklist (Widgets, Live Activity, Control Center, Siri/Spotlight)

These are the checks the automated E2E **cannot** cover — the sandboxed/headless runs are always
muted (`COLOPHON_AUTO_MUTE=1`), never touch real audio output, can't drive a widget gallery, an
ActivityKit Dynamic Island, a Control Center customization sheet, or "Hey Siri" the way a real
device does, and a `simctl openurl` deep-link shows a CLI-only "Open in Colophon?" confirmation a
real widget/Live-Activity/Spotlight tap never would. Every companion surface's underlying logic
IS unit-tested — the snapshot round-trip, the Live Activity start/update/end lifecycle against a
fake ActivityKit seam, the intent → player command mapping, the deep-link parse/route resolution,
the Spotlight item mapping — but the actual **system chrome** (Home Screen, Lock Screen, Dynamic
Island, Control Center, Siri, Spotlight) only exists on a real device. Run these on a **real
device** (not the simulator) built **unmuted** (do NOT set `COLOPHON_AUTO_MUTE`), signed into a
real Audiobookshelf server.

Legend: **Do** = the action to perform · **Expect** = the pass criterion.

---

## Dev-fixture limitations (read this first)

- The dev-seeded fixture (`make seed`) has **one audiobook** and **one podcast with 2 episodes** —
  fine for confirming each surface shows/updates/deep-links correctly, but too small to stress
  test the continue-listening widget's 3-item cap or a large multi-connection Spotlight index.
- **Dynamic Island** only exists on iPhone 14 Pro and later (and iPhone 15/16/17 non-Pro models
  that have it) — verify on a supported model; on an iPhone without Dynamic Island hardware the
  Live Activity still appears on the Lock Screen and as a *minimal* status-bar item, but the
  compact/expanded Dynamic Island states in this checklist need the right hardware.
- **Live Activity + Control Center are iOS/iPadOS-only** this milestone — the `ColophonWidgets`
  extension itself is an iOS-only build target, so there is no Mac widget, Mac Live Activity, or
  Mac Control Center control to verify. Siri/Shortcuts and Spotlight indexing DO build and run on
  macOS, but "Hey Siri" and system Spotlight search are still best verified on iPhone/iPad, where
  the OS surfaces are most natural to drive by hand.
- OIDC sign-in test cleanup: use two connections (or sign out/in) where a check calls for a
  "signed-out server" — the dev fixture only ships one real connection, so simulating a second,
  since-removed connection may require adding one temporarily via **Connections**.

---

## a. Continue-listening Widget on the Home Screen

- **Do:** Play part of a book (or podcast episode) so it appears on the app's Home continue-
  listening shelf. Background the app. From the Home Screen, long-press an empty area → **+** →
  find **Colophon** → add the small widget, then separately add the medium widget.
- **Expect:** The **small** widget shows the single most-recent in-progress item — cover art,
  title, author, and a progress ring — matching what the app's own Home shelf shows. The
  **medium** widget shows up to 3 in-progress items, each with its own cover thumbnail, title/
  author, and a progress bar.
- **Do:** Tap the small widget, then (separately) tap a middle row of the medium widget (not the
  top one).
- **Expect:** Each tap opens the app directly to **that item's** detail page (not just the app's
  Home tab) — the medium widget's per-row taps are independent deep-link targets, not all routed
  to the top item.
- **Do:** With nothing in progress (sign out, or a fresh library with no playback history), check
  the widget again (may need to wait for the next timeline reload, or re-add the widget).
- **Expect:** A native "Nothing in progress" / "Start a book to see it here" empty state — no
  crash, no stale data from a previous item.

## b. Now-playing Live Activity — Lock Screen + Dynamic Island

- **Do:** Start playing a book or episode. Lock the device (or swipe to the Home Screen on a
  Dynamic Island device to see the compact/minimal presentation).
- **Expect:** A Live Activity appears on the **Lock Screen**: cover art, title, chapter (or
  author), a progress bar, and play/pause + skip-forward/back buttons. On a Dynamic Island
  device, the **compact** presentation (cover + a play/pause glyph) shows around the sensor
  housing; long-press or tap-and-hold it to see the **expanded** presentation (title/chapter,
  elapsed time, progress bar, transport controls).
- **Do:** From the Lock Screen or the expanded Dynamic Island, tap **play/pause**, then tap
  **skip forward** and **skip backward**.
- **Expect:** Each button actually controls playback in the running app — play/pause toggles
  (verify by unlocking and checking the app's own player state matches), skip moves by the
  configured skip interval. The Live Activity's progress/chapter/play-pause state updates to
  reflect the new state within a few seconds (it doesn't have to be instant — the app throttles
  progress-only pushes — but it must not go stale for more than ~15s during active playback).
- **Do:** Let playback continue for a minute or two without touching anything.
- **Expect:** The progress bar and elapsed time visibly advance on their own (not frozen at the
  value from when the Activity started).
- **Do:** Stop playback (pause and leave it, or close the item / sign out).
- **Expect:** The Live Activity **ends** — it disappears from the Lock Screen and Dynamic Island;
  it does not linger showing a stale paused state indefinitely.
- **Do (the load-bearing check):** Start book A, let its Live Activity appear, then — without
  manually dismissing it — start playing book B (or a podcast episode) instead. Repeat by
  switching to a **different connection/server** (if you have a second one set up) mid-playback.
- **Expect:** At every point there is **exactly one** Live Activity, and it always reflects the
  **currently playing** item — never two stacked Activities, never one showing book A's cover
  while book B is actually playing, never one left over after a connection switch.

## c. Control Center / Lock Screen play-pause control — including resume-from-suspended

- **Do:** Open **Settings → Control Center → Controls Gallery** (or long-press Control Center →
  **+** on newer OS versions) and add the **Colophon** play/pause control. Also try adding it
  from the Lock Screen's control customization if available.
- **Expect:** The control appears in Control Center / on the Lock Screen with a glyph that
  reflects whether Colophon is currently playing or paused.
- **Do:** With Colophon playing (app in foreground or freshly backgrounded), tap the control.
- **Expect:** Playback toggles (pause↔play) and the control's glyph updates to match.
- **Do (the specific regression this checklist exists to catch):** Start playback, then pause it,
  then background/lock the device and **wait at least a minute** (long enough for iOS to suspend
  a paused audio app — it typically does within ~30 seconds of no audio session activity). Do
  **not** reopen the app. From the Lock Screen / Control Center, tap the play control to **resume**.
- **Expect:** Playback actually **resumes** — the app launches/wakes in the background and audio
  starts. This is the case a prior review round found broken (the intents originally lacked the
  `AudioPlaybackIntent` marker-protocol conformance needed to guarantee the OS routes `perform()`
  into the app process rather than the inert widget-extension fallback); it was fixed and is
  covered by a compile-time conformance test, but the **live, on-device resume-after-suspension**
  path itself has not been driven by a human. If tapping Play here silently does nothing (no
  audio starts, control doesn't flip), that is a regression of the fixed bug — treat it as a
  blocking finding, not a shrug.

## d. Siri / Shortcuts

- **Do:** With a book in progress on the continue-listening shelf, say **"Hey Siri, resume my
  audiobook in Colophon"** (or open the Shortcuts app and run the "Resume" shortcut for Colophon).
- **Expect:** Colophon opens (or resumes in the background) and starts playing the **top**
  continue-listening item — the same one the widget's top row shows.
- **Do:** Say **"Hey Siri, open Colophon."**
- **Expect:** The app launches to the foreground.
- **Do:** Say **"Hey Siri, search Colophon"** or **"Search my library in Colophon for [a book
  title]."**
- **Expect:** The app opens on the Search tab; if a query phrase was given, the search field is
  pre-filled with it.

## e. System Spotlight search

- **Do:** Pull down on the Home Screen to open system Spotlight search. Type part of a library
  book's title (the seeded book/podcast, or any book on a real library).
- **Expect:** The book (or podcast/episode) appears as a search result, with its title/author and
  cover art.
- **Do:** Tap the Spotlight result.
- **Expect:** Colophon opens directly to that item's detail page (not just the app's Home tab).
- **Do:** Sign out of the connection (or remove it), then repeat the Spotlight search for a book
  that ONLY existed on that now-signed-out server.
- **Expect:** That book's Spotlight result is **gone** — a de-indexed/signed-out connection's
  items must not keep surfacing in system search after sign-out. (If you have a second connection
  still signed in, confirm ITS books still show up normally — signing out of one connection must
  not wipe another's index.)

## f. Snapshot correctness across sign-out

- **Do:** With a book in progress and its widget/Live Activity/Control visible, sign out of the
  active connection (Settings → Connections, or however sign-out is triggered).
- **Expect:** The continue-listening widget clears to its empty state (no stale "in progress"
  item from the signed-out server lingers). Any active Live Activity for that connection ends
  (per item **b**'s exactly-one-and-current rule). The Control Center control shows a
  paused/inactive state (nothing to resume).
- **Do:** Sign back in (or switch to a different, still-signed-in connection) and start playing
  something there.
- **Expect:** The widget, Live Activity, and Control all update to reflect the **new** connection's
  now-playing/continue-listening state — no cross-connection leakage in either direction.

---

### Notes for the tester

- Build **unmuted** for these checks — the automated E2E is muted by design; these human checks
  are the audible/real-system-UI counterpart.
- Item **c**'s resume-from-suspended check is the single most important item in this checklist —
  it is the one specific bug a review round found and fixed (an `AppIntent` missing the
  `AudioPlaybackIntent` marker-protocol conformance needed to guarantee app-process routing), and
  the fix's real-world behavior has only been confirmed by a compile-time conformance test, never
  by an actual suspended-app tap on a device.
- Item **b**'s "exactly one Live Activity, always current" check is the primary device-only
  surface for M2b per every relevant task report — the lifecycle decision logic is thoroughly
  unit-tested against a fake ActivityKit seam, but the real ActivityKit host (and Dynamic Island
  hardware) can only be exercised by hand.
- The App Group never carries auth tokens or credentials — only display snapshots (titles, ids,
  progress, small artwork thumbnails). If you're auditing for a security concern, that's the
  boundary to check; there is nothing sensitive to leak via the widget/Live Activity/Spotlight
  surfaces even if the App Group container were somehow inspected.
- If a Live Activity or widget looks stale, try re-triggering a snapshot publish (play/pause, or
  pull-to-refresh Home) before concluding something is broken — the app reloads widget timelines
  and Live Activity content on every discrete playback-state change, not on a fixed poll.
