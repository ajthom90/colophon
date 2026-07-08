import SwiftUI
import PlayerEngine

/// A live session worth showing transport for. Mirrors the legacy `PlayerBarView`'s gate
/// (removed in M1c-a wrap-up once the shell's own transport superseded it).
private func hasActiveSession(_ playback: PlaybackController) -> Bool {
    playback.totalDuration > 0
}

/// h:mm:ss for the monospaced-digit time labels.
private func hms(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

/// Square cover artwork for the now-playing item — OPAQUE content (never glass). Reuses the
/// existing `CachedCoverView` (disk-cached, survives disconnects); a placeholder before the item's
/// cover has loaded or when nothing is playing.
private struct NowPlayingArtwork: View {
    @Environment(AppState.self) private var app
    let side: CGFloat

    var body: some View {
        Group {
            if let id = app.nowPlayingItemID {
                CachedCoverView(itemID: id, updatedAt: nil)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The transport control cluster — the primary glass group on the docked transport / full player:
/// a single tinted `.glassProminent` primary (play/pause) plus `.glass` skip buttons, clustered in
/// ONE `GlassEffectContainer`. (The docked `TransportBar` also carries a couple of standalone
/// `.glass` secondary buttons — bookmarks, expand — alongside this cluster; that's still one
/// prominent control per surface and no glass-on-glass, since the bar's own background is a plain
/// material.) Labels are forced back to SF (`.fontDesign(.default)`) so the root serif toggle never
/// reaches the controls.
///
/// NOTE: this cluster is used on surfaces whose background is a plain material or opaque content
/// (the Mac/iPad `TransportBar`, the `FullPlayerView`) — NOT inside the iPhone tab-bar bottom
/// accessory, which is itself system glass (glass-on-glass there would be a review violation; the
/// `MiniPlayerBar` uses a plain button instead).
struct TransportControls: View {
    let playback: PlaybackController

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    playback.skip(-Double(playback.skipInterval))
                } label: {
                    Image(systemName: "gobackward.\(playback.skipInterval)")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Skip back")

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Button {
                    playback.skip(Double(playback.skipInterval))
                } label: {
                    Image(systemName: "goforward.\(playback.skipInterval)")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Skip forward")
            }
        }
        .labelStyle(.iconOnly)
        .fontDesign(.default)
    }
}

/// iPhone now-playing bar for the tab bar's bottom accessory (`tabViewBottomAccessory`). OPAQUE
/// content row: artwork + serif title/author. The accessory itself is system Liquid Glass and
/// shares the tab-bar glass, so the play/pause control here is a PLAIN button — a `.glass` button
/// on the glass accessory would be glass-on-glass (a review-criterion violation). Tapping the bar
/// presents the (stub) full player.
struct MiniPlayerBar: View {
    @Environment(AppState.self) private var app
    var onExpand: () -> Void = {}

    var body: some View {
        let playback = app.playback
        if hasActiveSession(playback) {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    NowPlayingArtwork(side: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playback.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !playback.author.isEmpty {
                            Text(playback.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fontDesign(.default)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Mac & iPad docked transport, placed via `.safeAreaInset(edge: .bottom)` — a full-width bottom
/// bar on a plain `.bar` material, explicitly NOT a floating Music-app-style player, and NOT
/// system glass (so the glass control cluster it hosts is not glass-on-glass). OPAQUE content row
/// (artwork, serif title/author, monospaced elapsed time) plus the `TransportControls` glass
/// cluster. Shown only while a session is active.
struct TransportBar: View {
    @Environment(AppState.self) private var app
    /// The expand affordance: tapping the now-playing artwork/title (or the explicit expand button)
    /// opens the full player — a large detented sheet on iPad, the dedicated player Window on Mac
    /// (wired by `SplitShell`).
    var onExpand: () -> Void = {}
    /// Presents the shared `BookmarksView` (its list + create-at-current-time "+") straight from the
    /// docked bar, so Mac/iPad users reach bookmarks without first opening the Now Playing window.
    @State private var showingBookmarks = false

    var body: some View {
        let playback = app.playback
        if hasActiveSession(playback) {
            HStack(spacing: 14) {
                // The leading info region is the expand affordance (Task 4). A plain button so it
                // reads as opaque content, never glass; the glass stays on `TransportControls`.
                Button(action: onExpand) {
                    HStack(spacing: 14) {
                        NowPlayingArtwork(side: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playback.title).font(.headline).lineLimit(1)
                            if !playback.author.isEmpty {
                                Text(playback.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Player")
                Text(hms(playback.globalTime))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .fontDesign(.default)
                TransportControls(playback: playback)
                // Bookmark quick-access: the SAME `BookmarksView` the full player uses (list + its
                // create-at-current-time "+"), presented as a sheet so it doesn't require opening the
                // whole Now Playing window. A `.glass` SECONDARY control (never a second prominent —
                // the one tinted `.glassProminent` stays play/pause in `TransportControls`); the bar
                // renders only for an active session, so this is inherently session-gated.
                Button {
                    showingBookmarks = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.glass)
                .fontDesign(.default)
                .help("Bookmarks")
                .accessibilityLabel("Bookmarks")
                .sheet(isPresented: $showingBookmarks) {
                    BookmarksView()
                }
                // Visible expand affordance — the Mac docked bar previously had NO visible cue (only
                // the unlabeled artwork/title tap), so the full player (chapters, bookmarks, speed,
                // sleep timer, queue) was undiscoverable. This `.glass` secondary button opens the
                // Now Playing window (Mac) / full-player sheet (iPad); `.help` gives the macOS tooltip.
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .fontDesign(.default)
                .help("Open Now Playing")
                .accessibilityLabel("Open Now Playing")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            // A visible hairline above the bar so the docked transport reads as a distinct chrome
            // strip against the content, not a subtle material blend into the window.
            .overlay(alignment: .top) { Divider() }
        }
    }
}

// The full player (`FullPlayerView`) — artwork, serif title/author, a chapter-aware scrubber,
// the glass transport cluster, and a chapter list — now lives in `App/Player/`. Tapping this
// mini-bar presents it per-platform (see `PlayerPresentation.swift`: `iPhonePlayerCover` on
// iPhone, `iPadPlayerSheet` on iPad, a dedicated Mac `Window` via `PlayerWindowScene`).
