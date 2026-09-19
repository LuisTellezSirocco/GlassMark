import XCTest
@testable import GlassMark

final class GeminiChatStepAssemblerTests: XCTestCase {
    private func message(_ type: String, _ body: String) -> SSEMessage {
        SSEMessage(event: type, data: body)
    }

    func testThoughtSignatureIsRetainedButNotEmitted() throws {
        var assembler = GeminiChatStepAssembler()
        XCTAssertEqual(
            try assembler.handle(message("interaction.created", #"{"interaction":{"id":"i1","model":"gemini-3.5-flash-lite"},"event_type":"interaction.created"}"#)),
            .started(providerInteractionID: "i1", effectiveModelID: "gemini-3.5-flash-lite")
        )
        XCTAssertNil(try assembler.handle(message("step.start", #"{"index":0,"step":{"type":"thought"},"event_type":"step.start"}"#)))
        XCTAssertNil(try assembler.handle(message("step.delta", #"{"index":0,"delta":{"type":"thought_signature","signature":"opaque"},"event_type":"step.delta"}"#)))
        XCTAssertNil(try assembler.handle(message("step.stop", #"{"index":0,"event_type":"step.stop"}"#)))
        XCTAssertNil(try assembler.handle(message("step.start", #"{"index":1,"step":{"type":"model_output"},"event_type":"step.start"}"#)))
        XCTAssertEqual(
            try assembler.handle(message("step.delta", #"{"index":1,"delta":{"type":"text","text":"Hello"},"event_type":"step.delta"}"#)),
            .textDelta("Hello")
        )
        XCTAssertNil(try assembler.handle(message("step.stop", #"{"index":1,"event_type":"step.stop"}"#)))
        let completed = try XCTUnwrap(try assembler.handle(message("interaction.completed", #"{"interaction":{"status":"completed"},"event_type":"interaction.completed"}"#)))
        guard case .completed(let result) = completed else { return XCTFail("expected completion") }
        XCTAssertEqual(result.visibleText, "Hello")
        let steps = try XCTUnwrap(JSONSerialization.jsonObject(with: result.replayStepsJSON) as? [[String: Any]])
        XCTAssertEqual(steps.first?["signature"] as? String, "opaque")
    }
}
