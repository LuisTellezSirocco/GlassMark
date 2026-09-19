import AppKit
import SwiftUI
import XCTest
@testable import GlassMark

/// Tab/Shift-Tab behavior: a selection is indented (it is never deleted and
/// replaced by a literal tab), and the indent is written with spaces so the
/// result renders the way Markdown understands indentation.
@MainActor
final class EditorIndentationTests: XCTestCase {
    private var textView: NSTextView!
    private var coordinator: MarkdownTextView.Coordinator!
    private var boundText = ""

    override func setUp() {
        super.setUp()
        textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        coordinator = MarkdownTextView.Coordinator(
            text: Binding(get: { self.boundText }, set: { self.boundText = $0 }),
            activeLocation: .constant(0)
        )
        coordinator.textView = textView
        textView.delegate = coordinator
    }

    private func load(_ text: String, selection: NSRange) {
        boundText = text
        textView.string = text
        textView.setSelectedRange(selection)
    }

    @discardableResult
    private func pressTab() -> Bool {
        coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))
    }

    @discardableResult
    private func pressShiftTab() -> Bool {
        coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    }

    func testTabIndentsAllSelectedLinesWithSpaces() {
        load("uno\ndos", selection: NSRange(location: 0, length: 7))
        pressTab()
        XCTAssertEqual(textView.string, "    uno\n    dos")
        XCTAssertEqual(boundText, "    uno\n    dos")
        XCTAssertFalse(textView.string.contains("\t"), "Markdown indentation must use spaces, not tabs")
        // The selection stays over the same text so repeated presses keep working.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 11))
    }

    func testRepeatedTabKeepsIndentingTheSameBlock() {
        load("uno\ndos", selection: NSRange(location: 0, length: 7))
        pressTab()
        pressTab()
        XCTAssertEqual(textView.string, "        uno\n        dos")
    }

    func testTabIndentsLineWithPartialSelection() {
        load("uno\ndos", selection: NSRange(location: 2, length: 3))
        pressTab()
        XCTAssertEqual(textView.string, "    uno\n    dos")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 7))
    }

    func testTabSkipsBlankLinesInsideTheSelection() {
        load("uno\n\ndos", selection: NSRange(location: 0, length: 8))
        pressTab()
        XCTAssertEqual(textView.string, "    uno\n\n    dos")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 12))
    }

    func testTabWithNoSelectionInsertsSoftSpaces() {
        load("abc", selection: NSRange(location: 3, length: 0))
        pressTab()
        XCTAssertEqual(textView.string, "abc ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testTabAtLineStartInsertsFourSpaces() {
        load("abc", selection: NSRange(location: 0, length: 0))
        pressTab()
        XCTAssertEqual(textView.string, "    abc")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testShiftTabOutdentsSelectedLines() {
        load("    uno\n    dos", selection: NSRange(location: 0, length: 15))
        pressShiftTab()
        XCTAssertEqual(textView.string, "uno\ndos")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 7))
    }

    func testShiftTabWithoutSelectionOutdentsCurrentLine() {
        load("    abc", selection: NSRange(location: 7, length: 0))
        pressShiftTab()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testShiftTabOnUnindentedLineDoesNothing() {
        load("abc", selection: NSRange(location: 1, length: 0))
        pressShiftTab()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testTabInsideTableStillMovesToNextCell() {
        load("| a | b |", selection: NSRange(location: 2, length: 0))
        pressTab()
        XCTAssertEqual(textView.string, "| a | b |")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testIndentIsASingleUndoStep() {
        load("uno\ndos", selection: NSRange(location: 0, length: 7))
        pressTab()
        XCTAssertEqual(textView.string, "    uno\n    dos")
        coordinator.editorUndoManager.undo()
        XCTAssertEqual(textView.string, "uno\ndos")
    }
}
