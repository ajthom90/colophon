import SwiftUI
import LibraryCache

/// The value pushed onto a browse stack to open `EpisodeDetailView` — the episode counterpart to
/// `ItemDetailRoute`/`PodcastDetailRoute`. `EpisodeRow`'s row tap (NOT its Play button) pushes THIS
/// route; the destination is registered at each browse stack's stable root via
/// `.episodeDetailDestination()` (see `SplitShell`/`PhoneShell`), exactly like the podcast/book
/// routes. Deliberately minimal — just enough to LOOK UP the `CachedEpisode` + its `CachedProgress`
/// (both keyed by `podcastItemID`/`episodeID`) — plus `podcastTitle`/`updatedAt` so the header can
/// paint instantly (podcast title, cover art) without waiting on a fetch, the same instant-paint
/// convention `ItemDetailRoute`/`PodcastDetailRoute` use for their own display fields.
struct EpisodeDetailRoute: Hashable {
    /// The parent podcast's item ID — used both to look up this episode's `CachedEpisode`/
    /// `CachedProgress` rows and to resolve `CachedCoverView`'s cover (episodes have no distinct
    /// artwork of their own in `CachedEpisode` — they share the podcast's cover, à la Apple Podcasts
    /// showing the show's artwork on an episode page).
    let podcastItemID: String
    let episodeID: String
    /// The podcast's display title, threaded from the pushing `PodcastDetailView` for instant header
    /// paint (this view has no other route to a podcast title until/unless it fetches one).
    let podcastTitle: String
    /// The podcast cover's `updatedAt` (cache-busting), threaded from `PodcastDetailRoute`.
    let updatedAt: Int?
}

extension View {
    /// Registers `EpisodeDetailRoute` on the enclosing `NavigationStack`. Call once per stack, at its
    /// STABLE root — and, in a `NavigationSplitView` detail column, on the ROOT CONTENT view INSIDE
    /// the column's `NavigationStack` (never on the stack value itself, or a row tap dead-ends with
    /// "There is no next column after the detail column"; see `PodcastDetailRoute`'s same note).
    /// Registered alongside `.podcastDetailDestination()` in both shells since `EpisodeRow` (the only
    /// current pusher) lives inside `PodcastDetailView`, itself reached through the same stacks.
    func episodeDetailDestination() -> some View {
        navigationDestination(for: EpisodeDetailRoute.self) { EpisodeDetailView(route: $0) }
    }
}

/// The native episode page, à la Apple Podcasts. OPAQUE content throughout (cover, title, metadata,
/// HTML description); the ONE `.glassProminent` primary on this surface is the Play/Resume button
/// (the UI mandate's one-prominent allowance) — Add to Queue is a plain secondary `.bordered` button,
/// never glass.
///
/// Data flow mirrors `PodcastDetailView`: this episode's `CachedEpisode` comes from observing the
/// SAME `observeEpisodes` stream `PodcastDetailView` uses (filtered to `route.episodeID`) — so
/// opening this view right after browsing the episode list paints INSTANTLY from cache with no
/// flicker. Its per-episode `CachedProgress` is observed the same way (3-part PK, `episodeID`
/// populated). A background `AppState.refreshPodcastEpisodes` reconciles the podcast's full episode
/// list (the same call `PodcastDetailView` makes) so a direct/offline-then-online open still
/// resolves — and so a genuinely missing episode (removed from the feed) is distinguished from one
/// merely not yet fetched.
struct EpisodeDetailView: View {
    @Environment(AppState.self) private var app
    let route: EpisodeDetailRoute

