import XCTest
@testable import GlassMark

final class MarkdownSyntaxHighlighterTests: XCTestCase {
    private let highlighter = MarkdownSyntaxHighlighter()

    private func styles(in text: String) -> [MarkdownTokenStyle] {
        highlighter.tokens(in: text).map(\.style)
    }

    func testHeadingTokenCoversWholeLine() {
        let text = "# Title"
        let tokens = highlighter.tokens(in: text)
        XCTAssertEqual(tokens.first?.style, .heading(level: 1))
        XCTAssertEqual(tokens.first?.range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testInlineCodeAndEmphasis() {
        let styles = styles(in: "Use `code` and **bold** and _italic_.")
        XCTAssertTrue(styles.contains(.inlineCode))
        XCTAssertTrue(styles.contains(.strong))
        XCTAssertTrue(styles.contains(.emphasis))
    }

    func testStrikethrough() {
        XCTAssertTrue(styles(in: "~~done~~").contains(.strikethrough))
    }

    func testListMarkerTokenized() {
        XCTAssertTrue(styles(in: "- item").contains(.listMarker))
        XCTAssertTrue(styles(in: "1. item").contains(.listMarker))
    }

    func testBlockquoteTokenized() {
        XCTAssertTrue(styles(in: "> quote").contains(.blockquote))
    }

    func testFencedCodeBlockLinesTokenized() {
        let text = "```\nlet x = 1\n```"
        XCTAssertTrue(styles(in: text).allSatisfy { $0 == .codeBlock })
    }

    func testLinkTokenized() {
        XCTAssertTrue(styles(in: "[text](url)").contains(.link))
    }

    func testRangesStayWithinBounds() {
        let text = "# Heading with `code` and **bold**\n- list\n> quote"
        let length = (text as NSString).length
        for token in highlighter.tokens(in: text) {
            XCTAssertGreaterThanOrEqual(token.range.location, 0)
            XCTAssertLessThanOrEqual(token.range.location + token.range.length, length)
        }
    }

    func testUnicodeOffsetsAreUTF16Safe() {
        // Emoji are two UTF-16 units; token ranges must account for that.
        let text = "😀 `code`"
        let length = (text as NSString).length
        for token in highlighter.tokens(in: text) {
            XCTAssertLessThanOrEqual(token.range.location + token.range.length, length)
        }
    }

    func testCRLFOffsetsReferToOriginalText() {
        let text = "body\r\n😀 `code`\r\n# Title"
        let tokens = highlighter.tokens(in: text)
        XCTAssertEqual(tokens.first(where: { $0.style == .inlineCode })?.range,
                       (text as NSString).range(of: "`code`"))
        XCTAssertEqual(tokens.first(where: { $0.style == .heading(level: 1) })?.range,
                       (text as NSString).range(of: "# Title"))
    }

    func testIncrementalHighlightingOnlyParsesEditedLine() {
        var cache = MarkdownHighlightCache()
        let text = String(repeating: "**bold** and `code`\n", count: 4_000)
        _ = cache.update(text)
        let edited = "new line\n" + text
        let update = cache.update(edited)
        XCTAssertEqual(update.parsedLineCount, 1)
        XCTAssertEqual(update.range, NSRange(location: 0, length: 9))
        XCTAssertEqual(update.lineStarts, LineIndex.lineStarts(in: edited as NSString))
        XCTAssertEqual(cache.update(edited, forceFull: true).tokens, highlighter.tokens(in: edited))
    }

    func testIncrementalHighlightingTracksFenceChangesAndUnicodeEdits() {
        var cache = MarkdownHighlightCache()
        let versions = [
            "# Title\n```\n**code**\n```\n😀 _tail_\n",
            "# Title\n\n**code**\n```\n😀 _tail_\n",
            "# Title\n\n**code**\n\n😀 _tail_\n",
            "# Title\r\n~~~\r\n**code**\r\n~~~\r\n😀 _tail_\r\n",
            "# Title\r\n😀 _tail_\r\n",
            "# Title\r\n😀 _taíl_\r\n",
            "# Title\r\n😀 _tai\u{301}l_\r\n",
            "", "**bold**", "plain"
        ]
        for text in versions {
            _ = cache.update(text)
            let full = cache.update(text, forceFull: true)
            XCTAssertEqual(full.tokens, highlighter.tokens(in: text), text)
            XCTAssertEqual(full.lineStarts, LineIndex.lineStarts(in: text as NSString))
        }
    }
}
