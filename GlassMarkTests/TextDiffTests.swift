import XCTest
@testable import GlassMark

final class TextDiffTests: XCTestCase {
    private func assertReconstructs(
        original: String,
        proposed: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = TextDiff.makeRows(original: original, proposed: proposed)
        if result.exceedsBudget {
            return
        }
        XCTAssertEqual(TextDiff.reconstructOriginal(from: result.rows), original, file: file, line: line)
        XCTAssertEqual(TextDiff.reconstructProposed(from: result.rows), proposed, file: file, line: line)
    }

    func testIdenticalTextHasNoChanges() {
        let result = TextDiff.makeRows(original: "a\nb\n", proposed: "a\nb\n")
        XCTAssertEqual(result.insertedLineCount, 0)
        XCTAssertEqual(result.removedLineCount, 0)
        XCTAssertTrue(result.rows.allSatisfy { $0.kind == .unchanged })
    }

    func testReplacementCountsAndOrder() {
        let result = TextDiff.makeRows(original: "a\nb\n", proposed: "a\nc\n")
        XCTAssertEqual(result.removedLineCount, 1)
        XCTAssertEqual(result.insertedLineCount, 1)
        XCTAssertEqual(result.rows.map(\.kind), [.unchanged, .removed, .inserted])
        XCTAssertEqual(result.rows[1].text, "b")
        XCTAssertEqual(result.rows[2].text, "c")
        assertReconstructs(original: "a\nb\n", proposed: "a\nc\n")
    }

    func testInsertionAtStartMiddleAndEnd() {
        assertReconstructs(original: "a\nb\nc\n", proposed: "x\na\nb\nc\ny\n")
        assertReconstructs(original: "a\nb\nc\n", proposed: "a\nx\nb\nc\n")
    }

    func testDeletion() {
        let result = TextDiff.makeRows(original: "a\nb\nc\n", proposed: "a\nc\n")
        XCTAssertEqual(result.removedLineCount, 1)
        XCTAssertEqual(result.insertedLineCount, 0)
        assertReconstructs(original: "a\nb\nc\n", proposed: "a\nc\n")
    }

    func testCRLFAndMixedTerminators() {
        assertReconstructs(original: "a\r\nb\r\n", proposed: "a\nb\n")
        assertReconstructs(original: "a\r\nb", proposed: "a\r\nc")
        assertReconstructs(original: "a\nb", proposed: "a\r\nb")
    }

    func testNoTrailingNewline() {
        let result = TextDiff.makeRows(original: "a", proposed: "a\n")
        XCTAssertEqual(result.rows.map(\.kind), [.removed, .inserted])
        XCTAssertTrue(result.rows[0].hasNoTerminator)
        XCTAssertEqual(result.rows[1].newline, "\n")
        assertReconstructs(original: "a", proposed: "a\n")
    }

    func testRepeatedLinesAreStable() {
        assertReconstructs(original: "x\nx\nx\n", proposed: "x\nx\n")
        assertReconstructs(original: "x\nx\n", proposed: "x\nx\nx\n")
    }

    func testUnicodeContent() {
        assertReconstructs(original: "hola 🚀\nmundo\nañ\n", proposed: "hola 🌍\nmundo\nañ\n")
    }

    func testEmptyStrings() {
        assertReconstructs(original: "", proposed: "")
        assertReconstructs(original: "", proposed: "a\n")
        assertReconstructs(original: "a\n", proposed: "")
    }

    func testSplitLinesRoundTrips() {
        for source in ["", "a", "a\n", "a\nb", "a\r\nb\r\n", "a\rb", "x\n\n\ny\n"] {
            let joined = TextDiff.splitLines(source).map(\.rawValue).joined()
            XCTAssertEqual(joined, source, "source: \(source.debugDescription)")
        }
    }

    func testBudgetExceeded() {
        let original = String(repeating: "line\n", count: InlineEditLimits.diffMaxLines + 1)
        let proposed = original + "extra\n"
        let result = TextDiff.makeRows(original: original, proposed: proposed)
        XCTAssertTrue(result.exceedsBudget)
        XCTAssertTrue(result.rows.isEmpty)
    }
}
