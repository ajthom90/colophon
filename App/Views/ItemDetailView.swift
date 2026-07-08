import SwiftUI
import ABSKit
import LibraryCache

/// The value pushed onto a browse stack to open `ItemDetailView`. Carries just enough of the
/// browse row to paint the header instantly (cover + title + author + a duration for the progress
/// fraction) before the `GET /api/items/:id` round trip resolves. `Hashable` so it rides the
/// codebase's standard `NavigationLink(value:)` + `navigationDestination(for:)` pattern (like
/// `AuthorSummary`/`SeriesSummary`); the destination is registered at each stack's stable root
/// via `.itemDetailDestination()`.
struct ItemDetailRoute: Hashable {
    let itemID: String
    let title: String
    let author: String?
    let updatedAt: Int?
    let duration: Double?
}

extension View {
    /// Registers `ItemDetailRoute` on the enclosing `NavigationStack`. Call once per stack, at its
    /// STABLE root (never on a conditionally-mounted view — see `AuthorsListView`'s doc comment).
    func itemDetailDestination() -> some View {
        navigationDestination(for: ItemDetailRoute.self) { ItemDetailView(route: $0) }
    }
}

/// The native item-detail surface — a book's own page, à la Apple Books / Podcasts. Opaque
/// content throughout (cover, metadata, description, chapter rows); the ONLY Liquid Glass here is
/// the single tinted `.glassProminent` Play/Resume primary — the sanctioned one-prominent per the
/// UI mandate. A subtle blurred-cover hero backdrop is opaque ambient content, not glass.
///
/// Data flow mirrors the browse surfaces: instant paint from the cache (the pushed
/// `ItemDetailRoute` for the header, `LibraryCacheStore.itemDetail()` for the heavy description/
/// chapters), then a background `ABSClient.item(id:)` refresh that also re-caches via
/// `upsertItemDetail` so a later offline re-open still shows the full detail. The Resume position
/// comes from the live `CachedProgress` observation (kept fresh by `me()`/socket), falling back to
/// the fetched item's `userMediaProgress`.
///
/// Play/Resume calls `AppState.startPlayback` (what the browse surfaces used to call directly) and
/// lights the shell's mini-bar/transport. The full-screen player (and presenting it from here) is
/// Task 3/4 — this view deliberately does not build or present it.
struct ItemDetailView: View {
    @Environment(AppState.self) private var app
    let route: ItemDetailRoute

