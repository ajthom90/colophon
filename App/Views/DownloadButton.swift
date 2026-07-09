import SwiftUI
import LibraryCache

/// A reusable download/delete affordance (M2a Task 8), bound to a single book's or podcast episode's
/// own download state. REUSES `DownloadsView`'s state semantics/`DownloadCoordinator.State` string
/// constants so this control and the Downloads tab read identically. Deliberately PLAIN — an SF
/// Symbol `Button`, `.buttonStyle(.plain)`, never glass (the UI mandate keeps Liquid Glass on
/// transport/nav chrome + the ONE `.glassProminent` Play/Resume per surface; this is always a
/// secondary affordance next to it).
///
/// State → glyph → tap action (mirrors `DownloadsView`'s row semantics exactly, so the two surfaces
/// never disagree about what a state means):
///  - no `CachedDownload` row (`.notDownloaded`) → `arrow.down.circle` → tap calls
///    `DownloadCoordinator.download(itemID:episodeID:)`.
///  - `.queued`/`.downloading` (`.inProgress`) → a small determinate progress ring (the aggregate
///    `receivedBytes`/`totalBytes`, the same fraction math as `DownloadsView.Row.fraction`) with an
///    `xmark` overlay → tap CANCELS via `DownloadCoordinator.delete` (cancels the in-flight transfer
///    and removes any partial bytes — there's no partial-keep affordance, matching `DownloadsView`'s
///    own delete).
///  - `.downloaded` → a filled green checkmark → tap DELETES via `DownloadCoordinator.delete` (no
///    confirmation — `DownloadsView`'s swipe/context-menu delete has none either, so this stays
///    consistent rather than introducing a one-off confirmation sheet — also sidesteps the macOS
///    "every new sheet needs an explicit frame" gotcha by not adding a sheet at all).
///  - `.failed` → a red retry glyph → tap RE-DOWNLOADS via `DownloadCoordinator.download` (re-derives
///    a fresh URL — the same Retry semantics `DownloadsView` offers for a `.failed` row).
///
/// **State source** — two modes, chosen by `source`:
///  - `.selfObserved` (default; `ItemDetailView`/`EpisodeDetailView`, single instances): the button
///    opens its OWN `observeDownloads` stream filtered to this `(itemID, episodeID)`. Fine for one
///    instance per screen.
///  - `.provided(CachedDownload?)` (`EpisodeRow`): the PARENT (`PodcastDetailView`) observes ALL of
///    the podcast's downloads ONCE, indexes them by `episodeID`, and passes each row its own state —
///    so an N-episode list has ONE shared `ValueObservation`, not N per-row trackers each re-querying
///    on every byte tick. The button renders straight from the provided value and never self-observes.
struct DownloadButton: View {
    @Environment(AppState.self) private var app
    let itemID: String
    /// `nil` for a book; a podcast episode ID otherwise.
    let episodeID: String?
    /// Compact sizing for `EpisodeRow`'s trailing slot vs. the roomier detail-page placement.
    var compact: Bool = false
    /// Where this button gets its download row — see the type doc. Defaults to self-observing so the
    /// single-instance detail placements are unchanged.
    var source: StateSource = .selfObserved

    @State private var observed: CachedDownload?

    /// This button's current download row: the parent-provided value in `.provided` mode, else the
    /// self-observed one.
    private var download: CachedDownload? {
        switch source {
        case .selfObserved: return observed
        case .provided(let d): return d
        }
    }

    private var episode: String { episodeID ?? "" }
    private var side: CGFloat { compact ? 20 : 28 }
    /// Stroke width of the determinate in-progress ring — proportional to the button size, floored so
    /// it stays visible at the compact (20pt) size.
    private var ringWidth: CGFloat { max(2, side * 0.1) }

    var body: some View {
        Button(action: tap) { glyph }
            .buttonStyle(.plain)
            .disabled(app.activeConnectionID == nil)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            // Self-observe ONLY in `.selfObserved` mode — `.provided` rows share the parent's one
            // observation, so opening a per-row stream here would defeat the perf fix.
            .task(id: observeKey) { if case .selfObserved = source { await observe() } }
    }

    private var observeKey: String { "\(app.activeConnectionID ?? "")|\(itemID)|\(episode)" }

