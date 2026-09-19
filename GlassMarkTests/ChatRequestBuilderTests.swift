import XCTest
@testable import GlassMark

final class ChatRequestBuilderTests: XCTestCase {
    func testFirstTurnSendsFullSnapshotAndSecondTurnReferencesIt() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let workspaceID = UUID()
        let reference = ChatDocumentReference(
            ownerWindowID: UUID(), workspaceID: workspaceID,
            documentURL: URL(fileURLWithPath: "/tmp/note.md"), relativePath: "note.md",
            displayName: "note.md", documentSessionID: UUID(), documentRevision: 1
        )
        let context = CapturedDocumentContext(reference: reference, hasUnsavedChanges: true, text: "# Note")
        let conversationID = UUID()
        let conversation = ChatConversation(
            id: conversationID, workspaceID: workspaceID, noteRelativePath: "note.md",
            noteDisplayName: "note.md", noteResourceIdentity: nil, title: "Question",
            titleIsCustom: false, provider: "gemini", selectedModelID: AIModelCatalog.defaultModelID,
            promptVersion: ChatRequestBuilder.promptVersion,
            inputSchemaVersion: ChatRequestBuilder.inputSchemaVersion, draftText: "", draftVersion: 0,
            rowVersion: 0, createdAt: now, updatedAt: now, lastActivityAt: now,
            expiresAt: now.addingTimeInterval(ChatLimits.retentionDuration)
        )
        let snapshot = ChatContextSnapshot(conversationID: conversationID, context: context)
        let empty = ChatConversationDetail(conversation: conversation, snapshots: [snapshot], turns: [])
        let first = try ChatRequestBuilder.build(
            detail: empty, currentSnapshot: snapshot, question: "Summarize it",
            modelID: AIModelCatalog.defaultModelID, attemptID: UUID(), generationID: UUID()
        )
        let firstEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: first.userStepJSON) as? [String: Any])
        let firstText = try XCTUnwrap((firstEnvelope["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("\"update\":\"full\""))

        let completedAttempt = ChatAttempt(
            id: UUID(), conversationID: conversationID, turnID: UUID(), attemptNumber: 1,
            generationID: UUID(), requestedModelID: AIModelCatalog.defaultModelID,
            effectiveModelID: AIModelCatalog.defaultModelID,
            generationConfigJSON: Data(#"{"max_output_tokens":8192}"#.utf8),
            requestSHA256: String(repeating: "a", count: 64), state: .completed,
            assistantText: "A summary", replayStepsJSON: Data(#"[{"type":"model_output","text":"A summary"}]"#.utf8),
            providerInteractionID: nil, usageJSON: nil, errorCode: nil, errorMessage: nil,
            createdAt: now, updatedAt: now, completedAt: now
        )
        let turn = ChatTurn(
            id: completedAttempt.turnID, conversationID: conversationID, ordinal: 1,
            state: .completed, userText: "Summarize it", userStepJSON: first.userStepJSON,
            contextSnapshotID: snapshot.id, contextMode: .liveCapture, createdAt: now,
            attempts: [completedAttempt]
        )
        let second = try ChatRequestBuilder.build(
            detail: ChatConversationDetail(conversation: conversation, snapshots: [snapshot], turns: [turn]),
            currentSnapshot: snapshot, question: "What is the title?",
            modelID: AIModelCatalog.defaultModelID, attemptID: UUID(), generationID: UUID()
        )
        let secondEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: second.userStepJSON) as? [String: Any])
        let secondText = try XCTUnwrap((secondEnvelope["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(secondText.contains("\"update\":\"reference\""))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: second.inputStepsJSON) as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: second.bodyJSON) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["previous_interaction_id"])
    }
}
