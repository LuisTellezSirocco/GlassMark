import XCTest
@testable import GlassMark

final class SSEDecoderTests: XCTestCase {
    private func messages(from string: String, chunkSize: Int = 1) -> [SSEMessage] {
        var decoder = SSEDecoder()
        var result: [SSEMessage] = []
        let bytes = Array(string.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            for byte in bytes[index..<end] {
                if let message = decoder.consume(byte) {
                    result.append(message)
                }
            }
            index = end
        }
        return result
    }

    func testSingleMessageLF() {
        let result = messages(from: "event: step.delta\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(result, [SSEMessage(event: "step.delta", data: "{\"a\":1}")])
    }

    func testCRLFTerminators() {
        let result = messages(from: "event: x\r\ndata: y\r\n\r\n")
        XCTAssertEqual(result, [SSEMessage(event: "x", data: "y")])
    }

    func testLoneCRTerminators() {
        let result = messages(from: "data: a\r\r")
        XCTAssertEqual(result, [SSEMessage(event: nil, data: "a")])
    }

    func testMultipleMessages() {
        let result = messages(from: "data: one\n\ndata: two\n\n")
        XCTAssertEqual(result, [
            SSEMessage(event: nil, data: "one"),
            SSEMessage(event: nil, data: "two"),
        ])
    }

    func testMultilineDataJoinsWithNewline() {
        let result = messages(from: "data: one\ndata: two\ndata: three\n\n")
        XCTAssertEqual(result, [SSEMessage(event: nil, data: "one\ntwo\nthree")])
    }

    func testOnlyOneLeadingSpaceIsStripped() {
        let result = messages(from: "data:  leading space kept\n\n")
        XCTAssertEqual(result, [SSEMessage(event: nil, data: " leading space kept")])
    }

    func testCommentsAndUnknownFieldsAreIgnored() {
        let result = messages(from: ": comment\nid: 7\nretry: 500\nevent: e\ndata: d\n\n")
        XCTAssertEqual(result, [SSEMessage(event: "e", data: "d")])
    }

    func testByteOrderMarkIsStripped() {
        let result = messages(from: "\u{FEFF}data: x\n\n")
        XCTAssertEqual(result, [SSEMessage(event: nil, data: "x")])
    }

    func testIncompleteMessageAtEOFTerminatorIsDiscarded() {
        let result = messages(from: "data: never dispatched")
        XCTAssertEqual(result, [])
    }

    func testMultibyteCharactersAcrossEveryChunkBoundary() {
        let source = "data: añ🚀 fin\n\n"
        for chunkSize in 1...4 {
            XCTAssertEqual(
                messages(from: source, chunkSize: chunkSize),
                [SSEMessage(event: nil, data: "añ🚀 fin")],
                "chunk size \(chunkSize)"
            )
        }
    }

    func testEmptyLinesWithoutDataDoNotEmit() {
        let result = messages(from: "\n\n\ndata: x\n\n")
        XCTAssertEqual(result, [SSEMessage(event: nil, data: "x")])
    }
}
