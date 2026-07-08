# M1c-b — Human Verification Checklist

These are the on-device checks the automated E2E **cannot** cover, because the sandboxed/headless
runs are always muted (`COLOPHON_AUTO_MUTE=1`), never touch real audio output, and can't drive the
lock screen, Control Center, media keys, or the macOS Now Playing menu (all TCC / system-UI
surfaces). Run them on a **real device / Mac** against a **real Audiobookshelf library** (≥ 2.26.0),
with the app built **unmuted** (do NOT set `COLOPHON_AUTO_MUTE`).

Legend: **Do** = the action to perform · **Expect** = the pass criterion.

---

## a. Audio actually plays and is AUDIBLE

- **Do:** Sign in, open a book's detail, tap **Play/Resume**. Make sure the device is unmuted and
  the volume is up.
- **Expect:** You HEAR the audiobook narration within a second or two. The mini-bar and full player
  show it playing (pause glyph, ticking elapsed time, moving scrubber). Pause → audio stops
  immediately; resume → it continues from where it stopped.

## b. Chapters seek correctly by ear

- **Do:** Open the full player → **Chapters**. Note the current chapter, then tap a **different**
  chapter (e.g. chapter 3). Also try **skip forward/back** and the scrubber.
- **Expect:** Playback jumps to the tapped chapter's start and you hear the correct passage; the
  chapter label under the scrubber updates to the new chapter title. Skip forward/back move by the
  configured interval (10/15/30/45/60 s). Dragging the scrubber and releasing seeks to that point.

## c. Sleep timer fires + fades + pauses

- **Do:** In the full player's secondary cluster, arm the **sleep timer** at a short preset (e.g.
  5 min, or set a shorter one for testing if available) OR **End of Chapter**. Let it run to zero.
- **Expect:** A live countdown shows while armed. When it reaches zero the audio **fades out**
  smoothly over a few seconds (not a hard cut) and then **pauses**. Tapping play afterwards resumes
  at full volume. End-of-Chapter fires at the current chapter's boundary.

## d. Lock-screen / Control Center controls + media keys (iOS) · Now Playing menu (Mac)

- **Do (iPhone/iPad):** With a book playing, lock the phone (or open Control Center). Also try the
  physical volume/media buttons and, if paired, AirPods / a car head unit.
- **Expect:** The lock screen / Control Center shows the **cover art**, the current **chapter title**
  (with the book as the secondary/album line), the **author**, elapsed/remaining, and a **scrubber**.
  Play/pause, skip-forward, skip-back, and dragging the scrubber all control playback. The skip
  buttons show the **configured interval** (e.g. "30"). Media keys / headphone controls play/pause.
- **Do (skip-interval live change):** While a book is playing, change the skip interval in Settings
  (e.g. 30 → 15). Return to the lock screen / Control Center **without** reopening the book.
- **Expect:** The lock-screen skip buttons now advertise the **new** interval (e.g. "15") and skip by
  that amount — no need to restart the book. (Follow-up A.)
- **Do (chapter advances while playing):** Start near the END of a chapter and just **let it play**
  across the boundary into the next chapter — do NOT tap anything. Watch the lock screen / Control
  Center / Now Playing menu.
- **Expect:** The displayed **chapter title updates to the new chapter on its own** as playback
  crosses the boundary (it must NOT stay frozen on the previous chapter until you next tap something).
- **Do (now-playing clears on stop):** Let a book **finish** with an empty up-next queue, OR sign out
  / disconnect / switch accounts while a book is loaded.
- **Expect:** The now-playing entry **disappears** from the lock screen / Control Center / Now Playing
  menu — no zombie card for the retired book, and its play/pause no longer does anything.
- **Do (Mac):** With a book playing, open the **Now Playing** menu-bar item (and Control Center on
  macOS). Try the keyboard media keys (F8/play-pause).
- **Expect:** The Now Playing item shows the book/chapter, author, and cover art, and its controls
  play/pause/skip. Media keys toggle playback.

## e. Mac dedicated player Window + menu commands + keyboard shortcuts

- **Do:** On the Mac, start a book, then open the player via the transport's expand affordance OR
  the **Playback ▸ Show Player** menu item (**⌘0**). Exercise the whole **Playback** menu.
- **Expect:**
  - The player opens as a **real resizable Window titled "Now Playing"** — NOT a full-window
    takeover — with the app's main window still usable behind it.
  - The player Window has **no chevron-down "Close Player" button**; closing it uses the native
    **traffic-light close** (or ⌘W). (Follow-up B.)
  - **Playback** menu items all work and are **disabled when nothing is playing**:
    - **Show Player** — ⌘0
    - **Play / Pause** — menu click only (there is intentionally **no** bare-Space shortcut; verify
      Space typed into the sidebar Search field types a space and does NOT toggle playback)
    - **Skip Forward / Back** — ⌘→ / ⌘←
    - **Next / Previous Chapter** — ⌥⌘→ / ⌥⌘← (disabled when the book has no chapters)
    - **Increase / Decrease Speed** — ⇧⌘. / ⇧⌘, and the **Playback Speed** submenu
  - Each shortcut affects audio as expected.

## f. Per-book speed resumes

- **Do:** Set a book to a distinctive rate (e.g. **1.5×**) via the speed control. Leave the book
  (stop / play a different book at 1.0×), then reopen the first book.
- **Expect:** The first book **resumes at 1.5×** (audibly faster); the second book stays at 1.0×
  (or your global default). The rate persists across app relaunch.

## g. Bookmarks create / seek

- **Do:** While playing, tap the **bookmark** button → create a bookmark at the current time (accept
  or edit the default title). Reopen the bookmarks sheet, **tap** the bookmark. Try **rename** and
  **delete**.
- **Expect:** The bookmark appears with its time; tapping it **seeks** there (you hear that passage).
  Rename/delete update the list. Cross-check in another ABS client or the web UI (`/api/me`
  bookmarks) that the create/rename/delete round-tripped to the server.

## h. Up-next queue advances between two real books

- **Do:** From a book's detail / a shelf context menu, **Add to Queue** (or Play Next) a **second**
  book. Start the first book and either let it play to the end OR use the player's **Next** action.
- **Expect:** When the first book ends (or you tap Next), the **second book starts** automatically,
  the mini-bar/player update to the second book (new cover, title, chapters), and the queue entry is
  removed. Reordering / removing queue entries in the queue sheet behaves as shown.

---

### Notes for the tester

- Build **unmuted** for these checks. The automated E2E is muted by design and terminates the app
  afterward; these human checks are the audible/again-system-UI counterpart.
- The now-playing metadata (cover art, chapter title/number, author, elapsed, rate) is wired through
  `NowPlayingUpdater` (`MPNowPlayingInfoCenter`) and its remote commands through
  `MPRemoteCommandCenter` → `PlaybackController`; items **a, d** exercise that surface end to end.
- If audio does NOT route as expected on the Mac, confirm the app was not launched with
  `COLOPHON_AUTO_MUTE=1` in its environment.
