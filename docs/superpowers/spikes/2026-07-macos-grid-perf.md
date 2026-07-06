# Spike: macOS LazyVGrid performance at 10k items

**Date:** 2026-07-06
**Task:** M0 Task 14 — go/no-go for the Milestone 3 (Mac polish) shell's library grid
**Code:** `App/Views/PerfSpikeView.swift` (DEBUG+macOS only), `App/ColophonApp.swift`
(DEBUG+macOS-only `Window("Perf Spike", id: "perf-spike")` scene + auto-opener)

**Terminology:** in this project, "M0"/"M1"/"M3" are *plan milestones* (M1 =
Milestone 1, the first shipping library UI; M3 = Milestone 3, the Mac-polish
milestone) — **not** Apple silicon chip generations. Where hardware is meant, the
chip is named in full (e.g., "Apple M2 Ultra").

## Verdict: LazyVGrid OK to proceed, budget for cell simplification — NOT yet a full sign-off

Plain `LazyVGrid` inside a `ScrollView` handles a synthetic 10,000-item grid on this
machine with a **low but non-zero rate of frame-scheduling hitches** (0.04%–1.56% of
timer samples across four sweeps) and no sustained stalls. That is a green light to
**keep building the Milestone 3 (Mac shell) library grid on `LazyVGrid`** rather
than reaching for an `NSCollectionView` wrapper right now. It is **not** an
unconditional "ships as-is": the occasional hitches showed up even with cells far
lighter than real book covers (see Caveats), the test hardware (an Apple M2 Ultra —
a powerful desktop-class chip) is far above the low-end consumer Macs real users
will run, and no human has watched this scroll yet. Recommendation and conditions
are in full below — treat this as "proceed, with two follow-up gates before
Milestone 3 (Mac polish) locks in the grid," not "done."

## Environment

```
$ sw_vers && uname -m && sysctl -n machdep.cpu.brand_string
ProductName:    macOS
ProductVersion: 26.5
BuildVersion:   25F71
arm64
Apple M2 Ultra

$ sysctl -n hw.ncpu hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu hw.memsize
24   (16 performance + 8 efficiency)
64 GB RAM

$ xcodebuild -version
Xcode 26.6
Build version 17F113

$ swift --version
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

**This is high-end hardware, not what typical users run.** The only Mac available
to run this spike is an Apple M2 Ultra Mac Studio-class machine — 24 CPU cores
(16P+8E) and far more memory bandwidth/GPU throughput than the low-end consumer
Macs (e.g., a base MacBook Air) at the bottom of the range real users will run
Colophon on. Every millisecond in this document should be read as **a lower bound
on hitching for the consumer-hardware range, not a prediction of it** — see
Caveats.

`system_profiler SPDisplaysDataType` reported one attached display at
"3200×1800 @ 30.00Hz" and a second at "2560×1440 @ 100.00Hz," both non-standard
refresh rates for a normal MacBook/iMac panel (60Hz) or ProMotion panel (up to
120Hz). This machine's display configuration (likely a remote/virtualized session
for this environment) is atypical enough that this spike does not attempt to reason
about frame gaps in units of "dropped frames at N Hz" — it only measures raw
main-thread scheduling gaps in milliseconds (see Instrumentation).

## What was built

- `PerfSpikeView` (per brief): `ScrollView` + `LazyVGrid` of 10,000 synthetic cells,
  each a `RoundedRectangle` with a `LinearGradient` fill (`aspectRatio(1)`) plus two
  `Text` lines ("Synthetic Book N" / "Author N").
- `Window("Perf Spike", id: "perf-spike")` scene, gated `#if DEBUG && os(macOS)` in
  `ColophonApp.swift` so it (and everything below) is fully absent from release and
  iOS builds.
