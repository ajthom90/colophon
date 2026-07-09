# M1c-c — Human Verification Checklist (Podcasts)

These are the checks the automated E2E **cannot** cover — the sandboxed/headless runs are always
muted (`COLOPHON_AUTO_MUTE=1`), never touch real audio output, can't drive the lock screen, Control
Center, or the macOS Now Playing menu (all TCC / system-UI surfaces), and — for the whole M1c-c
run — a persistent Xcode-debugged Mac instance plus missing Accessibility permission in the agent's
shell blocked any live click-through on macOS (every M1c-c task report notes this same
environment block; Mac reachability was only build-verified + architecturally cross-checked against
the Mac-proven book/episode nav-destination pattern). Run these on a **real device / Mac** against a
**real Audiobookshelf library** (≥ 2.26.0), with the app built **unmuted** (do NOT set
`COLOPHON_AUTO_MUTE`).

Legend: **Do** = the action to perform · **Expect** = the pass criterion.

---

## Dev-fixture limitations (read this first)

The dev-seeded podcast (`make seed`) is a **local RSS fixture**, not a real-world show:

- **1 podcast** ("Colophon Test Podcast"), **2 episodes** ("Episode One: Laying Plans", "Episode
  Two: Attack by Stratagem"), **1 season** — the season-grouping UI is code-complete and
  unit-tested (`PodcastEpisodeOrganizerTests`), but **never rendered live with more than one
  season**, because the fixture can't produce one.
- Episode audio is **short LibriVox mp3 clips** (~7-8 minutes each, reused from the Art of War test
  book) — fine for confirming audio plays and progress advances, but too short to meaningfully
  exercise a sleep timer or a long scrub.
- Episodes carry **no per-episode artwork** — `EpisodeDetailView`/`EpisodeCard` intentionally show
  the shared podcast cover; this is a documented API/data limitation, not a rendering bug to chase.
- If you have access to a **real Audiobookshelf server with a real podcast library** (ideally one
  with a multi-season show), prefer running these checks against it — several items below are
  literally impossible to verify against the dev fixture alone (see item **c**).

---

## a. Episode audio actually plays and is AUDIBLE

- **Do:** Sign in, open a podcast library, tap into a podcast's episode list, tap an episode row's
  leading play glyph (or open episode detail and tap **Play**). Make sure the device is unmuted and
  the volume is up.
- **Expect:** You HEAR the episode audio within a second or two. The mini-bar and full player show
  it playing (pause glyph, ticking elapsed time, moving scrubber) with the **episode title** as the
  primary line. Pause → audio stops immediately; resume → it continues from where it stopped.
- **Do (row-glyph vs row-tap):** Tap a DIFFERENT episode's leading play glyph while still on the
  episode list (not the row body).
- **Expect:** The new episode starts playing (mini-bar switches) and the app **stays on the episode
  list** — it must NOT navigate into episode detail. (Tapping the row **body** instead should push
  episode detail without starting playback.)

## b. Per-episode progress persists across app restart + is distinct from book progress

- **Do:** Play an episode for at least 30-60 seconds, then **force-quit the app** (not just
  background it) and relaunch. Return to that episode's row / detail page. Separately, also play
  (or resume) an audiobook from the same server.
- **Expect:** The episode shows the SAME in-progress state it had before quitting (progress bar +
  "…left", or "Resume · Xm left" on episode detail) — progress survived the restart. The
  audiobook's progress is **unaffected** by the episode's progress and vice versa (they key off the
  3-part `connectionID/itemID/episodeID` cache PK — a book row and an episode row of the same
  podcast item must never bleed into each other). If the podcast has more than one episode, confirm
  sibling episodes track progress **independently** (advancing one doesn't move another).
- **Do (finished state):** Let an episode play to completion (or seek near the end and let it
  finish).
- **Expect:** The episode shows a **finished** checkmark (dimmed title in the list, "Played" on
  detail) that also survives an app restart.

## c. Season grouping renders correctly with a MULTI-season podcast

> **Cannot be verified against the dev fixture** — it seeds only one season. This item needs a real
> Audiobookshelf podcast library with a show that has episodes across 2+ seasons.

- **Do:** Open a multi-season podcast's episode list. Try each **sort** option: Newest First,
  Oldest First, By Season.
- **Expect:** Under Newest/Oldest, episodes are (optionally) grouped into `Section`s by season,
  each section labeled correctly (e.g. "Season 2"), sections ordered consistently with the overall
  sort direction. Under **By Season**, sections are ordered **ascending** (Season 1, 2, 3, …) with
  episodes within each season ordered by episode number. Episodes with no season metadata collect
  into a trailing, unlabeled "Episodes" section rather than being dropped. Switching sort options
  re-groups instantly with no stale/duplicated rows.

## d. Now-playing (lock screen / Control Center / Mac menu bar) shows the EPISODE title + podcast

- **Do (iPhone/iPad):** Start an episode playing, then lock the phone (or open Control Center).
- **Expect:** The lock screen / Control Center shows the **cover art** (the podcast's shared
  artwork), the **episode title** as the primary line, and the **podcast name** as the secondary/
  album line (NOT the podcast's `author` field) — matching the Apple Podcasts convention. Play/
  pause, skip, and the scrubber all control the episode. Confirm this is visually distinct from a
  book's now-playing card (book: title + author; episode: episode title + podcast name).
- **Do (Mac):** With an episode playing, open the **Now Playing** menu-bar item.
- **Expect:** Same episode-title/podcast-name convention. Media keys toggle playback.
- **Do (now-playing clears / switches):** Let an episode finish with an empty queue (or start a
  second episode / a book while the first is playing).
- **Expect:** The now-playing entry either clears (nothing queued) or fully switches to the new
  item — no stale episode card left showing after the session it belonged to has retired.

## e. Mac podcast surfaces are reachable and don't dead-end

> Flagged explicitly because Mac live click-through was **environment-blocked** in every M1c-c
> automated task (no Accessibility permission to script the window in the agent's shell) — this is
> the single most important item in this checklist to actually run by hand.

- **Do:** On a Mac, browse to a podcast library, open a podcast's detail (episode list), open an
  episode's detail page, and separately reach an episode two other ways: (1) an episode card on
  **Home** (Continue Listening / Newest Episodes shelf), and (2) an episode result from **Search**.
- **Expect:** Every one of these pushes into the correct destination in the **existing** detail
  column of the `NavigationSplitView` — podcast detail, episode detail — with no dead-end (blank
  detail pane), no crash, and the back/forward navigation controls work normally. Also confirm a
  podcast library's sidebar shows **no** Series/Authors disclosure (podcast libraries only show the
  plain library row) — this is intentional, not a missing feature.
- **Do:** Play an episode on the Mac and open the dedicated **Now Playing** window (⌘0 / Playback
  menu).
- **Expect:** The Now Playing window shows the episode title/podcast (per item **d**) and all
  `Playback` menu commands (skip, speed) work against the episode session exactly as they do for a
  book.

## f. Podcast search returns podcast + episode results and routes correctly

- **Do:** From Search, enter a query that matches both a podcast's title/metadata and an episode's
  title/description.
- **Expect:** Results show a **Titles** section including the matching podcast(s) (not silently
  dropped — podcast libraries used to show zero title rows before this milestone) and a separate
  **Episodes** section (podcast cover, episode title, "podcast name · duration") positioned right
  after Titles. Tapping the podcast Titles row opens **podcast detail** (episode list); tapping an
  Episodes row opens **episode detail** directly (not the podcast's episode list).

---

### Notes for the tester

- Build **unmuted** for these checks. The automated E2E is muted by design and terminates the app
  afterward; these human checks are the audible/real-system-UI counterpart.
- Per-episode progress and now-playing metadata reuse the exact same `PlayerEngine`,
  `NowPlayingUpdater`, and `cachedProgress` machinery the M1c-b book checklist
  (`docs/superpowers/m1c-b-human-verification.md`) already exercises — if a book behaves correctly
  there, most of the shared-player plumbing is already proven; this checklist focuses on what's
  genuinely **new or episode-specific** (season grouping, episode-vs-podcast now-playing labeling,
  per-episode progress isolation, and the podcast-specific navigation surfaces).
- Speed (playback rate) persists **per-podcast**, not per-episode, by design (documented in M1c-c
  Task 5) — don't treat two episodes of the same show having the same rate as a bug.
- If audio does NOT route as expected on the Mac, confirm the app was not launched with
  `COLOPHON_AUTO_MUTE=1` in its environment.
