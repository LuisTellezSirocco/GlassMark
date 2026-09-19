import Foundation

/// Chat-specific Interactions transport. It deliberately does not share the
/// inline replacement prompt or decoder, because chat must preserve replay
/// steps (including opaque thought signatures).
struct GeminiChatClient: ChatGenerating {
    static let endpointURL = GeminiClient.endpointURL
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = ChatLimits.requestInactivityTimeout
            configuration.timeoutIntervalForResource = ChatLimits.requestTotalTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    static func makeRequest(_ request: PreparedChatRequest, apiKey: String) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiAPIError.authentication
        }
        guard request.bodyJSON.count <= ChatLimits.maxPayloadBytes else {
            throw GeminiAPIError.localLimit("The chat request is too large or invalid.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.bodyJSON),
              JSONSerialization.isValidJSONObject(object) else {
            throw GeminiAPIError.invalidProtocol("The chat request is not valid JSON.")
        }
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = request.bodyJSON
        return urlRequest
    }

    static func syntheticRequest(modelID: String) throws -> PreparedChatRequest {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiAPIError.localLimit("No model is configured.")
        }
        var config: [String: Any] = [
            "max_output_tokens": 64,
            "thinking_summaries": "none",
        ]
        if let thinking = AIModelCatalog.thinkingLevel(for: modelID) { config["thinking_level"] = thinking }
        let input: [[String: Any]] = [[
            "type": "user_input",
            "content": [["type": "text", "text": "Reply with the single word: ok"]],
        ]]
        let body = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "system_instruction": "You are performing a synthetic connection test. Reply with one word.",
            "input": input,
            "stream": true,
            "store": false,
            "generation_config": config,
        ], options: [.sortedKeys])
        let id = UUID()
        return PreparedChatRequest(
            conversationID: id, turnID: id, attemptID: id, generationID: id,
            modelID: modelID, promptVersion: ChatRequestBuilder.promptVersion,
            inputSchemaVersion: ChatRequestBuilder.inputSchemaVersion,
            systemInstruction: "You are performing a synthetic connection test. Reply with one word.",
            inputStepsJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
            generationConfigJSON: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            bodyJSON: body, requestSHA256: ChatHash.sha256(body), expiresAt: .distantFuture
        )
    }

    func streamChat(
        _ request: PreparedChatRequest,
        apiKey: String
    ) -> AsyncThrowingStream<ChatGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, apiKey: apiKey, continuation: continuation)
                    continuation.finish()
                } catch let error as GeminiAPIError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: GeminiAPIError.cancelled)
                } catch {
                    continuation.finish(throwing: GeminiAPIError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: PreparedChatRequest,
        apiKey: String,
        continuation: AsyncThrowingStream<ChatGenerationEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try Self.makeRequest(request, apiKey: apiKey)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiAPIError.invalidProtocol("Missing HTTP response.")
        }
        guard http.statusCode == 200 else { throw await Self.mapHTTPError(http, bytes: bytes) }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.hasPrefix("text/event-stream") else {
            throw GeminiAPIError.invalidProtocol("Unexpected content type: \(contentType)")
        }

        var framing = SSEDecoder(maxLineBytes: ChatLimits.maxSSEMessageBytes)
        var assembler = GeminiChatStepAssembler()
        var totalBytes = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= ChatLimits.maxSSETotalBytes else {
                throw GeminiAPIError.localLimit("The response exceeded the local size limit.")
            }
            let message = framing.consume(byte)
            guard !framing.exceededLimit else {
                throw GeminiAPIError.localLimit("A response line exceeded the local size limit.")
            }
            guard let message else { continue }
            guard message.data.utf8.count <= ChatLimits.maxSSEMessageBytes else {
                throw GeminiAPIError.localLimit("A response event exceeded the local size limit.")
            }
            if let event = try assembler.handle(message) {
                continuation.yield(event)
                if case .completed = event { return }
            }
        }
        throw GeminiAPIError.incompleteResponse
    }

    private static func mapHTTPError(_ http: HTTPURLResponse, bytes: URLSession.AsyncBytes) async -> GeminiAPIError {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= ChatLimits.maxErrorBodyBytes { break }
            }
        } catch { }
        let message: String? = {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let error = object["error"] as? [String: Any],
                  let message = error["message"] as? String else { return nil }
            return String(message.prefix(512))
        }()
        switch http.statusCode {
        case 400: return .invalidRequest(message ?? "")
        case 401: return .authentication
        case 403: return .permission(message)
        case 404: return .modelUnavailable(message ?? "")
        case 429: return .rateLimited(retryAfter: retryAfter(from: http))
        default: return .server(http.statusCode)
        }
    }

    private static func retryAfter(from http: HTTPURLResponse) -> TimeInterval? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
