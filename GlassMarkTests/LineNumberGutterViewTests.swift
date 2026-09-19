import AppKit
import SwiftUI
import XCTest
@testable import GlassMark

/// Exercises the line-number gutter and the container that keeps it beside the
/// editor scroll view, both off-screen and inside the real SwiftUI embedding.
@MainActor
final class LineNumberGutterViewTests: XCTestCase {
    // MARK: - Builders

    private func makeEditor(
        text: String,
        width: CGFloat = 420,
        height: CGFloat = 320,
        gutterVisible: Bool = true,
        logicalLineSpacing: CGFloat = 0
    ) -> (container: EditorContainerView, scrollView: NSScrollView, textView: NSTextView, gutter: LineNumberGutterView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacing = logicalLineSpacing
        if let textStorage = textView.textStorage, textStorage.length > 0 {
            textStorage.addAttribute(
                .paragraphStyle,
                value: paragraphStyle.copy() as! NSParagraphStyle,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        scrollView.documentView = textView

        let gutter = LineNumberGutterView(textView: textView)
        gutter.textSize = CGFloat(DocumentTextSize.defaultSize)
        let container = EditorContainerView(scrollView: scrollView, gutter: gutter)
        gutter.refresh()
        container.setGutterVisible(gutterVisible)
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        container.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        return (container, scrollView, textView, gutter)
    }

    private func makeWindowEditor(
        text: String,
        gutterVisible: Bool = true
    ) -> (window: NSWindow, container: EditorContainerView, scrollView: NSScrollView, textView: NSTextView, gutter: LineNumberGutterView) {
        let (container, scrollView, textView, gutter) = makeEditor(text: text, gutterVisible: gutterVisible)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        return (window, container, scrollView, textView, gutter)
    }

    // MARK: - Rendering helpers

    private func render(_ view: NSView) -> NSBitmapImageRep {
        let width = max(Int(ceil(view.bounds.width)), 1)
        let height = max(Int(ceil(view.bounds.height)), 1)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.cacheDisplay(in: view.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Ink pixels in the text area, excluding the strip the gutter occupies.
    /// Compares against the bitmap's own background so it works in light and
    /// dark appearances.
    private func textAreaInk(in view: NSView, gutterWidth: CGFloat) -> Int {
        let rep = render(view)
        guard let reference = rep.colorAt(x: 2, y: rep.pixelsHigh - 2) else { return 0 }
        var count = 0
        let fromX = max(Int(gutterWidth) + 4, 0)
        for x in stride(from: fromX, to: max(fromX + 1, rep.pixelsWide - 8), by: 2) {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if abs(color.brightnessComponent - reference.brightnessComponent) > 0.08 { count += 1 }
            }
        }
        return count
    }

    private let everything = NSRect(x: 0, y: 0, width: 500, height: 100_000)

    private func lineFragmentCount(in textView: NSTextView) -> Int {
        guard let layoutManager = textView.layoutManager else { return 0 }
        var count = 0
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { _, _, _, _, _ in
            count += 1
        }
        return count
    }

    // MARK: - Regression: the note must stay visible with the gutter on

    func testGutterKeepsStandardClipGeometryAndVisibleText() {
        let (container, scrollView, textView, gutter) = makeEditor(
            text: (1...40).map { "Line \($0) with words." }.joined(separator: "\n")
        )

        XCTAssertTrue(container.isGutterVisible)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 0.5, "the clip view must not compensate for the gutter")
        XCTAssertGreaterThan(textView.visibleRect.width, 100)
        XCTAssertGreaterThan(textView.frame.width, gutter.preferredWidth)
        XCTAssertGreaterThan(
            textAreaInk(in: container, gutterWidth: gutter.preferredWidth), 0,
            "the note must stay visible next to the gutter: clip=\(scrollView.contentView.frame) text=\(textView.frame) visible=\(textView.visibleRect)"
        )
    }

    func testTogglingTheGutterKeepsTheNoteVisible() {
        let (window, container, scrollView, _, gutter) = makeWindowEditor(
            text: "The note must stay visible.\nSecond line.\nThird line."
        )
        defer { window.close() }

        var ink = textAreaInk(in: container, gutterWidth: gutter.preferredWidth)
        XCTAssertGreaterThan(ink, 0, "visible with the gutter on")

        container.setGutterVisible(false)
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.frame.minX, 0, accuracy: 0.5, "the editor takes the full width when the gutter hides")
        ink = textAreaInk(in: container, gutterWidth: 0)
        XCTAssertGreaterThan(ink, 0, "visible with the gutter off")

        container.setGutterVisible(true)
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        ink = textAreaInk(in: container, gutterWidth: gutter.preferredWidth)
        XCTAssertGreaterThan(ink, 0, "visible again with the gutter back on")
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 0.5)
    }

