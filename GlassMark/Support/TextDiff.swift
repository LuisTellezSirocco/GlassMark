import Foundation

enum DiffRowKind: Equatable, Sendable {
    case unchanged
    case inserted
    case removed
}

/// A single unified-diff row. `text` excludes the line terminator, which is kept
/// in `newline` so both sides can be reconstructed byte-for-byte.
struct DiffRow: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: DiffRowKind
    let text: String
    let newline: String

    var hasCarriageReturn: Bool { newline == "\r\n" }
    var hasNoTerminator: Bool { newline.isEmpty }
}

struct TextDiffResult: Equatable, Sendable {
    let rows: [DiffRow]
    let insertedLineCount: Int
    let removedLineCount: Int
    let exceedsBudget: Bool
}

/// Line-based diff built on the standard library's `CollectionDifference`.
/// Comparison is exact UTF-16 (not canonical equivalence).
enum TextDiff {
    struct Line: Equatable, Sendable {
        let text: String
        let newline: String

        var rawValue: String { text + newline }

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.text.isExactlyEqual(to: rhs.text) && lhs.newline == rhs.newline
        }
    }

    static func makeRows(original: String, proposed: String) -> TextDiffResult {
        let originalLines = splitLines(original)
        let proposedLines = splitLines(proposed)

        if originalLines.count > InlineEditLimits.diffMaxLines
            || proposedLines.count > InlineEditLimits.diffMaxLines
            || originalLines.count * proposedLines.count > InlineEditLimits.diffMaxLineProduct {
            return TextDiffResult(rows: [], insertedLineCount: 0, removedLineCount: 0, exceedsBudget: true)
        }

        let difference = proposedLines.difference(from: originalLines)
        var inserted: [Int: Line] = [:]
        var removed: [Int: Line] = [:]
        for change in difference {
            switch change {
            case .insert(let offset, let element, _):
                // Insert offsets are indices in the proposed (new) collection.
                inserted[offset] = element
            case .remove(let offset, let element, _):
                // Remove offsets are indices in the original collection.
                removed[offset] = element
            }
        }

        var rows: [DiffRow] = []
        rows.reserveCapacity(originalLines.count + inserted.count)
        var insertedCount = 0
        var removedCount = 0
        var rowID = 0
        var originalIndex = 0
        var proposedIndex = 0

        while originalIndex < originalLines.count || proposedIndex < proposedLines.count {
            if originalIndex < originalLines.count, removed[originalIndex] != nil {
                let line = originalLines[originalIndex]
                rows.append(DiffRow(id: rowID, kind: .removed, text: line.text, newline: line.newline))
                removedCount += 1
                rowID += 1
                originalIndex += 1
                continue
            }
            if proposedIndex < proposedLines.count, let line = inserted[proposedIndex] {
                rows.append(DiffRow(id: rowID, kind: .inserted, text: line.text, newline: line.newline))
                insertedCount += 1
                rowID += 1
                proposedIndex += 1
                continue
            }
            if originalIndex < originalLines.count, proposedIndex < proposedLines.count {
                let line = originalLines[originalIndex]
                rows.append(DiffRow(id: rowID, kind: .unchanged, text: line.text, newline: line.newline))
                rowID += 1
                originalIndex += 1
                proposedIndex += 1
                continue
            }
            break
        }

        return TextDiffResult(
            rows: rows,
            insertedLineCount: insertedCount,
            removedLineCount: removedCount,
            exceedsBudget: false
        )
    }

    /// Splits a string into lines, keeping each terminator ("", "\n" or "\r\n").
    /// `splitLines("a\n").map(\.rawValue).joined() == "a\n"` always holds.
    static func splitLines(_ string: String) -> [Line] {
        var lines: [Line] = []
        var lineStart = string.startIndex
        var index = string.startIndex

        while index < string.endIndex {
            let character = string[index]
            if character == "\n" || character == "\r" {
                let content = String(string[lineStart..<index])
                var newline = String(character)
                if character == "\r" {
                    let next = string.index(after: index)
                    if next < string.endIndex, string[next] == "\n" {
                        newline = "\r\n"
                        index = next
                    }
                }
                lines.append(Line(text: content, newline: newline))
                index = string.index(after: index)
                lineStart = index
            } else {
                index = string.index(after: index)
            }
        }

        if lineStart < string.endIndex {
            lines.append(Line(text: String(string[lineStart...]), newline: ""))
        }
        return lines
    }

    static func reconstructOriginal(from rows: [DiffRow]) -> String {
        rows.filter { $0.kind != .inserted }
            .map { $0.text + $0.newline }
            .joined()
    }

    static func reconstructProposed(from rows: [DiffRow]) -> String {
        rows.filter { $0.kind != .removed }
            .map { $0.text + $0.newline }
            .joined()
    }
}
