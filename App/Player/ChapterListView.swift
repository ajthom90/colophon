import SwiftUI
import ABSKit

/// The now-playing chapter list, presented as a `[.medium, .large]` sheet from `FullPlayerView`.
/// Opaque rows (never glass): each chapter's title + start time (`.monospacedDigit()`), with the
/// currently-playing chapter highlighted (a filled play indicator + tinted title). Tapping a
/// chapter seeks the shared `PlaybackController` to that chapter's global start and dismisses, so
/// the player reflects the new chapter immediately.
///
/// Reads chapters and the live position from `AppState` via a recreated-per-body `PlayerModel`
/// (which holds no state); the current-chapter highlight tracks playback while the sheet is open.
struct ChapterListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = PlayerModel(app: app)
        let currentID = model.currentChapter?.id
        NavigationStack {
            List(model.chapters) { chapter in
                Button {
                    model.seekToChapter(chapter)
                    dismiss()
                } label: {
                    row(chapter, isCurrent: chapter.id == currentID)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Chapters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ chapter: Chapter, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "play.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .fontDesign(.default)
            Text(chapter.title ?? "Chapter \(chapter.id + 1)")
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(PlayerModel.timeString(chapter.start))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fontDesign(.default)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
