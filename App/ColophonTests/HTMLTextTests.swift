import Testing
import Foundation
@testable import Colophon

/// Unit coverage for `HTMLText` — the shared, SAFE (synchronous, network-free) HTML→text helper
/// that `ItemDetailView` / `AuthorDetailView` use so ABS's HTML descriptions render as formatted
/// text instead of literal tags. No WebKit importer, so no `@MainActor` requirement.
struct HTMLTextTests {
    /// HTML tags are stripped; the words survive with no stray `<`.
    @Test func htmlTagsBecomeFormattingNotLiteralText() {
        let plain = HTMLText.plainText(fromHTML: "<p>Hello <b>world</b></p>")
        #expect(plain == "Hello world")
        #expect(!plain.contains("<"))
    }

    /// `<br>` and block-closing tags map to newlines so paragraph structure survives.
    @Test func lineBreakAndParagraphsBecomeNewlines() {
        let plain = HTMLText.plainText(fromHTML: "<p>One<br>Two</p><p>Three</p>")
        #expect(!plain.contains("<"))
        #expect(plain.contains("One"))
        #expect(plain.contains("Two"))
        #expect(plain.contains("Three"))
        #expect(plain.contains("\n"))   // a paragraph/line break produced a newline
    }

    /// Plain (tag-free) text passes through unchanged.
    @Test func plainTextPassesThroughUnchanged() {
        #expect(HTMLText.plainText(fromHTML: "Just text") == "Just text")
    }

    /// THE FALSE-POSITIVE FIX: plain prose with a literal `<` is NOT treated as HTML (a tag must
    /// start with a letter), so it round-trips verbatim instead of being mangled by a parser.
    @Test func literalAngleBracketsInPlainTextAreNotStripped() {
        #expect(HTMLText.plainText(fromHTML: "if x < 3 and y > 2 then win") == "if x < 3 and y > 2 then win")
        #expect(HTMLText.plainText(fromHTML: "I <3 audiobooks") == "I <3 audiobooks")
        #expect(HTMLText.plainText(fromHTML: "5<10 chapters") == "5<10 chapters")
    }

    /// HTML entities decode to their characters; `&amp;` resolves last so an escaped entity survives.
    @Test func entitiesDecode() {
        #expect(HTMLText.plainText(fromHTML: "<p>Tom &amp; Jerry</p>") == "Tom & Jerry")
        #expect(HTMLText.plainText(fromHTML: "<p>a &lt; b &gt; c</p>") == "a < b > c")
        #expect(HTMLText.plainText(fromHTML: "<p>quote: &quot;hi&quot; &#39;yo&#39;</p>") == "quote: \"hi\" 'yo'")
        #expect(HTMLText.plainText(fromHTML: "<p>ma&#241;ana</p>") == "mañana")          // numeric decimal
        #expect(HTMLText.plainText(fromHTML: "<p>&#x2014;dash</p>") == "—dash")          // numeric hex
        // "&amp;lt;" is an ESCAPED "&lt;" → the literal text "&lt;", not the character "<".
        #expect(HTMLText.plainText(fromHTML: "<p>&amp;lt;</p>") == "&lt;")
    }

    /// Empty input stays empty (no crash, no injected whitespace).
    @Test func emptyStringStaysEmpty() {
        #expect(HTMLText.plainText(fromHTML: "").isEmpty)
    }

    /// A real ABS-style description (paragraphs, entities, self-closing break) yields clean prose with
    /// no residual markup or raw entities.
    @Test func realisticDescriptionHasNoResidualMarkup() {
        let html = "<p>#1 <b>BESTSELLER</b> &mdash; a story of love &amp; loss.<br/>&ldquo;Artful.&rdquo;</p>"
        let plain = HTMLText.plainText(fromHTML: html)
        #expect(!plain.contains("<"))
        #expect(!plain.contains("&amp;"))
        #expect(!plain.contains("&mdash;"))
        #expect(plain.contains("BESTSELLER"))
        #expect(plain.contains("love & loss"))
        #expect(plain.contains("—"))
        #expect(plain.contains("\u{201C}Artful.\u{201D}"))   // curly quotes decoded
    }

    /// Overlong input is truncated rather than allowed to stall the synchronous transform (and never
    /// crashes).
    @Test func hugeInputIsCappedAndSafe() {
        let huge = String(repeating: "<p>word &amp; word</p>", count: 20_000)
        let plain = HTMLText.plainText(fromHTML: huge)
        #expect(!plain.isEmpty)
        #expect(!plain.contains("<"))
        #expect(plain.count < huge.count)
    }
}
