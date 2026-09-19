import Foundation
import SwiftUI

enum ChatCoordinatorEvent: Sendable {
    case prepared(ChatPrepareResult)
    case started(generationID: UUID, providerInteractionID: String?, effectiveModelID: String?)
    case textDelta(generationID: UUID, text: String)
    case completed(generationID: UUID, result: ChatGenerationResult, detail: ChatConversationDetail)
    case failed(generationID: UUID?, message: String, retryable: Bool)
}

/// Coordinates the local prepare/remote stream/final SQLite commit sequence.
/// It never receives a DocumentStore and therefore cannot mutate a note.
@MainActor
final class ChatCoordinator: ObservableObject {
    let repository: ChatRepository
    let client: any ChatGenerating

    @Published private(set) var activeGenerationIDs: Set<UUID> = []
    private var activeContinuations: [UUID: AsyncStream<ChatCoordinatorEvent>.Continuation] = [:]

    init(repository: ChatRepository = ChatRepository(), client: any ChatGenerating = GeminiChatClient()) {
        self.repository = repository
        self.client = client
    }

    func listConversations(filter: ChatConversationFilter = ChatConversationFilter()) async throws -> [ChatConversation] {
        try await repository.listConversations(filter: filter)
    }

    func loadConversation(id: UUID) async throws -> ChatConversationDetail {
        try await repository.loadConversation(id: id)
    }

    func createDraft(workspaceID: UUID?, modelID: String) async throws -> ChatConversation {
        try await repository.createDraft(workspaceID: workspaceID, selectedModelID: modelID)
    }

    func saveDraft(id: UUID, expectedVersion: Int64, text: String) async throws -> ChatConversation {
        try await repository.saveDraft(conversationID: id, expectedDraftVersion: expectedVersion, text: text)
    }

    func rename(id: UUID, title: String) async throws -> ChatConversation {
        try await repository.renameConversation(id: id, title: title)
    }

    func delete(id: UUID) async throws {
        cancelConversation(id)
        try await repository.deleteConversation(id: id)
    }

    func deleteAll() async throws {
        cancelAll()
        try await repository.deleteAllConversations()
    }

    func cleanupExpired() async {
        if let expired = try? await repository.deleteExpired() {
            cancel(conversations: expired)
        }
    }

    func cancel(conversations: [UUID]) {
        for conversationID in conversations {
            cancelConversation(conversationID)
        }
    }

