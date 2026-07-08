import SwiftUI
import ABSKit

/// The full-screen audiobook player — the emotional center of the app. Native and opaque
/// throughout, with Liquid Glass confined to the ONE transport cluster (`TransportControls`:
/// a single tinted `.glassProminent` play/pause plus `.glass` skips, in one `GlassEffectContainer`).
///
/// Layout (a `ZStack`):
///   (a) an immersive backdrop — the cover art, scaled to fill and blurred into the safe area via
///       `.backgroundExtensionEffect()` (mirror-blur), under a legibility scrim;
///   (b) the opaque content column: large rounded artwork with a shadow, serif title + author,
///       a chapter-aware `Slider` over `0...duration` with the current chapter title and
///       elapsed / -remaining labels (monospaced), the glass transport row, and a "Chapters" button.
///
/// The scrubber works directly in GLOBAL book seconds (chapters are global; `PlaybackController`
/// maps global↔track internally). Dragging seeks only on release (editing-ended) to avoid thrashing
/// the player with a seek per drag tick.
///
/// Presentation is a Task-4 concern; for now the shell presents this over the mini-bar (a
/// `fullScreenCover` on iOS, a sheet elsewhere) — a deliberate stopgap so the player is viewable
/// and testable today.
struct FullPlayerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Transient scrubber state — lives here on the view, not on the (stateless) `PlayerModel`.
    /// While `scrubbing`, the slider shows `scrubTime` and the labels track it for feedback; the
    /// actual `seek` fires once, on release.
    @State private var scrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showingChapters = false
    @State private var showingBookmarks = false

    var body: some View {
        // `PlayerModel` holds no persistent state, so recreating it per body is correct — its
        // property reads hit the observed `PlaybackController`/`AppState`, so the view still
        // updates as playback ticks.
        let model = PlayerModel(app: app)
        // The time the UI should reflect right now: the drag target while scrubbing, else live.
        let displayTime = scrubbing ? scrubTime : model.currentTime
        let displayChapterTitle = PlayerModel.chapter(at: displayTime, in: model.chapters)?.title

        // The opaque content column defines the layout (constrained to the safe area), and the
        // immersive `backdrop` is drawn BEHIND it via `.background` — NOT as a `ZStack` sibling. A
        // sibling backdrop with `.backgroundExtensionEffect()` inflates the shared coordinate space
        // (the effect reports an enlarged ideal size), which pushed the leading-aligned dismiss
        // chevron and the full-width scrubber off-screen (verified live: a11y chevron x = -172,
        // slider width 722 on a 402pt screen). As a `.background`, the backdrop fills behind the
        // content (it ignores the safe area itself) without dictating the content's size.
        VStack(spacing: 0) {
            dismissBar
            Spacer(minLength: 8)
            artwork(model: model)
                .padding(.horizontal, 32)
            Spacer(minLength: 20)
            titleBlock(model: model)
                .padding(.horizontal, 32)
            Spacer(minLength: 20)
            scrubber(model: model, displayTime: displayTime, chapterTitle: displayChapterTitle)
                .padding(.horizontal, 28)
            Spacer(minLength: 22)
            TransportControls(playback: model.playback)
                .controlSize(.large)
            secondaryControls(model: model)
            Spacer(minLength: 12)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { backdrop }
        .sheet(isPresented: $showingChapters) {
            ChapterListView()
        }
    }

    // MARK: - Backdrop (immersive mirror-blur cover)

    @ViewBuilder
    private var backdrop: some View {
        Group {
            if let id = app.nowPlayingItemID {
                CachedCoverView(itemID: id, updatedAt: nil)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .blur(radius: 60)
        .backgroundExtensionEffect()
        .overlay(scrim)
        .ignoresSafeArea()
    }

    /// A dark, slightly graded scrim so the opaque foreground stays legible over any cover.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.35), .black.opacity(0.55)],
            startPoint: .top, endPoint: .bottom)
        .background(.ultraThinMaterial)
    }

    // MARK: - Dismiss bar

    private var dismissBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fontDesign(.default)
            .accessibilityLabel("Close Player")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Artwork (opaque)

    @ViewBuilder
    private func artwork(model: PlayerModel) -> some View {
        Group {
            if let id = app.nowPlayingItemID {
                CachedCoverView(itemID: id, updatedAt: nil)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(maxWidth: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
    }

    // MARK: - Title / author (opaque, serif via the app-wide fontDesign)

    private func titleBlock(model: PlayerModel) -> some View {
        VStack(spacing: 6) {
            Text(model.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(.white)
            if !model.author.isEmpty {
                Text(model.author)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chapter-aware scrubber (opaque)

    private func scrubber(model: PlayerModel, displayTime: Double, chapterTitle: String?) -> some View {
        VStack(spacing: 6) {
            if let chapterTitle, !chapterTitle.isEmpty {
                Text(chapterTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubTime : model.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        // Seed the drag from the live position so there's no jump on grab.
                        scrubTime = model.currentTime
                        scrubbing = true
                    } else {
                        model.seek(toGlobal: scrubTime)
                        scrubbing = false
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(PlayerModel.timeString(displayTime))
                Spacer()
                Text("-" + PlayerModel.timeString(max(model.duration - displayTime, 0)))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
            .fontDesign(.default)
        }
    }

    // MARK: - Secondary controls (sleep timer + bookmarks + speed + Chapters; queue lands in Task 8)

    private func secondaryControls(model: PlayerModel) -> some View {
        VStack(spacing: 14) {
            // The shared secondary glass cluster. Task 5 adds the sleep timer; bookmarks (T6) and
            // speed (T7) join it here; up-next queue (T8) joins this same `GlassEffectContainer` as
            // a further `.buttonStyle(.glass)` member — one cluster, never glass-on-glass.
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    SleepTimerView(timer: app.sleepTimer, hasChapters: !model.chapters.isEmpty)
                    bookmarkButton
                    SpeedControl(model: model)
                }
            }
            .controlSize(.large)

            // Chapters affordance (Task 3) — opaque text, not part of the glass cluster.
            Button {
                showingChapters = true
            } label: {
                Label("Chapters", systemImage: "list.bullet")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .fontDesign(.default)
            .disabled(model.chapters.isEmpty)
            .opacity(model.chapters.isEmpty ? 0 : 1)
            .accessibilityLabel("Show Chapters")
        }
        .padding(.top, 18)
    }

    /// The bookmark control — a `.buttonStyle(.glass)` member of the secondary cluster (NOT its own
    /// glass surface), opening the native `BookmarksView` sheet (list + create-at-current-time).
    ///
    /// The bookmarks sheet is attached HERE (on the button), not on the root `VStack`, on purpose:
    /// the Chapters sheet already lives on the root view, and two `.sheet(isPresented:)` modifiers on
    /// the SAME view conflict — only the first presents (verified live via idb: the second tap was a
    /// no-op). Hanging this sheet off a distinct subview lets both present independently.
    private var bookmarkButton: some View {
        Button {
            showingBookmarks = true
        } label: {
            Image(systemName: "bookmark")
        }
        .buttonStyle(.glass)
        .fontDesign(.default)
        .accessibilityLabel("Bookmarks")
        .sheet(isPresented: $showingBookmarks) {
            BookmarksView()
        }
    }
}
