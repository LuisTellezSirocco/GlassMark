import XCTest
@testable import GlassMark

final class ChatMarkdownRendererTests: XCTestCase {
    func testImagesAreRenderedAsAltTextAndUnsafeLinksAreInert() {
        let html = ChatMarkdownRenderer().renderHTML(
            "![tracking](https://example.test/pixel.png) [file](file:///tmp/secret) [web](https://example.test/docs)"
        )
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("tracking"))
        XCTAssertTrue(html.contains("href=\"#\""))
        XCTAssertTrue(html.contains("target=\"_blank\""))
    }

    func testRawHTMLIsEscapedByChatRenderer() {
        let html = ChatMarkdownRenderer().renderHTML("<script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testAttributedRendererDropsNonHTTPLinks() throws {
        let value = try XCTUnwrap(ChatMarkdownRenderer().renderAttributed(
            "[unsafe](file:///tmp/note) [safe](https://example.test)"
        ))
        let links = value.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.scheme, "https")
    }
}
