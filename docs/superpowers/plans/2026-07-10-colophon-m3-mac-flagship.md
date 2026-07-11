# Colophon M3 — Mac flagship polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac app a genuinely-native flagship — the full menu command set, a menu-bar now-playing extra, a compact mini-player window, a Table/inspector browse mode, a dock menu, drag-and-drop, and window-restoration + keyboard-navigation audits — the differentiator this project exists for.

**Architecture:** All additive Mac-only surfaces (`#if os(macOS)`) layered on the existing `SplitShell` (NavigationSplitView) + the `Window("Now Playing")` player + the `PlaybackCommands`/`CommandMenu` scaffold from M1c-b. Everything drives the EXISTING `AppState`/`PlaybackController`/`PlayerModel` + the existing routes — no forked player, no new data model. iOS/iPadOS/tvOS/visionOS/watchOS builds MUST stay green (Mac code gated).

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI macOS 26 — `MenuBarExtra`, `Table`/`TableColumn`, `.inspector`, `CommandMenu`/`CommandGroup`, `Window`/`openWindow`, `.dockMenu` (AppKit `NSApplication.dockMenu` via an `NSApplicationDelegateAdaptor`), `draggable`/`dropDestination`, scene/window restoration. Existing ABSKit/PlayerEngine/LibraryCache.

## Global Constraints

- All prior constraints bind: Swift 6.2 strict concurrency (complete), default-MainActor; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **UI MANDATE (the whole point):** native macOS HIG — real menus, a menu-bar extra, `Table` with sortable columns, an `.inspector`, standard keyboard shortcuts, window behaviors that match Music/Books/Podcasts on the Mac. Liquid Glass where the platform uses it (sidebar, toolbars); content opaque. Respect the serif toggle + Dynamic Type.
- **Mac-only, gated:** every new surface is `#if os(macOS)`; **`make build-ios` and the other platforms MUST stay green** (verify each task). The shared views (grid, detail) keep working on iOS unchanged.
- **Reuse, not rebuild:** menu commands / menu-bar / dock / mini-player all call the EXISTING `AppState`/`PlaybackController`/`PlayerModel`/routes. NO new player, no schema change, no server call.
- **Verification reality:** macOS UI is TCC-blocked from automated idb screenshotting and the sim can't drive AppKit menu-bar/dock/window-restoration — so **the primary verification is the human Mac checklist** (Task 6). Build + unit-test the testable LOGIC (command enablement, table sort/columns model, dock-menu model, restoration keys); the ACTUAL Mac UX is device-verified. Each task notes its human-verify items.
- **Guardrails from prior Mac bugs (memory):** NavigationSplitView detail-column `navigationDestination` stays INSIDE the column NavigationStack; `.sheet` gets `#if os(macOS) .frame(...)`; the `.commands` closure can't hold `@Environment(\.openWindow)` directly (use a child `View`, as `ShowPlayerButton` does).

## File Structure (M3 new/changed)

```
App/ColophonApp.swift                              MOD  MenuBarExtra scene; NSApplicationDelegateAdaptor for the dock menu; window restoration ids; mini-player Window scene; full .commands
App/Mac/MacCommands.swift                          NEW  the full Playback + View + Go command menus (Mac), wired to AppState/PlayerModel with enablement
App/Mac/MenuBarExtraView.swift                     NEW  menu-bar now-playing extra (cover/title/chapter/progress + transport + Show Player / Open)
App/Mac/MiniPlayerWindow.swift                     NEW  compact mini-player Window scene + view (cover, title, transport, scrubber) — small footprint
App/Mac/LibraryTableView.swift                     NEW  Table (title/author/narrator/duration/progress columns, sortable, selection) toggled with the grid; feeds the inspector
App/Mac/AppDelegate.swift (or in ColophonApp)      NEW  NSApplicationDelegate.applicationDockMenu(_:) → now-playing controls + recents
App/Views/{LibraryGridView, ItemDetailView, SplitShell}.swift  MOD  grid⇄table toggle (View menu / a toolbar control); .inspector(detail) on the Mac; drag-and-drop hooks
App/Player/QueueView.swift                         MOD  drag-and-drop into/within the queue on Mac (already .onMove — add drop)
docs/superpowers/m3-mac-human-verification.md      NEW  the Mac device checklist (the real verification surface)
```

---

### Task 1: Full Mac menu command set

**Files:** Create `App/Mac/MacCommands.swift`; `App/ColophonApp.swift` (`.commands`); consolidate the M1c-b `PlaybackCommands` + `SplitShell`'s "Playback" `CommandMenu`.