    func streamChat(
        conversationID: UUID?,
        question: String,
        context: CapturedDocumentContext,
        selectedModelID: String,
        expectedRowVersion: Int64? = nil,
        expectedDraftVersion: Int64? = nil,
        apiKey: String
    ) -> AsyncStream<ChatCoordinatorEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.yield(.failed(generationID: nil, message: "Copilot is unavailable.", retryable: false))
                    continuation.finish()
                    return
                }
                var prepared: ChatPrepareResult?
                var visibleText = ""
                var didComplete = false
                do {
                    guard self.activeGenerationIDs.count < ChatLimits.maxConcurrentGenerations else {
                        throw ChatError.localLimit("Two Copilot responses are already generating. Try again when one finishes.")
                    }
                    let result = try await self.repository.prepareTurn(
                        conversationID: conversationID,
                        question: question,
                        context: context,
                        selectedModelID: selectedModelID,
                        expectedRowVersion: expectedRowVersion,
                        expectedDraftVersion: expectedDraftVersion
                    )
                    prepared = result
                    let generationID = result.preparedRequest.generationID
                    guard self.activeGenerationIDs.count < ChatLimits.maxConcurrentGenerations else {
                        try? await self.repository.failAttempt(
                            attemptID: result.preparedRequest.attemptID,
                            generationID: generationID,
                            errorCode: "concurrency_limit",
                            message: "Another Copilot response is already generating."
                        )
                        throw ChatError.localLimit("Two Copilot responses are already generating. Try again when one finishes.")
                    }
                    self.activeGenerationIDs.insert(generationID)
                    self.activeContinuations[result.preparedRequest.conversationID] = continuation
                    continuation.yield(.prepared(result))
                    try await self.repository.markAttemptSending(
                        attemptID: result.preparedRequest.attemptID,
                        generationID: generationID
                    )

                    var lastCheckpointAt = Date.distantPast
                    for try await event in self.client.streamChat(result.preparedRequest, apiKey: apiKey) {
                        try Task.checkCancellation()
                        switch event {
                        case .started(let providerID, let effectiveModel):
                            try await self.repository.markAttemptStreaming(
                                attemptID: result.preparedRequest.attemptID,
                                generationID: generationID,
                                providerInteractionID: providerID
                            )
                            continuation.yield(.started(
                                generationID: generationID,
                                providerInteractionID: providerID,
                                effectiveModelID: effectiveModel
                            ))
                        case .textDelta(let delta):
                            visibleText.append(delta)
                            continuation.yield(.textDelta(generationID: generationID, text: delta))
                            // Checkpoints are deliberately bounded and at most
                            // once per second. The final save remains atomic.
                            if visibleText.utf8.count <= ChatLimits.maxVisibleResponseBytes,
                               Date().timeIntervalSince(lastCheckpointAt) >= 1 {
                                try? await self.repository.checkpointAttempt(
                                    attemptID: result.preparedRequest.attemptID,
                                    generationID: generationID,
                                    partialText: visibleText
                                )
                                lastCheckpointAt = Date()
                            }
                        case .completed(let generationResult):
                            try await self.repository.finishAttempt(
                                attemptID: result.preparedRequest.attemptID,
                                generationID: generationID,
                                result: generationResult
                            )
                            let detail = try await self.repository.loadConversation(id: result.preparedRequest.conversationID)
                            continuation.yield(.completed(
                                generationID: generationID,
                                result: generationResult,
                                detail: detail
                            ))
                            didComplete = true
                        }
                    }
                    // A well-formed client emits completed before finishing.
                    try Task.checkCancellation()
                    if !didComplete {
                        throw GeminiAPIError.incompleteResponse
                    }
                } catch is CancellationError {
                    if let prepared {
                        if !visibleText.isEmpty {
                            try? await self.repository.checkpointAttempt(
                                attemptID: prepared.preparedRequest.attemptID,
                                generationID: prepared.preparedRequest.generationID,
                                partialText: visibleText
                            )
                        }
                        try? await self.repository.failAttempt(
                            attemptID: prepared.preparedRequest.attemptID,
                            generationID: prepared.preparedRequest.generationID,
                            state: .cancelled,
                            errorCode: "cancelled",
                            message: nil
                        )
                        continuation.yield(.failed(
                            generationID: prepared.preparedRequest.generationID,
                            message: "Generation stopped.",
                            retryable: true
                        ))
                    }
                } catch let error as GeminiAPIError {
                    if let prepared {
                        try? await self.repository.failAttempt(
                            attemptID: prepared.preparedRequest.attemptID,
                            generationID: prepared.preparedRequest.generationID,
                            state: error == .cancelled ? .cancelled : .failed,
                            errorCode: Self.errorCode(error),
                            message: error.userMessage
                        )
                    }
                    continuation.yield(.failed(
                        generationID: prepared?.preparedRequest.generationID,
                        message: error.userMessage,
                        retryable: Self.isRetryable(error)
                    ))
                } catch let error as ChatError {
                    if let prepared {
                        try? await self.repository.failAttempt(
                            attemptID: prepared.preparedRequest.attemptID,
                            generationID: prepared.preparedRequest.generationID,
                            errorCode: "local",
                            message: error.userMessage
                        )
                    }
                    continuation.yield(.failed(
                        generationID: prepared?.preparedRequest.generationID,
                        message: error.userMessage,
                        retryable: true
                    ))
                } catch {
                    if let prepared {
                        try? await self.repository.failAttempt(
                            attemptID: prepared.preparedRequest.attemptID,
                            generationID: prepared.preparedRequest.generationID,
                            errorCode: "local",
                            message: error.localizedDescription
                        )
                    }
                    continuation.yield(.failed(
                        generationID: prepared?.preparedRequest.generationID,
                        message: error.localizedDescription,
                        retryable: true
                    ))
                }
                if let prepared {
                    self.activeGenerationIDs.remove(prepared.preparedRequest.generationID)
                    self.activeContinuations[prepared.preparedRequest.conversationID] = nil
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                // The task's cancellation handler marks the attempt and
                // removes its generation ID before the stream finishes.
                _ = self
            }
        }
    }

    /// Streams a previously prepared retry. No turn or snapshot is created by
    /// this method; the repository has already frozen the original input.
    func streamPrepared(
        _ prepared: ChatPrepareResult,
        apiKey: String
    ) -> AsyncStream<ChatCoordinatorEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                let request = prepared.preparedRequest
                guard self.activeGenerationIDs.count < ChatLimits.maxConcurrentGenerations else {
                    try? await self.repository.failAttempt(
                        attemptID: request.attemptID,
                        generationID: request.generationID,
                        errorCode: "concurrency_limit",
                        message: "Another Copilot response is already generating."
                    )
                    continuation.yield(.failed(
                        generationID: request.generationID,
                        message: "Two Copilot responses are already generating. Try again when one finishes.",
                        retryable: true
                    ))
                    continuation.finish()
                    return
                }
                self.activeGenerationIDs.insert(request.generationID)
                self.activeContinuations[request.conversationID] = continuation
                continuation.yield(.prepared(prepared))
                var visibleText = ""
                var didComplete = false
                var lastCheckpointAt = Date.distantPast
                do {
                    try await self.repository.markAttemptSending(
                        attemptID: request.attemptID, generationID: request.generationID
                    )
                    for try await event in self.client.streamChat(request, apiKey: apiKey) {
                        try Task.checkCancellation()
                        switch event {
                        case .started(let providerID, let effectiveModel):
                            try await self.repository.markAttemptStreaming(
                                attemptID: request.attemptID,
                                generationID: request.generationID,
                                providerInteractionID: providerID
                            )
                            continuation.yield(.started(
                                generationID: request.generationID,
                                providerInteractionID: providerID,
                                effectiveModelID: effectiveModel
                            ))
                        case .textDelta(let text):
                            visibleText.append(text)
                            continuation.yield(.textDelta(generationID: request.generationID, text: text))
                            if visibleText.utf8.count <= ChatLimits.maxVisibleResponseBytes,
                               Date().timeIntervalSince(lastCheckpointAt) >= 1 {
                                try? await self.repository.checkpointAttempt(
                                    attemptID: request.attemptID,
                                    generationID: request.generationID,
                                    partialText: visibleText
                                )
                                lastCheckpointAt = Date()
                            }
                        case .completed(let result):
                            try await self.repository.finishAttempt(
                                attemptID: request.attemptID,
                                generationID: request.generationID,
                                result: result
                            )
                            let detail = try await self.repository.loadConversation(id: request.conversationID)
                            continuation.yield(.completed(
                                generationID: request.generationID,
                                result: result,
                                detail: detail
                            ))
                            didComplete = true
                        }
                    }
                    try Task.checkCancellation()
                    guard didComplete else { throw GeminiAPIError.incompleteResponse }
                } catch is CancellationError {
                    if !visibleText.isEmpty {
                        try? await self.repository.checkpointAttempt(
                            attemptID: request.attemptID,
                            generationID: request.generationID,
                            partialText: visibleText
                        )
                    }
                    try? await self.repository.failAttempt(
                        attemptID: request.attemptID, generationID: request.generationID,
                        state: .cancelled, errorCode: "cancelled", message: nil
                    )
                    continuation.yield(.failed(generationID: request.generationID, message: "Generation stopped.", retryable: true))
                } catch let error as GeminiAPIError {
                    try? await self.repository.failAttempt(
                        attemptID: request.attemptID, generationID: request.generationID,
                        state: error == .cancelled ? .cancelled : .failed,
                        errorCode: Self.errorCode(error), message: error.userMessage
                    )
                    continuation.yield(.failed(
                        generationID: request.generationID,
                        message: error.userMessage,
                        retryable: Self.isRetryable(error)
                    ))
                } catch {
                    try? await self.repository.failAttempt(
                        attemptID: request.attemptID, generationID: request.generationID,
                        state: .failed, errorCode: "local", message: error.localizedDescription
                    )
                    continuation.yield(.failed(
                        generationID: request.generationID,
                        message: error.localizedDescription,
                        retryable: true
                    ))
                }
                self.activeGenerationIDs.remove(request.generationID)
                self.activeContinuations[request.conversationID] = nil
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelConversation(_ conversationID: UUID) {
        // Finishing the continuation invokes its onTermination callback, which
        // cancels the URLSession task and lets the stream persist a final
        // checkpoint before marking the attempt cancelled.
        activeContinuations[conversationID]?.finish()
    }

    func cancelAll() {
        for continuation in activeContinuations.values {
            continuation.finish()
        }
    }

    private static func isRetryable(_ error: GeminiAPIError) -> Bool {
        switch error {
        case .authentication, .permission, .modelUnavailable, .invalidRequest: false
        default: true
        }
    }

    private static func errorCode(_ error: GeminiAPIError) -> String {
        switch error {
        case .authentication: "authentication"
        case .permission: "permission"
        case .modelUnavailable: "model_unavailable"
        case .rateLimited: "rate_limited"
        case .server(let code): "server_\(code)"
        case .providerError(let code, _): code
        case .transport: "transport"
        case .timedOut: "timeout"
        case .invalidProtocol: "invalid_protocol"
        case .incompleteResponse: "incomplete"
        case .invalidRequest: "invalid_request"
        case .localLimit: "local_limit"
        case .cancelled: "cancelled"
        }
    }
}
