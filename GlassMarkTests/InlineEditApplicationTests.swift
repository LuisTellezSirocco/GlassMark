import AppKit
import SwiftUI
import XCTest
@testable import GlassMark

@MainActor
final class InlineEditApplicationTests: XCTestCase {
    private var textView: NSTextView!
    private var coordinator: MarkdownTextView.Coordinator!
    private var boundText = ""

    override func setUp() {
        super.setUp()
        boundText = "hello world"
        textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = boundText
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)

        coordinator = MarkdownTextView.Coordinator(
            text: Binding(get: { self.boundText }, set: { self.boundText = $0 }),
            activeLocation: .constant(0)
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.editorID = UUID()
        coordinator.windowID = UUID()
        coordinator.documentSessionID = UUID()
        coordinator.documentRevision = 0
    }

    private func makeRequest(range: NSRange, original: String, replacement: String) -> ReplacementRequest {
        let target = InlineEditTarget(
            windowID: coordinator.windowID,
            editorID: coordinator.editorID,
            workspaceID: UUID(),
            documentURL: URL(fileURLWithPath: "/tmp/glassmark-test.md"),
            documentSessionID: coordinator.documentSessionID,
            revision: coordinator.documentRevision,
            range: range,
            original: original
        )
        return ReplacementRequest(id: UUID(), generationID: UUID(), target: target, replacement: replacement)
    }

    func testAppliesReplacementLiterally() {
        let outcome = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "HELLO")
        )
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(textView.string, "HELLO world")
        XCTAssertEqual(boundText, "HELLO world")
    }

    func testUndoAndRedoAreSingleActions() {
        _ = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "HELLO")
        )
        XCTAssertEqual(coordinator.editorUndoManager.undoActionName, "Edit with Gemini")

        coordinator.editorUndoManager.undo()
        XCTAssertEqual(textView.string, "hello world")

        coordinator.editorUndoManager.redo()
        XCTAssertEqual(textView.string, "HELLO world")
    }

    func testWrapperCharacterReplacementIsNotAutoPaired() {
        let outcome = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "(")
        )
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(textView.string, "( world")
    }

    func testRedoOfWrapperCharacterIsNotTransformed() {
        _ = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "(")
        )
        coordinator.editorUndoManager.undo()
        XCTAssertEqual(textView.string, "hello world")

        coordinator.editorUndoManager.redo()
        XCTAssertEqual(textView.string, "( world")
    }

    func testEmojiSelectionIsReplacedSafely() {
        textView.string = "hola 🚀 fin"
        boundText = textView.string
        let outcome = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 5, length: 2), original: "🚀", replacement: "planeta")
        )
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(textView.string, "hola planeta fin")
    }

    func testEmptyReplacementDeletesSelection() {
        let outcome = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 6), original: "hello ", replacement: "")
        )
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(textView.string, "world")
    }

    func testRejectsWhenOriginalTextDoesNotMatch() {
        let outcome = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 5), original: "wrong", replacement: "X")
        )
        guard case .rejected = outcome else {
            return XCTFail("expected rejection, got \(outcome)")
        }
        XCTAssertEqual(textView.string, "hello world")
    }

    func testRejectsWhenSessionMismatches() {
        var request = makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "X")
        request = ReplacementRequest(
            id: request.id,
            generationID: request.generationID,
            target: InlineEditTarget(
                windowID: request.target.windowID,
                editorID: request.target.editorID,
                workspaceID: request.target.workspaceID,
                documentURL: request.target.documentURL,
                documentSessionID: UUID(),
                revision: request.target.revision,
                range: request.target.range,
                original: request.target.original
            ),
            replacement: request.replacement
        )
        guard case .rejected = coordinator.applyInlineReplacement(request) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(textView.string, "hello world")
    }

    func testRejectsWhenRevisionMismatches() {
        var request = makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "X")
        request = ReplacementRequest(
            id: request.id,
            generationID: request.generationID,
            target: InlineEditTarget(
                windowID: request.target.windowID,
                editorID: request.target.editorID,
                workspaceID: request.target.workspaceID,
                documentURL: request.target.documentURL,
                documentSessionID: request.target.documentSessionID,
                revision: request.target.revision + 1,
                range: request.target.range,
                original: request.target.original
            ),
            replacement: request.replacement
        )
        guard case .rejected = coordinator.applyInlineReplacement(request) else {
            return XCTFail("expected rejection")
        }
    }

    func testRejectsWhenBoundTextDiffers() {
        boundText = "different content"
        guard case .rejected = coordinator.applyInlineReplacement(
            makeRequest(range: NSRange(location: 0, length: 5), original: "hello", replacement: "X")
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(textView.string, "hello world")
    }

    func testRestoreSelectionRequestAppliesWhenViable() {
        coordinator.documentRevision = 0
        let request = SelectionRestoreRequest(
            id: UUID(),
            editorID: coordinator.editorID,
            documentSessionID: coordinator.documentSessionID,
            range: NSRange(location: 6, length: 5)
        )
        coordinator.processSelectionRestore(request)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 5))
    }
}
