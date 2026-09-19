import XCTest
@testable import GlassMark

final class ChatRepositoryTests: XCTestCase {
    private static let workspaceID = UUID()
    private static let documentSessionID = UUID()

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glassmark-chat-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("chat.sqlite")
    }

    private func context() -> CapturedDocumentContext {
        let reference = ChatDocumentReference(
            ownerWindowID: UUID(), workspaceID: Self.workspaceID,
            documentURL: URL(fileURLWithPath: "/tmp/note.md"), relativePath: "note.md",
            displayName: "note.md", documentSessionID: Self.documentSessionID, documentRevision: 1
        )
        return CapturedDocumentContext(reference: reference, hasUnsavedChanges: false, text: "hello")
    }

    func testPrepareFinishAndReloadPreservesConversation() async throws {
        let repository = ChatRepository(databaseURL: temporaryURL())
        let first = try await repository.prepareTurn(
            conversationID: nil, question: "What is this?", context: context(),
            selectedModelID: AIModelCatalog.defaultModelID
        )
        try await repository.markAttemptSending(
            attemptID: first.preparedRequest.attemptID,
            generationID: first.preparedRequest.generationID
        )
        let result = ChatGenerationResult(
            visibleText: "It is a note.",
            replayStepsJSON: Data(#"[{"type":"model_output","text":"It is a note."}]"#.utf8),
            usage: ChatGenerationUsage(totalTokens: 4), providerInteractionID: "i1",
            effectiveModelID: AIModelCatalog.defaultModelID
        )
        try await repository.finishAttempt(
            attemptID: first.preparedRequest.attemptID,
            generationID: first.preparedRequest.generationID,
            result: result
        )
        let loaded = try await repository.loadConversation(id: first.preparedRequest.conversationID)
        XCTAssertEqual(loaded.turns.count, 1)
        XCTAssertEqual(loaded.turns[0].state, .completed)
        XCTAssertEqual(loaded.turns[0].completedAttempt?.assistantText, "It is a note.")
        XCTAssertEqual(loaded.snapshots.count, 1)

        let second = try await repository.prepareTurn(
            conversationID: first.preparedRequest.conversationID,
            question: "And the context?", context: context(),
            selectedModelID: AIModelCatalog.defaultModelID,
            expectedRowVersion: loaded.conversation.rowVersion
        )
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: second.preparedRequest.inputStepsJSON) as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
    }

    func testExpiredConversationIsHiddenAndCascades() async throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = ChatRepository(databaseURL: temporaryURL())
        let draft = try await repository.createDraft(now: created)
        let listed = try await repository.listConversations(now: created)
        XCTAssertEqual(listed.count, 1)
        _ = try await repository.deleteExpired(now: created.addingTimeInterval(ChatLimits.retentionDuration))
        do {
            _ = try await repository.loadConversation(id: draft.id, now: created.addingTimeInterval(ChatLimits.retentionDuration))
            XCTFail("expired conversation should be hidden")
        } catch {
            XCTAssertEqual(error as? ChatError, .notFound)
        }
    }

    func testRetryCreatesAnotherAttemptWithoutDuplicatingTurn() async throws {
        let repository = ChatRepository(databaseURL: temporaryURL())
        let first = try await repository.prepareTurn(
            conversationID: nil, question: "Try this", context: context(),
            selectedModelID: AIModelCatalog.defaultModelID
        )
        try await repository.markAttemptSending(
            attemptID: first.preparedRequest.attemptID,
            generationID: first.preparedRequest.generationID
        )
        try await repository.failAttempt(
            attemptID: first.preparedRequest.attemptID,
            generationID: first.preparedRequest.generationID,
            errorCode: "transport",
            message: "offline"
        )

        let pending = try await repository.loadConversation(id: first.preparedRequest.conversationID)
        let turn = try XCTUnwrap(pending.turns.first)
        let retry = try await repository.prepareRetry(
            turnID: turn.id,
            selectedModelID: "gemini-3.8-flash",
            expectedRowVersion: pending.conversation.rowVersion
        )
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: retry.preparedRequest.inputStepsJSON) as? [[String: Any]])
        XCTAssertEqual(input.count, 1)

        let retried = try await repository.loadConversation(id: first.preparedRequest.conversationID)
        XCTAssertEqual(retried.turns.count, 1)
        XCTAssertEqual(retried.turns[0].attempts.count, 2)
        XCTAssertEqual(retried.turns[0].attempts.last?.requestedModelID, "gemini-3.8-flash")
    }
    func testSecondConnectionReportsLockedStorageWithoutWaiting() throws {
        let url = temporaryURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ChatSQLiteConnection(url: url)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try ChatSQLiteConnection(url: url)) { error in
                guard case ChatError.storageUnavailable = error else {
                    return XCTFail("Expected unavailable storage, got \(error)")
                }
            }
        }
    }

}
