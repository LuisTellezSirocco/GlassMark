import Foundation

/// Markdown policy for assistant output. Unlike note preview HTML, this value
/// type never emits an image resource and never grants generated Markdown a
/// workspace/file base URL.
struct ChatMarkdownRenderer: Sendable {
    private let markdown = MarkdownHTMLRenderer()

    func renderHTML(_ source: String) -> String {
        let rendered = markdown.renderBody(source)
        return sanitizeLinks(replaceImagesWithAltText(rendered))
    }

    /// Produces a SwiftUI-friendly value renderer for the transcript. Images
    /// are converted to their alt text before Foundation parses Markdown, and
    /// link attributes are stripped unless the URL is explicitly HTTP(S).
    func renderAttributed(_ source: String) -> AttributedString? {
        let withoutImages = replaceMarkdownImagesWithAltText(source)
        guard var attributed = try? AttributedString(markdown: withoutImages) else { return nil }
        let unsafeRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link else { return nil }
            let scheme = link.scheme?.lowercased()
            return scheme == "http" || scheme == "https" ? nil : run.range
        }
        for range in unsafeRanges {
            attributed[range].link = nil
        }
        return attributed
    }

    func copyText(_ source: String) -> String { source }

    private func replaceMarkdownImagesWithAltText(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\([^)]*\)"#,
            options: []
        ) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var result = source
        for match in expression.matches(in: source, range: range).reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let altRange = Range(match.range(at: 1), in: source) else { continue }
            result.replaceSubrange(wholeRange, with: String(source[altRange]))
        }
        return result
    }

    private func replaceImagesWithAltText(_ html: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"<img\b[^>]*\balt="([^"]*)"[^>]*>"#, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html
        for match in expression.matches(in: html, range: range).reversed() {
            guard match.numberOfRanges > 1,
                  let altRange = Range(match.range(at: 1), in: html),
                  let wholeRange = Range(match.range, in: result) else { continue }
            let alt = String(html[altRange])
            result.replaceSubrange(wholeRange, with: alt.isEmpty ? "" : "<span class=\"chat-image-alt\">\(alt)</span>")
        }
        return result
    }

    private func sanitizeLinks(_ html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"<a\b[^>]*\bhref="([^"]*)"[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html
        for match in expression.matches(in: html, range: range).reversed() {
            guard match.numberOfRanges > 1,
                  let wholeRange = Range(match.range, in: result),
                  let originalWholeRange = Range(match.range, in: html),
                  let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[hrefRange])
            let normalized = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let opening = String(html[originalWholeRange])
            if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") {
                let secured = opening.replacingOccurrences(
                    of: "<a ",
                    with: "<a target=\"_blank\" rel=\"noopener noreferrer\" ",
                    options: [.caseInsensitive],
                    range: nil
                )
                result.replaceSubrange(wholeRange, with: secured)
            } else {
                // mailto:, file:, data:, javascript: and relative URLs are
                // deliberately inert in the chat renderer.
                let inert = opening.replacingOccurrences(
                    of: #"href="[^"]*""#,
                    with: "href=\"#\"",
                    options: [.regularExpression, .caseInsensitive],
                    range: nil
                )
                result.replaceSubrange(wholeRange, with: inert)
            }
        }
        return result
    }
}
