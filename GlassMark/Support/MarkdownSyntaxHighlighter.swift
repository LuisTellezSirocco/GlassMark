import Foundation

/// Semantic classification of a Markdown token, mapped to text attributes by the
/// editor. Kept UI-agnostic so the tokenizer can be unit-tested in isolation.
enum MarkdownTokenStyle: Equatable {
    case heading(level: Int)
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    case codeBlock
    case blockquote
    case listMarker
    case link
    case delimiter
}

/// Retains line tokens and fence state. A local edit only reparses changed lines
/// and any following lines whose fenced-code context changed.
struct MarkdownHighlightCache {
    struct Update {
        let range: NSRange
        let tokens: [MarkdownToken]
        let lineStarts: [Int]
        let parsedLineCount: Int
    }

    private struct Line {
        let text: String
        let incomingFence: Character?
        let outgoingFence: Character?
        let tokens: [MarkdownToken]
    }

    private var lines: [Line] = []
    private let highlighter = MarkdownSyntaxHighlighter()

    mutating func update(_ text: String, forceFull: Bool = false) -> Update {
        let source = text.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(source.count, lines.count), source[prefix].utf16.elementsEqual(lines[prefix].text.utf16) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(source.count, lines.count) - prefix,
              source[source.count - suffix - 1].utf16.elementsEqual(lines[lines.count - suffix - 1].text.utf16) {
            suffix += 1
        }

        var updated: [Line] = []
        updated.reserveCapacity(source.count)
        var starts: [Int] = []
        starts.reserveCapacity(source.count)
        var offset = 0
        var fence: Character?
        var parsed = 0
        // Include the preceding newline: inserted text can inherit its styling.
        let firstChanged = max(0, prefix - 1)
        var endChanged = min(source.count, max(firstChanged + 1, source.count - suffix))

        for (index, line) in source.enumerated() {
            starts.append(offset)
            offset += line.utf16.count + 1
            let oldIndex: Int? = index < prefix ? index
                : (index >= source.count - suffix ? index + lines.count - source.count : nil)
            if let oldIndex, lines[oldIndex].incomingFence == fence {
                let cached = lines[oldIndex]
                updated.append(cached)
                fence = cached.outgoingFence
            } else {
                let incoming = fence
                let tokens = highlighter.tokens(inLine: line, openFence: &fence)
                updated.append(Line(text: line, incomingFence: incoming, outgoingFence: fence, tokens: tokens))
                parsed += 1
                endChanged = max(endChanged, index + 1)
            }
        }
        let unchanged = prefix == source.count && source.count == lines.count
        lines = updated
        let lower = forceFull ? 0 : firstChanged
        let upper = forceFull ? lines.count : endChanged
        let totalLength = offset - 1
        let end = upper < starts.count ? starts[upper] : totalLength
        let range = !forceFull && unchanged ? NSRange(location: 0, length: 0)
            : NSRange(location: starts[lower], length: end - starts[lower])
        var tokens: [MarkdownToken] = []
        if range.length > 0 {
            for index in lower..<upper {
                tokens.append(contentsOf: lines[index].tokens.map {
                    MarkdownToken(range: NSRange(location: starts[index] + $0.range.location, length: $0.range.length), style: $0.style)
                })
            }
        }
        return Update(range: range, tokens: tokens, lineStarts: starts, parsedLineCount: parsed)
    }
}

struct MarkdownToken: Equatable {
    let range: NSRange
    let style: MarkdownTokenStyle
}

