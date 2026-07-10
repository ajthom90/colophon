import ColophonShared
import SwiftUI
import UIKit
import WidgetKit

/// The continue-listening home-screen widget (M2b Task 2): shows the most-recent in-progress
/// book(s) from `ContinueListeningSnapshot`, the App-Group snapshot `AppState.
/// publishContinueListeningSnapshot` writes after every Home shelf load. `.systemSmall` shows the
/// single most-recent item (cover + progress ring); `.systemMedium` shows up to
/// `ContinueListeningSnapshot.maxWidgetDisplayCount` (3). Tapping a row deep-links straight to that
/// book/episode via `ColophonDeepLink` — the SAME grammar the app's `onOpenURL` routing parses.
struct ContinueListeningWidget: Widget {
    static let kind = "ContinueListeningWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ContinueListeningProvider()) { entry in
            ContinueListeningWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Continue Listening")
        .description("Jump back into your most recent book or episode.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    let items: [ContinueListeningWidgetItem]
    /// Mirrors the app's `@AppStorage("colophon.typeface")` (`ColophonApp.swift`,
    /// `SharedStore.writeTypefacePreference`) so the widget's text matches the app's serif/default
    /// typography choice.
    let typeface: String
}

struct ContinueListeningProvider: TimelineProvider {
    private let store = SharedStore(appGroupID: ColophonAppGroup.identifier)

    /// A plausible, fully-populated entry for the system placeholder. WidgetKit renders this
    /// wrapped in `.redacted(reason: .placeholder)` automatically, so the exact copy doesn't
    /// matter — only that there are enough rows to fill both families' skeleton believably.
    func placeholder(in context: Context) -> ContinueListeningEntry {
        ContinueListeningEntry(
            date: .now,
            items: [
                .init(itemID: "placeholder-1", title: "Book Title", author: "Author Name", progress: 0.4),
                .init(itemID: "placeholder-2", title: "Another Book", author: "Author Name", progress: 0.2),
                .init(itemID: "placeholder-3", title: "A Third Book", author: "Author Name", progress: 0.7),
            ],
            typeface: "serif")
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueListeningEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueListeningEntry>) -> Void) {
        // The app pushes `WidgetCenter.shared.reloadAllTimelines()` on every snapshot change
        // (`SnapshotPublisher`, M2b Task 1) — a single `.never` entry avoids burning the widget's
        // refresh budget on a poll the app already drives more precisely and promptly.
        completion(Timeline(entries: [makeEntry()], policy: .never))
    }

    private func makeEntry() -> ContinueListeningEntry {
        let snapshot = store.readContinueListening() ?? ContinueListeningSnapshot()
        return ContinueListeningEntry(
            date: .now,
            items: snapshot.widgetItems(),
            typeface: store.readTypefacePreference())
    }
}

// MARK: - Views

struct ContinueListeningWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueListeningEntry

    var body: some View {
        content
            .fontDesign(entry.typeface == "serif" ? .serif : .default)
            .containerBackground(.fill.tertiary, for: .widget)
            // A sensible DEFAULT tap target (the most-recent item); the per-row `Link`s below
            // override it within their own bounds for `.systemMedium`'s other rows.
            .widgetURL(entry.items.first?.deepLinkURL)
    }

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            switch family {
            case .systemSmall:
                ContinueListeningSmallView(item: first)
            default:
                ContinueListeningMediumView(items: Array(entry.items.prefix(ContinueListeningSnapshot.maxWidgetDisplayCount)))
            }
        } else {
            ContinueListeningEmptyView()
        }
    }
}

/// `.systemSmall`: one cover with a progress ring in the corner, title, author — the Apple
/// Podcasts/Books "Up Next" tile shape.
private struct ContinueListeningSmallView: View {
    let item: ContinueListeningWidgetItem

    var body: some View {
        Link(destination: item.deepLinkURL) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    ContinueListeningCoverView(relativePath: item.artworkThumbnailPath)
                        .aspectRatio(1, contentMode: .fit)
                    ContinueListeningProgressRing(progress: item.progress)
                        .frame(width: 24, height: 24)
                        .padding(4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(item.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// `.systemMedium`: up to `maxWidgetDisplayCount` rows, each its OWN tap target — cover thumbnail,
/// title/author, and a progress bar.
private struct ContinueListeningMediumView: View {
    let items: [ContinueListeningWidgetItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Listening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                ContinueListeningRow(item: item)
            }
        }
    }
}

private struct ContinueListeningRow: View {
    let item: ContinueListeningWidgetItem

    var body: some View {
        Link(destination: item.deepLinkURL) {
            HStack(spacing: 10) {
                ContinueListeningCoverView(relativePath: item.artworkThumbnailPath)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(item.author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: min(max(item.progress, 0), 1))
                        .tint(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The "nothing in progress" empty state — a gentle prompt rather than a blank tile.
private struct ContinueListeningEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Nothing in progress")
                .font(.subheadline.weight(.semibold))
            Text("Start a book to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A simple circular progress indicator — the "ring" the Apple Podcasts/Books "Up Next" widget
/// draws over the corner of the cover.
private struct ContinueListeningProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().fill(.background)
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, min(progress, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Renders the thumbnail `AppState.publishContinueListeningSnapshot` wrote into the App Group
/// container (a local file read — no network from the widget process), or a placeholder glyph
/// when there isn't one yet (a fresh install, or a cover fetch that failed/hasn't landed).
private struct ContinueListeningCoverView: View {
    let relativePath: String?
    private static let store = SharedStore(appGroupID: ColophonAppGroup.identifier)

    var body: some View {
        Group {
            if let relativePath, let data = Self.store.readArtwork(atRelativePath: relativePath),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.fill.tertiary)
                    .overlay(
                        Image(systemName: "book.closed")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
