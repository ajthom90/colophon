# Colophon M2b — Companion surfaces (Widgets, Live Activity, Control Center, App Intents/Siri/Spotlight)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface Colophon's now-playing + continue-listening state outside the app — a home-screen Widget, a now-playing Live Activity (Lock Screen + Dynamic Island), a Control Center / Lock Screen play-pause control, and App Intents for Siri/Shortcuts + Spotlight — all reading a shared snapshot the app publishes.

**Architecture:** Extensions are separate processes, so they cannot read the app's in-memory `@Observable` state. The app publishes a small, Codable **snapshot** (now-playing + continue-listening) into an **App Group** container whenever that state changes; a new `ColophonShared` package holds the snapshot types + a `SharedStore` read/write API used by BOTH the app and a new `ColophonWidgets` widget-extension target. Playback control from the Live Activity / Control widget flows through **App Intents** (`AudioPlaybackIntent`) that reach the running app's `PlayerEngine`. `NowPlayingUpdater` (`MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`) already exists and stays — the Live Activity/Control widget are additive.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI, WidgetKit, ActivityKit (Live Activity), App Intents (AudioPlaybackIntent / AppShortcutsProvider / IndexedEntity), Core Spotlight; a new `ColophonShared` SwiftPM package + a `ColophonWidgets` app-extension target (XcodeGen). App Group `group.com.andrewthom.colophon`.

## Global Constraints