    @State private var detail: LibraryItemDetail?
    @State private var cachedDetail: CachedItemDetail?
    @State private var progress: CachedProgress?
    @State private var state: LoadState = .idle
    @State private var showingChapters = false
    @State private var descriptionExpanded = false
    /// The HTML description parsed into an `AttributedString` ONCE (see `HTMLText`) — populated by
    /// `.task(id: displayDescription)`, never per `body`. Nil until parsed / when there's no description.
    @State private var formattedDescription: AttributedString?

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                titleBlock
                playSection
                if let description = displayDescription, !description.isEmpty {
                    descriptionSection(description)
                }
                if !chapters.isEmpty {
                    chaptersRow
                }
                metadataSection
                if state == .loading, detail == nil, cachedDetail == nil {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                } else if case .failed(let message) = state, detail == nil, cachedDetail == nil {
                    detailsUnavailable(message)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingChapters) {
            ChapterPreviewSheet(title: displayTitle, chapters: chapters)
        }
        .task(id: route.itemID) { await load() }
        .task(id: app.activeConnectionID) { await observeProgress() }
        .task(id: displayDescription) {
            // Parse the HTML description ONCE per value on the main actor (NSAttributedString's HTML
            // importer is main-actor-only + expensive); the render then just reads this @State.
            if let description = displayDescription, !description.isEmpty {
                formattedDescription = HTMLText.attributed(fromHTML: description)
            } else {
                formattedDescription = nil
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack {
            CachedCoverView(itemID: route.itemID, updatedAt: route.updatedAt)
                .aspectRatio(contentMode: .fill)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .blur(radius: 40)
                .opacity(0.35)
                .clipped()

            CachedCoverView(itemID: route.itemID, updatedAt: route.updatedAt)
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 14, y: 8)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Title / author / narrator / series

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Serif comes from the app-wide `.fontDesign` toggle — not reintroduced per-view.
            Text(displayTitle)
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)
            if let subtitle = detail?.media.metadata.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let author = displayAuthor, !author.isEmpty {
                Text(author)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let narrator = displayNarrator, !narrator.isEmpty {
                Text("Narrated by \(narrator)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let series = seriesLabel {
                Text(series)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Play / Resume

    private var playSection: some View {
        VStack(spacing: 10) {
            Button {
                Task { await app.startPlayback(itemID: route.itemID) }
            } label: {
                Label(playLabel, systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .fontDesign(.default)

            // Up-next queue affordances (Task 8) — native, opaque (never glass): enqueue this book
            // to play right after the current one, or at the end of the queue. Enabled only while a
            // book is playing (there's a "current book" to queue after); `AppState` scopes the entry
            // to the active connection.
            HStack(spacing: 12) {
                Button {
                    app.playNext(itemID: route.itemID, title: displayTitle, author: displayAuthor)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    app.addToQueue(itemID: route.itemID, title: displayTitle, author: displayAuthor)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .font(.subheadline.weight(.medium))
            .fontDesign(.default)
            .disabled(app.nowPlayingItemID == nil)

            if let fraction = progressFraction {
                VStack(spacing: 4) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    HStack {
                        Text("\(Int((fraction * 100).rounded()))% listened")
                        Spacer()
                        if let remaining = remainingLabel {
                            Text("\(remaining) left").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.default)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Description

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.title3.weight(.semibold))
            // HTML rendered as formatted text (see `HTMLText`); falls back to the raw string until
            // the parse task populates `formattedDescription`. The app's serif body font + secondary
            // colour + line-limit/expand still apply — the parsed string's own font/colour are stripped.
            Text(formattedDescription ?? AttributedString(description))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 4)
            Button(descriptionExpanded ? "Show Less" : "More") {
                withAnimation { descriptionExpanded.toggle() }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.horizontal)
    }

    // MARK: - Chapters

    private var chaptersRow: some View {
        Button {
            showingChapters = true
        } label: {
            HStack {
                Label("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")", systemImage: "list.bullet")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Metadata rows

    @ViewBuilder
    private var metadataSection: some View {
        let rows = metadataRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Information")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Text(row.value)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .modifier(MonospaceIf(row.monospaced))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    Divider().padding(.leading)
                }
            }
        }
    }

    /// The `.failed` message rendered verbatim (a real network/server error), falling back to the
    /// friendly offline copy for the `"offline"` sentinel or an empty message.
    private func detailsUnavailable(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message.isEmpty || message == "offline"
                 ? "Full details are unavailable offline."
                 : message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Derived display values

    private var displayTitle: String { detail?.media.metadata.title ?? route.title }
    private var displayAuthor: String? { detail?.media.metadata.authorName ?? route.author }
    private var displayNarrator: String? { detail?.media.metadata.narratorName }

    private var displayDescription: String? {
        detail?.media.metadata.description ?? cachedDetail?.description
    }

    private var totalDuration: Double? { detail?.media.duration ?? route.duration }

    /// The series name + this book's sequence, when present (empty seed values → nil).
    private var seriesLabel: String? {
        if let ref = detail?.media.metadata.series?.first, let name = ref.name, !name.isEmpty {
            if let seq = ref.sequence, !seq.isEmpty { return "\(name) · Book \(seq)" }
            return name
        }
        if let name = detail?.media.metadata.seriesName, !name.isEmpty { return name }
        return nil
    }

    /// Chapters from the live fetch, falling back to the cached detail for offline re-open.
    private var chapters: [CachedChapter] {
        if let live = detail?.media.chapters {
            return live.map { CachedChapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title) }
        }
        return cachedDetail?.chapters ?? []
    }

    private var resumeTime: Double {
        progress?.currentTime ?? detail?.userMediaProgress?.currentTime ?? 0
    }

    private var isFinished: Bool {
        progress?.isFinished ?? detail?.userMediaProgress?.isFinished ?? false
    }

    /// The in-progress fraction (0 < f < 1, not finished) — nil for an untouched or completed item.
    private var progressFraction: Double? {
        guard !isFinished, let duration = totalDuration, duration > 0 else { return nil }
        let f = resumeTime / duration
        guard f > 0, f < 1 else { return nil }
        return f
    }

    private var playLabel: String {
        guard progressFraction != nil, let duration = totalDuration else { return "Play" }
        if let remaining = Self.compactDuration(duration - resumeTime) {
            return "Resume · \(remaining) left"
        }
        return "Resume"
    }

    private var remainingLabel: String? {
        guard let duration = totalDuration else { return nil }
        return Self.compactDuration(duration - resumeTime)
    }

    private struct MetadataRow { let label: String; let value: String; let monospaced: Bool }

    private var metadataRows: [MetadataRow] {
        var rows: [MetadataRow] = []
        let md = detail?.media.metadata
        if let genres = md?.genres, !genres.isEmpty {
            rows.append(MetadataRow(label: "Genres", value: genres.joined(separator: ", "), monospaced: false))
        }
        if let year = md?.publishedYear, !year.isEmpty {
            rows.append(MetadataRow(label: "Published", value: year, monospaced: false))
        }
        if let publisher = md?.publisher ?? cachedDetail?.publisher, !publisher.isEmpty {
            rows.append(MetadataRow(label: "Publisher", value: publisher, monospaced: false))
        }
        if let language = md?.language ?? cachedDetail?.language, !language.isEmpty {
            rows.append(MetadataRow(label: "Language", value: language, monospaced: false))
        }
        if let isbn = md?.isbn ?? cachedDetail?.isbn, !isbn.isEmpty {
            rows.append(MetadataRow(label: "ISBN", value: isbn, monospaced: true))
        }
        if let asin = md?.asin ?? cachedDetail?.asin, !asin.isEmpty {
            rows.append(MetadataRow(label: "ASIN", value: asin, monospaced: true))
        }
        if let duration = totalDuration, duration > 0, let full = Self.fullDuration(duration) {
            rows.append(MetadataRow(label: "Duration", value: full, monospaced: true))
        }
        return rows
    }

    // MARK: - Data

    private func load() async {
        let connectionID = app.activeConnectionID
        if let connectionID {
            cachedDetail = try? app.cache.itemDetail(connectionID: connectionID, itemID: route.itemID)
        }
        guard let client = app.client else {
            state = (detail == nil && cachedDetail == nil) ? .failed("offline") : .loaded
            return
        }
        if detail == nil { state = .loading }
        do {
            let fresh = try await client.item(id: route.itemID)
            detail = fresh
            state = .loaded
            if let connectionID { try? app.cache.upsertItemDetail(Self.cached(fresh, connectionID: connectionID)) }
        } catch {
            state = (detail == nil && cachedDetail == nil)
                ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : .loaded
        }
    }

    private func observeProgress() async {
        progress = nil
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progress = rows.indexedByItem()[route.itemID]
            }
        } catch {
            // Best-effort live Resume position; the fetched `userMediaProgress` still drives it.
        }
    }

    /// Maps the fetched detail to the v2 `cachedItemDetail` row (heavy fields + chapters) for
    /// offline re-open — the light fields (title/author/narrator/series/genres/year/duration)
    /// already live on the browse `cachedItem` row.
    private static func cached(_ detail: LibraryItemDetail, connectionID: String) -> CachedItemDetail {
        let md = detail.media.metadata
        return CachedItemDetail(
            connectionID: connectionID,
            itemID: detail.id,
            description: md.description,
            publisher: md.publisher,
            isbn: md.isbn,
            asin: md.asin,
            language: md.language,
            explicit: md.explicit,
            abridged: md.abridged,
            publishedDate: md.publishedDate,
            chapters: (detail.media.chapters ?? []).map {
                CachedChapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title)
            })
    }

    // MARK: - Formatting

    /// "1h 12m" / "12m" / "45s" — the compact remaining/resume form (drops seconds above a minute).
    static func compactDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// "1h 12m 17s" — the full metadata-row form.
    static func fullDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

/// Applies `.monospacedDigit()` only when `active` — lets the metadata rows share one `ForEach`
/// while ISBN/ASIN/duration get monospaced digits and text rows don't.
private struct MonospaceIf: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }
    func body(content: Content) -> some View {
        if active { content.monospacedDigit() } else { content }
    }
}

/// A minimal read-only chapter list, presented as a sheet from the detail's "N chapters" row.
/// Deliberately NOT interactive (the tap-to-seek chapter list bound to live playback is Task 3) —
/// this just proves the chapters exist and shows their titles + start times.
private struct ChapterPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let chapters: [CachedChapter]

    var body: some View {
        NavigationStack {
            List(chapters) { chapter in
                HStack(spacing: 12) {
                    Text(chapter.title ?? "Chapter \(chapter.id + 1)")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(Self.timestamp(chapter.start))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fontDesign(.default)
                }
                .padding(.vertical, 2)
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
        // macOS ignores `.presentationDetents`, so without an explicit size the sheet collapses to
        // its content's ideal size and the chapter rows get clipped. Give it a usable minimum.
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    /// h:mm:ss for a chapter start (global seconds).
    static func timestamp(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
