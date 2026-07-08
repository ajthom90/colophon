import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Converts an Audiobookshelf HTML description (server metadata is HTML: `<p>`, `<br>`, `<i>`, …)
/// into an `AttributedString` for display, so the tags render as formatting instead of literal text.
///
/// **Main-actor-only + parse ONCE.** `NSAttributedString`'s HTML importer must run on the main actor
/// and is expensive, so callers parse into `@State` from a `.task` (keyed on the description) — NEVER
/// per `body`. The parsed string's own font/colour are STRIPPED here so the call site's serif
/// `.font(.body)` + `.foregroundStyle(.secondary)` styling (and `.lineLimit`/expand) apply cleanly
/// instead of clashing with the importer's system font/black. Plain (tag-free) strings skip the
/// parser entirely and round-trip unchanged.
enum HTMLText {
    @MainActor
    static func attributed(fromHTML html: String) -> AttributedString {
        // No tags → plain text; avoid the parser (and any whitespace it might introduce) entirely.
        guard html.contains("<") else { return AttributedString(html) }
        guard let data = html.data(using: .utf8),
              let ns = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil)
        else { return AttributedString(html) }

        // Drop the HTML-provided font + colour so the app's `.font`/`.foregroundStyle` win (removing
        // `.font` at the NSAttributedString level, before conversion, is the reliable cross-platform
        // way to clear the importer's system font — it also clears bold/italic, an accepted trade for
        // uniform, non-clashing styling).
        let mutable = NSMutableAttributedString(attributedString: ns)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.font, range: full)
        mutable.removeAttribute(.foregroundColor, range: full)

        // The HTML importer appends a trailing newline (from the wrapping block element); trim any
        // trailing whitespace so the text block doesn't carry dead space under it.
        var result = AttributedString(mutable)
        while let last = result.characters.last, last.isWhitespace {
            let end = result.endIndex
            let start = result.index(end, offsetByCharacters: -1)
            result.removeSubrange(start..<end)
        }
        return result
    }
}
