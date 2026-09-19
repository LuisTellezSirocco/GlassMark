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

    func testLocalEditPreservesAttributesOfDistantLines() throws {
        textView.string = "# Title\nbody\n\n**unchanged**"
        coordinator.applyHighlighting()
        let storage = try XCTUnwrap(textView.textStorage)
        let marker = NSAttributedString.Key("unchanged-test-marker")
        storage.addAttribute(marker, value: true, range: (textView.string as NSString).range(of: "unchanged"))
        textView.insertText("new ", replacementRange: NSRange(location: 8, length: 0))
        let range = (textView.string as NSString).range(of: "unchanged")
        XCTAssertEqual(storage.attribute(marker, at: range.location, effectiveRange: nil) as? Bool, true)
        XCTAssertTrue(highlightedFont(at: range.location)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testRemovingFenceRestylesFollowingLines() {
        textView.string = "```\n**body**\nend"
        coordinator.applyHighlighting()
        textView.insertText("", replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(highlightedFont(at: 3)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor,
                       NSColor.textColor)
    }

    func testIncrementalAttributesMatchFullHighlightingAfterStructuralEdits() throws {
        let versions = [
            "# Title\n**bold**\n_tail_\n",
            "# Title\n\n**bold**\n_tail_\n",
            "# Title\n```\n**bold**\n_tail_\n",
            "# Title\n```\n**bold**\n```\n_tail_\n",
            "# Title\n~~~\n**bold**\n```\n_tail_\n",
            "# Title\n_tail_\n", "# Title", "", "😀 **café**\r\n_tail_",
            "😀 **cafe\u{301}**\r\n_tail_"
        ]
        coordinator.applyHighlighting()
        for next in versions {
            let before = Array(textView.string.utf16)
            let after = Array(next.utf16)
            var prefix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(before.count, after.count) - prefix,
                  before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
            let replacement = (next as NSString).substring(with: NSRange(location: prefix, length: after.count - prefix - suffix))
            textView.insertText(replacement, replacementRange: NSRange(location: prefix, length: before.count - prefix - suffix))
            let incremental = NSAttributedString(attributedString: try XCTUnwrap(textView.textStorage))
            coordinator.applyHighlighting()
            XCTAssertEqual(incremental, textView.textStorage, next)
        }
    }

}