- **Controller-authorized additions for headless measurement**, all inside the
  DEBUG+macOS-gated code:
  - `PerfSpikeAutoOpener`: a zero-size helper view (`Color.clear` + `.task`) placed
    in the main `WindowGroup`'s background. If `COLOPHON_PERF_AUTOSCROLL=1` is set,
    it stamps `PerfSpikeClock.windowOpenRequestedAt = Date()` and calls
    `openWindow(id: "perf-spike")` on launch — no human has to click Window ▸ Perf
    Spike.
  - `PerfSpikeView.runAutoSweep`: if `COLOPHON_PERF_AUTOSCROLL=1`, runs
    `COLOPHON_PERF_SWEEP_COUNT` (default 2, so cold+warm happen automatically in one
    launch) top→bottom→top sweeps via `ScrollViewReader.scrollTo`, 40 animated
    steps down + 40 up per sweep, 250ms per step (~20s/sweep as specified — measured
    ~22.3–22.7s including the animation settle on the outer edges).
  - `FrameGapMonitor`: a 120Hz `Timer` (`RunLoop.main`, `.common` mode so it keeps
    firing during scroll tracking) that records the actual wall-clock delta between
    consecutive fires. This is exactly the brief's sanctioned "coarse
    instrumentation" — comparing expected (~8.3ms) vs. actual tick deltas — not a
    CVDisplayLink/CADisplayLink tie-in to real vsync. Reports max/mean gap and count
    of gaps >33ms.
  - Time-to-first-content: `PerfSpikeClock.windowOpenRequestedAt` (set by the
    auto-opener right before `openWindow`) vs. the first grid cell's `onAppear`,
    printed once with an `origin=` label. If the window already existed before the
    auto-opener ran (macOS state restoration re-creates it when the previous
    process was killed with the window open), the measurement instead uses a
    process-launch timestamp stamped in `ColophonApp.init()` and is labeled
    `origin=process_launch` so it can never masquerade as an
    `origin=open_window_request` number. (The first version of this instrumentation
    lacked the label and silently fell back to "now", printing a meaningless
    `0.00` — see the fix note under Measurements.)
  - All results printed to stdout via a `perfLog` helper that calls
    `fflush(stdout)` after every `print`, so output is captured in real time
    through a redirected log file even though stdout isn't a TTY when launched via
    `open --stdout`.

## Running it headlessly — a real gotcha

The first attempt launched the built binary directly
(`Colophon.app/Contents/MacOS/Colophon &` via `nohup`, env vars prefixed). The
process came up and sat idle in its `NSApplication run` loop for 90+ seconds with
**zero output and zero windows** (confirmed via
`osascript -e 'tell application "System Events" to get name of every window of ...'`
returning empty, and `sample <pid>` showing the main thread parked in
`mach_msg2_trap`, i.e., genuinely idle, not stuck in app code).

`log show --predicate 'processID == <pid>'` explained it:

```
[com.apple.AppKit:StateRestoration] -[NSApplication ... _reopenWindowsAsNecessaryIncludingRestorableState:...]
  shouldRestoreState=1 hasPersistentStateToRestore=1 ...
[com.apple.AppKit:StateRestoration] ... restoreWindowWithIdentifier:state:completionHandler:] ... window=0x0 ...
[com.apple.processmanager:...] BringForward: ... launchedByLS=0 ...
```

Launched by directly exec'ing the Mach-O (`launchedByLS=0`, i.e. not through
LaunchServices), macOS's window-state-restoration path ran, found "persistent state
to restore" (this bundle ID had been run before during earlier M0 tasks), tried to
restore a window, and the restore silently produced `window=0x0` — no window, no
fallback default window, no crash, no error, just an app parked forever waiting for
events with nothing on screen. **Launching the raw binary bypasses the normal window
creation path for an already-run app bundle.**

Fix: launch through Launch Services with `open`, which supports passing environment
variables directly:

```bash
open -n -a "$APP_PATH" \
  --env COLOPHON_PERF_AUTOSCROLL=1 --env COLOPHON_PERF_SWEEP_COUNT=2 \
  --stdout "$LOG" --stderr "$LOG"
```

`-n` forces a new instance each time (needed since we relaunch repeatedly for
cold/warm comparisons); `--stdout`/`--stderr` capture the app's `print()` output to
a file in real time (confirmed live-tailable, thanks to the explicit `fflush`).
After this fix, `osascript`'s window list showed `"Perf Spike — 10k items, Colophon"`
immediately and the sweep ran end to end. This is a real, reusable finding for
future headless-Mac-app spikes in this repo, not just a one-off workaround.

