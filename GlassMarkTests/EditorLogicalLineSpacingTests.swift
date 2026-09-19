import AppKit
import SwiftUI
import XCTest
@testable import GlassMark

/// Exercises logical-line paragraph spacing through the real TextKit layout
/// manager. Soft wraps remain in one paragraph; only the following paragraph
/// moves when spacing changes.
@MainActor
final class EditorLogicalLineSpacingTests: XCTestCase {
    private var textView: NSTextView!
    private var coordinator: MarkdownTextView.Coordinator!
    private var boundText = ""

    override func setUp() {
        super.setUp()
        boundText = ""
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 10_000))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)

        coordinator = MarkdownTextView.Coordinator(
            text: Binding(get: { self.boundText }, set: { self.boundText = $0 }),
            activeLocation: .constant(0)
        )
        coordinator.textView = textView
        textView.delegate = coordinator
    }

    override func tearDown() {
        textView = nil
        coordinator = nil
        super.tearDown()
    }

    private func setText(_ text: String, width: CGFloat = 220) {
        boundText = text
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }

    private func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        textView.textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    private struct LineFragment {
        let logicalLine: Int
        let minY: CGFloat
    }

    private func lineFragments() -> [LineFragment] {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let nsString = textView.string as NSString
        var fragments: [LineFragment] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            let location = min(characterRange.location, nsString.length)
            let prefix = nsString.substring(to: location)
            let logicalLine = prefix.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            fragments.append(LineFragment(logicalLine: logicalLine, minY: fragmentRect.minY))
        }
        return fragments
    }

    func testParagraphStyleIsAppliedToExistingTextAndTypingAttributes() {
        setText("first line\nsecond line")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        coordinator.setLogicalLineSpacing(17)
        coordinator.applyHighlighting()

        let first = paragraphStyle(at: 0)
        let second = paragraphStyle(at: 11)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first!.paragraphSpacing, 17, accuracy: 0.001)
        XCTAssertEqual(second!.paragraphSpacing, 17, accuracy: 0.001)
        XCTAssertEqual(first!.lineSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(second!.lineSpacing, 0, accuracy: 0.001)

        let typing = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(typing)
        XCTAssertEqual(typing!.paragraphSpacing, 17, accuracy: 0.001)
        XCTAssertEqual(typing!.lineSpacing, 0, accuracy: 0.001)
    }

    func testSpacingChangesOnlyTheBoundaryBetweenLogicalLines() {
        let first = String(repeating: "long wrapped source line ", count: 40).trimmingCharacters(in: .whitespaces)
        setText(first + "\nsecond", width: 180)

        coordinator.setLogicalLineSpacing(0)
        coordinator.applyHighlighting()
        let withoutSpacing = lineFragments()
        let firstLineWithoutSpacing = withoutSpacing.filter { $0.logicalLine == 0 }
        let secondLineWithoutSpacing = withoutSpacing.filter { $0.logicalLine == 1 }
        XCTAssertGreaterThanOrEqual(firstLineWithoutSpacing.count, 2, "precondition: the first logical line must soft-wrap")
        XCTAssertFalse(secondLineWithoutSpacing.isEmpty)

        coordinator.setLogicalLineSpacing(20)
        coordinator.applyHighlighting()
        let withSpacing = lineFragments()
        let firstLineWithSpacing = withSpacing.filter { $0.logicalLine == 0 }
        let secondLineWithSpacing = withSpacing.filter { $0.logicalLine == 1 }
        XCTAssertEqual(firstLineWithSpacing.count, firstLineWithoutSpacing.count)
        XCTAssertFalse(secondLineWithSpacing.isEmpty)

        let withoutWrapGap = firstLineWithoutSpacing[1].minY - firstLineWithoutSpacing[0].minY
        let withWrapGap = firstLineWithSpacing[1].minY - firstLineWithSpacing[0].minY
        XCTAssertEqual(withWrapGap, withoutWrapGap, accuracy: 0.5)

        let withoutBoundaryGap = secondLineWithoutSpacing[0].minY - firstLineWithoutSpacing.last!.minY
        let withBoundaryGap = secondLineWithSpacing[0].minY - firstLineWithSpacing.last!.minY
        XCTAssertEqual(withBoundaryGap, withoutBoundaryGap + 20, accuracy: 0.5)
    }

    func testChangingSpacingDoesNotChangeTextSelectionOrUndo() {
        setText("first\nsecond")
        coordinator.applyHighlighting()
        textView.setSelectedRange(NSRange(location: 2, length: 3))

        let originalText = textView.string
        let originalSelection = textView.selectedRange()
        let originalCanUndo = textView.undoManager?.canUndo

        coordinator.setLogicalLineSpacing(20)
        coordinator.applyHighlighting()

        XCTAssertEqual(textView.string, originalText)
        XCTAssertEqual(textView.selectedRange(), originalSelection)
        XCTAssertEqual(textView.undoManager?.canUndo, originalCanUndo)
    }

    func testInvalidCoordinatorSpacingIsNormalized() {
        setText("line")

        for (value, expected) in [
            (CGFloat(-1), CGFloat(0)),
            (CGFloat(101), CGFloat(100)),
            (CGFloat.nan, CGFloat(0)),
            (CGFloat.infinity, CGFloat(0)),
            (-CGFloat.infinity, CGFloat(0))
        ] {
            coordinator.setLogicalLineSpacing(value)
            coordinator.applyHighlighting()
            XCTAssertEqual(paragraphStyle(at: 0)!.paragraphSpacing, expected, accuracy: 0.001)
        }
    }

    func testEmptyDocumentUsesSpacingForNewTyping() {
        setText("")

        coordinator.setLogicalLineSpacing(12)
        coordinator.applyHighlighting()

        let typing = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(typing)
        XCTAssertEqual(typing!.paragraphSpacing, 12, accuracy: 0.001)
        XCTAssertEqual(typing!.lineSpacing, 0, accuracy: 0.001)
    }
}
