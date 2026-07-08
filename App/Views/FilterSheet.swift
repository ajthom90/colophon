import SwiftUI
import ABSKit
import LibraryCache

/// The library filter sheet: a native `Form` built from `ABSClient.filterData(libraryID:)`, with a
/// section per facet group (genres, authors, series, narrators, tags, languages, published decades)
/// — only groups that actually have values are shown. Selecting a value sets `AppState.libraryFilter`
/// (→ `items?filter=<group>.<base64url(value)>`) and dismisses; a Clear action removes the filter.
///
/// Liquid Glass discipline: the sheet CONTENT is opaque native `Form`/`List` — the only glass is the
/// system sheet/nav chrome. `.presentationDetents([.medium, .large])`.
///
/// Thin-fixture note: the seeded dev library has a single author ("Sun Tzu") and no genres/series/
/// tags/narrators, so live only the Authors section is populated — the empty groups are correctly
/// omitted, and a fuller seed (M1c-c) would exercise the rest.
struct FilterSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let library: CachedLibrary

    @State private var data: FilterData?
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Filter")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    if app.libraryFilter != nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Clear") { app.libraryFilter = nil; dismiss() }
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load filters", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        case .loaded:
            if let data {
                filterForm(data)
            }
        }
    }

    @ViewBuilder
    private func filterForm(_ data: FilterData) -> some View {
        let groups = facetGroups(data)
        Form {
            if let active = app.libraryFilter {
                Section {
                    Button(role: .destructive) {
                        app.libraryFilter = nil
                        dismiss()
                    } label: {
                        Label("Clear Filter", systemImage: "xmark.circle")
                    }
                } footer: {
                    Text("Filtering by \(active.group.capitalized): \(active.displayValue)")
                }
            }

            if groups.allSatisfy(\.rows.isEmpty) {
                Section {
                    ContentUnavailableView("No Filters Available", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("This library has no facets to filter by yet."))
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    if !group.rows.isEmpty {
                        Section(group.title) {
                            ForEach(group.rows) { row in
                                Button { apply(row) } label: {
                                    HStack {
                                        Text(row.display).foregroundStyle(.primary)
                                        Spacer()
                                        if isSelected(row) {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Facets

    /// One selectable facet value. `raw` is what gets base64url-encoded into the request — the
    /// author/series ID for those groups, the plain string for the rest.
    private struct FacetRow: Identifiable, Hashable {
        let id: String
        let group: String
        let display: String
        let raw: String
    }

    private func facetGroups(_ data: FilterData) -> [(title: String, rows: [FacetRow])] {
        [
            ("Genres", data.genres.map { stringRow(group: "genres", $0) }),
            ("Authors", data.authors.map { FacetRow(id: "authors.\($0.id)", group: "authors", display: $0.name, raw: $0.id) }),
            ("Series", data.series.map { FacetRow(id: "series.\($0.id)", group: "series", display: $0.name, raw: $0.id) }),
            ("Narrators", data.narrators.map { stringRow(group: "narrators", $0) }),
            ("Tags", data.tags.map { stringRow(group: "tags", $0) }),
            ("Languages", data.languages.map { stringRow(group: "languages", $0) }),
            ("Published Decades", data.publishedDecades.map { stringRow(group: "publishedDecades", $0) }),
        ]
    }

    private func stringRow(group: String, _ value: String) -> FacetRow {
        FacetRow(id: "\(group).\(value)", group: group, display: value, raw: value)
    }

    private func isSelected(_ row: FacetRow) -> Bool {
        guard let active = app.libraryFilter else { return false }
        return active.group == row.group && active.rawValue == row.raw
    }

    private func apply(_ row: FacetRow) {
        app.libraryFilter = LibraryFilter(group: row.group, displayValue: row.display, rawValue: row.raw)
        dismiss()
    }

    private func load() async {
        guard let client = app.client else {
            state = .failed("You're offline — filters need a live connection.")
            return
        }
        if data == nil { state = .loading }
        do {
            data = try await client.filterData(libraryID: library.id)
            state = .loaded
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
