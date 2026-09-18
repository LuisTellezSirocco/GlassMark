import XCTest
@testable import GlassMark

final class GeminiClientTests: XCTestCase {
    // MARK: - Request encoding

    func testEncodedBodyUsesInteractionsSchema() throws {
        let input = GeminiEditInput(
            model: "gemini-3.5-flash-lite",
            instruction: "Fix grammar",
            selection: "me gustan los manzanas",
            thinkingLevel: "low"
        )
        let data = try GeminiClient.encodeBody(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gemini-3.5-flash-lite")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertNotNil(object["system_instruction"])

        let blocks = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        let payloadText = try XCTUnwrap(blocks[0]["text"] as? String)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["instruction"] as? String, "Fix grammar")
        XCTAssertEqual(payload["selection"] as? String, "me gustan los manzanas")

        let config = try XCTUnwrap(object["generation_config"] as? [String: Any])
        XCTAssertEqual(config["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(config["thinking_level"] as? String, "low")
    }

    func testEncodedBodyOmitsThinkingLevelWhenNil() throws {
        let input = GeminiEditInput(model: "custom-model", instruction: "x", selection: "y", thinkingLevel: nil)
        let data = try GeminiClient.encodeBody(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let config = try XCTUnwrap(object["generation_config"] as? [String: Any])
        XCTAssertNil(config["thinking_level"])
        XCTAssertEqual(config["max_output_tokens"] as? Int, 4096)
    }

    func testRequestHeadersAndURL() throws {
        let input = GeminiEditInput(model: "m", instruction: "i", selection: "s")
        let request = try GeminiClient.makeRequest(input: input, apiKey: "secret-key")
        XCTAssertEqual(request.url, GeminiClient.endpointURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testValidationRejectsBadInput() {
        XCTAssertThrowsError(
            try GeminiClient.validate(
                input: GeminiEditInput(model: "m", instruction: "i", selection: "s"),
                apiKey: "   "
            )
        ) { error in
            XCTAssertEqual(error as? GeminiAPIError, .authentication)
        }

        let hugeSelection = String(repeating: "a", count: InlineEditLimits.maxSelectionUTF16 + 1)
        XCTAssertThrowsError(
            try GeminiClient.validate(
                input: GeminiEditInput(model: "m", instruction: "i", selection: hugeSelection),
                apiKey: "k"
            )
        ) { error in
            guard case .localLimit = error as? GeminiAPIError else {
                return XCTFail("expected localLimit, got \(error)")
            }
        }
    }

    // MARK: - Event decoding

    private func message(_ eventType: String, _ json: String) -> SSEMessage {
        SSEMessage(event: eventType, data: json)
    }

    func testEventDecoderHappyPath() throws {
        var decoder = GeminiEventDecoder()

        let started = try decoder.handle(message("interaction.created",
            #"{"interaction":{"id":"v1_test","status":"in_progress"},"event_type":"interaction.created"}"#))
        XCTAssertEqual(started, .started(id: "v1_test"))

        XCTAssertNil(try decoder.handle(message("step.start",
            #"{"index":0,"step":{"type":"thought"},"event_type":"step.start"}"#)))
        XCTAssertNil(try decoder.handle(message("step.delta",
            #"{"index":0,"delta":{"signature":"xx","type":"thought_signature"},"event_type":"step.delta"}"#)))
        XCTAssertNil(try decoder.handle(message("step.stop",
            #"{"index":0,"event_type":"step.stop"}"#)))

        XCTAssertNil(try decoder.handle(message("step.start",
            #"{"index":1,"step":{"type":"model_output"},"event_type":"step.start"}"#)))
        let first = try decoder.handle(message("step.delta",
            #"{"index":1,"delta":{"text":"me gustan","type":"text"},"event_type":"step.delta"}"#))
        XCTAssertEqual(first, .textDelta("me gustan"))
        let second = try decoder.handle(message("step.delta",
            #"{"index":1,"delta":{"text":" las manzanas","type":"text"},"event_type":"step.delta"}"#))
        XCTAssertEqual(second, .textDelta(" las manzanas"))
        XCTAssertNil(try decoder.handle(message("step.stop",
            #"{"index":1,"event_type":"step.stop"}"#)))

        let completed = try decoder.handle(message("interaction.completed",
            #"{"interaction":{"status":"completed","usage":{"total_tokens":40,"total_input_tokens":36,"total_output_tokens":4}},"event_type":"interaction.completed"}"#))
        XCTAssertEqual(completed, .completed(usage: GeminiUsage(totalTokens: 40, inputTokens: 36, outputTokens: 4)))

        XCTAssertNil(try decoder.handle(SSEMessage(event: "done", data: "[DONE]")))
    }

    func testIncompleteTerminalStatusThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertThrowsError(try decoder.handle(message("interaction.completed",
            #"{"interaction":{"status":"incomplete"},"event_type":"interaction.completed"}"#)))
        { error in
            XCTAssertEqual(error as? GeminiAPIError, .incompleteResponse)
        }
    }

    func testFailedStatusUpdateThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertThrowsError(try decoder.handle(message("interaction.status_update",
            #"{"status":"failed","event_type":"interaction.status_update"}"#)))
    }

    func testTextOutsideOutputStepThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertNoThrow(try decoder.handle(message("step.start",
            #"{"index":0,"step":{"type":"thought"},"event_type":"step.start"}"#)))
        XCTAssertThrowsError(try decoder.handle(message("step.delta",
            #"{"index":0,"delta":{"text":"nope","type":"text"},"event_type":"step.delta"}"#)))
    }

    func testDeltaForUnknownStepThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertThrowsError(try decoder.handle(message("step.delta",
            #"{"index":9,"delta":{"text":"x","type":"text"},"event_type":"step.delta"}"#)))
    }

    func testSecondOutputStepThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertNoThrow(try decoder.handle(message("step.start",
            #"{"index":0,"step":{"type":"model_output"},"event_type":"step.start"}"#)))
        XCTAssertThrowsError(try decoder.handle(message("step.start",
            #"{"index":1,"step":{"type":"model_output"},"event_type":"step.start"}"#)))
    }

    func testCompletedBeforeOutputStepClosesThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertNoThrow(try decoder.handle(message("step.start",
            #"{"index":0,"step":{"type":"model_output"},"event_type":"step.start"}"#)))
        XCTAssertThrowsError(try decoder.handle(message("interaction.completed",
            #"{"interaction":{"status":"completed"},"event_type":"interaction.completed"}"#)))
    }

    func testProviderErrorEventMapsToTypedError() {
        var decoder = GeminiEventDecoder()
        XCTAssertThrowsError(try decoder.handle(message("error",
            #"{"error":{"message":"boom","code":"gateway_timeout"},"event_type":"error"}"#)))
        { error in
            XCTAssertEqual(error as? GeminiAPIError, .providerError(code: "gateway_timeout", message: "boom"))
        }
    }

    func testUnknownEventTypesAreIgnored() throws {
        var decoder = GeminiEventDecoder()
        XCTAssertNil(try decoder.handle(message("something.new",
            #"{"event_type":"something.new","payload":{}}"#)))
    }

    func testMalformedKnownEventThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertThrowsError(try decoder.handle(message("step.start",
            #"{"event_type":"step.start"}"#)))
    }

    func testDoneWithoutCompletionThrows() {
        var decoder = GeminiEventDecoder()
        XCTAssertThrowsError(try decoder.handle(SSEMessage(event: "done", data: "[DONE]")))
    }

    // MARK: - HTTP transport (URLProtocol stub)

    private func makeStubbedClient() -> GeminiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GeminiClient(session: URLSession(configuration: configuration))
    }

    private static func sseBody(_ events: [(String, String)]) -> Data {
        var text = ""
        for (name, payload) in events {
            text += "event: \(name)\ndata: \(payload)\n\n"
        }
        text += "event: done\ndata: [DONE]\n\n"
        return Data(text.utf8)
    }

    func testStreamHappyPathOverHTTP() async throws {
        let body = Self.sseBody([
            ("interaction.created", #"{"interaction":{"id":"v1_a","status":"in_progress"},"event_type":"interaction.created"}"#),
            ("step.start", #"{"index":0,"step":{"type":"model_output"},"event_type":"step.start"}"#),
            ("step.delta", #"{"index":0,"delta":{"text":"hola","type":"text"},"event_type":"step.delta"}"#),
            ("step.stop", #"{"index":0,"event_type":"step.stop"}"#),
            ("interaction.completed", #"{"interaction":{"status":"completed"},"event_type":"interaction.completed"}"#),
        ])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            return (200, ["Content-Type": "text/event-stream"], body)
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        let input = GeminiEditInput(model: "m", instruction: "i", selection: "s")
        var events: [GeminiStreamEvent] = []
        for try await event in client.streamEdit(input, apiKey: "test-key") {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .started(id: "v1_a"),
            .textDelta("hola"),
            .completed(usage: nil),
        ])
    }

    func testStreamEndingWithoutCompletionThrowsIncomplete() async {
        let body = Data("""
        event: interaction.created
        data: {"interaction":{"id":"v1_a","status":"in_progress"},"event_type":"interaction.created"}


        """.utf8)
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], body) }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        do {
            for try await _ in client.streamEdit(
                GeminiEditInput(model: "m", instruction: "i", selection: "s"),
                apiKey: "k"
            ) {}
            XCTFail("expected incompleteResponse")
        } catch {
            XCTAssertEqual(error as? GeminiAPIError, .incompleteResponse)
        }
    }

    func testUnauthorizedMapsToAuthentication() async {
        StubURLProtocol.handler = { _ in (401, ["Content-Type": "application/json"], Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        do {
            for try await _ in client.streamEdit(
                GeminiEditInput(model: "m", instruction: "i", selection: "s"),
                apiKey: "k"
            ) {}
            XCTFail("expected authentication error")
        } catch {
            XCTAssertEqual(error as? GeminiAPIError, .authentication)
        }
    }

    func testRateLimitedReadsRetryAfter() async {
        StubURLProtocol.handler = { _ in
            (429, ["Content-Type": "application/json", "Retry-After": "7"], Data())
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        do {
            for try await _ in client.streamEdit(
                GeminiEditInput(model: "m", instruction: "i", selection: "s"),
                apiKey: "k"
            ) {}
            XCTFail("expected rate limited")
        } catch {
            XCTAssertEqual(error as? GeminiAPIError, .rateLimited(retryAfter: 7))
        }
    }

    func testModelUnavailableExtractsMessage() async {
        StubURLProtocol.handler = { _ in
            (404, ["Content-Type": "application/json"], Data(#"{"error":{"message":"model gone"}}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        do {
            for try await _ in client.streamEdit(
                GeminiEditInput(model: "m", instruction: "i", selection: "s"),
                apiKey: "k"
            ) {}
            XCTFail("expected modelUnavailable")
        } catch {
            XCTAssertEqual(error as? GeminiAPIError, .modelUnavailable("model gone"))
        }
    }

    func testNonEventStreamContentTypeThrows() async {
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        do {
            for try await _ in client.streamEdit(
                GeminiEditInput(model: "m", instruction: "i", selection: "s"),
                apiKey: "k"
            ) {}
            XCTFail("expected invalidProtocol")
        } catch {
            guard case .invalidProtocol = error as? GeminiAPIError else {
                return XCTFail("expected invalidProtocol, got \(error)")
            }
        }
    }
}

/// Minimal URLProtocol stub: returns a canned status, headers and body.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
