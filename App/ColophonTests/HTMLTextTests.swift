import Testing
import Foundation
@testable import Colophon

/// Unit coverage for `HTMLText.attributed(fromHTML:)` — the shared HTML→`AttributedString` helper
/// that `ItemDetailView` / `AuthorDetailView` use so ABS's HTML descriptions render as formatted
/// text instead of literal tags. The importer is main-actor-only, so the suite is `@MainActor`.
@MainActor
struct HTMLTextTests {
    /// HTML tags become formatting, not literal text: the plain string carries the words with the
    /// tags stripped (no stray `<` left) and the block's trailing newline trimmed.
    @Test func htmlTagsBecomeFormattingNotLiteralText() {
        let result = HTMLText.attributed(fromHTML: "<p>Hello <b>world</b></p>")
        let plain = String(result.characters)
        #expect(plain == "Hello world")
        #expect(!plain.contains("<"))
    }

    /// A `<br>` is consumed as formatting (the importer renders it as whitespace), never left as a
    /// literal tag in the text.
    @Test func lineBreakTagIsNotLiteral() {
        let result = HTMLText.attributed(fromHTML: "<p>One<br>Two</p>")
        let plain = String(result.characters)
        #expect(!plain.contains("<"))
        #expect(plain.contains("One"))
        #expect(plain.contains("Two"))
    }

    /// Plain (tag-free) text passes through unchanged — the helper skips the parser entirely.
    @Test func plainTextPassesThroughUnchanged() {
        let result = HTMLText.attributed(fromHTML: "Just text")
        #expect(String(result.characters) == "Just text")
    }

    /// Empty input stays empty (no crash, no injected whitespace).
    @Test func emptyStringStaysEmpty() {
        let result = HTMLText.attributed(fromHTML: "")
        #expect(String(result.characters).isEmpty)
    }
}
