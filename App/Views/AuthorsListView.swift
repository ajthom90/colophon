import SwiftUI
import ABSKit
import LibraryCache
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The authors browse surface (`GET /api/libraries/:id/authors`): a native `List` of authors, each
/// row an avatar circle + name + "N books" subtitle (à la Apple Books' Authors tab). Tapping a row
/// pushes `AuthorDetailView`.
///
/// **The caller registers `.navigationDestination(for: AuthorSummary.self)`, not this view.**
/// `SplitShell` uses this view as the literal, unconditional root of its own dedicated
/// `NavigationStack`, where self-registering would be fine — but `PhoneShell`'s Library tab
/// reaches this view through a `browseMode` switch (Grid/Series/Authors) that swaps the
/// NavigationStack's root CONTENT view. A `navigationDestination` registered on a conditionally-
/// present view is exactly the fragile pattern `ConnectionsView` already warns about ("declared at
/// the stack root, not inside the pushed view, where a destination registered from within another
/// view fails to resolve") — empirically, on that iPhone path it went further: popping the pushed
/// `AuthorDetailView` back to this conditionally-mounted root caused `LibraryTabContent`'s entire
/// `@State` (including `browseMode`) to reset, silently landing back on Grid instead of Authors.
/// Hoisting the registration to each call site's STABLE root (the outer `Group` in
/// `LibraryTabContent`, the dedicated `NavigationStack` in `SplitShell`) fixed it. See
/// `PhoneShell.LibraryTabContent` and `SplitShell.detailColumn` for the registrations.
///
/// Liquid Glass discipline: the ONLY glass is the system nav-bar/sidebar chrome the shell provides
/// — the list rows, avatars and text are all OPAQUE content.
struct AuthorsListView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary

    @State private var authors: [AuthorSummary] = []
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    var body: some View {
        content
            .navigationTitle("Authors")
            .task(id: library.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if authors.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load authors", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No Authors", systemImage: "person.2")
                } description: {
                    Text("This library has no authors yet.")
                }
            }
        } else {
            List(authors) { author in
                NavigationLink(value: author) {
                    AuthorRow(library: library, author: author)
                }
            }
        }
    }

    private func load() async {
        guard let client = app.client else {
            if authors.isEmpty { state = .failed("You're offline — authors need a live connection.") }
            return
        }
        if authors.isEmpty { state = .loading }
        do {
            authors = try await client.authors(libraryID: library.id)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            state = .loaded
        } catch {
            if authors.isEmpty {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

private struct AuthorRow: View {
    let library: CachedLibrary
    let author: AuthorSummary

    var body: some View {
        HStack(spacing: 12) {
            AuthorAvatarView(
                library: library, authorID: author.id, name: author.name,
                imagePath: author.imagePath, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(author.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(bookCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var bookCountLabel: String {
        let n = author.numBooks ?? 0
        return "\(n) book\(n == 1 ? "" : "s")"
    }
}

/// An author's detail: a header (avatar, name, book count, description if present) above a grid of
/// their books (`GET /api/authors/:id?include=items` → `libraryItems`), reusing `ItemsCoverGrid`.
/// The list-row's `AuthorSummary` seeds the header instantly (name/avatar/count show before the
/// network round trip resolves) — only the description and the exact book list wait on `load()`.
/// Tapping a book pushes `ItemDetailView` (via `CoverCard` → `ItemDetailRoute`), same as everywhere
/// else; the destination is registered at the enclosing stack's root.
struct AuthorDetailView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary
    let author: AuthorSummary

    @State private var detail: AuthorDetail?
    @State private var progressByItem: [String: CachedProgress] = [:]
    @State private var state: LoadState = .idle
    /// The author bio (HTML) parsed into an `AttributedString` ONCE (see `HTMLText`) — populated by
    /// `.task(id: detail?.description)`, never per `body`. Nil until parsed / when there's no bio.
    @State private var formattedDescription: AttributedString?

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private var books: [LibraryItemSummary] { detail?.libraryItems ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                booksSection
            }
            .padding(.bottom)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(author.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: author.id) { await load() }
        .task(id: app.activeConnectionID) { await observeProgress() }
        .task(id: detail?.description) {
            // Parse the HTML bio ONCE per value on the main actor (see `ItemDetailView`).
            if let description = detail?.description, !description.isEmpty {
                formattedDescription = HTMLText.attributed(fromHTML: description)
            } else {
                formattedDescription = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AuthorAvatarView(
                library: library, authorID: author.id, name: author.name,
                imagePath: detail?.imagePath ?? author.imagePath, size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(author.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text(bookCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let description = detail?.description, !description.isEmpty {
                    // HTML bio rendered as formatted text (see `HTMLText`); raw fallback until parsed.
                    Text(formattedDescription ?? AttributedString(description))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var bookCountLabel: String {
        let n = detail?.libraryItems?.count ?? author.numBooks ?? 0
        return "\(n) book\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var booksSection: some View {
        switch state {
        case .idle, .loading:
            if books.isEmpty {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                ItemsCoverGrid(items: books, progressByItem: progressByItem)
            }
        case .failed(let message):
            if books.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load books", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ItemsCoverGrid(items: books, progressByItem: progressByItem)
            }
        case .loaded:
            if books.isEmpty {
                ContentUnavailableView {
                    Label("No Books", systemImage: "book")
                } description: {
                    Text("No books found for this author.")
                }
            } else {
                ItemsCoverGrid(items: books, progressByItem: progressByItem)
            }
        }
    }

    private func load() async {
        guard let client = app.client else {
            if detail == nil { state = .failed("You're offline — this author's books need a live connection.") }
            return
        }
        if detail == nil { state = .loading }
        do {
            detail = try await client.author(id: author.id, include: "items")
            state = .loaded
        } catch {
            if detail == nil {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func observeProgress() async {
        progressByItem = [:]
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progressByItem = rows.indexedByItem()
            }
        } catch {
            // Best-effort live pills; the grid still paints without progress.
        }
    }
}

/// A simple `LazyVGrid` of `CoverCard`s for a fixed, already-fetched list of items — an author's or
/// series' books. Unlike `LibraryGridView` there is no sort/filter/cache-observation: the list is
/// exactly what the author/series endpoint returned, so this is just the grid layout, shared by
/// `AuthorDetailView` and `SeriesDetailView`. The caller wraps it (with its header) in one
/// `ScrollView` — this view contributes no `ScrollView` of its own, so header + grid never nest
/// two scrollers. Progress is still joined live so pills track playback started elsewhere.
struct ItemsCoverGrid: View {
    let items: [LibraryItemSummary]
    let progressByItem: [String: CachedProgress]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                CoverCard(
                    itemID: item.id,
                    updatedAt: item.updatedAt,
                    title: item.media.metadata.title ?? "Untitled",
                    author: item.media.metadata.authorName,
                    duration: item.media.duration,
                    progress: progressByItem[item.id])
            }
        }
        .padding(.horizontal)
    }
}

/// An author's avatar: a circle showing their `/api/authors/:id/image` artwork when `imagePath !=
/// nil`, or an initials placeholder otherwise (the seed's "Sun Tzu", whose `imagePath` is nil,
/// renders "ST"). **Auth finding (source + live verified, this task):** the image endpoint is
/// PUBLIC, exactly like the item-cover endpoint — ABS `Auth.js` lists `authors/:id/image` in the
/// same unauthenticated-GET `ignorePatterns` allowlist as `items/:id/cover`; live against this dev
/// server, an unauthenticated GET and a Bearer-authed GET for the seeded (imageless) author 404
/// IDENTICALLY, which is what actually demonstrates auth isn't the deciding factor (a truly
/// auth-gated endpoint would 401 without the token, not 404 both ways). So this fetches a plain
/// unauthenticated URL, same as `CachedCoverView` — no Bearer header, no token query param needed.
/// Reuses `AppState.coverStore` for disk caching/fetch-dedup, keyed `"author:<id>"` so an author
/// avatar can never collide with a same-ID library item's cover in the shared cache.
struct AuthorAvatarView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary
    let authorID: String
    let name: String
    let imagePath: String?
    var size: CGFloat = 56

    @State private var image: Image?

    var body: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(name)
            .task(id: "\(authorID)-\(imagePath ?? "")") { await load() }
    }

    /// First letter of up to the first two name components, e.g. "Sun Tzu" → "ST". Empty when the
    /// name has no letters at all (falls back to the plain circle with no overlay text).
    private var initials: String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    private func load() async {
        image = nil
        guard imagePath != nil, let client = app.client else { return }
        let width = max(Int(size.rounded()) * 2, 64)
        do {
            let data = try await app.coverStore.coverData(
                connectionID: library.connectionID, itemID: "author:\(authorID)", updatedAt: nil
            ) {
                try await URLSession.shared.data(from: client.authorImageURL(authorID: authorID, width: width)).0
            }
            #if os(macOS)
            guard let platformImage = NSImage(data: data) else { return }
            image = Image(nsImage: platformImage)
            #else
            guard let platformImage = UIImage(data: data) else { return }
            image = Image(uiImage: platformImage)
            #endif
        } catch {
            // Fetch/decode/404 failure: fall back to the initials placeholder, never a broken image.
            image = nil
        }
    }
}