- All prior constraints bind: Swift 6.2 strict concurrency (complete), default-MainActor; bundle prefix `com.andrewthom` (team LL334G7KP2); commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **UI MANDATE (review criterion):** native-first, HIG-idiomatic per surface (Apple Podcasts/Music widget + Live Activity conventions). Widgets/Live Activity respect the serif (New York) toggle where legible; monospaced digits for time; opaque content.
- **Platform scope:** Widgets, Live Activity, Control Center, App Intents/Siri/Spotlight are **iOS/iPadOS** first. macOS widgets work where WidgetKit supports them (best-effort); **Live Activity + Control Center controls are iOS-only** (`#if os(iOS)`-gate; don't break the macOS/other-platform builds). tvOS/watchOS/visionOS companions are later milestones (M4/M5) — NOT in M2b.
- **App Group:** `group.com.andrewthom.colophon` added to the app + widget entitlements. Automatic signing provisions app groups (no Apple approval needed, unlike CarPlay). The `SharedStore` NEVER stores tokens/credentials in the app group (device-local keychain only) — only display snapshots (titles, ids, progress, small artwork thumbnails).
- **No new schema migration** (LibraryCache v5 stays frozen from M2a); the snapshot is a separate app-group surface, not the GRDB cache. If a widget needs the cache, it reads the snapshot the app writes, not the DB directly.
- **Reuse, not fork:** the Live Activity/Control widget control playback via App Intents that reach the EXISTING `AppState`/`PlayerEngine`; do NOT build a parallel player. Deep links reuse the app's existing routing (`ItemDetailRoute`/`PodcastDetailRoute`/resume).
- **Device-only verification (carry to the human-verification doc):** Live Activity (Dynamic Island), Control Center control, Siri phrases, and widget-add flows need a real device — automated sim/E2E can't fully cover them.

## Verified reference (M2b confirms during T1)

```
App Group container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.andrewthom.colophon")
Shared small state: UserDefaults(suiteName: "group.com.andrewthom.colophon")  (now-playing snapshot: JSON blob)
Continue-listening list + artwork thumbnails: files under the app-group container
Widget reload: WidgetCenter.shared.reloadTimelines(ofKind:) / reloadAllTimelines from the app on snapshot change
Live Activity: ActivityKit Activity<Attributes> — request on playback start (if authorized), update(...), end(...)
App Intents in-app process: an AudioPlaybackIntent's perform() runs in the app process when the app is running
  (media apps holding the audio session) — reaches AppState.playback; else it launches the app.
Deep link scheme: colophon:// (existing) — colophon://item/<id>, colophon://resume ; app handles .onOpenURL
Spotlight: CSSearchableItem (Core Spotlight) or App Intents IndexedEntity for library items → deep-link to detail
```

## File Structure (M2b new/changed)

```
project.yml                                       MOD  ColophonWidgets app-extension target (iOS); app-group capability; ColophonShared dep on app + ext
App/Colophon.entitlements                         MOD  com.apple.security.application-groups = [group.com.andrewthom.colophon]
Widgets/ColophonWidgets.entitlements              NEW  same app group
Packages/ColophonShared/…                         NEW  NowPlayingSnapshot + ContinueListeningSnapshot (Codable, Sendable) + SharedStore (app-group read/write) + deep-link URL helpers
App/AppState.swift + a SnapshotPublisher          MOD  publish now-playing + continue-listening snapshot to SharedStore on change; WidgetCenter reload; Live Activity lifecycle
App/Intents/…                                      NEW  AudioPlaybackIntent (play/pause/skip), ResumeIntent, Open/SearchIntent, AppShortcutsProvider; onOpenURL deep-link handling
App/Spotlight/…                                    NEW  index library items into Core Spotlight / IndexedEntity; deep-link resolution
Widgets/…                                          NEW  ContinueListeningWidget (WidgetKit), NowPlayingLiveActivity (ActivityKit widget), PlayPauseControlWidget (ControlWidget)
docs/superpowers/m2b-human-verification.md         NEW  device-only checklist
```

---

### Task 1: App Group + ColophonShared snapshot + widget-extension scaffold

**Files:** `project.yml` (ColophonWidgets target + app-group capability); `App/Colophon.entitlements`; `Widgets/ColophonWidgets.entitlements`; create `Packages/ColophonShared/…`; `App/AppState.swift` (publish snapshot).

The foundation everything else reads. Create the `ColophonShared` package: `NowPlayingSnapshot` (itemID, episodeID?, title, author, chapterTitle?, progress 0…1, isPlaying, updatedAt, artwork thumbnail ref) + `ContinueListeningSnapshot` ([entry: itemID, title, author, progress, artwork ref]) — Codable + Sendable; a `SharedStore` (init with the app-group id) that reads/writes them to `UserDefaults(suiteName:)` (now-playing JSON) + a file (continue-listening) + small artwork thumbnails into the container; deep-link URL helpers (`colophon://item/<id>`, `colophon://resume`). Add `group.com.andrewthom.colophon` to the app entitlements + a new widget-extension entitlements. Scaffold a `ColophonWidgets` **app-extension (widget) target** in project.yml (iOS; depends on ColophonShared) with ONE placeholder StaticConfiguration widget that builds + loads. Wire `AppState` to publish the snapshot to `SharedStore` whenever now-playing or the continue-listening shelf changes (a small `SnapshotPublisher` observing the relevant state), and call `WidgetCenter.shared.reloadAllTimelines()` on change (iOS).

- [ ] `make gen` builds the app + the new ColophonWidgets extension; ColophonShared unit tests (snapshot round-trip through SharedStore; deep-link URL build/parse). `make build-ios` green (the extension is iOS; keep macOS building — gate the extension iOS-only in project.yml or ensure it's excluded from the mac build). Commit `feat(widgets): app group + ColophonShared snapshot + widget-extension scaffold`.

---

### Task 2: Continue-listening Widget

**Files:** `Widgets/ContinueListeningWidget.swift`; ColophonShared as needed.

A WidgetKit widget (small + medium) with a `TimelineProvider` reading `ContinueListeningSnapshot` from `SharedStore` (app group): shows the most-recent continue-listening book(s) — cover thumbnail (opaque), title, author, a progress bar/ring. Tapping deep-links `colophon://item/<id>` (or `colophon://resume` for the top item) via `widgetURL`/`Link`. Native placeholder + no-content ("Nothing in progress") states. The app already reloads timelines on snapshot change (T1). Respect Dynamic Type + the serif toggle where legible.

- [ ] Build the extension; a widget snapshot/preview renders in the widget gallery (sim add-widget where feasible). Unit-test the provider's snapshot→entry mapping. Commit `feat(widgets): continue-listening widget`.

---

### Task 3: App Intents core + Control Center / Lock Screen play-pause control

**Files:** `App/Intents/AudioPlaybackIntent.swift` (+ related); `Widgets/PlayPauseControlWidget.swift` (ControlWidget); `App/AppState.swift` (intent → player bridge).

Define the App Intents that control playback and reach the RUNNING app's player: `AudioPlaybackIntent` (toggle play/pause), plus skip-forward/back intents. Ground the intent→player bridge: when the app is running (it holds the audio session during playback), the intent's `perform()` reaches `AppState.playback` (in-process); decide the mechanism (direct shared-controller access vs an app-group command the app observes) and document it. Add a `ControlWidget` (iOS Control Center / Lock Screen, iOS 18+) that toggles playback via the intent + reflects `isPlaying` from the snapshot. Keep `NowPlayingUpdater`'s `MPRemoteCommandCenter` wiring intact (this is additive — Control Center's *media* controls already work via MPRemoteCommandCenter; the ControlWidget is the new Control-Center-gallery toggle).

- [ ] `#if os(iOS)`-gate the ControlWidget; build. Unit-test the intent's perform() path against a fake player (toggles play/pause). Device-verify the Control widget later (human checklist). Commit `feat(intents): AudioPlaybackIntent + Control Center play-pause`.

---

### Task 4: Now-playing Live Activity

**Files:** `Widgets/NowPlayingLiveActivity.swift` (ActivityKit widget + ActivityAttributes); `App/AppState.swift` (Live Activity lifecycle).

An ActivityKit Live Activity for the currently-playing book: **Lock Screen** view (cover, title, chapter, progress bar, play/pause + skip buttons) + **Dynamic Island** (compact: cover + play/pause; expanded: title/chapter/progress/controls). `ActivityAttributes` (static: itemID, title, author) + `ContentState` (chapterTitle, progress, isPlaying, elapsed). The app starts the Activity on playback start (if `ActivityAuthorizationInfo().areActivitiesEnabled`), `update(...)`s it on progress/chapter/pause (throttled), and `end(...)`s it on stop/retire. Buttons use the T3 App Intents (`LiveActivityIntent`). iOS-only (`#if os(iOS)`). Lifecycle must be robust: no leaked/duplicate Activities across book switches or connection changes (tie into `retireCurrentSession`).

- [ ] Build (iOS). Unit-test the Activity lifecycle decision logic (start/update/end triggers) against a fake ActivityManager seam. Device-verify the Dynamic Island/Lock Screen later (human checklist — the primary verification surface). Commit `feat(widgets): now-playing Live Activity`.

---

### Task 5: Siri/Shortcuts App Intents + Spotlight indexing

**Files:** `App/Intents/` (ResumeIntent, OpenIntent, SearchIntent, AppShortcutsProvider); `App/Spotlight/` (indexer); `App/…App.swift` (onOpenURL deep-link routing).

`AppShortcutsProvider` exposing: **"Resume my audiobook"** (ResumeIntent → resume the last/continue-listening item through AppState), **"Open Colophon"**, **"Search Colophon"** — with natural Siri phrases. Spotlight: index library items (`CSSearchableItem` via Core Spotlight, OR App Intents `IndexedEntity`) from the cache/snapshot so a system Spotlight search surfaces books → tapping deep-links to detail. Wire `onOpenURL` in the app to route `colophon://item/<id>` / `colophon://resume` / Spotlight `userActivity` to the existing routes (ItemDetailRoute/PodcastDetailRoute/startPlayback). Keep it conservative (index title/author/cover; re-index on library refresh; don't leak across connections).

- [ ] Build both platforms (App Intents/Spotlight compile on macOS too; gate anything iOS-only). Unit-test the deep-link/userActivity → route resolution + the ResumeIntent's target selection. Device-verify Siri phrases + Spotlight later (human checklist). Commit `feat(intents): Siri/Shortcuts resume/open/search + Spotlight indexing`.

---

### Task 6: Wrap-up + human-verification + final review

**Files:** `README.md`; `docs/superpowers/m2b-human-verification.md`; contract-block refresh.

- [ ] README → M2b reality (continue-listening widget, now-playing Live Activity, Control Center play-pause, Siri/Shortcuts resume/open/search, Spotlight). Human-verification checklist (DEVICE-ONLY: add the widget → it shows continue-listening + deep-links; start playback → Live Activity appears on Lock Screen + Dynamic Island with working play/pause/skip; Control Center toggle; "Hey Siri, resume my audiobook"; Spotlight finds a book → opens it; snapshot updates as playback progresses; no leaked Live Activity across book switches). Full cold-start sweep `make test && make test-app && make build-ios && make build-mac` green, zero warnings. Commit `docs: M2b status`. Then the whole-branch adversarial review before merge.

---

## Self-review notes (plan-writing time)

- **Coverage vs M2 overview §M2b:** widgets/continue-listening (T2), Live Activity now-playing (T4), Control Center ControlWidget + AudioPlaybackIntent (T3), App Intents Resume/open/search + Siri + Spotlight IndexedEntity (T5); shared app-group snapshot + extension target infra (T1). Wrap-up (T6).
- **Infra-first:** T1 (app group + ColophonShared snapshot + extension scaffold) is load-bearing — every surface reads the snapshot; it also de-risks the fiddly XcodeGen-extension + entitlement setup before UI piles on.
- **Reuse, not rebuild:** control flows through App Intents into the EXISTING AppState/PlayerEngine; deep links reuse existing routes; NowPlayingUpdater (MPNowPlayingInfoCenter) stays. No new player, no schema change.
- **Platform discipline:** Live Activity + Control widget are `#if os(iOS)`; macoS/other builds must stay green (the plan gates them). tvOS/watchOS/visionOS companions are M4/M5.
- **Security:** the app group carries ONLY display snapshots — never tokens/credentials (keychain stays device-local).
- **Device-only reality:** Live Activity, Control Center, Siri, and widget-add are the human-verification surface; automated coverage is the snapshot round-trip + intent/lifecycle logic + deep-link routing. Called out in T6's checklist.
- **Deferred beyond M2b:** tip jar + CarPlay (M2c); tvOS/watchOS/visionOS surfaces (M4/M5); iCloud-synced snapshot/prefs (post-v1).
