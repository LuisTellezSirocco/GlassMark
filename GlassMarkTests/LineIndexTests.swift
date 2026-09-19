import XCTest
@testable import GlassMark

final class LineIndexTests: XCTestCase {
    func testEmptyDocumentHasASingleLine() {
        let starts = LineIndex.lineStarts(in: "" as NSString)
        XCTAssertEqual(starts, [0])
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 0, lineStarts: starts), 1)
    }

    func testTextWithoutNewlinesIsAlwaysLineOne() {
        // A long paragraph is one logical line, however many rows it wraps to on screen.
        let text = "one long paragraph that will certainly be soft-wrapped by the editor margin" as NSString
        let starts = LineIndex.lineStarts(in: text)
        XCTAssertEqual(starts, [0])
        for location in [0, 10, 40, text.length - 1] {
            XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: location, lineStarts: starts), 1)
        }
    }

    func testEachNewlineOpensTheNextLine() {
        let starts = LineIndex.lineStarts(in: "a\nb" as NSString)
        XCTAssertEqual(starts, [0, 2])
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 0, lineStarts: starts), 1)
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 1, lineStarts: starts), 1, "the newline closes line 1")
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 2, lineStarts: starts), 2)
    }

    func testTrailingNewlineOpensAnEmptyLastLine() {
        let starts = LineIndex.lineStarts(in: "a\n" as NSString)
        XCTAssertEqual(starts, [0, 2])
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 2, lineStarts: starts), 2)
    }

    func testBlankLineCountsAsItsOwnLine() {
        let starts = LineIndex.lineStarts(in: "a\n\nb" as NSString)
        XCTAssertEqual(starts, [0, 2, 3])
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 2, lineStarts: starts), 2)
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 3, lineStarts: starts), 3)
    }

    func testMixedDocumentNumbersLinesInOrder() {
        let starts = LineIndex.lineStarts(in: "a\n\nb\n" as NSString)
        XCTAssertEqual(starts, [0, 2, 3, 5])
        // Offsets 0…5 cover the whole string including its end: the newline at
        // offset 4 still belongs to line 3, and offset 5 opens the empty line 4.
        let numbers = (0...5).map { LineIndex.lineNumber(forCharacterAt: $0, lineStarts: starts) }
        XCTAssertEqual(numbers, [1, 1, 2, 3, 3, 4])
    }

    func testCRLFCountsAsOneBreak() {
        let starts = LineIndex.lineStarts(in: "a\r\nb" as NSString)
        XCTAssertEqual(starts, [0, 3])
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 3, lineStarts: starts), 2)
    }

    func testOffsetsPastTheEndClampToTheLastLine() {
        let starts = LineIndex.lineStarts(in: "a\nb" as NSString)
        XCTAssertEqual(LineIndex.lineNumber(forCharacterAt: 99, lineStarts: starts), 2)
    }
}
