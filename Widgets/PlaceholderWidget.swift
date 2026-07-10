import SwiftUI
import WidgetKit
import ColophonShared

/// A trivial `StaticConfiguration` widget proving the extension scaffold builds + loads (M2b Task 1).
/// It reads nothing meaningful yet — Task 2 replaces it with the real continue-listening timeline
/// provider reading `ContinueListeningSnapshot` from `SharedStore(appGroupID:)`.
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ColophonPlaceholderWidget", provider: PlaceholderProvider()) { entry in
            PlaceholderWidgetView(entry: entry)
        }
        .configurationDisplayName("Colophon")
        .description("Your listening, at a glance. More widgets are on the way.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        // The app drives reloads via `WidgetCenter.reloadAllTimelines()` on snapshot change, so a
        // never-refreshing single entry is correct here.
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

struct PlaceholderWidgetView: View {
    let entry: PlaceholderEntry

    /// Confirms the extension links `ColophonShared` (Task 1 scaffold check).
    private let appGroup = ColophonAppGroup.identifier

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "books.vertical.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Colophon")
                .font(.headline)
            Text("Continue listening arrives soon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