    /// This episode's row from the cache, `nil` until observed (or if the episode doesn't exist).
    @State private var episode: CachedEpisode?
    /// This episode's progress, joined from `cachedProgress` (3-part PK, `episodeID` populated).
    @State private var progress: CachedProgress?
    @State private var descriptionExpanded = false
    /// The HTML description parsed to an `AttributedString` ONCE (see `HTMLText`), on the main actor.
    @State private var formattedDescription: AttributedString?
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let episode {
                    header(episode)
                    playSection(episode)
                    if let description = episode.episodeDescription, !description.isEmpty {
                        descriptionSection(description)
                    }
                } else {
                    statusRow
                }
            }
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(episode?.title ?? route.podcastTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: route.episodeID) { await observeEpisode() }
        .task(id: route.episodeID) { await observeProgress() }
        .task(id: route.episodeID) { await refresh() }
        .task(id: episode?.episodeDescription) {
            // Parse the HTML description ONCE per value on the main actor (expensive), so the render
            // just reads this @State — never re-parses per `body`.
            if let description = episode?.episodeDescription, !description.isEmpty {
                formattedDescription = HTMLText.attributed(fromHTML: description)
            } else {
                formattedDescription = nil
            }
        }
    }

    // MARK: - Header

    private func header(_ episode: CachedEpisode) -> some View {
        VStack(spacing: 12) {
            CachedCoverView(itemID: route.podcastItemID, updatedAt: route.updatedAt)
                .aspectRatio(contentMode: .fit)
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 10, y: 6)

            VStack(spacing: 6) {
                Text(episode.title ?? "Untitled Episode")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text(route.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                let meta = metaText(episode)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fontDesign(.default)
                }

                statusBadge(episode)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// "Played" (green checkmark) when finished, or an in-progress bar + "…left" when partly played —
    /// the same finished/in-progress convention `EpisodeRow` uses in the list, surfaced here as the
    /// detail page's own status readout.
    @ViewBuilder
    private func statusBadge(_ episode: CachedEpisode) -> some View {
        if isFinished {
            Label("Played", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.top, 2)
        } else if let fraction = progressFraction(episode) {
            VStack(spacing: 4) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                if let remaining = remainingLabel(episode) {
                    Text("\(remaining) left")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fontDesign(.default)
                }
            }
            .frame(maxWidth: 220)
            .padding(.top, 4)
        }
    }

    // MARK: - Play / Resume + queue

    private func playSection(_ episode: CachedEpisode) -> some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    await app.startPlayback(itemID: route.podcastItemID, episodeId: route.episodeID,
                                             podcastTitle: route.podcastTitle)
                }
            } label: {
                Label(playLabel(episode), systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .fontDesign(.default)

            Button {
                app.addToQueue(itemID: route.podcastItemID,
                                title: episode.title ?? "Untitled Episode",
                                author: route.podcastTitle,
                                episodeId: route.episodeID)
            } label: {
                Label("Add to Queue", systemImage: "text.append")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .font(.subheadline.weight(.medium))
            .fontDesign(.default)
        }
        .padding(.horizontal)
    }

    // MARK: - Description

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About This Episode")
                .font(.title3.weight(.semibold))
            // HTML rendered as formatted text (see `HTMLText`, safe + network-free); the fallback
            // runs the SAME synchronous strip for the frame before the parse task populates — never
            // raw tags.
            Text(formattedDescription ?? HTMLText.attributed(fromHTML: description))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 6)
            Button(descriptionExpanded ? "Show Less" : "More") {
                withAnimation { descriptionExpanded.toggle() }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.horizontal)
    }

    // MARK: - Loading / not-found / error

    @ViewBuilder
    private var statusRow: some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView().controlSize(.large)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load episode", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message.isEmpty || message == "offline"
                         ? "This episode is unavailable offline."
                         : message)
                } actions: {
                    Button("Retry") { Task { await refresh() } }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("Episode Not Found", systemImage: "questionmark.circle")
                } description: {
                    Text("This episode may have been removed from the podcast.")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Derived display values

    private var isFinished: Bool { progress?.isFinished ?? false }

    /// The in-progress fraction (0 < f < 1, not finished) — nil for an untouched, finished, or
    /// duration-less episode.
    private func progressFraction(_ episode: CachedEpisode) -> Double? {
        guard !isFinished, let progress, let duration = episode.durationSeconds, duration > 0 else { return nil }
        let f = progress.currentTime / duration
        guard f > 0, f < 1 else { return nil }
        return f
    }

    private func remainingLabel(_ episode: CachedEpisode) -> String? {
        guard let progress, let duration = episode.durationSeconds, duration > 0,
              progress.currentTime > 0, progress.currentTime < duration else { return nil }
        return ItemDetailView.compactDuration(duration - progress.currentTime)
    }

    /// "Play" (untouched or finished — starts over, matching `ItemDetailView.playLabel`'s convention)
    /// or "Resume · Xm left" while in progress.
    private func playLabel(_ episode: CachedEpisode) -> String {
        guard let remaining = remainingLabel(episode) else { return "Play" }
        return "Resume · \(remaining) left"
    }

    /// "Jul 8, 2026 · 42m" — reuses `EpisodeRow.formattedDate` + `ItemDetailView.compactDuration` (no
    /// duplicate formatters).
    private func metaText(_ episode: CachedEpisode) -> String {
        [EpisodeRow.formattedDate(episode), episode.durationSeconds.flatMap(ItemDetailView.compactDuration)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Data

    private func observeEpisode() async {
        episode = nil
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await value in app.cache.observeEpisodes(connectionID: connectionID, itemID: route.podcastItemID) {
                episode = value.first { $0.episodeID == route.episodeID }
            }
        } catch {
            // Best-effort instant paint; the background refresh below still drives the load.
        }
    }

    private func observeProgress() async {
        progress = nil
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progress = rows.first { $0.itemID == route.podcastItemID && $0.episodeID == route.episodeID }
            }
        } catch {
            // Best-effort live finished/in-progress state; the page still renders without it.
        }
    }

    /// One background round trip (via `AppState.refreshPodcastEpisodes`, the SAME call
    /// `PodcastDetailView` makes): reconciles the podcast's full episode list into the cache,
    /// repainting THIS episode through `observeEpisode` above. Instant paint already came from the
    /// cache observation when reached via the episode list, so a failure with the episode already
    /// cached is non-fatal; a failure with nothing cached surfaces the retry state.
    private func refresh() async {
        guard app.client != nil else {
            state = episode == nil ? .failed("offline") : .loaded
            return
        }
        if episode == nil { state = .loading }
        do {
            try await app.refreshPodcastEpisodes(itemID: route.podcastItemID)
            state = .loaded
        } catch {
            state = episode == nil
                ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : .loaded
        }
    }
}
