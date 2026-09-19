import Foundation

/// Reconstructs provider steps without projecting thought signatures into the
/// visible transcript. The raw step data is retained for stateless replay.
struct GeminiChatStepAssembler {
    private struct StepState {
        let index: Int
        let type: String
        var start: [String: Any]
        var deltas: [[String: Any]]
        var closed: Bool
    }

    private var steps: [Int: StepState] = [:]
    private var outputIndices: Set<Int> = []
    private var visibleText = ""
    private var visibleBytes = 0
    private var interactionID: String?
    private var effectiveModelID: String?
    private var completed = false
    private var terminalSteps: [[String: Any]]?
    private var usage: ChatGenerationUsage?

    mutating func handle(_ message: SSEMessage) throws -> ChatGenerationEvent? {
        if message.data == "[DONE]" {
            guard completed else { throw GeminiAPIError.incompleteResponse }
            return nil
        }
        guard let data = message.data.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiAPIError.invalidProtocol("Malformed event payload.")
        }
        let eventType = object["event_type"] as? String ?? message.event
        guard let eventType else { throw GeminiAPIError.invalidProtocol("Event type is missing.") }

        switch eventType {
        case "interaction.created":
            guard let interaction = object["interaction"] as? [String: Any],
                  let id = interaction["id"] as? String else {
                throw GeminiAPIError.invalidProtocol("Malformed interaction.created.")
            }
            interactionID = id
            effectiveModelID = interaction["model"] as? String
            return .started(providerInteractionID: id, effectiveModelID: effectiveModelID)

        case "interaction.status_update":
            if let status = object["status"] as? String, Self.isFailure(status) {
                throw Self.error(for: status)
            }
            return nil

        case "step.start":
            guard let index = object["index"] as? Int,
                  let step = object["step"] as? [String: Any],
                  let type = step["type"] as? String else {
                throw GeminiAPIError.invalidProtocol("Malformed step.start.")
            }
            guard steps[index] == nil else { throw GeminiAPIError.invalidProtocol("A step started twice.") }
            if type == "model_output" { outputIndices.insert(index) }
            steps[index] = StepState(index: index, type: type, start: step, deltas: [], closed: false)
            if type == "model_output", let text = text(in: step), !text.isEmpty {
                try appendVisible(text)
                return .textDelta(text)
            }
            return nil

        case "step.delta":
            guard let index = object["index"] as? Int,
                  var step = steps[index],
                  let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else {
                throw GeminiAPIError.invalidProtocol("Malformed step.delta.")
            }
            guard !step.closed else { throw GeminiAPIError.invalidProtocol("A delta arrived after step.stop.") }
            step.deltas.append(delta)
            apply(delta: delta, to: &step.start)
            steps[index] = step
            guard step.type == "model_output", outputIndices.contains(index) else {
                // Thinking signatures and other non-visible fields are kept in
                // the step but are never emitted to the transcript.
                return nil
            }
            guard deltaType == "text" else { return nil }
            let text = delta["text"] as? String ?? ""
            try appendVisible(text)
            return text.isEmpty ? nil : .textDelta(text)

        case "step.stop":
            guard let index = object["index"] as? Int,
                  var step = steps[index], !step.closed else {
                throw GeminiAPIError.invalidProtocol("A step stopped twice or was never started.")
            }
            step.closed = true
            steps[index] = step
            return nil

        case "interaction.completed":
            guard let interaction = object["interaction"] as? [String: Any] else {
                throw GeminiAPIError.invalidProtocol("Malformed interaction.completed.")
            }
            let status = interaction["status"] as? String ?? ""
            guard status == "completed" else { throw Self.error(for: status) }
            guard !outputIndices.isEmpty,
                  outputIndices.allSatisfy({ steps[$0]?.closed == true }) else {
                throw GeminiAPIError.invalidProtocol("The output step did not close before completion.")
            }
            if steps.values.contains(where: { !$0.closed }) {
                throw GeminiAPIError.invalidProtocol("A provider step did not close before completion.")
            }
            effectiveModelID = (interaction["model"] as? String) ?? effectiveModelID
            usage = Self.usage(from: interaction["usage"] as? [String: Any])
            if let fullSteps = interaction["steps"] as? [[String: Any]], !fullSteps.isEmpty {
                terminalSteps = fullSteps
                // Some Interactions responses provide the authoritative steps
                // only in the terminal event. Project their model output when
                // deltas were omitted, and prefer the complete representation
                // when it differs so final persistence never duplicates text.
                let terminalVisible = try visibleText(in: fullSteps)
                if !terminalVisible.isEmpty, terminalVisible != visibleText {
                    visibleText = terminalVisible
                    visibleBytes = terminalVisible.utf8.count
                    guard visibleBytes <= ChatLimits.maxVisibleResponseBytes else {
                        throw GeminiAPIError.localLimit("The response is too large.")
                    }
                }
            }
            guard !visibleText.isEmpty else {
                throw GeminiAPIError.invalidProtocol("Gemini returned no visible text.")
            }
            completed = true
            let replay = try replayJSON()
            return .completed(ChatGenerationResult(
                visibleText: visibleText,
                replayStepsJSON: replay,
                usage: usage,
                providerInteractionID: interactionID,
                effectiveModelID: effectiveModelID
            ))

        case "error":
            let error = object["error"] as? [String: Any]
            throw GeminiAPIError.providerError(
                code: error?["code"] as? String ?? "unknown",
                message: error?["message"] as? String
            )

        default:
            // New informational event types are safe to ignore. A new event
            // that changes step reconstruction must be represented by the
            // terminal steps or it will fail closed above.
            return nil
        }
    }

    private mutating func appendVisible(_ text: String) throws {
        visibleBytes += text.utf8.count
        guard visibleBytes <= ChatLimits.maxVisibleResponseBytes else {
            throw GeminiAPIError.localLimit("The response is too large.")
        }
        visibleText.append(text)
    }

    private func replayJSON() throws -> Data {
        let result: [[String: Any]]
        if let terminalSteps { result = terminalSteps }
        else {
            result = steps.keys.sorted().compactMap { index in
                guard let step = steps[index] else { return nil }
                return step.start
            }
        }
        guard !result.isEmpty, JSONSerialization.isValidJSONObject(result) else {
            throw GeminiAPIError.invalidProtocol("Provider steps could not be reconstructed.")
        }
        for step in result {
            guard let type = step["type"] as? String, !type.isEmpty,
                  type != "tool_call", type != "tool_result" else {
                throw GeminiAPIError.providerError(
                    code: "unsupported_step",
                    message: "The response requested an unsupported tool step."
                )
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard data.count <= ChatLimits.maxReplayStepsBytes else {
            throw GeminiAPIError.localLimit("The provider response is too large to replay.")
        }
        return data
    }

    private func text(in step: [String: Any]) -> String? {
        if let text = step["text"] as? String { return text }
        if let content = step["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    private func visibleText(in providerSteps: [[String: Any]]) throws -> String {
        var text = ""
        for step in providerSteps {
            guard let type = step["type"] as? String, !type.isEmpty else {
                throw GeminiAPIError.invalidProtocol("A provider step has no type.")
            }
            guard type != "tool_call", type != "tool_result" else {
                throw GeminiAPIError.providerError(
                    code: "unsupported_step",
                    message: "The response requested an unsupported tool step."
                )
            }
            if type == "model_output" {
                text.append(self.text(in: step) ?? "")
            }
        }
        return text
    }

    private func apply(delta: [String: Any], to step: inout [String: Any]) {
        if let type = delta["type"] as? String {
            switch type {
            case "text":
                let value = delta["text"] as? String ?? ""
                if let old = step["text"] as? String { step["text"] = old + value }
                else {
                    var content = step["content"] as? [[String: Any]] ?? []
                    content.append(["type": "text", "text": value])
                    step["content"] = content
                }
            case "thought_signature":
                if let signature = delta["signature"] { step["signature"] = signature }
                if let signature = delta["thought_signature"] { step["thought_signature"] = signature }
            default:
                for (key, value) in delta where key != "type" { step[key] = value }
            }
        }
    }

    private static func usage(from object: [String: Any]?) -> ChatGenerationUsage? {
        guard let object else { return nil }
        return ChatGenerationUsage(
            totalTokens: int(object["total_tokens"]),
            inputTokens: int(object["total_input_tokens"] ?? object["input_tokens"]),
            outputTokens: int(object["total_output_tokens"] ?? object["output_tokens"]),
            reasoningTokens: int(object["reasoning_tokens"] ?? object["thoughts_tokens"]),
            cachedTokens: int(object["cached_content_tokens"] ?? object["cached_tokens"])
        )
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func isFailure(_ status: String) -> Bool {
        ["failed", "cancelled", "incomplete", "budget_exceeded", "requires_action"].contains(status)
    }

    private static func error(for status: String) -> GeminiAPIError {
        switch status {
        case "cancelled": return .cancelled
        case "incomplete", "budget_exceeded": return .incompleteResponse
        case "requires_action": return .providerError(code: status, message: "The model requested tool use, which is not supported.")
        default: return .providerError(code: status, message: "The interaction ended with status: \(status)")
        }
    }
}
