import Testing
import Foundation
@testable import Colophon

/// Unit coverage for the library-browse sort/filter mapping (Task 8): the UI sort choices must map
/// to the exact verified ABS `sort=` keys, and the filter value must be base64url-encoded per the
/// ABS filter convention. These are the deterministic, offline proofs behind the live E2E.
struct LibraryBrowseTests {
    @Test func sortChoicesMapToVerifiedServerKeys() {
        #expect(LibrarySort.title.serverKey == "media.metadata.title")
        #expect(LibrarySort.author.serverKey == "media.metadata.authorName")
        #expect(LibrarySort.added.serverKey == "addedAt")
        #expect(LibrarySort.published.serverKey == "media.metadata.publishedYear")
        #expect(LibrarySort.progress.serverKey == "progress")
    }

    @Test func base64URLEncodingIsURLSafeAndUnpadded() {
        // "Sun Tzu" → standard base64 "U3VuIFR6dQ==" → url-safe, unpadded "U3VuIFR6dQ".
        #expect(LibraryFilter.base64URLEncode("Sun Tzu") == "U3VuIFR6dQ")
        // A value whose standard base64 contains `+`/`/` must be translated to `-`/`_` with no `=`.
        // "\u{00ff}\u{00ff}\u{00ff}" (0xC3BF ×3 in UTF-8) → standard "w7/Dv8O/", url-safe "w7_Dv8O_".
        let encoded = LibraryFilter.base64URLEncode("\u{00ff}\u{00ff}\u{00ff}")
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(encoded == "w7_Dv8O_")
    }

    @Test func filterQueryValueUsesGroupAndEncodedRawValue() {
        // Authors/series filter by ID (the raw value), not the display name.
        let authorFilter = LibraryFilter(group: "authors", displayValue: "Sun Tzu", rawValue: "aut_123")
        #expect(authorFilter.queryValue == "authors.\(LibraryFilter.base64URLEncode("aut_123"))")
        // String facets encode the value itself.
        let genreFilter = LibraryFilter(group: "genres", displayValue: "History", rawValue: "History")
        #expect(genreFilter.queryValue == "genres.\(LibraryFilter.base64URLEncode("History"))")
    }
}