## Measurements

Four sweeps across two separate process launches (`open -n` each time, so each
launch is a genuine fresh process). Each launch ran `COLOPHON_PERF_SWEEP_COUNT=2`
in-process — sweep 1 ("cold") is the very first layout pass over the 10k cells in
that process; sweep 2 ("warm") is the second pass in the same still-running window,
after SwiftUI has already computed layout/identity for cells it has seen once.

| Launch | Sweep | Phase | Duration (s) | Max gap (ms) | Mean gap (ms) | Timer samples | Gaps >33ms | Hitch rate |
|---|---|---|---|---|---|---|---|---|
| A | 1 | cold | 22.28 | 38.15 | 9.92 | 2244 | 12 | 0.53% |
| A | 2 | warm | 22.35 | 40.78 | 8.70 | 2567 | 1  | 0.04% |
| B | 1 | cold | 22.49 | 53.60 | 9.89 | 2272 | 26 | 1.14% |
| B | 2 | warm | 22.74 | 51.13 | 11.11 | 2046 | 32 | 1.56% |

(A preliminary single-sweep dry run, used only to validate the instrumentation
before the two real launches above, recorded: duration 22.34s, max gap 73.87ms,
mean 9.87ms, 2263 samples, 16 hitches (0.71%), `time_to_first_content_ms=69.04`,
`phys_footprint`=86MB/peak 129MB. Consistent with the table above; not included as
a primary data point since it predates the final instrumentation.)

**Time to first content** (window-open request → first grid cell's `onAppear`):
**23–42ms** on this hardware, from two clean re-runs after an instrumentation fix
(42.12ms and 22.99ms, both labeled `origin=open_window_request`).

*Fix note — the original launches A/B printed `time_to_first_content_ms=0.00`,
which was an instrumentation bug, not a measurement.* Root cause, confirmed by a
diagnostic re-run: launches A and B were each started after killing a previous
process that had the perf-spike window open, so macOS state restoration re-created
that window at launch, and the first cell's `onAppear` fired *before* the
auto-opener's `.task` stamped `windowOpenRequestedAt`. The first version of the
code silently fell back to "now" as the start time, yielding exactly 0.00. The
fixed instrumentation labels every measurement's origin; the diagnostic run (state
restoration still active) printed `time_to_first_content_ms=175.93
origin=process_launch (window existed before auto-opener ran…)` — proving the
restored-window path — and the two clean runs (state restoration suppressed via
`defaults write com.ajthom90.colophon ApplePersistenceIgnoreState YES`) measured
the real openWindow→first-content path at 42.12ms and 22.99ms. Note this also
means the sweep in launches A/B ran in a *restored* window rather than a
freshly-opened one; the frame-gap data is unaffected (the sweep triggers off the
view's `onAppear` + env var either way, and no duplicate sweep starts appear in
the logs), but it explains the 0.00 artifact lines preserved in the raw output
below. The dry run's 69.04ms predates the origin labeling but was a genuine
openWindow-path measurement (no perf-spike window existed in saved state at that
point — the prior process had died windowless).

**Memory footprint** — sampled *externally* from the terminal by running Apple's
`/usr/bin/footprint <pid>` against the live process (this is not in-process
instrumentation), after both in-process sweeps completed and before killing the
process:

| Launch | phys_footprint | phys_footprint_peak | RSS (`ps`) |
|---|---|---|---|
| A | 83 MB | 107 MB | ~179 MB |
| B | 96 MB | 136 MB | ~207 MB |

No unbounded growth across the ~44s of continuous scrolling per launch (peak stayed
within ~1.3x of the post-sweep resting value) — no evidence of a cell/view leak in
this run, though two ~45-second sessions is a thin basis for a leak verdict either
way.

