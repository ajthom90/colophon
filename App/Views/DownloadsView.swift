import SwiftUI
import Foundation
import LibraryCache

/// The Downloads tab/sidebar entry (M2a Task 7) — a native list of every downloaded/downloading
/// book and podcast episode for the ACTIVE connection, à la the iOS Podcasts/Books "Downloaded"
/// collection. Observes `LibraryCacheStore.observeDownloads(connectionID:)` LIVE (`CachedDownload`,
/// the v4 aggregate record — one row per book or per episode, `episodeID` empty for a book) and
/// joins each row's title from the already-pinned `cachedItem`/`cachedEpisode` rows:
/// `DownloadCoordinator.download` pins the item's detail (book) or its episode list (podcast)
/// BEFORE enqueuing any transfer, so a download's title/author/podcast-name is always resolvable
/// with no network, even offline.
///
/// Reachable from BOTH shells — a 4th iPhone/iPad tab (`PhoneShell`) and a Mac/iPad-split sidebar
/// entry (`SplitShell`) — this view registers its OWN `.itemDetailDestination()`/
/// `.episodeDetailDestination()` at its stack's root (the macOS nav gotcha: a `navigationDestination`
/// must live INSIDE the column's `NavigationStack`, on root content — this view IS that root
/// content in both shells, so a downloaded row's tap resolves in-column rather than dead-ending).
///
/// Liquid Glass discipline: OPAQUE content throughout (covers, rows, progress bars); the storage
/// footer is the one piece of "chrome" (a `.bar` material dock, like a mini transport), never the
/// rows/covers themselves.
///
/// **Row tap → the item's DETAIL page** (`ItemDetailRoute` for a book, `EpisodeDetailRoute` for an
/// episode) — NOT direct playback — matching `CoverCard`/`EpisodeCard`'s existing tap convention
/// everywhere else in the app (the detail page owns the Play/Resume button).
struct DownloadsView: View {
    @Environment(AppState.self) private var app

    @State private var downloads: [CachedDownload] = []
    @State private var itemsByID: [String: CachedItem] = [:]
    @State private var episodesByKey: [String: CachedEpisode] = [:]
    @State private var totalBytes = 0
    /// Distinguishes "still waiting on the first cache emission" (spinner) from "observed — there
    /// are genuinely zero downloads" (the native empty state) — `observeDownloads` emits an initial
    /// value (possibly `[]`) almost immediately, so this flips true on the very first tick.
    @State private var hasLoaded = false

