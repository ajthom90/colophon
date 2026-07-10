#if os(iOS)
import ActivityKit
import AppIntents
import ColophonShared
import SwiftUI
import UIKit
import WidgetKit

/// The now-playing Live Activity (M2b Task 4) — a Lock Screen banner + Dynamic Island following the
/// Apple Podcasts / Music now-playing conventions: opaque cover, title, chapter, a progress bar, and
/// play/pause + skip transport. The transport buttons invoke the shared App Intents (M2b Task 3)
/// (`TogglePlaybackIntent` / `SkipBackwardIntent` / `SkipForwardIntent`), which route to the running
/// app's live `PlaybackController`. iOS-only; registered in `ColophonWidgetsBundle`.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            NowPlayingLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
                // Tapping the banner body (outside the transport buttons) OPENS the now-playing item —
                // the native Music / Podcasts idiom (a body tap navigates; the transport buttons own
                // play/pause). NOT `resume`, which would just toggle playback / no-op for the item that
                // is already loaded (M2b review #2). The transport buttons still own play/pause/skip.
                .widgetURL(ColophonDeepLink.item(
                    id: context.attributes.itemID, episodeID: context.attributes.episodeID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NowPlayingCover(relativePath: context.state.artworkThumbnailPath)
                        .frame(width: 44, height: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NowPlayingElapsed(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.chapterTitle ?? context.attributes.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        NowPlayingProgressBar(state: context.state)
                        NowPlayingTransport(isPlaying: context.state.isPlaying)
                    }
                }
            } compactLeading: {
                NowPlayingCover(relativePath: context.state.artworkThumbnailPath)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.white)
            }
            // A body tap OPENS the now-playing item (native Music/Podcasts idiom), NOT `resume` — the
            // transport buttons own play/pause (M2b review #2).
            .widgetURL(ColophonDeepLink.item(
                id: context.attributes.itemID, episodeID: context.attributes.episodeID).url)
        }
    }
}

// MARK: - Lock Screen

/// The Lock Screen / banner presentation: cover, title + chapter, progress bar, transport row.
private struct NowPlayingLockScreenView: View {
    let attributes: NowPlayingActivityAttributes
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            NowPlayingCover(relativePath: state.artworkThumbnailPath)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.chapterTitle ?? attributes.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                NowPlayingProgressBar(state: state)
            }
            NowPlayingTransport(isPlaying: state.isPlaying)
        }
        .padding()
        .foregroundStyle(.white)
    }
}

// MARK: - Self-advancing elapsed + progress (M2b review #3)

/// The elapsed-time label. While PLAYING it renders ActivityKit's SELF-ADVANCING `Text(timerInterval:)`
/// — the system counts it up on-device from the position anchor with NO app updates (the app publishes
/// only on discrete transitions, so a static value would otherwise FREEZE between them). While PAUSED it
/// shows the static elapsed value.
///
/// RATE CAVEAT: `timerInterval` advances in REAL wall-clock time, so the label is exact at **1× speed**
/// and an APPROXIMATION at other playback speeds. That's acceptable — the app re-anchors it (pushes a
/// fresh update) on every pause / seek / chapter transition, so the drift is bounded and self-correcting.
private struct NowPlayingElapsed: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPlaying, let range = state.timerRange {
                Text(timerInterval: range, countsDown: false)
            } else {
                Text(NowPlayingTime.string(state.elapsed))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// The progress bar. While PLAYING it renders ActivityKit's SELF-ADVANCING `ProgressView(timerInterval:)`
/// (fills on-device from the anchor, no per-tick app pushes; labels suppressed so it reads as a bare
/// bar); while PAUSED it shows the static fraction. Same 1×-exact / other-speeds-approximate caveat as
/// `NowPlayingElapsed`.
private struct NowPlayingProgressBar: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPlaying, let range = state.timerRange {
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: state.progress.clampedUnit)
            }
        }
        .tint(.white)
    }
}

private extension NowPlayingActivityAttributes.ContentState {
    /// The wall-clock range the self-advancing timer/progress advance across: `anchor ... anchor +
    /// duration`, where `anchor = updatedAt - elapsed` is the instant the book's position-0 corresponds
    /// to. `nil` (→ the static fallback) when the duration is unknown or the position is already at/past
    /// the end, so `Text`/`ProgressView(timerInterval:)` always get a valid, non-empty forward range.
    var timerRange: ClosedRange<Date>? {
        guard duration > 0, elapsed >= 0, elapsed < duration else { return nil }
        let start = updatedAt.addingTimeInterval(-elapsed)
        let end = start.addingTimeInterval(duration)
        guard start < end else { return nil }
        return start...end
    }
}

// MARK: - Transport (buttons → the shared T3 App Intents)

/// Skip-back / play-pause / skip-forward, each firing a shared playback App Intent that reaches the
/// running app's `PlaybackController`.
private struct NowPlayingTransport: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 20) {
            Button(intent: SkipBackwardIntent()) {
                Image(systemName: "gobackward")
            }
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button(intent: SkipForwardIntent()) {
                Image(systemName: "goforward")
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .tint(.white)
    }
}

// MARK: - Cover

/// Renders the App-Group cover thumbnail the app wrote (a local file read — no network from the
/// extension), or an opaque placeholder glyph when there isn't one yet.
private struct NowPlayingCover: View {
    let relativePath: String?
    private static let store = SharedStore(appGroupID: ColophonAppGroup.identifier)

    var body: some View {
        Group {
            if let relativePath, let data = Self.store.readArtwork(atRelativePath: relativePath),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.gray.opacity(0.4))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.white.opacity(0.8)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Helpers

private enum NowPlayingTime {
    /// `H:MM:SS` (or `M:SS`) for an elapsed-seconds label, monospaced-digit friendly.
    static func string(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private extension Double {
    /// Clamp to `0...1` for `ProgressView` (a malformed snapshot never traps or overdraws).
    var clampedUnit: Double { Swift.min(Swift.max(self, 0), 1) }
}
#endif