**Raw log output** (Launch A, in full — the `time_to_first_content_ms=0.00` lines
are the instrumentation artifact explained in the fix note above, preserved here
because raw evidence shouldn't be retouched):

```
[PerfSpike] time_to_first_content_ms=0.00
[PerfSpike] sweep=1/2 phase=cold starting
[PerfSpike] sweep=1/2 phase=cold duration_s=22.28 max_gap_ms=38.15 mean_gap_ms=9.92 samples=2244 hitches_gt_33ms=12
[PerfSpike] sweep=2/2 phase=warm starting
[PerfSpike] sweep=2/2 phase=warm duration_s=22.35 max_gap_ms=40.78 mean_gap_ms=8.70 samples=2567 hitches_gt_33ms=1
[PerfSpike] ALL_SWEEPS_COMPLETE
```

Launch B:

```
[PerfSpike] time_to_first_content_ms=0.00
[PerfSpike] sweep=1/2 phase=cold starting
[PerfSpike] sweep=1/2 phase=cold duration_s=22.49 max_gap_ms=53.60 mean_gap_ms=9.89 samples=2272 hitches_gt_33ms=26
[PerfSpike] sweep=2/2 phase=warm starting
[PerfSpike] sweep=2/2 phase=warm duration_s=22.74 max_gap_ms=51.13 mean_gap_ms=11.11 samples=2046 hitches_gt_33ms=32
[PerfSpike] ALL_SWEEPS_COMPLETE
```

Diagnostic + clean re-runs after the first-content instrumentation fix (first
lines only; sweeps were not left to complete since the frame-gap data above
already stands):

```
# diagnostic (state restoration active — proves the restored-window path):
[PerfSpike] time_to_first_content_ms=175.93 origin=process_launch (window existed before auto-opener ran — likely state restoration; NOT comparable to origin=open_window_request)
# clean run 1 (ApplePersistenceIgnoreState YES):
[PerfSpike] time_to_first_content_ms=42.12 origin=open_window_request
# clean run 2:
[PerfSpike] time_to_first_content_ms=22.99 origin=open_window_request
```

Note Launch B's warm sweep (32 hitches) was *worse* than its own cold sweep (26
hitches), while Launch A's warm sweep (1 hitch) was much *better* than its cold
sweep (12 hitches). Cold-vs-warm is not a clean monotonic win in this data — the
between-launch variance (driven by whatever else was running on this shared
machine at the time) is at least as large as the cold/warm effect within a launch.
Treat "warm is better" as unconfirmed, not as a finding.

## Caveats — what this instrumentation CAN and CANNOT tell us

(All "see Caveats" references elsewhere in this document point here.)

**Can tell us:**
- Whether the main thread's run loop goes substantially unresponsive (tens/hundreds
  of ms) during a sustained programmatic scroll — it did not; max observed gap was
  74ms (dry run) / 38–54ms (the four real sweeps), and hitches (>33ms) were a small
  fraction (≤1.56%) of ~2000–2500 timer samples per 22s sweep.
- A directional signal on memory: no runaway growth across ~1,300–1,400 grid
  positions of scroll per launch.
- That `LazyVGrid` + `ScrollViewReader.scrollTo` does not itself throw, hang, or
  visibly break on 10k items with animated programmatic scrolling.

**CANNOT tell us (explicitly out of scope for this instrumentation):**
- **How the scroll actually *feels*.** A 120Hz `Timer` on the main run loop is a
  proxy for "was the main thread blocked," not a measurement of dropped compositor
  frames, visible stutter, or perceived smoothness. Nothing here substitutes for a
  human watching (or Instruments' Animation Hitches template, which the brief
  offered as an alternative and which was not run in this pass). **This entire
  spike's smoothness verdict is PENDING HUMAN VERIFICATION.**
- GPU-side cost. The gradient fills here are nearly free to render; there's no
  signal here about Core Animation commit time, layer count, or compositor load —
  only "was Swift/AppKit's main thread free to run."
- Real-world cell cost. **The synthetic cells in this spike are lighter than the
  real library grid will be**: a `LinearGradient`-filled `RoundedRectangle` is
  cheap to lay out and paint compared to a real cover image (`AsyncImage` or
  equivalent network fetch + JPEG/PNG decode + placeholder-to-loaded state
  transition + possibly rounded-corner masking/shadow) plus title/author text with
  real (variable-length, possibly multi-line-wrapping) strings. If real cells cost
  meaningfully more CPU/GPU per layout pass, the hitch rates measured here
  (0.04%–1.56%) should be expected to be a **floor, not a ceiling**, for the real
  grid.
