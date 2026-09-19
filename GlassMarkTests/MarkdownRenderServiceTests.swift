import XCTest
import JavaScriptCore
@testable import GlassMark

final class MarkdownRenderServiceTests: XCTestCase {
    private let service = MarkdownRenderService()

    func testSplitFrontmatterParsesKeyValues() {
        let markdown = """
        ---
        title: My Note
        tags: "draft"
        ---
        # Body
        """
        let result = service.splitFrontmatter(markdown)
        XCTAssertNotNil(result.frontmatter)
        XCTAssertEqual(result.frontmatter?.count, 2)
        XCTAssertEqual(result.frontmatter?.first?.0, "title")
        XCTAssertEqual(result.frontmatter?.first?.1, "My Note")
        XCTAssertEqual(result.frontmatter?[1].1, "draft", "Quotes should be stripped")
        XCTAssertEqual(result.body.trimmingCharacters(in: .whitespacesAndNewlines), "# Body")
    }

    func testNoFrontmatterWhenMissingClosingFence() {
        let markdown = "---\ntitle: x\n# Body"
        XCTAssertNil(service.splitFrontmatter(markdown).frontmatter)
    }

    func testDocumentWithoutLeadingFenceHasNoFrontmatter() {
        let markdown = "# Just a heading\n\nSome text."
        XCTAssertNil(service.splitFrontmatter(markdown).frontmatter)
    }

    func testRenderBodyIncludesFrontmatterBlock() {
        let markdown = "---\ntitle: Hi\n---\n# Body"
        let body = service.renderBody(markdown: markdown)
        XCTAssertTrue(body.contains("frontmatter"))
        XCTAssertTrue(body.contains("<h1 id=\"body\">Body</h1>"))
    }

    func testFullHTMLIsSelfContained() {
        let html = service.fullHTML(markdown: "# Title", title: "Title")
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
    }

    func testDocumentShellHasContentContainerAndScript() {
        let shell = service.documentShell(title: "T")
        XCTAssertTrue(shell.contains("id=\"content\""))
        XCTAssertTrue(shell.contains("function setContent"))
        XCTAssertTrue(shell.contains("id=\"userTheme\""))
        XCTAssertTrue(shell.contains("function setTheme"))
    }

    func testPreviewBodyTagsLinesPastFrontmatter() {
        let markdown = "---\ntitle: Doc\n---\n# Heading"
        let body = service.renderPreviewBody(markdown: markdown)
        // Frontmatter occupies lines 0-2, so the heading is source line 3.
        XCTAssertTrue(body.contains("data-line=\"3\""))
        XCTAssertTrue(body.contains("frontmatter"))
    }

    func testThemeCSSComposition() {
        XCTAssertEqual(service.themeCSS(.system, customCSS: ""), "")
        XCTAssertTrue(service.themeCSS(.sepia, customCSS: "").contains("f4ecd8"))
        let combined = service.themeCSS(.dark, customCSS: "p { color: red; }")
        XCTAssertTrue(combined.contains("#1e1e1e"))
        XCTAssertTrue(combined.contains("p { color: red; }"))
    }
    func testPreviewScrollSearchUsesLiveGeometryAndLogarithmicLookups() throws {
        let shell = service.documentShell(title: "Test")
        let start = try XCTUnwrap(shell.range(of: "<script>"))
        let end = try XCTUnwrap(shell.range(of: "</script>", range: start.upperBound..<shell.endIndex))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var scrollHandler, reads = 0, shift = 0, messages = [];
        var document = { scrollingElement: { scrollTop: 90000 } };
        var window = {
          addEventListener: function (_, handler) { scrollHandler = handler; },
          webkit: { messageHandlers: { glassmarkScroll: {
            postMessage: function (line) { messages.push(line); }
          } } }
        };
        """)
        context.evaluateScript(String(shell[start.upperBound..<end.lowerBound]))
        context.evaluateScript("""
        lineElements = Array.from({length: 10000}, function (_, i) {
          return {
            getAttribute: function () { return String(i); },
            getBoundingClientRect: function () {
              reads++;
              return { top: i * 10 + shift - document.scrollingElement.scrollTop };
            }
          };
        });
        scrollHandler();
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("messages[0]")?.toInt32(), 9000)
        XCTAssertLessThanOrEqual(context.evaluateScript("reads")?.toInt32() ?? 999, 15)
        context.evaluateScript("scrollHandler(); shift = 100; scrollHandler();")
        XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("messages[1]")?.toInt32(), 8990)
    }

}
