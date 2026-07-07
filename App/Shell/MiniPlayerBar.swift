import SwiftUI
import PlayerEngine

/// A live session worth showing transport for. Mirrors `PlayerBarView`'s existing gate.
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

/// The transport control cluster — the ONE Liquid Glass element on the docked transport / full
/// player. A single tinted `.glassProminent` primary (play/pause) plus `.glass` skip buttons,
/// clustered in ONE `GlassEffectContainer`. Labels are forced back to SF (`.fontDesign(.default)`)
/// so the root serif toggle never reaches the controls.
///
/// NOTE: this cluster is used on surfaces whose background is a plain material or opaque content
/// (the Mac/iPad `TransportBar`, the `FullPlayerSheet`) — NOT inside the iPhone tab-bar bottom
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

    var body: some View {
        let playback = app.playback
        if hasActiveSession(playback) {
            HStack(spacing: 14) {
                NowPlayingArtwork(side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.title).font(.headline).lineLimit(1)
                    if !playback.author.isEmpty {
                        Text(playback.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(hms(playback.globalTime))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .fontDesign(.default)
                TransportControls(playback: playback)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

/// A minimal full-player stub presented when the iPhone mini-bar is tapped. The real player
/// (chapters, sleep timer, bookmarks, per-book speed, queue) is M1c-b; this shows the current
/// item's artwork, serif title/author, a scrubber, elapsed/total time, and the transport cluster.
struct FullPlayerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let playback = app.playback
        VStack(spacing: 24) {
            NowPlayingArtwork(side: 240)
                .shadow(radius: 12, y: 6)
            VStack(spacing: 6) {
                Text(playback.title)
                    .font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                if !playback.author.isEmpty {
                    Text(playback.author)
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                }
            }
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { playback.globalTime },
                                   set: { playback.seek(toGlobal: $0) }),
                    in: 0...max(playback.totalDuration, 1))
                HStack {
                    Text(hms(playback.globalTime)).monospacedDigit()
                    Spacer()
                    Text(hms(playback.totalDuration)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary).fontDesign(.default)
            }
            TransportControls(playback: playback)
                .controlSize(.large)
            Spacer()
        }
        .padding(24)
        .presentationDragIndicator(.visible)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3)
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
