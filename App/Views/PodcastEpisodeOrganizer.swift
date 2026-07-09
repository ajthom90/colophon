import Foundation
import LibraryCache

/// How a podcast's episode list is ordered — surfaced via `PodcastDetailView`'s toolbar sort `Menu`.
/// `.season` additionally forces season `Section`s even for a single-season feed.
enum EpisodeSort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, season
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .season: return "By Season"
        }
    }
}

/// One rendered episode section — a season group ("Season 1") or the flat/ungrouped list ("Episodes").
struct EpisodeSection: Identifiable, Equatable, Sendable {
    /// The season value for a season group, or "" for the flat / season-less "Episodes" section.
    let id: String
    let title: String
    let episodes: [CachedEpisode]
}

/// The PURE, unit-tested grouping + sort logic behind `PodcastDetailView`'s episode list, extracted
/// from the view so the multi-season / NULL-date / non-numeric-season paths (which the thin 1-season
/// dev fixture can't exercise live) have deterministic offline proofs. Stateless static funcs over
/// `[CachedEpisode]` + `EpisodeSort` — no SwiftUI, no I/O.
enum PodcastEpisodeOrganizer {
    /// Distinct non-empty season values, in first-seen order.
    static func seasons(_ episodes: [CachedEpisode]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for episode in episodes {
            if let season = episode.season, !season.isEmpty, seen.insert(season).inserted {
                order.append(season)
            }
        }
        return order
    }

    /// Group into season `Section`s when the feed spans more than one season, or when the user
    /// explicitly sorts By Season. A single-season (or season-less) feed under Newest/Oldest stays flat.
    static func shouldGroupBySeason(_ episodes: [CachedEpisode], sort: EpisodeSort) -> Bool {
        sort == .season || seasons(episodes).count > 1
    }

    /// The chosen flat ordering. Newest/Oldest by `publishedAt` with NULLs sorting LAST in BOTH
    /// directions (nil → `.min` under a descending compare, `.max` under an ascending one); By Season
    /// by numeric episode number (non-numeric last), tie-broken by `publishedAt` ascending.
    static func sortedEpisodes(_ list: [CachedEpisode], sort: EpisodeSort) -> [CachedEpisode] {
        switch sort {
        case .newest:
            return list.sorted { ($0.publishedAt ?? .min) > ($1.publishedAt ?? .min) }
        case .oldest:
            return list.sorted { ($0.publishedAt ?? .max) < ($1.publishedAt ?? .max) }
        case .season:
            return list.sorted { lhs, rhs in
                let ln = Int(lhs.episode ?? "") ?? .max
                let rn = Int(rhs.episode ?? "") ?? .max
                if ln != rn { return ln < rn }
                return (lhs.publishedAt ?? .max) < (rhs.publishedAt ?? .max)
            }
        }
    }

    /// A TOTAL, deterministic ordering key for a season label — the fix for the non-deterministic
    /// `Dictionary.keys.sorted` on non-numeric labels. Numeric seasons sort as numbers and BEFORE any
    /// non-numeric label; non-numeric labels sort lexically among themselves. Because it's a proper
    /// strict-weak (tuple-lexicographic) order, the result is identical run-to-run regardless of the
    /// dictionary's hash-seed iteration order.
    static func seasonSortKey(_ season: String) -> (Int, Int, String) {
        if let n = Int(season) { return (0, n, season) }   // group 0 = numeric, ordered by value
        return (1, 0, season)                              // group 1 = non-numeric, ordered lexically
    }

    /// The organized episode sections for a sort. When grouping (see `shouldGroupBySeason`):
    /// one `Section` per season (ordered ascending for Oldest/By-Season, descending for Newest via the
    /// deterministic `seasonSortKey`), plus a trailing "Episodes" section for any season-less episodes.
    /// Otherwise a single flat "Episodes" section. Always ≥ 1 section for a non-empty input.
    static func sections(_ episodes: [CachedEpisode], sort: EpisodeSort) -> [EpisodeSection] {
        guard shouldGroupBySeason(episodes, sort: sort) else {
            return [EpisodeSection(id: "", title: "Episodes", episodes: sortedEpisodes(episodes, sort: sort))]
        }
        let grouped = Dictionary(grouping: episodes.filter { !($0.season ?? "").isEmpty }) { $0.season ?? "" }
        let ascending = (sort != .newest)
        let keys = grouped.keys.sorted { lhs, rhs in
            ascending ? seasonSortKey(lhs) < seasonSortKey(rhs) : seasonSortKey(lhs) > seasonSortKey(rhs)
        }
        var out = keys.map { key in
            EpisodeSection(id: key, title: "Season \(key)", episodes: sortedEpisodes(grouped[key] ?? [], sort: sort))
        }
        let seasonless = episodes.filter { ($0.season ?? "").isEmpty }
        if !seasonless.isEmpty {
            out.append(EpisodeSection(id: "", title: "Episodes", episodes: sortedEpisodes(seasonless, sort: sort)))
        }
        return out
    }
}