/// Produces a flat list of tokens describing Markdown syntax for editor
/// highlighting. Ranges are UTF-16 offsets compatible with `NSTextStorage`.
struct MarkdownSyntaxHighlighter {
    func tokens(in text: String) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        var offset = 0
        var openFence: Character?

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            tokens.append(contentsOf: self.tokens(inLine: line, openFence: &openFence).map {
                MarkdownToken(range: NSRange(location: offset + $0.range.location, length: $0.range.length), style: $0.style)
            })
            offset += line.utf16.count + 1
        }
        return tokens
    }

    /// Relative ranges allow unchanged lines to survive edits earlier in the note.
    fileprivate func tokens(inLine rawLine: String, openFence: inout Character?) -> [MarkdownToken] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        let lineRange = NSRange(location: 0, length: line.utf16.count)
        if let fence = fenceCharacter(of: line) {
            if let current = openFence {
                if fence == current { openFence = nil }
            } else {
                openFence = fence
            }
            return [MarkdownToken(range: lineRange, style: .codeBlock)]
        }
        if openFence != nil { return [MarkdownToken(range: lineRange, style: .codeBlock)] }
        var tokens: [MarkdownToken] = []
        appendBlockTokens(line: line, lineStart: 0, into: &tokens)
        appendInlineTokens(line: line, lineStart: 0, into: &tokens)
        return tokens
    }

    private func fenceCharacter(of line: String) -> Character? {
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        return count >= 3 ? first : nil
    }

    private func appendBlockTokens(line: String, lineStart: Int, into tokens: inout [MarkdownToken]) {
        let nsLine = line as NSString
        let indent = line.prefix(while: { $0 == " " }).count

        // Headings.
        let afterIndent = Array(line.dropFirst(indent))
        var level = 0
        while level < afterIndent.count, afterIndent[level] == "#" { level += 1 }
        if level >= 1, level <= 6, level < afterIndent.count, afterIndent[level] == " " {
            tokens.append(MarkdownToken(range: NSRange(location: lineStart, length: nsLine.length), style: .heading(level: level)))
            return
        }

        // Blockquote.
        if afterIndent.first == ">" {
            tokens.append(MarkdownToken(range: NSRange(location: lineStart, length: nsLine.length), style: .blockquote))
            return
        }

        // List markers (unordered and ordered).
        if afterIndent.count >= 2 {
            let first = afterIndent[0]
            if (first == "-" || first == "*" || first == "+"), afterIndent[1] == " " {
                let markerStart = lineStart + (String(line.prefix(indent)) as NSString).length
                tokens.append(MarkdownToken(range: NSRange(location: markerStart, length: 1), style: .listMarker))
            } else if first.isNumber {
                var cursor = 0
                while cursor < afterIndent.count, afterIndent[cursor].isNumber { cursor += 1 }
                if cursor < afterIndent.count, afterIndent[cursor] == "." || afterIndent[cursor] == ")",
                   cursor + 1 < afterIndent.count, afterIndent[cursor + 1] == " " {
                    let markerStart = lineStart + (String(line.prefix(indent)) as NSString).length
                    tokens.append(MarkdownToken(range: NSRange(location: markerStart, length: cursor + 1), style: .listMarker))
                }
            }
        }
    }

    private func appendInlineTokens(line: String, lineStart: Int, into tokens: inout [MarkdownToken]) {
        let chars = Array(line)
        var index = 0
        var utf16Offset = 0

        func utf16Length(_ range: ClosedRange<Int>) -> Int {
            chars[range].reduce(0) { $0 + String($1).utf16.count }
        }

        while index < chars.count {
            let character = chars[index]
            let characterUTF16 = String(character).utf16.count

            switch character {
            case "`":
                if let end = matchRun(chars, from: index, character: "`") {
                    let length = utf16Length(index...end)
                    tokens.append(MarkdownToken(range: NSRange(location: lineStart + utf16Offset, length: length), style: .inlineCode))
                    utf16Offset += length
                    index = end + 1
                    continue
                }
            case "*", "_", "~":
                if let (end, style) = matchEmphasis(chars, from: index) {
                    let length = utf16Length(index...end)
                    tokens.append(MarkdownToken(range: NSRange(location: lineStart + utf16Offset, length: length), style: style))
                    utf16Offset += length
                    index = end + 1
                    continue
                }
            case "[":
                if let end = matchLink(chars, from: index) {
                    let length = utf16Length(index...end)
                    tokens.append(MarkdownToken(range: NSRange(location: lineStart + utf16Offset, length: length), style: .link))
                    utf16Offset += length
                    index = end + 1
                    continue
                }
            default:
                break
            }

            utf16Offset += characterUTF16
            index += 1
        }
    }

    /// Finds the end index of a delimiter run starting at `from` (e.g. a code span).
    private func matchRun(_ chars: [Character], from start: Int, character: Character) -> Int? {
        var ticks = 0
        var cursor = start
        while cursor < chars.count, chars[cursor] == character { ticks += 1; cursor += 1 }
        var search = cursor
        while search < chars.count {
            if chars[search] == character {
                var closing = 0
                var probe = search
                while probe < chars.count, chars[probe] == character { closing += 1; probe += 1 }
                if closing == ticks { return probe - 1 }
                search = probe
            } else {
                search += 1
            }
        }
        return nil
    }

    private func matchEmphasis(_ chars: [Character], from start: Int) -> (end: Int, style: MarkdownTokenStyle)? {
        let delimiter = chars[start]
        var runLength = 0
        var cursor = start
        while cursor < chars.count, chars[cursor] == delimiter { runLength += 1; cursor += 1 }
        guard cursor < chars.count, chars[cursor] != " " else { return nil }

        let desired = delimiter == "~" ? 2 : min(runLength, 2)
        if delimiter == "~", runLength < 2 { return nil }

        var search = cursor
        while search < chars.count {
            if chars[search] == delimiter, chars[search - 1] != " " {
                var closing = 0
                var probe = search
                while probe < chars.count, chars[probe] == delimiter { closing += 1; probe += 1 }
                if closing >= desired {
                    let style: MarkdownTokenStyle
                    if delimiter == "~" { style = .strikethrough }
                    else { style = desired >= 2 ? .strong : .emphasis }
                    return (probe - 1, style)
                }
                search = probe
            } else {
                search += 1
            }
        }
        return nil
    }

    private func matchLink(_ chars: [Character], from start: Int) -> Int? {
        var cursor = start + 1
        var depth = 1
        while cursor < chars.count {
            if chars[cursor] == "[" { depth += 1 }
            if chars[cursor] == "]" { depth -= 1; if depth == 0 { break } }
            cursor += 1
        }
        guard cursor < chars.count, cursor + 1 < chars.count, chars[cursor + 1] == "(" else { return nil }
        var urlCursor = cursor + 2
        while urlCursor < chars.count, chars[urlCursor] != ")" { urlCursor += 1 }
        guard urlCursor < chars.count, chars[urlCursor] == ")" else { return nil }
        return urlCursor
    }
}
