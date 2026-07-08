import SwiftUI
import LibraryCache

/// One episode row in `PodcastDetailView` — OPAQUE content (never glass), à la Apple Podcasts: a
/// leading status/play glyph, the episode title, a metadata line (pubDate · duration, with
/// `.monospacedDigit()` so the numbers align), and — when the episode is partly played — an
/// in-progress bar plus a "…left" affordance. A finished episode dims its title and shows a green
/// checkmark instead of the play glyph.
///
/// The WHOLE row is the play tap target (a plain-styled `Button`); a context menu offers
/// Play / Add to Queue. The two actions are DISTINCT hooks (M1c-c Task 5): the row tap and the
/// context-menu "Play" invoke `onPlay` (real episode playback via the shared player); "Add to Queue"
/// invokes `onAddToQueue` (enqueues the episode into the up-next queue). This row deliberately does
/// NOT start playback or mutate the queue itself (no forked playback path) — it only calls back.
struct EpisodeRow: View {
    let episode: CachedEpisode
    /// The per-episode progress for THIS episode (nil = untouched), joined from `cachedProgress`.
    let progress: CachedProgress?
    /// Play THIS episode now — invoked by the row tap and the context-menu "Play".
    let onPlay: () -> Void
    /// Enqueue THIS episode into the up-next queue — invoked by the context-menu "Add to Queue".
    let onAddToQueue: () -> Void

    private var isFinished: Bool { progress?.isFinished ?? false }

    /// In-progress fraction (0 < f < 1, not finished) — needs a known duration to turn `currentTime`
    /// into one, so an episode with no duration shows no bar.
    private var fraction: Double? {
        guard !isFinished, let progress,
              let duration = episode.durationSeconds, duration > 0 else { return nil }
        let f = progress.currentTime / duration
        guard f > 0, f < 1 else { return nil }
        return f
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isFinished ? "checkmark.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isFinished ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title ?? "Untitled Episode")
                        .font(.headline)
                        .foregroundStyle(isFinished ? .secondary : .primary)
                        .lineLimit(2)

                    if !metaText.isEmpty {
                        Text(metaText)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fontDesign(.default)
                    }

                    if let fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
            Button(action: onAddToQueue) { Label("Add to Queue", systemImage: "text.append") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "Jul 8, 2026 · 42m" (untouched/finished) or "Jul 8, 2026 · 12m left" (in progress).
    private var metaText: String {
        [Self.formattedDate(episode), trailingTime].compactMap { $0 }.joined(separator: " · ")
    }

    /// The "…left" remaining string while in progress, otherwise the total duration — reusing
    /// `ItemDetailView.compactDuration` so episodes and books format identically.
    private var trailingTime: String? {
        if let progress, !isFinished, let duration = episode.durationSeconds, duration > 0,
           progress.currentTime > 0, progress.currentTime < duration,
           let remaining = ItemDetailView.compactDuration(duration - progress.currentTime) {
            return "\(remaining) left"
        }
        if let duration = episode.durationSeconds {
            return ItemDetailView.compactDuration(duration)
        }
        return nil
    }

    /// The episode's publish date, formatted from `publishedAt` (epoch ms) when present, else the
    /// raw RSS `pubDate` string as a last resort.
    static func formattedDate(_ episode: CachedEpisode) -> String? {
        if let ms = episode.publishedAt {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
                .formatted(date: .abbreviated, time: .omitted)
        }
        if let raw = episode.pubDate, !raw.isEmpty { return raw }
        return nil
    }
}
