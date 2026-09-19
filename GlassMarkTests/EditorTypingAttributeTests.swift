import AppKit
import SwiftUI
import XCTest
@testable import GlassMark

/// Regression tests for the "characters appear small and then grow" typing
/// effect: the editor must insert text with the same font the highlighter
/// applies, and highlighting must run in the same cycle as the edit (instead of
/// being applied 50 ms later) for regular-size documents.
@MainActor
final class EditorTypingAttributeTests: XCTestCase {
    private var textView: NSTextView!
    private var coordinator: MarkdownTextView.Coordinator!
    private var boundText = ""

    override func setUp() {
        super.setUp()
        boundText = ""
        textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.string = boundText
        coordinator = MarkdownTextView.Coordinator(
            text: Binding(get: { self.boundText }, set: { self.boundText = $0 }),
            activeLocation: .constant(0)
        )
        coordinator.textView = textView
        textView.delegate = coordinator
    }

    private func highlightedFont(at index: Int) -> NSFont? {
        textView.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    func testTypingAttributesMatchBodyTextFont() {
        boundText = "hello world"
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: boundText.utf16.count, length: 0))
        coordinator.applyHighlighting()

        let typingFont = textView.typingAttributes[.font] as? NSFont
        XCTAssertNotNil(typingFont)
        XCTAssertEqual(typingFont, highlightedFont(at: boundText.utf16.count - 1))
    }

    func testTypingAttributesInheritHeadingFont() {
        boundText = "# Title\nbody"
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        coordinator.applyHighlighting()

        let typingFont = textView.typingAttributes[.font] as? NSFont
        XCTAssertNotNil(typingFont)
        XCTAssertEqual(typingFont, highlightedFont(at: 6))
        XCTAssertTrue(typingFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testEditingHighlightsSynchronouslyForRegularDocuments() {
        boundText = "plain"
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.string = "plain text"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let font = highlightedFont(at: 3)
        XCTAssertNotNil(font, "Highlighting should run in the same cycle as the edit, not a moment later.")
        XCTAssertTrue(font?.isFixedPitch ?? false)
        XCTAssertEqual(boundText, "plain text")
    }
    func testScrollLineIndexUpdatesBeforeDeferredHighlighting() {
        textView.string = "😀\n" + String(repeating: "long line\n", count: 12_000)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(coordinator.characterIndex(forLine: 1), 3)
        XCTAssertEqual(coordinator.characterIndex(forLine: 12_001), textView.string.utf16.count)
        textView.string = "short\n"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(coordinator.characterIndex(forLine: 1), 6)
        XCTAssertEqual(coordinator.characterIndex(forLine: 99), 6)
        XCTAssertEqual(coordinator.characterIndex(forLine: -1), 0)
    }

}
