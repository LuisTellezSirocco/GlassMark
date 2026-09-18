import Foundation

/// One event-stream message: the optional `event` name plus the joined `data:` lines.
struct SSEMessage: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Incremental SSE framing (WHATWG event streams): bytes in, messages out.
///
/// Handles UTF-8 multibyte sequences (line delimiters are ASCII, so per-line
/// decoding is safe), an optional leading BOM, LF/CRLF/CR terminators, comments,
/// and multi-line `data:` fields (joined with `\n`). A pending message without its
/// terminating blank line is discarded at EOF.
struct SSEDecoder {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private var undecidedPrefix: [UInt8] = []
    private var prefixDecided = false
    private var lineBytes: [UInt8] = []
    private var pendingCarriageReturn = false
    private var eventName: String?
    private var dataLines: [String] = []

    /// Feeds one byte and returns a message when a blank line completes one.
    mutating func consume(_ byte: UInt8) -> SSEMessage? {
        if !prefixDecided {
            undecidedPrefix.append(byte)
            if undecidedPrefix.count < SSEDecoder.bom.count {
                if Array(SSEDecoder.bom.prefix(undecidedPrefix.count)) == undecidedPrefix {
                    return nil
                }
                return flushPrefix()
            }
            prefixDecided = true
            if undecidedPrefix == SSEDecoder.bom {
                undecidedPrefix = []
                return nil
            }
            return flushPrefix()
        }
        return consumeLineByte(byte)
    }

    private mutating func flushPrefix() -> SSEMessage? {
        prefixDecided = true
        var message: SSEMessage?
        for byte in undecidedPrefix {
            if let emitted = consumeLineByte(byte) {
                message = emitted
            }
        }
        undecidedPrefix = []
        return message
    }

    private mutating func consumeLineByte(_ byte: UInt8) -> SSEMessage? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if byte == 0x0A {
                return nil // LF completing a CRLF pair
            }
        }
        switch byte {
        case 0x0A, 0x0D:
            pendingCarriageReturn = (byte == 0x0D)
            return endLine()
        default:
            lineBytes.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> SSEMessage? {
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        return process(line: line)
    }

    private mutating func process(line: String) -> SSEMessage? {
        if line.isEmpty {
            guard !dataLines.isEmpty || eventName != nil else { return nil }
            let message = SSEMessage(event: eventName, data: dataLines.joined(separator: "\n"))
            eventName = nil
            dataLines = []
            return message
        }

        if line.hasPrefix(":") {
            return nil // comment
        }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        default:
            break // "id", "retry" and unknown fields are ignored
        }
        return nil
    }
}
