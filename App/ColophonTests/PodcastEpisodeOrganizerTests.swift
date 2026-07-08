import Testing
import Foundation
import LibraryCache
@testable import Colophon

/// Deterministic offline proofs for `PodcastEpisodeOrganizer` — the season grouping + sort logic
/// behind `PodcastDetailView`'s episode list. The live E2E's dev fixture has only ONE season (→ a
/// flat list), so the multi-season / NULL-`publishedAt` / non-numeric-season paths — the most
/// complex net-new logic — are verified here instead.
struct PodcastEpisodeOrganizerTests {

    /// Builds a `CachedEpisode` with just the fields the organizer reads (season / episode /
    /// publishedAt); everything else defaulted.
    private func ep(_ id: String, season: String? = nil, episode: String? = nil, publishedAt: Int? = nil) -> CachedEpisode {
        CachedEpisode(connectionID: "c", itemID: "i", episodeID: id,
                      season: season, episode: episode, title: id, publishedAt: publishedAt)
    }

    // MARK: - Grouping decision

    @Test func flatWhenSingleSeasonAndNotSeasonSort() {
        let eps = [ep("a", season: "1", publishedAt: 100), ep("b", season: "1", publishedAt: 200)]
        #expect(PodcastEpisodeOrganizer.shouldGroupBySeason(eps, sort: .newest) == false)
        let sections = PodcastEpisodeOrganizer.sections(eps, sort: .newest)
        #expect(sections.count == 1)
        #expect(sections[0].title == "Episodes")
        #expect(sections[0].episodes.map(\.episodeID) == ["b", "a"])   // newest first
    }

    @Test func flatWhenNoSeasonAndNotSeasonSort() {
        let eps = [ep("a", publishedAt: 100), ep("b", publishedAt: 200)]
        #expect(PodcastEpisodeOrganizer.shouldGroupBySeason(eps, sort: .oldest) == false)
        let sections = PodcastEpisodeOrganizer.sections(eps, sort: .oldest)
        #expect(sections.count == 1 && sections[0].title == "Episodes")
    }

    @Test func groupsWhenMoreThanOneSeasonEvenUnderNewest() {
        let eps = [ep("s1e1", season: "1", publishedAt: 100),
                   ep("s2e1", season: "2", publishedAt: 300)]
        #expect(PodcastEpisodeOrganizer.shouldGroupBySeason(eps, sort: .newest) == true)
        let titles = PodcastEpisodeOrganizer.sections(eps, sort: .newest).map(\.title)
        #expect(titles == ["Season 2", "Season 1"])   // Newest → seasons DESCENDING
    }

    @Test func groupsUnderBySeasonEvenWithSingleSeason() {
        let eps = [ep("a", season: "1", episode: "1"), ep("b", season: "1", episode: "2")]
        #expect(PodcastEpisodeOrganizer.shouldGroupBySeason(eps, sort: .season) == true)
        let sections = PodcastEpisodeOrganizer.sections(eps, sort: .season)
        #expect(sections.map(\.title) == ["Season 1"])
        #expect(sections[0].episodes.map(\.episodeID) == ["a", "b"])   // by episode number asc
    }

    // MARK: - Section-per-season + within-section order

    @Test func bySeasonOrdersSeasonsAscendingAndEpisodesByNumber() {
        let eps = [ep("s2e2", season: "2", episode: "2"),
                   ep("s1e2", season: "1", episode: "2"),
                   ep("s1e1", season: "1", episode: "1"),
                   ep("s2e1", season: "2", episode: "1")]
        let sections = PodcastEpisodeOrganizer.sections(eps, sort: .season)
        #expect(sections.map(\.title) == ["Season 1", "Season 2"])   // ascending
        #expect(sections[0].episodes.map(\.episodeID) == ["s1e1", "s1e2"])
        #expect(sections[1].episodes.map(\.episodeID) == ["s2e1", "s2e2"])
    }

    @Test func seasonlessEpisodesGetTrailingEpisodesSectionWhenGrouped() {
        let eps = [ep("s1", season: "1", publishedAt: 100),
                   ep("s2", season: "2", publishedAt: 200),
                   ep("nx", publishedAt: 300)]   // no season → forces a trailing "Episodes"
        let titles = PodcastEpisodeOrganizer.sections(eps, sort: .newest).map(\.title)
        #expect(titles == ["Season 2", "Season 1", "Episodes"])
    }

    // MARK: - NULL publishedAt sorts LAST in both directions

    @Test func newestSortsNullsLast() {
        let eps = [ep("mid", publishedAt: 200), ep("none"), ep("hi", publishedAt: 300), ep("lo", publishedAt: 100)]
        let order = PodcastEpisodeOrganizer.sortedEpisodes(eps, sort: .newest).map(\.episodeID)
        #expect(order == ["hi", "mid", "lo", "none"])   // 300,200,100, then nil LAST
    }

    @Test func oldestSortsNullsLast() {
        let eps = [ep("mid", publishedAt: 200), ep("none"), ep("hi", publishedAt: 300), ep("lo", publishedAt: 100)]
        let order = PodcastEpisodeOrganizer.sortedEpisodes(eps, sort: .oldest).map(\.episodeID)
        #expect(order == ["lo", "mid", "hi", "none"])   // 100,200,300, then nil LAST
    }

    // MARK: - Non-numeric season ordering is deterministic

    @Test func nonNumericSeasonsOrderDeterministically() {
        let build: () -> [CachedEpisode] = {
            [self.ep("x", season: "special"), self.ep("y", season: "10"),
             self.ep("z", season: "2"), self.ep("w", season: "apple")]
        }
        // Numeric seasons (by value) BEFORE non-numeric (lexical): 2, 10, then apple, special.
        let expected = ["Season 2", "Season 10", "Season apple", "Season special"]
        #expect(PodcastEpisodeOrganizer.sections(build(), sort: .season).map(\.title) == expected)

        // Deterministic regardless of input order (the Dictionary.keys hazard the fix closes):
        // several shuffles all yield the SAME section order.
        for _ in 0..<20 {
            let shuffled = build().shuffled()
            #expect(PodcastEpisodeOrganizer.sections(shuffled, sort: .season).map(\.title) == expected)
        }
    }
}
