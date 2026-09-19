import Foundation

/// Logical-line arithmetic for the editor's line-number gutter.
///
/// A logical line is a run of characters delimited by `\n`. Soft wrapping is
/// purely visual: a wrapped paragraph is still one logical line, so it gets a
/// single number no matter how many screen rows it spans. A trailing `\n` opens
/// a final empty line (the one the caret sits on right after pressing Return),
/// matching the status bar's line count.
enum LineIndex {
    /// Character offsets at which each logical line starts. Always begins with
    /// `0`, so an empty document still has a line 1.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            if text.character(at: index) == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    /// 1-based number of the logical line containing `location`.
    ///
    /// Offsets beyond the last start (such as the caret at the end of the
    /// document) clamp into the final line, so callers can pass any offset.
    static func lineNumber(forCharacterAt location: Int, lineStarts: [Int]) -> Int {
        let target = max(0, location)
        var lowerBound = 0
        var upperBound = lineStarts.count - 1
        var match = 0
        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lineStarts[middle] <= target {
                match = middle
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }
        return match + 1
    }
}