- Low-end-hardware behavior. Measured on an Apple M2 Ultra (16P+8E, 24 cores) — a
  powerful desktop-class chip. Real users run everything from base MacBook Airs
  up; a low-end consumer machine doing the same work should be expected to show a
  *higher* hitch rate than what's reported here, not the same or lower.
- Scrollbar-drag / discontinuous jump-scroll. The brief's Step 3 also suggested
  testing a scroller-drag jump; this spike only exercises smooth animated
  `scrollTo` sweeps, not a discontinuous multi-thousand-row jump, which forces a
  larger burst of view instantiation than an animated sweep does.
- Sustained/thermal behavior beyond ~45 seconds per launch, or behavior under
  background system load contention (this machine is shared/multi-purpose during
  this session).

## Recommendation for the Milestone 3 (Mac polish) shell

**Proceed with `LazyVGrid`** for the Milestone 3 Mac library grid — do not
pre-emptively build an `NSCollectionView` wrapper. Nothing observed here indicates
`LazyVGrid` is structurally unable to handle a 10k-item macOS grid; the hitch
rates are low, and SwiftUI's own diffing/recycling handled the synthetic content
without any catastrophic multi-hundred-ms stalls.

**But treat this as conditional, not a final sign-off**, given the caveats above.
Two concrete gates before Milestone 3 (Mac polish) locks in this grid:

1. **Re-run with real cell content** (actual cover-art loading path + real
   title/author strings) once the real library-grid cell view exists — the library
   UI ships in Milestone 1, so this gate can run any time after that view lands —
   using the same `COLOPHON_PERF_AUTOSCROLL`/`COLOPHON_PERF_SWEEP_COUNT` harness.
   Watch specifically whether the hitch rate stays in the same ballpark or climbs
   once image decode/state-transition cost is added per cell.
2. **Get a human to actually watch it scroll** (ideally on a low-end consumer
   machine — e.g., a base MacBook Air — or at minimum on this machine) — fast
   continuous scroll top-to-bottom, then a scrollbar-drag jump, per the brief's
   original Step 3. This spike's numeric instrumentation is a proxy; it is not a
   substitute for eyes on the screen. **PENDING HUMAN VERIFICATION.**

If gate 1 shows a meaningfully higher hitch rate with real covers, the next lever
to pull is cell simplification (downsampled/pre-resized thumbnails, avoid
per-cell shadows/blurs, consider `.drawingGroup()` on the cell content) before
reaching for `NSCollectionView` — that escalation ladder (simplify cells → only
then consider an `NSCollectionView` wrapper) is the right order given nothing here
shows `LazyVGrid` itself is the bottleneck.

## Reusable notes for future headless Mac-app spikes in this repo

- **Launch via `open -n -a <App.app> --env K=V --stdout <file> --stderr <file>`,
  not by exec'ing the binary directly.** Directly exec'ing an already-run app
  bundle can silently produce zero windows (macOS window-state-restoration finds
  stale persisted state, tries to restore, fails with `window=0x0`, and — because
  it wasn't launched via LaunchServices — there's no fallback window creation).
  This cost the most time in this spike and will bite again if not written down.
- `footprint <pid>` (see `man footprint`) is the right tool for `phys_footprint` /
  `phys_footprint_peak` — matches Apple's own jetsam-relevant memory metric, and is
  a better instrument here than `ps`'s RSS (which was consistently ~2x higher and
  includes shared/mapped pages that don't reflect this process's actual
  contribution to system memory pressure).
- `print()` piped through `open --stdout <file>` is not line-buffered by default;
  call `fflush(stdout)` after every `print()` you need to observe in real time from
  a polling script, or you'll only see it at process exit.
- **State restoration races your on-launch hooks.** If a previous process was
  killed with app windows open, the next LaunchServices launch re-creates those
  windows via state restoration *before* your own `.task`/auto-open hooks run. Any
  "time from window-open" instrumentation must label its timing origin explicitly
  (or suppress restoration for the run:
  `defaults write <bundle-id> ApplePersistenceIgnoreState YES`), or it will
  silently measure garbage — this exact failure produced the `0.00`
  first-content artifact documented and fixed above.
