import Foundation

/// Converts an Audiobookshelf HTML description into a plain `AttributedString` for display.
///
/// Server metadata descriptions are HTML (`<p>`, `<br>`, `<i>`, entities like `&amp;`). This does a
/// SAFE, synchronous, NETWORK-FREE conversion: strip tags (mapping line-break / block-closing tags
/// to newlines so paragraph structure survives) and decode HTML entities.
///
/// It deliberately does NOT use `NSAttributedString`'s WebKit-backed HTML importer, which
/// (a) loads external resources referenced in the HTML — `<img src="http://…">`, remote
/// stylesheets — from *semi-trusted server metadata*, synchronously on the main thread (an
/// IP-leak / tracking-pixel privacy risk plus a UI hang on large input), and (b) is main-actor-only
/// and slow. The importer path already stripped `.font` (dropping bold/italic to avoid clashing
/// with the app's styling), so nothing is lost visually by not using it.
///
/// Plain prose containing a literal `<` ("if x < 3", "<3") is NOT treated as HTML — a tag must start
/// with a letter (`</?[A-Za-z]`) — so it round-trips unchanged.
enum HTMLText {
    /// Hard cap so a pathological description can't stall the (synchronous) transform.
    private static let maxInputLength = 50_000

    static func attributed(fromHTML html: String) -> AttributedString {
        AttributedString(plainText(fromHTML: html))
    }

    static func plainText(fromHTML html: String) -> String {
        let input = html.count > maxInputLength ? String(html.prefix(maxInputLength)) : html
        // Fast path: no real tag AND no entity → return as-is (preserves a literal "<").
        guard containsMarkup(input) else { return input }

        var s = input
        // Map line-break / block-closing tags to newlines BEFORE stripping so paragraphs survive.
        s = replace(s, pattern: #"(?i)<br\s*/?>"#, with: "\n")
        s = replace(s, pattern: #"(?i)</(p|div|li|h[1-6]|ul|ol|blockquote|tr)>"#, with: "\n")
        // Strip every remaining tag. A tag starts with a letter after an optional "/", so "< 3" and
        // "<3" (space / digit) are left intact — that's the plain-text-with-angle-bracket fix.
        s = replace(s, pattern: #"(?i)</?[a-z][a-z0-9]*[^>]*>"#, with: "")
        s = decodeEntities(s)
        s = replace(s, pattern: #"\n{3,}"#, with: "\n\n")   // collapse runaway blank lines
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsMarkup(_ s: String) -> Bool {
        s.range(of: #"</?[A-Za-z]"#, options: .regularExpression) != nil
            || s.range(of: #"&(#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z]+);"#, options: .regularExpression) != nil
    }

    private static func replace(_ s: String, pattern: String, with repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [String: String] = [
            "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
            "&trade;": "™", "&copy;": "©", "&reg;": "®",
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        out = decodeNumericEntities(out)
        // `&amp;` LAST so an escaped entity like "&amp;lt;" resolves to the literal text "&lt;".
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let token = ns.substring(with: match.range(at: 1))
            let value: UInt32? = token.lowercased().hasPrefix("x")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token, radix: 10)
            if let value, let scalar = Unicode.Scalar(value) {
                result += String(scalar)
            } else {
                result += ns.substring(with: match.range)   // invalid → leave as-is
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }
}