    @ViewBuilder
    private var glyph: some View {
        Group {
            switch ViewState.from(download) {
            case .downloaded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: side))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: side * 0.75))
                    .foregroundStyle(.red)
            case .inProgress(let fraction):
                // A DETERMINATE ring (M2a final review #8): `ProgressView(value:).circular` IGNORES
                // the value on iOS/iPadOS and renders an indeterminate spinner, so download progress
                // was invisible. Draw the ring by hand — a faint track + an accent arc trimmed to the
                // fraction, rotated so 0% starts at 12 o'clock. Opaque/plain (never glass), matching
                // the rest of this secondary affordance.
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: ringWidth)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "xmark")
                        .font(.system(size: side * 0.32, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(ringWidth)
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: side))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
    }

    /// The STATE description only (M2a final review #9). The action instruction moved to
    /// `accessibilityHint` — baking "Double tap to…" into the label made VoiceOver double-announce
    /// it (the button trait already speaks the activation gesture).
    private var accessibilityLabel: String {
        switch ViewState.from(download) {
        case .downloaded: return "Downloaded"
        case .failed: return "Download failed"
        case .inProgress: return "Downloading"
        case .notDownloaded: return "Download"
        }
    }

    /// What activating the button DOES — VoiceOver reads this as the hint after the label + trait, so
    /// it never collides with the system's own "Double tap to activate" announcement.
    private var accessibilityHint: String {
        switch ViewState.from(download) {
        case .downloaded: return "Deletes the download"
        case .failed: return "Retries the download"
        case .inProgress: return "Cancels the download"
        case .notDownloaded: return "Downloads for offline listening"
        }
    }

    private func tap() {
        switch ViewState.from(download) {
        case .downloaded, .inProgress:
            // Route through `AppState.deleteDownload` (M2a final review #5), which retires playback
            // first if this is the item currently playing FROM LOCAL FILES — so a manual delete never
            // pulls files out from under a live `AVPlayer` (the auto-delete path already guards this).
            Task { await app.deleteDownload(itemID: itemID, episodeID: episodeID) }
        case .failed, .notDownloaded:
            Task { await app.downloads.download(itemID: itemID, episodeID: episodeID) }
        }
    }

    private func observe() async {
        observed = nil
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeDownloads(connectionID: connectionID) {
                observed = rows.first { $0.itemID == itemID && $0.episodeID == episode }
            }
        } catch {
            // Best-effort; leaves the button at its last-known state on an observation hiccup.
        }
    }
}

extension DownloadButton {
    /// Where a `DownloadButton` sources its download row — see the type doc.
    enum StateSource {
        /// The button opens its own filtered `observeDownloads` stream (single-instance placements).
        case selfObserved
        /// The parent supplies (and shares one observation for) this row (`EpisodeRow` via
        /// `PodcastDetailView`). `nil` = not downloaded.
        case provided(CachedDownload?)
    }

    /// The button's own reduced view-state, derived from an optional `CachedDownload` row — pure (no
    /// view/cache dependency), so the mapping is directly unit-testable. A `nil` row (never
    /// downloaded, or already deleted) and any state string outside the known four both fall back to
    /// `.notDownloaded` (never crashes, never strands the control on a stale glyph).
    enum ViewState: Equatable {
        case notDownloaded
        case inProgress(fraction: Double)
        case downloaded
        case failed

        static func from(_ download: CachedDownload?) -> ViewState {
            guard let download else { return .notDownloaded }
            switch download.state {
            case DownloadCoordinator.State.downloaded:
                return .downloaded
            case DownloadCoordinator.State.failed:
                return .failed
            case DownloadCoordinator.State.downloading, DownloadCoordinator.State.queued:
                guard download.totalBytes > 0 else { return .inProgress(fraction: 0) }
                let f = Double(download.receivedBytes) / Double(download.totalBytes)
                return .inProgress(fraction: min(1, max(0, f)))
            default:
                return .notDownloaded
            }
        }
    }
}

/// The compact, OPAQUE download-state badge (M2a Task 8) overlaid on a browse cover — `CoverCard`/
/// `EpisodeCard` show it only for `.downloaded`/an in-progress transfer (never `.failed`/absent, so
/// it never claims an item is offline-available when it isn't). Deliberately NOT glass: a solid-fill
/// circle behind a small glyph — exactly the "opaque, subtle" badge the UI mandate calls for (Liquid
/// Glass stays on transport/nav chrome, never browse-grid content).
struct DownloadStateBadge: View {
    /// The raw `CachedDownload.state` string (`DownloadCoordinator.State`) for this item/episode, or
    /// `nil` (not downloaded) — no badge either way for `.failed` (a failed download isn't "available
    /// offline"; `DownloadsView`/the detail page's own button already surface that error).
    let state: String?

    var body: some View {
        // Compared against `state ?? ""` (never the raw Optional) so this switches on a plain,
        // non-optional `String` — a `nil` state (never downloaded) falls into `default` exactly like
        // any other unrecognized value, with no optional-pattern-matching subtlety.
        switch state ?? "" {
        case DownloadCoordinator.State.downloaded:
            badge { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
        case DownloadCoordinator.State.downloading, DownloadCoordinator.State.queued:
            badge { ProgressView().controlSize(.mini).tint(.white) }
        default:
            EmptyView()
        }
    }

    private func badge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            // A near-opaque dark disc (not translucent glass) with a hairline ring, so the badge
            // reads clearly on any cover art — the "opaque, subtle" badge the UI mandate calls for.
            .background(Circle().fill(Color.black.opacity(0.9)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}