Round out the native Mac menu bar into a proper command set, wired to `AppState`/`PlayerModel`, each item ENABLED only when valid (a session exists / a chapter list exists / etc.):
- **Playback menu:** Play/Pause (⌘P or the space-in-window that exists), Skip Forward / Backward (the configured interval, ⌘→ / ⌘← or ⌥ variants — avoid clashing with the existing chapter ⌥⌘←/→ from M1c-b), Next/Previous Chapter (keep ⌥⌘←/→), a Chapters submenu (jump to chapter), Increase/Decrease/Reset Speed (keep ⇧⌘,/.), a Sleep Timer submenu (off/presets/end-of-chapter), Add Bookmark (⌘D?), Mark as Finished, Show Player (⌘0, exists).
- **View menu:** Library as Grid / Table (⌘1/⌘2 — feeds Task 3's toggle via a shared `@AppStorage`/AppState flag), Toggle Sidebar (system), Toggle Inspector (Task 3).
- **Go menu (optional):** Home / Library / Search / Downloads.
Keep the `.commands`-can't-hold-`openWindow` rule (child `View` buttons). Standard app/File/Edit/Window/Help menus stay system-default. Put the ENABLEMENT + action logic behind testable helpers where possible (a command-state model over AppState) so it's unit-testable without a menu host.

- [ ] Build ALL platforms (Mac gains the menus; iOS unaffected — the `.commands` are macOS-scoped). Unit-test the command-enablement logic (e.g. `MacCommandState`: play/pause enabled only with a session; chapters only with chapters; sleep-timer reflects state). Human-verify the actual menu bar (Task 6). Commit `feat(mac): full playback + view command menus`.

---

### Task 2: Menu-bar now-playing extra

**Files:** Create `App/Mac/MenuBarExtraView.swift`; `App/ColophonApp.swift` (`MenuBarExtra` scene).

A `MenuBarExtra` (Mac menu bar) now-playing item: a compact popover/menu showing the current book (cover thumbnail, title, chapter, a progress bar) + transport (play/pause, skip ±, prev/next chapter) + "Show Player" (opens the Now Playing window) + "Open Colophon". Reflects `nowPlayingItemID`/isPlaying/progress live (reuse the `PlayerModel` or the now-playing snapshot). When nothing's playing, a minimal state ("Colophon — nothing playing" + Open). Choose `.menuBarExtraStyle(.window)` (a rich mini view) vs `.menu` — `.window` for the cover+scrubber. It should be unobtrusive + not duplicate the dock. Consider a Settings toggle to show/hide the menu-bar extra (default on) — or always-on; document the choice.

- [ ] Build all platforms (MenuBarExtra is macOS-only). Human-verify the menu-bar extra (Task 6 — the primary surface). If a testable view-model exists (now-playing → menu-bar content), unit-test it. Commit `feat(mac): menu-bar now-playing extra`.

---

### Task 3: Library Table view + inspector

**Files:** Create `App/Mac/LibraryTableView.swift`; modify `App/Views/LibraryGridView.swift` (grid⇄table toggle), `App/Shell/SplitShell.swift` (`.inspector`), `App/ColophonApp.swift`/View menu (from Task 1).

The Mac-native browse alternative:
- **`Table`** of the library: sortable `TableColumn`s — cover (small), Title, Author, Narrator, Duration, Progress (a bar/%), maybe Added. `@State` sort order (`KeyPathComparator`), row selection (single). Double-click / Return → open the item (existing route) or play. Reuse the cached items (the same source as the grid). Toggled with the grid via the Task-1 View-menu `⌘1/⌘2` + a toolbar control; the choice persists (`@AppStorage`).
- **`.inspector`** — a trailing inspector panel showing the selected row's detail (cover, metadata, description via `HTMLText`, chapters, actions) so a user can browse the table + inspect without leaving. Toggle via the View menu (Task 1) + the toolbar.
This is the headline Mac-native feature. Keep the grid the default; the Table is the power-user/Mac-idiomatic mode. iOS unaffected (Table is Mac-only here; iOS keeps the grid).

- [ ] Build all platforms (Table/inspector `#if os(macOS)`; iOS keeps the grid). Unit-test the table model (sort comparators produce the right order; the column→value mapping; the selection→inspector item). Human-verify the Table interaction + inspector + sort + double-click (Task 6). Commit `feat(mac): library Table view + inspector`.

---

### Task 4: Mini-player window

**Files:** Create `App/Mac/MiniPlayerWindow.swift`; `App/ColophonApp.swift` (a `Window` scene + `openWindow` affordance + a menu item).

A COMPACT mini-player `Window` (distinct from the full "Now Playing" window) — a small always-available now-playing surface: cover, title/chapter, a scrubber, play/pause + skip, small footprint (fixed compact size, resizable-min). Opened via a menu item (View or Window menu) / a transport affordance / a keyboard shortcut; single instance. Reuses `PlayerModel`/the transport. The full player Window stays; the mini-player is the "keep it in a corner while I work" surface (Music's MiniPlayer idiom). Consider `.windowResizability(.contentSize)` + a sensible default frame + `.defaultPosition`.

- [ ] Build all platforms (Window scene macOS-only). Human-verify the mini-player window (Task 6). Commit `feat(mac): compact mini-player window`.

---

### Task 5: Dock menu + drag-and-drop + window-restoration + keyboard-nav audit

**Files:** Create `App/Mac/AppDelegate.swift` (or fold into ColophonApp) with `NSApplicationDelegateAdaptor`; modify `App/Player/QueueView.swift` (drop), `App/Views/*` (draggable), `App/ColophonApp.swift` (restoration ids).

The remaining flagship polish (a grab-bag of smaller Mac niceties):
- **Dock menu:** `NSApplicationDelegate.applicationDockMenu(_:)` → now-playing controls (Play/Pause, Skip ±, Next/Prev Chapter) + a few Recents (continue-listening items → open/play). Build the menu from AppState; a testable `dockMenuModel`.
- **Drag-and-drop:** drag a book (cover/row) to the queue to enqueue it (`draggable(itemID)` on covers/rows + `dropDestination` on `QueueView`); the queue already reorders via `.onMove` — ensure Mac drag reorder works. Keep it conservative (enqueue on drop; no destructive drags).
- **Window restoration audit:** ensure the main window + the player/mini-player windows restore on relaunch (scene `id`s stable, `@SceneStorage` where useful for the selected library/mode/inspector); audit that reopening lands the user where they were (the active connection auto-resumes already). Document what restores.
- **Keyboard-navigation audit:** verify/curate full keyboard nav — tab order, arrow-key nav in the sidebar/grid/table, Return/Space actions, the command shortcuts don't clash, focus rings visible. Fix gaps; document the keyboard map.

- [ ] Build all platforms (AppKit dock/delegate macOS-only; drag-drop cross-platform but scoped). Unit-test the dockMenuModel (now-playing + recents) + the drop→enqueue logic. Human-verify dock menu / drag-drop / restoration / keyboard nav (Task 6 — all device-only). Commit `feat(mac): dock menu + drag-and-drop + restoration + keyboard-nav`.

---

### Task 6: Wrap-up + human-verification + final review

**Files:** `README.md`; `docs/superpowers/m3-mac-human-verification.md`; contract-block refresh.

- [ ] README → M3 reality (native Mac: full menus, menu-bar extra, mini-player window, Table/inspector browse, dock menu, drag-and-drop, restoration, keyboard nav). Human-verification checklist — THE primary M3 verification (all Mac device-only): every menu item works + is enabled/disabled correctly; the menu-bar extra shows now-playing + controls it; the mini-player window; the Table view + sort + double-click + inspector + grid⇄table toggle (⌘1/⌘2); the dock menu; drag-a-book-to-queue; window restoration on relaunch; keyboard-only navigation of the whole app; no clashing shortcuts. Full cold-start sweep `make test && make test-app && make build-ios && make build-mac` green, zero warnings. Commit `docs: M3 status`. Then the whole-branch adversarial review before merge.

---

## Self-review notes (plan-writing time)

- **Coverage vs spec §9 M3:** menu bar extra (T2), mini-player window (T4), full command set (T1), Table/inspector (T3), dock menu (T5), drag-and-drop (T5), window-restoration audit (T5), keyboard-nav audit (T5). (Spec also lists "Control Center widget" under M3 — already shipped in M2b's `PlayPauseControlWidget`; note it as done.)
- **Additive + gated:** every surface is `#if os(macOS)` on top of the existing SplitShell/player/commands; iOS + the other platforms stay green (each task builds all platforms). No forked player, no schema change.
- **Verification reality baked in:** the plan states up front that macOS UI is the human-verification surface (TCC/sim limits); each task builds + unit-tests the testable LOGIC (command enablement, table sort model, dock-menu model, restoration keys) and defers the actual Mac UX to the Task-6 checklist + the user's Mac.
- **Prior-Mac-bug guardrails** in Global Constraints (nav-destination-inside-stack, sheet-frame, openWindow-in-a-child-View) so M3 doesn't repeat M1c's real-Mac bugs.
- **Deferred beyond M3:** CarPlay (pending entitlement); tvOS/visionOS (M4); watchOS (M5); AppleScript/MCP-on-Mac (post-v1, spec §deferred).