    var body: some View {
        content
            .navigationTitle("Downloads")
            .itemDetailDestination()
            .episodeDetailDestination()
            .safeAreaInset(edge: .bottom) {
                if hasLoaded { storageFooter }
            }
            .task(id: app.activeConnectionID) { await observe() }
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            if hasLoaded {
                ContentUnavailableView {
                    Label("No Downloads Yet", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download a book or podcast episode to listen without a connection.")
                }
            } else {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List {
                ForEach(rows) { row in rowView(row) }
            }
        }
    }

    private var storageFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
            Text("Total storage used: \(Self.humanizeBytes(totalBytes))")
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Row

    private func rowView(_ row: Row) -> some View {
        Group {
            if row.isEpisode {
                NavigationLink(value: EpisodeDetailRoute(
                    podcastItemID: row.itemID, episodeID: row.episodeID,
                    podcastTitle: row.subtitle ?? "", updatedAt: itemsByID[row.itemID]?.updatedAt)
                ) { rowLabel(row) }
            } else {
                NavigationLink(value: ItemDetailRoute(
                    itemID: row.itemID, title: row.title, author: row.subtitle,
                    updatedAt: itemsByID[row.itemID]?.updatedAt, duration: itemsByID[row.itemID]?.duration)
                ) { rowLabel(row) }
            }
        }
        .swipeActions {
            Button(role: .destructive) { delete(row) } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            if row.state == DownloadCoordinator.State.failed {
                Button { retry(row) } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive) { delete(row) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func rowLabel(_ row: Row) -> some View {
        HStack(spacing: 12) {
            CachedCoverView(itemID: row.itemID, updatedAt: itemsByID[row.itemID]?.updatedAt)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                stateLabel(row)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The per-row state readout: a downloaded item's on-disk size, a failed item's error + inline
    /// Retry (closing the T4 carry-forward where a >1h-interrupted transfer lands `.failed` with no
    /// affordance to resume it), a queued item's plain label, or an in-flight item's progress bar +
    /// percent (from the aggregate `receivedBytes`/`totalBytes` — no per-file breakdown needed here).
    @ViewBuilder
    private func stateLabel(_ row: Row) -> some View {
        switch row.state {
        case DownloadCoordinator.State.downloaded:
            Text(Self.humanizeBytes(row.receivedBytes))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case DownloadCoordinator.State.failed:
            HStack(spacing: 8) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                Button("Retry") { retry(row) }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        case DownloadCoordinator.State.queued:
            Label("Queued", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        default:   // "downloading"
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: row.fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("\(Int((row.fraction * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: 160)
        }
    }

    // MARK: - Actions

    /// Retry a failed download — re-runs `DownloadCoordinator.download`, which re-derives a fresh
    /// download URL (the previous one's query token is ~1h-lived and may have expired, exactly the
    /// T4 carry-forward this closes) and re-enqueues every file.
    private func retry(_ row: Row) {
        Task { await app.downloads.download(itemID: row.itemID, episodeID: row.episodeID.isEmpty ? nil : row.episodeID) }
    }

    private func delete(_ row: Row) {
        Task { await app.downloads.delete(itemID: row.itemID, episodeID: row.episodeID.isEmpty ? nil : row.episodeID) }
    }

    // MARK: - Data

    /// Observes the connection's downloads live, joining in each row's title on every emission (a
    /// progress tick re-emits the same small join — cheap, synchronous SQLite reads) and refreshing
    /// the storage total alongside it, so the footer stays current as bytes land.
    private func observe() async {
        downloads = []; itemsByID = [:]; episodesByKey = [:]; totalBytes = 0; hasLoaded = false
        guard let connectionID = app.activeConnectionID else {
            hasLoaded = true
            return
        }
        do {
            for try await value in app.cache.observeDownloads(connectionID: connectionID) {
                downloads = value
                loadJoins(value, connectionID: connectionID)
                totalBytes = app.downloads.totalDownloadedBytes()
                hasLoaded = true
            }
        } catch {
            // Best-effort instant paint; an observation hiccup just leaves the list as last-known.
            hasLoaded = true
        }
    }

    /// Resolves each download's title source: a book's `CachedItem` (title/author, pinned by
    /// `DownloadCoordinator.enumerateAndPin`), or a podcast episode's `CachedEpisode` (episode
    /// title) keyed alongside its podcast's OWN `CachedItem` (show title/cover). One lookup per
    /// unique `itemID` regardless of how many of its episodes are downloaded.
    private func loadJoins(_ downloads: [CachedDownload], connectionID: String) {
        var items: [String: CachedItem] = [:]
        for itemID in Set(downloads.map(\.itemID)) {
            if let item = try? app.cache.item(connectionID: connectionID, itemID: itemID) {
                items[itemID] = item
            }
        }
        var episodes: [String: CachedEpisode] = [:]
        for itemID in Set(downloads.filter { !$0.episodeID.isEmpty }.map(\.itemID)) {
            if let list = try? app.cache.episodes(connectionID: connectionID, itemID: itemID) {
                for ep in list { episodes[itemID + "/" + ep.episodeID] = ep }
            }
        }
        itemsByID = items
        episodesByKey = episodes
    }

    /// The rows to render, in `downloads`' own order (newest-updated first, per `observeDownloads`).
    private var rows: [Row] {
        downloads.map { download in
            Self.makeRow(download, item: itemsByID[download.itemID],
                        episode: episodesByKey[download.itemID + "/" + download.episodeID])
        }
    }
}

// MARK: - Row view-model (pure, unit-tested — see `DownloadsViewTests`)

extension DownloadsView {
    /// One Downloads-tab row: a `CachedDownload` aggregate joined with its resolved title. Pure data
    /// (no view/cache dependency), so `makeRow` below is directly unit-testable.
    struct Row: Identifiable, Equatable {
        let id: String
        let itemID: String
        let episodeID: String   // "" for a book
        let isEpisode: Bool
        let title: String
        /// Author (book) or podcast/show title (episode) — `nil`/empty renders no subtitle line.
        let subtitle: String?
        let state: String
        let receivedBytes: Int
        let totalBytes: Int

        /// Downloaded-fraction for the progress bar — clamped to `[0, 1]` and 0 with an unknown/zero
        /// total, so a stale or momentarily-inconsistent byte count never produces NaN or an
        /// out-of-range `ProgressView` value.
        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
        }
    }

    /// Joins one `CachedDownload` with its already-pinned title rows. `item`/`episode` `nil` only
    /// for a download whose pinned rows were somehow evicted — falls back to a generic label rather
    /// than dropping the row (no silent loss of a download's visibility, matching the plan's global
    /// "no silent data loss" constraint).
    static func makeRow(_ download: CachedDownload, item: CachedItem?, episode: CachedEpisode?) -> Row {
        let isEpisode = !download.episodeID.isEmpty
        let title: String
        let subtitle: String?
        if isEpisode {
            title = episode?.title ?? "Untitled Episode"
            subtitle = item?.title
        } else {
            title = item?.title ?? "Untitled"
            subtitle = item?.authorName
        }
        return Row(id: download.id, itemID: download.itemID, episodeID: download.episodeID,
                  isEpisode: isEpisode, title: title, subtitle: subtitle, state: download.state,
                  receivedBytes: download.receivedBytes, totalBytes: download.totalBytes)
    }

    /// "128 MB" / "1.2 GB" — the Downloads tab's storage figures (per-row downloaded size + the
    /// footer total), via the system `ByteCountFormatter` (matches the platform's own Settings/
    /// Storage wording rather than a hand-rolled unit table).
    static func humanizeBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
