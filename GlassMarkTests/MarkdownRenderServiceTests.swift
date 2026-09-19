import XCTest
import JavaScriptCore
import WebKit
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

@MainActor
final class PreviewDOMPerformanceTests: XCTestCase, WKNavigationDelegate {
    private var navigationFinished: XCTestExpectation?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished?.fulfill()
    }

    private func makePreview() async throws -> WKWebView {
        let shell = MarkdownRenderService().documentShell(title: "Test")
        let start = try XCTUnwrap(shell.range(of: "<script>"))
        let end = try XCTUnwrap(shell.range(of: "</script>", range: start.upperBound..<shell.endIndex))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        webView.navigationDelegate = self
        let finished = expectation(description: "Preview shell loaded")
        navigationFinished = finished
        // Exercise the real WebKit DOM with deterministic, instrumented rich
        // renderers. No network, assets, or external services are involved.
        webView.loadHTMLString("""
        <html><body><main id="content"></main><script>
        // An offscreen WKWebView may suspend animation frames. Drive that
        // scheduling boundary explicitly while retaining the real DOM.
        var frames = [];
        window.requestAnimationFrame = function (callback) { frames.push(callback); };
        function flushFrames() {
          var pending = frames; frames = []; pending.forEach(function (callback) { callback(); });
        }
        var highlightCalls = 0, mathCalls = 0, mermaidCalls = 0;
        window.hljs = { highlightElement: function (node) {
          highlightCalls++; node.innerHTML = '<span>highlighted</span>';
        } };
        window.renderMathInElement = function (node) {
          if (node.textContent.indexOf('$') >= 0) { mathCalls++; node.innerHTML = '<span>math</span>'; }
        };
        window.mermaid = { run: function (options) {
          mermaidCalls += options.nodes.length;
          options.nodes.forEach(function (node) { node.innerHTML = '<svg></svg>'; });
          return Promise.resolve();
        } };
        \(shell[start.upperBound..<end.lowerBound])
        </script></body></html>
        """, baseURL: nil)
        await fulfillment(of: [finished], timeout: 15)
        return webView
    }

    func testUnchangedRichBlocksSurviveEditsAndSourceLineShifts() async throws {
        let webView = try await makePreview()
        let result = try await webView.callAsyncJavaScript("""
        var rich = '<pre data-line="2"><code>code</code></pre>' +
          '<p data-line="5">$x$</p>' +
          '<pre data-line="7"><code class="language-mermaid">graph TD; A-->B</code></pre>' +
          '<p data-line="10"><img alt="local image"></p>';
        setContent('<p data-line="0">first</p>' + rich, 'note');
        flushFrames();
        var originals = Array.from(document.getElementById('content').children).slice(1);
        var shifted = rich.replace(/data-line="(\\d+)"/g, function (_, n) {
          return 'data-line="' + (Number(n) + 3) + '"';
        });
        setContent('<p data-line="0">changed</p>' + shifted, 'note');
        flushFrames();
        var current = Array.from(document.getElementById('content').children).slice(1);
        return [originals.every(function (node, i) { return node === current[i]; }),
          highlightCalls, mathCalls, mermaidCalls, current[2].getAttribute('data-line'), lineElements.length];
        """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [Any])
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Int, 1)
        XCTAssertEqual(values[2] as? Int, 1)
        XCTAssertEqual(values[3] as? Int, 1)
        XCTAssertEqual(values[4] as? String, "10")
        XCTAssertEqual(values[5] as? Int, 5)
    }

    func testRapidUpdatesDuplicatesDocumentSwitchAndEmptyContent() async throws {
        let webView = try await makePreview()
        let result = try await webView.callAsyncJavaScript("""
        var code = '<pre><code>same</code></pre>';
        setContent(code + code, 'first');
        setContent('<p>latest</p>' + code + code, 'first');
        flushFrames();
        var main = document.getElementById('content');
        var original = main.children[1];
        var distinct = original !== main.children[2];
        var firstCalls = highlightCalls;
        setContent('<p>latest</p>' + code + code, 'second');
        flushFrames();
        var switched = main.children[1] !== original;
        setContent('', 'second');
        flushFrames();
        return [distinct, firstCalls, switched, highlightCalls, main.children.length, lineElements.length];
        """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [Any])
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Int, 2)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Int, 4)
        XCTAssertEqual(values[4] as? Int, 0)
        XCTAssertEqual(values[5] as? Int, 0)
    }
}