    func testGutterLayoutHandsItsWidthToTheEditor() {
        let (container, scrollView, _, gutter) = makeEditor(text: "hello", gutterVisible: false)

        XCTAssertEqual(scrollView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scrollView.frame.width, container.bounds.width, accuracy: 0.5)

        container.setGutterVisible(true)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.frame.minX, gutter.preferredWidth, accuracy: 0.5)
        XCTAssertEqual(gutter.frame.width, gutter.preferredWidth, accuracy: 0.5)
        XCTAssertEqual(scrollView.frame.maxX, container.bounds.width, accuracy: 0.5)
    }

    // MARK: - Gutter behavior

    func testGutterUsesFlippedCoordinates() {
        let (_, _, _, gutter) = makeEditor(text: "hello")

        XCTAssertTrue(gutter.isFlipped, "the gutter must share the text view's top-down geometry")
        XCTAssertGreaterThan(gutter.preferredWidth, 0)
    }

    func testWidthFitsAtLeastTwoDigits() {
        let (_, _, _, gutter) = makeEditor(text: "one\ntwo\nthree")

        XCTAssertGreaterThanOrEqual(gutter.preferredWidth, 20)
        XCTAssertLessThan(gutter.preferredWidth, 60)
    }

    func testWidthGrowsWithLineCount() {
        let few = makeEditor(text: "one\ntwo\nthree").gutter
        let many = makeEditor(text: Array(repeating: "line", count: 150).joined(separator: "\n")).gutter

        XCTAssertGreaterThan(many.preferredWidth, few.preferredWidth)
    }

    func testLabelsCountLogicalLinesNotWrappedRows() {
        let paragraph = String(repeating: "wrap ", count: 80).trimmingCharacters(in: .whitespaces)
        let (_, _, textView, gutter) = makeEditor(text: paragraph, width: 240)

        XCTAssertGreaterThan(lineFragmentCount(in: textView), 1, "precondition: the paragraph must wrap")
        let labels = gutter.labels(in: everything)
        XCTAssertEqual(labels.count, 1, "a wrapped paragraph keeps a single number")
        XCTAssertEqual(labels.first?.number, 1)
    }

    func testLabelsContinueNumberingAfterAWrappedLine() {
        let first = String(repeating: "wrap ", count: 30).trimmingCharacters(in: .whitespaces)
        let (_, _, textView, gutter) = makeEditor(text: first + "\nsecond\nthird", width: 240)

        XCTAssertGreaterThan(lineFragmentCount(in: textView), 3, "precondition: the first line must wrap")
        XCTAssertEqual(gutter.labels(in: everything).map(\.number), [1, 2, 3])
    }

    func testLogicalSpacingDoesNotCreateNumbersForWrappedFragments() {
        let first = String(repeating: "wrap ", count: 30).trimmingCharacters(in: .whitespaces)
        let (_, _, textView, gutter) = makeEditor(
            text: first + "\nsecond",
            width: 240,
            logicalLineSpacing: 20
        )

        XCTAssertGreaterThan(lineFragmentCount(in: textView), 2, "precondition: the first line must wrap")
        XCTAssertEqual(gutter.labels(in: everything).map(\.number), [1, 2])
    }

    func testGutterLabelsStayCenteredOnTextWhenLogicalSpacingIsLarge() {
        let (_, _, textView, gutter) = makeEditor(
            text: "first logical line\nsecond logical line",
            logicalLineSpacing: 40
        )
        let labels = gutter.labels(in: everything)

        var usedRects: [NSRect] = []
        guard let layoutManager = textView.layoutManager else {
            XCTFail("the editor should have a layout manager")
            return
        }
        let nsString = textView.string as NSString
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            let location = min(characterRange.location, nsString.length)
            if location == 0 || nsString.character(at: location - 1) == 0x0A {
                usedRects.append(usedRect)
            }
        }

        XCTAssertEqual(labels.map(\.number), [1, 2])
        XCTAssertEqual(usedRects.count, 2)
        XCTAssertEqual(labels.count, usedRects.count)
        for (label, usedRect) in zip(labels, usedRects) {
            let converted = gutter.convert(
                usedRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y),
                from: textView
            )
            XCTAssertEqual(label.rect.midY, converted.midY, accuracy: 0.5)
        }
    }

    func testLabelsIncludeBlankAndTrailingEmptyLines() {
        let (_, _, _, gutter) = makeEditor(text: "alpha\n\nbeta\n")

        let labels = gutter.labels(in: everything)
        XCTAssertEqual(labels.map(\.number), [1, 2, 3, 4], "the empty line after the trailing newline is line 4")
        XCTAssertTrue(
            zip(labels, labels.dropFirst()).allSatisfy { $0.rect.minY < $1.rect.minY },
            "numbers should climb down the gutter"
        )
    }

    func testLabelsAreEmptyBelowTheText() {
        let (_, _, _, gutter) = makeEditor(text: "only line")

        let belowTheText = NSRect(x: 0, y: 400, width: gutter.preferredWidth, height: 40)
        XCTAssertTrue(gutter.labels(in: belowTheText).isEmpty)
    }

    func testDrawingWrappedBlankAndTrailingLinesDoesNotCrash() {
        let text = """
        one very long paragraph that will wrap across several rows because the container is narrow

        final line
        """
        let (_, _, _, gutter) = makeEditor(text: text, width: 240)

        _ = render(gutter)
    }

    // MARK: - The real SwiftUI embedding

    func testHostedEditorWithGutterKeepsTheNoteVisible() throws {
        let longText = (1...60).map { "Line \($0) with some words." }.joined(separator: "\n")
        let editor = MarkdownTextView(
            text: .constant(longText),
            pendingCommand: .constant(nil),
            scrollRequest: .constant(nil),
            activeLocation: .constant(0),
            scrollSync: nil,
            onScroll: { _ in },
            focusMode: false,
            typewriterMode: false,
            showLineNumbers: true,
            fontSize: 14,
            logicalLineSpacing: 0,
            editorID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            documentURL: URL(fileURLWithPath: "/tmp/gutter-hosted.md"),
            documentSessionID: UUID(),
            documentRevision: 0,
            isInlineEditActive: false,
            inlineEditActivation: .constant(nil),
            pendingReplacement: .constant(nil),
            selectionRestore: .constant(nil),
            onInlineEditCapture: { _, _ in },
            onInlineEditAnchorUpdate: { _, _ in },
            onInlineEditApplicationResult: { _, _ in }
        )
        let hosting = NSHostingView(rootView: editor)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 380)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        var container: EditorContainerView?
        func findContainer(in view: NSView) {
            if let match = view as? EditorContainerView { container = match; return }
            for subview in view.subviews where container == nil {
                findContainer(in: subview)
            }
        }
        findContainer(in: hosting)

        let editorContainer = try XCTUnwrap(container, "the hosted editor should embed an EditorContainerView")
        let textView = try XCTUnwrap(editorContainer.scrollView.documentView as? NSTextView)
        XCTAssertTrue(editorContainer.isGutterVisible)
        XCTAssertEqual(editorContainer.scrollView.contentView.bounds.origin.x, 0, accuracy: 0.5)
        XCTAssertGreaterThan(textView.frame.width, editorContainer.gutter.preferredWidth)
        XCTAssertGreaterThan(
            textAreaInk(in: editorContainer, gutterWidth: editorContainer.gutter.preferredWidth), 0,
            "the note must stay visible in the hosted editor: clip=\(editorContainer.scrollView.contentView.frame) text=\(textView.frame) visible=\(textView.visibleRect)"
        )
    }
}
