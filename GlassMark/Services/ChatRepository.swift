import Foundation
import SQLite3

/// Actor-isolated SQLite repository for Copilot. All public reads apply the
/// expiration boundary, so an expired row is never exposed even if cleanup is
/// delayed while the app was closed.
actor ChatRepository {
    private let databaseURL: URL
    private let clock: @Sendable () -> Date
    private var database: ChatSQLiteConnection?
    private var openError: ChatError?
    private var lastObservedNow: Date?

    init(
        databaseURL: URL? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clock = clock
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        do {
            var directory = self.databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The database contains note text, prompts and opaque provider
            // steps. Keep the containing directory private even when the
            // process inherits a permissive umask.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            self.database = try ChatSQLiteConnection(url: self.databaseURL)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: self.databaseURL.path
            )
        } catch let error as ChatError {
            self.openError = error
        } catch {
            self.openError = .storageUnavailable(error.localizedDescription)
        }
    }

    static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("GlassMark/Copilot/chat.sqlite", isDirectory: false)
    }

    var isAvailable: Bool { database != nil }

    var storageErrorMessage: String? {
        openError?.userMessage
    }

    func createDraft(
        workspaceID: UUID? = nil,
        selectedModelID: String = AIModelCatalog.defaultModelID,
        now: Date? = nil
    ) throws -> ChatConversation {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        let conversation = makeConversation(
            id: UUID(),
            workspaceID: workspaceID,
            note: nil,
            title: "New Chat",
            selectedModelID: selectedModelID,
            now: timestamp
        )
        let statement = try db.prepare("""
            INSERT INTO chat_conversations
            (id, workspace_id, note_relative_path, note_display_name, note_resource_identity,
             title, title_is_custom, provider, selected_model_id, prompt_version, input_schema_version,
             draft_text, draft_version, row_version, created_at, updated_at, last_activity_at, expires_at)
            VALUES (?, ?, NULL, NULL, NULL, ?, 0, 'gemini', ?, ?, ?, '', 0, 0, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: conversation.id.uuidString)
        db.bind(statement, index: 2, text: workspaceID?.uuidString)
        db.bind(statement, index: 3, text: conversation.title)
        db.bind(statement, index: 4, text: conversation.selectedModelID)
        db.bind(statement, index: 5, text: conversation.promptVersion)
        db.bind(statement, index: 6, int: Int64(ChatRequestBuilder.inputSchemaVersion))
        bindDates(db, statement, startIndex: 7, conversation: conversation)
        try db.step(statement)
        return conversation
    }

    func listConversations(
        filter: ChatConversationFilter = ChatConversationFilter(),
        now: Date? = nil
    ) throws -> [ChatConversation] {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        try deleteExpiredLocked(db: db, now: timestamp)

        var clauses = ["expires_at > ?"]
        var values: [SQLiteValue] = [.int(ms(timestamp))]
        if let workspaceID = filter.workspaceID, !filter.includeAllWorkspaces {
            clauses.append("workspace_id = ?")
            values.append(.text(workspaceID.uuidString))
        }
        if let notePath = filter.noteRelativePath {
            clauses.append("note_relative_path = ?")
            values.append(.text(notePath))
        }
        if let query = filter.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            clauses.append("(title LIKE ? ESCAPE '\\' OR note_display_name LIKE ? ESCAPE '\\' OR note_relative_path LIKE ? ESCAPE '\\')")
            let escaped = Self.escapeLike(query)
            let pattern = "%\(escaped)%"
            values.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
        }
        if let cursor = filter.cursor {
            clauses.append("(last_activity_at < ? OR (last_activity_at = ? AND id < ?))")
            values.append(.int(ms(cursor.lastActivityAt)))
            values.append(.int(ms(cursor.lastActivityAt)))
            values.append(.text(cursor.id.uuidString))
        }
        let sql = """
            SELECT id, workspace_id, note_relative_path, note_display_name, note_resource_identity,
                   title, title_is_custom, provider, selected_model_id, prompt_version,
                   input_schema_version, draft_text, draft_version, row_version,
                   created_at, updated_at, last_activity_at, expires_at
            FROM chat_conversations WHERE \(clauses.joined(separator: " AND "))
            ORDER BY last_activity_at DESC, id DESC LIMIT \(filter.limit)
            """
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, db: db)
        var result: [ChatConversation] = []
        while try db.step(statement) == SQLITE_ROW {
            result.append(try conversation(from: statement, db: db))
        }
        return result
    }

    func loadConversation(id: UUID, now: Date? = nil) throws -> ChatConversationDetail {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        try deleteExpiredLocked(db: db, now: timestamp)
        guard let detail = try loadDetailLocked(db: db, id: id, now: timestamp) else {
            throw ChatError.notFound
        }
        return detail
    }

    @discardableResult
    func saveDraft(
        conversationID: UUID,
        expectedDraftVersion: Int64,
        text: String,
        now: Date? = nil
    ) throws -> ChatConversation {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        try ChatLimits.validateQuestion(text)
        guard let existing = try loadConversationRow(db: db, id: conversationID, now: timestamp) else {
            throw ChatError.notFound
        }
        guard existing.draftVersion == expectedDraftVersion else { throw ChatError.conflict }
        let statement = try db.prepare("""
            UPDATE chat_conversations
            SET draft_text = ?, draft_version = draft_version + 1, updated_at = ?, row_version = row_version + 1
            WHERE id = ? AND draft_version = ? AND expires_at > ?
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: text)
        db.bind(statement, index: 2, int: ms(timestamp))
        db.bind(statement, index: 3, text: conversationID.uuidString)
        db.bind(statement, index: 4, int: expectedDraftVersion)
        db.bind(statement, index: 5, int: ms(timestamp))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
        return try loadConversationRow(db: db, id: conversationID, now: timestamp) ?? existing
    }

    func renameConversation(id: UUID, title: String, now: Date? = nil) throws -> ChatConversation {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ChatError.invalidState("A chat title cannot be empty.") }
        guard normalized.count <= 120 else { throw ChatError.localLimit("Chat titles are limited to 120 characters.") }
        let statement = try db.prepare("""
            UPDATE chat_conversations SET title = ?, title_is_custom = 1, updated_at = ?, row_version = row_version + 1
            WHERE id = ? AND expires_at > ?
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: normalized)
        db.bind(statement, index: 2, int: ms(timestamp))
        db.bind(statement, index: 3, text: id.uuidString)
        db.bind(statement, index: 4, int: ms(timestamp))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1,
              let conversation = try loadConversationRow(db: db, id: id, now: timestamp) else { throw ChatError.notFound }
        return conversation
    }

    func updateSelectedModel(id: UUID, modelID: String, now: Date? = nil) throws -> ChatConversation {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.invalidPayload("No Gemini model is configured.")
        }
        let statement = try db.prepare("""
            UPDATE chat_conversations SET selected_model_id = ?, updated_at = ?, row_version = row_version + 1
            WHERE id = ? AND expires_at > ?
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: modelID)
        db.bind(statement, index: 2, int: ms(timestamp))
        db.bind(statement, index: 3, text: id.uuidString)
        db.bind(statement, index: 4, int: ms(timestamp))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1,
              let conversation = try loadConversationRow(db: db, id: id, now: timestamp) else { throw ChatError.notFound }
        return conversation
    }

    /// Atomically captures a question, snapshot, replay request and prepared
    /// attempt. The caller must not start network work until this returns.
    func prepareTurn(
        conversationID: UUID?,
        question: String,
        context: CapturedDocumentContext,
        selectedModelID: String,
        expectedRowVersion: Int64? = nil,
        expectedDraftVersion: Int64? = nil,
        now: Date? = nil
    ) throws -> ChatPrepareResult {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        try ChatLimits.validateQuestion(question)
        try ChatLimits.validateSnapshot(context.text)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.localLimit("Enter a question before sending.")
        }

        try db.execute("BEGIN IMMEDIATE;")
        do {
            let conversation: ChatConversation
            if let conversationID {
                guard let loaded = try loadConversationRow(db: db, id: conversationID, now: timestamp) else {
                    throw ChatError.notFound
                }
                conversation = loaded
            } else {
                conversation = makeConversation(
                    id: UUID(),
                    workspaceID: context.reference.workspaceID,
                    note: context.reference,
                    title: Self.derivedTitle(from: question),
                    selectedModelID: selectedModelID,
                    now: timestamp
                )
                try insertConversation(db: db, conversation: conversation, note: context.reference)
            }

            guard conversation.expiresAt > timestamp else { throw ChatError.expired }
            if let expectedRowVersion, expectedRowVersion != conversation.rowVersion { throw ChatError.conflict }
            guard conversation.provider == "gemini" else { throw ChatError.invalidState("Unsupported chat provider.") }
            guard !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatError.invalidPayload("No Gemini model is configured.")
            }
            guard conversation.noteRelativePath == nil
                || (conversation.workspaceID == context.reference.workspaceID
                    && conversation.noteRelativePath == context.reference.relativePath
                    && conversation.noteDisplayName == context.reference.displayName) else {
                throw ChatError.contextMismatch
            }
            if conversation.noteRelativePath == nil {
                try bindConversationNote(db: db, id: conversation.id, note: context.reference, now: timestamp)
            }
            if conversation.selectedModelID != selectedModelID {
                try updateSelectedModelLocked(
                    db: db,
                    id: conversation.id,
                    modelID: selectedModelID,
                    now: timestamp
                )
            }

            let detail = try loadDetailLocked(db: db, id: conversation.id, now: timestamp)
                ?? ChatConversationDetail(conversation: conversation, snapshots: [], turns: [])
            guard !detail.turns.contains(where: { $0.state == .pending }) else { throw ChatError.invalidState("Resolve the pending turn before sending another question.") }
            guard detail.turns.count < ChatLimits.maxTurns else { throw ChatError.localLimit("This chat has reached its turn limit. Start a new chat.") }

            let snapshot = try insertOrReuseSnapshot(db: db, conversationID: conversation.id, context: context, now: timestamp)
            let refreshed = try loadDetailLocked(db: db, id: conversation.id, now: timestamp)
                ?? ChatConversationDetail(conversation: conversation, snapshots: [snapshot], turns: [])
            let attemptID = UUID()
            let generationID = UUID()
            let build = try ChatRequestBuilder.build(
                detail: refreshed,
                currentSnapshot: snapshot,
                question: question,
                modelID: selectedModelID,
                attemptID: attemptID,
                generationID: generationID
            )
            let ordinal = (refreshed.turns.map(\.ordinal).max() ?? 0) + 1
            let turnID = UUID()
            let userStep = build.userStepJSON
            let insertTurn = try db.prepare("""
                INSERT INTO chat_turns
                (id, conversation_id, ordinal, state, user_text, user_step_json, context_snapshot_id, context_mode, created_at)
                VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insertTurn) }
            db.bind(insertTurn, index: 1, text: turnID.uuidString)
            db.bind(insertTurn, index: 2, text: conversation.id.uuidString)
            db.bind(insertTurn, index: 3, int: Int64(ordinal))
            db.bind(insertTurn, index: 4, text: question)
            db.bind(insertTurn, index: 5, data: userStep)
            db.bind(insertTurn, index: 6, text: snapshot.id.uuidString)
            db.bind(insertTurn, index: 7, text: build.contextMode.rawValue)
            db.bind(insertTurn, index: 8, int: ms(timestamp))
            try db.step(insertTurn)

            let attemptNumber = try nextAttemptNumber(db: db, turnID: turnID)
            let insertAttempt = try db.prepare("""
                INSERT INTO chat_attempts
                (id, conversation_id, turn_id, attempt_number, generation_id, requested_model_id,
                 effective_model_id, generation_config_json, request_sha256, state, assistant_text,
                 replay_steps_json, provider_interaction_id, usage_json, error_code, error_message,
                 created_at, updated_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, 'prepared', '', NULL, NULL, NULL, NULL, NULL, ?, ?, NULL)
                """)
            defer { sqlite3_finalize(insertAttempt) }
            db.bind(insertAttempt, index: 1, text: attemptID.uuidString)
            db.bind(insertAttempt, index: 2, text: conversation.id.uuidString)
            db.bind(insertAttempt, index: 3, text: turnID.uuidString)
            db.bind(insertAttempt, index: 4, int: Int64(attemptNumber))
            db.bind(insertAttempt, index: 5, text: generationID.uuidString)
            db.bind(insertAttempt, index: 6, text: selectedModelID)
            db.bind(insertAttempt, index: 7, data: build.generationConfigJSON)
            db.bind(insertAttempt, index: 8, text: build.requestSHA256)
            db.bind(insertAttempt, index: 9, int: ms(timestamp))
            db.bind(insertAttempt, index: 10, int: ms(timestamp))
            try db.step(insertAttempt)

            let draftClause: String
            if let expectedDraftVersion {
                draftClause = "draft_version = \(expectedDraftVersion)"
            } else {
                draftClause = "1 = 1"
            }
            let clearDraft = try db.prepare("""
                UPDATE chat_conversations
                SET draft_text = '', draft_version = draft_version + 1,
                    last_activity_at = ?, updated_at = ?, row_version = row_version + 1,
                    title = CASE WHEN title_is_custom = 0 THEN ? ELSE title END
                WHERE id = ? AND expires_at > ? AND \(draftClause)
                """)
            defer { sqlite3_finalize(clearDraft) }
            db.bind(clearDraft, index: 1, int: ms(timestamp))
            db.bind(clearDraft, index: 2, int: ms(timestamp))
            let title = conversation.title == "New Chat" && !conversation.titleIsCustom
                ? Self.derivedTitle(from: question)
                : conversation.title
            db.bind(clearDraft, index: 3, text: title)
            db.bind(clearDraft, index: 4, text: conversation.id.uuidString)
            db.bind(clearDraft, index: 5, int: ms(timestamp))
            try db.step(clearDraft)
            guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }

            try db.execute("COMMIT;")
            guard let committed = try loadDetailLocked(db: db, id: conversation.id, now: timestamp) else {
                throw ChatError.notFound
            }
            let attempt = committed.turns.last?.attempts.last(where: { $0.id == attemptID })
                ?? ChatAttempt(
                    id: attemptID, conversationID: conversation.id, turnID: turnID,
                    attemptNumber: attemptNumber, generationID: generationID,
                    requestedModelID: selectedModelID, effectiveModelID: nil,
                    generationConfigJSON: build.generationConfigJSON, requestSHA256: build.requestSHA256,
                    state: .prepared, assistantText: "", replayStepsJSON: nil,
                    providerInteractionID: nil, usageJSON: nil, errorCode: nil, errorMessage: nil,
                    createdAt: timestamp, updatedAt: timestamp, completedAt: nil
                )
            let prepared = PreparedChatRequest(
                conversationID: conversation.id,
                turnID: turnID,
                attemptID: attemptID,
                generationID: generationID,
                modelID: selectedModelID,
                promptVersion: conversation.promptVersion,
                inputSchemaVersion: conversation.inputSchemaVersion,
                systemInstruction: ChatRequestBuilder.systemInstruction,
                inputStepsJSON: build.inputStepsJSON,
                generationConfigJSON: build.generationConfigJSON,
                bodyJSON: build.bodyJSON,
                requestSHA256: build.requestSHA256,
                expiresAt: committed.conversation.expiresAt
            )
            return ChatPrepareResult(detail: committed, preparedRequest: prepared, attempt: attempt)
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    func markAttemptSending(attemptID: UUID, generationID: UUID, now: Date? = nil) throws {
        try updateAttemptState(attemptID: attemptID, generationID: generationID, state: .sending, now: now)
    }

    /// Prepares another attempt for the last unresolved turn. The original
    /// question and snapshot are read from SQLite; a retry never recaptures the
    /// currently-open note and never duplicates the user turn.
    func prepareRetry(
        turnID: UUID,
        selectedModelID: String,
        expectedRowVersion: Int64? = nil,
        now: Date? = nil
    ) throws -> ChatPrepareResult {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        try db.execute("BEGIN IMMEDIATE;")
        do {
            guard let conversationID = try? scalarUUID(db: db, sql: "SELECT conversation_id FROM chat_turns WHERE id = ?", value: turnID),
                  let detail = try loadDetailLocked(db: db, id: conversationID, now: timestamp),
                  let turn = detail.turns.first(where: { $0.id == turnID }),
                  turn.state == .pending,
                  !turn.attempts.contains(where: { $0.state.isActive }) else {
                throw ChatError.invalidState("This turn cannot be retried yet.")
            }
            if let expectedRowVersion, expectedRowVersion != detail.conversation.rowVersion {
                throw ChatError.conflict
            }
            guard !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatError.invalidPayload("No Gemini model is configured.")
            }
            guard turn.attempts.count < ChatLimits.maxAttemptsPerTurn else {
                throw ChatError.localLimit("This turn has reached its retry limit.")
            }
            guard let snapshot = detail.snapshots.first(where: { $0.id == turn.contextSnapshotID }) else {
                throw ChatError.invalidPayload("The captured note version is unavailable.")
            }
            let attemptID = UUID()
            let generationID = UUID()
            let build = try ChatRequestBuilder.build(
                detail: detail,
                currentSnapshot: snapshot,
                question: turn.userText,
                modelID: selectedModelID,
                attemptID: attemptID,
                generationID: generationID,
                storedUserStepJSON: turn.userStepJSON
            )
            let attemptNumber = (turn.attempts.map(\.attemptNumber).max() ?? 0) + 1
            let insert = try db.prepare("""
                INSERT INTO chat_attempts
                (id, conversation_id, turn_id, attempt_number, generation_id, requested_model_id,
                 effective_model_id, generation_config_json, request_sha256, state, assistant_text,
                 replay_steps_json, provider_interaction_id, usage_json, error_code, error_message,
                 created_at, updated_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, 'prepared', '', NULL, NULL, NULL, NULL, NULL, ?, ?, NULL)
                """)
            defer { sqlite3_finalize(insert) }
            db.bind(insert, index: 1, text: attemptID.uuidString)
            db.bind(insert, index: 2, text: conversationID.uuidString)
            db.bind(insert, index: 3, text: turnID.uuidString)
            db.bind(insert, index: 4, int: Int64(attemptNumber))
            db.bind(insert, index: 5, text: generationID.uuidString)
            db.bind(insert, index: 6, text: selectedModelID)
            db.bind(insert, index: 7, data: build.generationConfigJSON)
            db.bind(insert, index: 8, text: build.requestSHA256)
            db.bind(insert, index: 9, int: ms(timestamp))
            db.bind(insert, index: 10, int: ms(timestamp))
            try db.step(insert)
            try updateSelectedModelLocked(
                db: db,
                id: conversationID,
                modelID: selectedModelID,
                now: timestamp,
                updateActivity: false
            )
            try db.execute("COMMIT;")
            let refreshed = try loadDetailLocked(db: db, id: conversationID, now: timestamp) ?? detail
            let attempt = refreshed.turns.first(where: { $0.id == turnID })?.attempts.last
                ?? ChatAttempt(
                    id: attemptID, conversationID: conversationID, turnID: turnID,
                    attemptNumber: attemptNumber, generationID: generationID,
                    requestedModelID: selectedModelID, effectiveModelID: nil,
                    generationConfigJSON: build.generationConfigJSON, requestSHA256: build.requestSHA256,
                    state: .prepared, assistantText: "", replayStepsJSON: nil,
                    providerInteractionID: nil, usageJSON: nil, errorCode: nil, errorMessage: nil,
                    createdAt: timestamp, updatedAt: timestamp, completedAt: nil
                )
            let request = PreparedChatRequest(
                conversationID: conversationID, turnID: turnID, attemptID: attemptID,
                generationID: generationID, modelID: selectedModelID,
                promptVersion: refreshed.conversation.promptVersion,
                inputSchemaVersion: refreshed.conversation.inputSchemaVersion,
                systemInstruction: ChatRequestBuilder.systemInstruction,
                inputStepsJSON: build.inputStepsJSON,
                generationConfigJSON: build.generationConfigJSON,
                bodyJSON: build.bodyJSON, requestSHA256: build.requestSHA256,
                expiresAt: refreshed.conversation.expiresAt
            )
            return ChatPrepareResult(detail: refreshed, preparedRequest: request, attempt: attempt)
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    func markAttemptStreaming(attemptID: UUID, generationID: UUID, providerInteractionID: String? = nil, now: Date? = nil) throws {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        let statement = try db.prepare("""
            UPDATE chat_attempts SET state = 'streaming', provider_interaction_id = COALESCE(?, provider_interaction_id), updated_at = ?
            WHERE id = ? AND generation_id = ? AND state IN ('prepared', 'sending')
              AND EXISTS (
                SELECT 1 FROM chat_conversations AS c
                WHERE c.id = chat_attempts.conversation_id AND c.expires_at > ?
              )
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: providerInteractionID)
        db.bind(statement, index: 2, int: ms(timestamp))
        db.bind(statement, index: 3, text: attemptID.uuidString)
        db.bind(statement, index: 4, text: generationID.uuidString)
        db.bind(statement, index: 5, int: ms(timestamp))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
    }

    func checkpointAttempt(
        attemptID: UUID,
        generationID: UUID,
        partialText: String,
        now: Date? = nil
    ) throws {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        guard ChatLimits.byteCount(partialText) <= ChatLimits.maxVisibleResponseBytes else {
            throw ChatError.localLimit("The response is too large.")
        }
        let statement = try db.prepare("""
            UPDATE chat_attempts SET assistant_text = ?, updated_at = ?
            WHERE id = ? AND generation_id = ? AND state IN ('sending', 'streaming')
              AND EXISTS (
                SELECT 1 FROM chat_conversations AS c
                WHERE c.id = chat_attempts.conversation_id AND c.expires_at > ?
              )
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: partialText)
        db.bind(statement, index: 2, int: ms(timestamp))
        db.bind(statement, index: 3, text: attemptID.uuidString)
        db.bind(statement, index: 4, text: generationID.uuidString)
        db.bind(statement, index: 5, int: ms(timestamp))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
    }

    func finishAttempt(
        attemptID: UUID,
        generationID: UUID,
        result: ChatGenerationResult,
        now: Date? = nil
    ) throws {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        guard !result.visibleText.isEmpty else { throw ChatError.invalidState("Gemini returned an empty response.") }
        guard ChatLimits.byteCount(result.visibleText) <= ChatLimits.maxVisibleResponseBytes,
              result.replayStepsJSON.count <= ChatLimits.maxReplayStepsBytes else {
            throw ChatError.localLimit("The response cannot be saved because it is too large.")
        }
        guard let replay = try? JSONSerialization.jsonObject(with: result.replayStepsJSON) as? [[String: Any]],
              !replay.isEmpty,
              JSONSerialization.isValidJSONObject(replay) else {
            throw ChatError.invalidPayload("The provider response could not be replayed.")
        }
        guard let usageJSON = try? JSONEncoder.sorted.encode(result.usage) else {
            throw ChatError.invalidPayload("Usage data could not be encoded.")
        }
        try db.execute("BEGIN IMMEDIATE;")
        do {
            let updateAttempt = try db.prepare("""
                UPDATE chat_attempts SET state = 'completed', assistant_text = ?, replay_steps_json = ?,
                    effective_model_id = ?, provider_interaction_id = COALESCE(?, provider_interaction_id),
                    usage_json = ?, updated_at = ?, completed_at = ?
                WHERE id = ? AND generation_id = ? AND state IN ('sending', 'streaming')
                """)
            defer { sqlite3_finalize(updateAttempt) }
            db.bind(updateAttempt, index: 1, text: result.visibleText)
            db.bind(updateAttempt, index: 2, data: result.replayStepsJSON)
            db.bind(updateAttempt, index: 3, text: result.effectiveModelID)
            db.bind(updateAttempt, index: 4, text: result.providerInteractionID)
            db.bind(updateAttempt, index: 5, data: usageJSON)
            db.bind(updateAttempt, index: 6, int: ms(timestamp))
            db.bind(updateAttempt, index: 7, int: ms(timestamp))
            db.bind(updateAttempt, index: 8, text: attemptID.uuidString)
            db.bind(updateAttempt, index: 9, text: generationID.uuidString)
            try db.step(updateAttempt)
            guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }

            let turnID = try scalarUUID(db: db, sql: "SELECT turn_id FROM chat_attempts WHERE id = ?", value: attemptID)
            let updateTurn = try db.prepare("UPDATE chat_turns SET state = 'completed' WHERE id = ? AND state = 'pending'")
            defer { sqlite3_finalize(updateTurn) }
            db.bind(updateTurn, index: 1, text: turnID.uuidString)
            try db.step(updateTurn)
            guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
            let updateConversation = try db.prepare("UPDATE chat_conversations SET last_activity_at = ?, updated_at = ?, row_version = row_version + 1 WHERE id = ? AND expires_at > ?")
            defer { sqlite3_finalize(updateConversation) }
            db.bind(updateConversation, index: 1, int: ms(timestamp))
            db.bind(updateConversation, index: 2, int: ms(timestamp))
            let conversationID = try scalarUUID(db: db, sql: "SELECT conversation_id FROM chat_attempts WHERE id = ?", value: attemptID)
            db.bind(updateConversation, index: 3, text: conversationID.uuidString)
            db.bind(updateConversation, index: 4, int: ms(timestamp))
            try db.step(updateConversation)
            guard sqlite3_changes(db.handle) == 1 else { throw ChatError.expired }
            try db.execute("COMMIT;")
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    func failAttempt(
        attemptID: UUID,
        generationID: UUID,
        state: ChatAttemptState = .failed,
        errorCode: String?,
        message: String?,
        now: Date? = nil
    ) throws {
        guard [.failed, .cancelled, .interrupted].contains(state) else { throw ChatError.invalidState("Invalid terminal attempt state.") }
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        let statement = try db.prepare("""
            UPDATE chat_attempts SET state = ?, error_code = ?, error_message = ?, updated_at = ?
            WHERE id = ? AND generation_id = ? AND state IN ('prepared', 'sending', 'streaming')
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: state.rawValue)
        db.bind(statement, index: 2, text: errorCode)
        db.bind(statement, index: 3, text: Self.sanitizeError(message))
        db.bind(statement, index: 4, int: ms(timestamp))
        db.bind(statement, index: 5, text: attemptID.uuidString)
        db.bind(statement, index: 6, text: generationID.uuidString)
        try db.step(statement)
    }

    func abandonPendingTurn(turnID: UUID, now: Date? = nil) throws {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        try db.execute("BEGIN IMMEDIATE;")
        do {
            let attempts = try db.prepare("UPDATE chat_attempts SET state = 'cancelled', updated_at = ? WHERE turn_id = ? AND state IN ('prepared', 'sending', 'streaming')")
            defer { sqlite3_finalize(attempts) }
            db.bind(attempts, index: 1, int: ms(timestamp))
            db.bind(attempts, index: 2, text: turnID.uuidString)
            try db.step(attempts)
            let turn = try db.prepare("UPDATE chat_turns SET state = 'abandoned' WHERE id = ? AND state = 'pending'")
            defer { sqlite3_finalize(turn) }
            db.bind(turn, index: 1, text: turnID.uuidString)
            try db.step(turn)
            try db.execute("COMMIT;")
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    func deleteConversation(id: UUID) throws {
        let db = try requireDatabase()
        let statement = try db.prepare("DELETE FROM chat_conversations WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: id.uuidString)
        try db.step(statement)
    }

    func deleteAllConversations() throws {
        let db = try requireDatabase()
        try db.execute("BEGIN IMMEDIATE;")
        do {
            try db.execute("DELETE FROM chat_conversations;")
            try db.execute("COMMIT;")
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    func deleteExpired(now: Date? = nil) throws -> [UUID] {
        let db = try requireDatabase()
        return try deleteExpiredLocked(db: db, now: effectiveNow(now))
    }

    func recoverInterruptedAttempts(now: Date? = nil) throws {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        let statement = try db.prepare("""
            UPDATE chat_attempts SET state = 'interrupted', updated_at = ?
            WHERE state IN ('prepared', 'sending', 'streaming')
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, int: ms(timestamp))
        try db.step(statement)
    }

    // MARK: - Private database operations

    private enum SQLiteValue {
        case text(String)
        case int(Int64)
    }

    private func requireDatabase() throws -> ChatSQLiteConnection {
        if let database { return database }
        throw openError ?? .storageUnavailable("Database is unavailable")
    }

    private func effectiveNow(_ requested: Date?) -> Date {
        let candidate = requested ?? clock()
        if let lastObservedNow, candidate < lastObservedNow { return lastObservedNow }
        lastObservedNow = candidate
        return candidate
    }

    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    private func date(_ value: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(value) / 1000) }

    private func bindDates(_ db: ChatSQLiteConnection, _ statement: OpaquePointer, startIndex: Int32, conversation: ChatConversation) {
        db.bind(statement, index: startIndex, int: ms(conversation.createdAt))
        db.bind(statement, index: startIndex + 1, int: ms(conversation.updatedAt))
        db.bind(statement, index: startIndex + 2, int: ms(conversation.lastActivityAt))
        db.bind(statement, index: startIndex + 3, int: ms(conversation.expiresAt))
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer, db: ChatSQLiteConnection) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let value): db.bind(statement, index: index, text: value)
            case .int(let value): db.bind(statement, index: index, int: value)
            }
        }
    }

    private func makeConversation(
        id: UUID,
        workspaceID: UUID?,
        note: ChatDocumentReference?,
        title: String,
        selectedModelID: String,
        now: Date
    ) -> ChatConversation {
        ChatConversation(
            id: id,
            workspaceID: workspaceID,
            noteRelativePath: note?.relativePath,
            noteDisplayName: note?.displayName,
            noteResourceIdentity: note?.resourceIdentity,
            title: title,
            titleIsCustom: false,
            provider: "gemini",
            selectedModelID: selectedModelID,
            promptVersion: ChatRequestBuilder.promptVersion,
            inputSchemaVersion: ChatRequestBuilder.inputSchemaVersion,
            draftText: "",
            draftVersion: 0,
            rowVersion: 0,
            createdAt: now,
            updatedAt: now,
            lastActivityAt: now,
            expiresAt: now.addingTimeInterval(ChatLimits.retentionDuration)
        )
    }

    private func insertConversation(db: ChatSQLiteConnection, conversation: ChatConversation, note: ChatDocumentReference?) throws {
        let statement = try db.prepare("""
            INSERT INTO chat_conversations
            (id, workspace_id, note_relative_path, note_display_name, note_resource_identity,
             title, title_is_custom, provider, selected_model_id, prompt_version, input_schema_version,
             draft_text, draft_version, row_version, created_at, updated_at, last_activity_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'gemini', ?, ?, ?, '', 0, 0, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: conversation.id.uuidString)
        db.bind(statement, index: 2, text: conversation.workspaceID?.uuidString)
        db.bind(statement, index: 3, text: note?.relativePath)
        db.bind(statement, index: 4, text: note?.displayName)
        db.bind(statement, index: 5, data: note?.resourceIdentity)
        db.bind(statement, index: 6, text: conversation.title)
        db.bind(statement, index: 7, bool: conversation.titleIsCustom)
        db.bind(statement, index: 8, text: conversation.selectedModelID)
        db.bind(statement, index: 9, text: conversation.promptVersion)
        db.bind(statement, index: 10, int: Int64(conversation.inputSchemaVersion))
        bindDates(db, statement, startIndex: 11, conversation: conversation)
        try db.step(statement)
    }

    private func bindConversationNote(db: ChatSQLiteConnection, id: UUID, note: ChatDocumentReference, now: Date) throws {
        let statement = try db.prepare("""
            UPDATE chat_conversations SET workspace_id = ?, note_relative_path = ?, note_display_name = ?,
                note_resource_identity = ?, updated_at = ?, row_version = row_version + 1
            WHERE id = ? AND expires_at > ?
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: note.workspaceID.uuidString)
        db.bind(statement, index: 2, text: note.relativePath)
        db.bind(statement, index: 3, text: note.displayName)
        db.bind(statement, index: 4, data: note.resourceIdentity)
        db.bind(statement, index: 5, int: ms(now))
        db.bind(statement, index: 6, text: id.uuidString)
        db.bind(statement, index: 7, int: ms(now))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
    }

    private func updateSelectedModelLocked(
        db: ChatSQLiteConnection,
        id: UUID,
        modelID: String,
        now: Date,
        updateActivity: Bool = false
    ) throws {
        let statement = try db.prepare("""
            UPDATE chat_conversations
            SET selected_model_id = ?, updated_at = ?,
                last_activity_at = CASE WHEN ? THEN ? ELSE last_activity_at END,
                row_version = row_version + 1
            WHERE id = ? AND expires_at > ?
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: modelID)
        db.bind(statement, index: 2, int: ms(now))
        db.bind(statement, index: 3, bool: updateActivity)
        db.bind(statement, index: 4, int: ms(now))
        db.bind(statement, index: 5, text: id.uuidString)
        db.bind(statement, index: 6, int: ms(now))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
    }

    private func loadConversationRow(db: ChatSQLiteConnection, id: UUID, now: Date) throws -> ChatConversation? {
        let statement = try db.prepare("""
            SELECT id, workspace_id, note_relative_path, note_display_name, note_resource_identity,
                   title, title_is_custom, provider, selected_model_id, prompt_version,
                   input_schema_version, draft_text, draft_version, row_version,
                   created_at, updated_at, last_activity_at, expires_at
            FROM chat_conversations WHERE id = ? AND expires_at > ?
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: id.uuidString)
        db.bind(statement, index: 2, int: ms(now))
        guard try db.step(statement) == SQLITE_ROW else { return nil }
        return try conversation(from: statement, db: db)
    }

    private func conversation(from statement: OpaquePointer, db: ChatSQLiteConnection) throws -> ChatConversation {
        guard let id = UUID(uuidString: db.text(statement, 0) ?? ""),
              let title = db.text(statement, 5),
              let provider = db.text(statement, 7),
              let selectedModelID = db.text(statement, 8),
              let promptVersion = db.text(statement, 9) else { throw ChatError.storageUnavailable("Invalid conversation row") }
        return ChatConversation(
            id: id,
            workspaceID: db.text(statement, 1).flatMap(UUID.init(uuidString:)),
            noteRelativePath: db.text(statement, 2),
            noteDisplayName: db.text(statement, 3),
            noteResourceIdentity: db.blob(statement, 4),
            title: title,
            titleIsCustom: sqlite3_column_int(statement, 6) != 0,
            provider: provider,
            selectedModelID: selectedModelID,
            promptVersion: promptVersion,
            inputSchemaVersion: Int(sqlite3_column_int64(statement, 10)),
            draftText: db.text(statement, 11) ?? "",
            draftVersion: sqlite3_column_int64(statement, 12),
            rowVersion: sqlite3_column_int64(statement, 13),
            createdAt: date(sqlite3_column_int64(statement, 14)),
            updatedAt: date(sqlite3_column_int64(statement, 15)),
            lastActivityAt: date(sqlite3_column_int64(statement, 16)),
            expiresAt: date(sqlite3_column_int64(statement, 17))
        )
    }

    private func loadDetailLocked(db: ChatSQLiteConnection, id: UUID, now: Date) throws -> ChatConversationDetail? {
        guard let conversation = try loadConversationRow(db: db, id: id, now: now) else { return nil }
        var snapshots: [ChatContextSnapshot] = []
        let snapshotStatement = try db.prepare("""
            SELECT id, conversation_id, source_kind, document_name, relative_path_at_capture,
                   document_session_id, document_revision, has_unsaved_changes, captured_at,
                   content_text, content_sha256, snapshot_fingerprint, byte_count
            FROM chat_context_snapshots WHERE conversation_id = ? ORDER BY captured_at ASC, id ASC
            """)
        defer { sqlite3_finalize(snapshotStatement) }
        db.bind(snapshotStatement, index: 1, text: id.uuidString)
        while try db.step(snapshotStatement) == SQLITE_ROW {
            guard let snapshotID = UUID(uuidString: db.text(snapshotStatement, 0) ?? ""),
                  let conversationID = UUID(uuidString: db.text(snapshotStatement, 1) ?? ""),
                  let sourceKind = db.text(snapshotStatement, 2),
                  let documentName = db.text(snapshotStatement, 3),
                  let relativePath = db.text(snapshotStatement, 4),
                  let sessionID = UUID(uuidString: db.text(snapshotStatement, 5) ?? ""),
                  let revision = db.text(snapshotStatement, 6),
                  let text = db.text(snapshotStatement, 9),
                  let sha = db.text(snapshotStatement, 10),
                  let fingerprint = db.text(snapshotStatement, 11) else { throw ChatError.storageUnavailable("Invalid snapshot row") }
            snapshots.append(ChatContextSnapshot(
                id: snapshotID, conversationID: conversationID, sourceKind: sourceKind,
                documentName: documentName, relativePathAtCapture: relativePath,
                documentSessionID: sessionID, documentRevision: revision,
                hasUnsavedChanges: sqlite3_column_int(snapshotStatement, 7) != 0,
                capturedAt: date(sqlite3_column_int64(snapshotStatement, 8)), contentText: text,
                contentSHA256: sha, snapshotFingerprint: fingerprint,
                byteCount: Int(sqlite3_column_int64(snapshotStatement, 12))
            ))
        }

        var turns: [ChatTurn] = []
        let turnStatement = try db.prepare("""
            SELECT id, conversation_id, ordinal, state, user_text, user_step_json,
                   context_snapshot_id, context_mode, created_at
            FROM chat_turns WHERE conversation_id = ? ORDER BY ordinal ASC
            """)
        defer { sqlite3_finalize(turnStatement) }
        db.bind(turnStatement, index: 1, text: id.uuidString)
        while try db.step(turnStatement) == SQLITE_ROW {
            guard let turnID = UUID(uuidString: db.text(turnStatement, 0) ?? ""),
                  let conversationID = UUID(uuidString: db.text(turnStatement, 1) ?? ""),
                  let stateRaw = db.text(turnStatement, 3),
                  let state = ChatTurnState(rawValue: stateRaw),
                  let userText = db.text(turnStatement, 4),
                  let userStepJSON = db.blob(turnStatement, 5),
                  let snapshotID = UUID(uuidString: db.text(turnStatement, 6) ?? ""),
                  let contextMode = ChatContextMode(rawValue: db.text(turnStatement, 7) ?? "") else {
                throw ChatError.storageUnavailable("Invalid turn row")
            }
            let attempts = try loadAttempts(db: db, turnID: turnID, conversationID: conversationID)
            turns.append(ChatTurn(
                id: turnID, conversationID: conversationID,
                ordinal: Int(sqlite3_column_int64(turnStatement, 2)), state: state,
                userText: userText, userStepJSON: userStepJSON,
                contextSnapshotID: snapshotID, contextMode: contextMode,
                createdAt: date(sqlite3_column_int64(turnStatement, 8)), attempts: attempts
            ))
        }
        return ChatConversationDetail(conversation: conversation, snapshots: snapshots, turns: turns)
    }

    private func loadAttempts(db: ChatSQLiteConnection, turnID: UUID, conversationID: UUID) throws -> [ChatAttempt] {
        let statement = try db.prepare("""
            SELECT id, attempt_number, generation_id, requested_model_id, effective_model_id,
                   generation_config_json, request_sha256, state, assistant_text, replay_steps_json,
                   provider_interaction_id, usage_json, error_code, error_message,
                   created_at, updated_at, completed_at
            FROM chat_attempts WHERE turn_id = ? AND conversation_id = ? ORDER BY attempt_number ASC
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: turnID.uuidString)
        db.bind(statement, index: 2, text: conversationID.uuidString)
        var attempts: [ChatAttempt] = []
        while try db.step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: db.text(statement, 0) ?? ""),
                  let generationID = UUID(uuidString: db.text(statement, 2) ?? ""),
                  let requestedModelID = db.text(statement, 3),
                  let config = db.blob(statement, 5),
                  let requestSHA256 = db.text(statement, 6),
                  let state = ChatAttemptState(rawValue: db.text(statement, 7) ?? "") else {
                throw ChatError.storageUnavailable("Invalid attempt row")
            }
            attempts.append(ChatAttempt(
                id: id, conversationID: conversationID, turnID: turnID,
                attemptNumber: Int(sqlite3_column_int64(statement, 1)), generationID: generationID,
                requestedModelID: requestedModelID, effectiveModelID: db.text(statement, 4),
                generationConfigJSON: config, requestSHA256: requestSHA256, state: state,
                assistantText: db.text(statement, 8) ?? "", replayStepsJSON: db.blob(statement, 9),
                providerInteractionID: db.text(statement, 10), usageJSON: db.blob(statement, 11),
                errorCode: db.text(statement, 12), errorMessage: db.text(statement, 13),
                createdAt: date(sqlite3_column_int64(statement, 14)),
                updatedAt: date(sqlite3_column_int64(statement, 15)),
                completedAt: sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil : date(sqlite3_column_int64(statement, 16))
            ))
        }
        return attempts
    }

    private func insertOrReuseSnapshot(
        db: ChatSQLiteConnection,
        conversationID: UUID,
        context: CapturedDocumentContext,
        now: Date
    ) throws -> ChatContextSnapshot {
        do {
            let lookup = try db.prepare("SELECT id, captured_at, content_text, content_sha256, snapshot_fingerprint FROM chat_context_snapshots WHERE conversation_id = ? AND snapshot_fingerprint = ? LIMIT 1")
            defer { sqlite3_finalize(lookup) }
            db.bind(lookup, index: 1, text: conversationID.uuidString)
            db.bind(lookup, index: 2, text: context.snapshotFingerprint)
            if try db.step(lookup) == SQLITE_ROW,
               let id = UUID(uuidString: db.text(lookup, 0) ?? "") {
                return ChatContextSnapshot(
                    id: id, conversationID: conversationID, sourceKind: "active_document",
                    documentName: context.reference.displayName, relativePathAtCapture: context.reference.relativePath,
                    documentSessionID: context.reference.documentSessionID, documentRevision: context.reference.documentRevision,
                    hasUnsavedChanges: context.hasUnsavedChanges,
                    capturedAt: date(sqlite3_column_int64(lookup, 1)), contentText: db.text(lookup, 2) ?? context.text,
                    contentSHA256: db.text(lookup, 3) ?? context.contentSHA256,
                    snapshotFingerprint: db.text(lookup, 4) ?? context.snapshotFingerprint,
                    byteCount: ChatLimits.byteCount(context.text)
                )
            }
        }
        let snapshot = ChatContextSnapshot(conversationID: conversationID, context: context)
        let statement = try db.prepare("""
            INSERT INTO chat_context_snapshots
            (id, conversation_id, source_kind, document_name, relative_path_at_capture,
             document_session_id, document_revision, has_unsaved_changes, captured_at,
             content_text, content_sha256, snapshot_fingerprint, byte_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: snapshot.id.uuidString)
        db.bind(statement, index: 2, text: conversationID.uuidString)
        db.bind(statement, index: 3, text: snapshot.sourceKind)
        db.bind(statement, index: 4, text: snapshot.documentName)
        db.bind(statement, index: 5, text: snapshot.relativePathAtCapture)
        db.bind(statement, index: 6, text: snapshot.documentSessionID.uuidString)
        db.bind(statement, index: 7, text: snapshot.documentRevision)
        db.bind(statement, index: 8, bool: snapshot.hasUnsavedChanges)
        db.bind(statement, index: 9, int: ms(snapshot.capturedAt))
        db.bind(statement, index: 10, text: snapshot.contentText)
        db.bind(statement, index: 11, text: snapshot.contentSHA256)
        db.bind(statement, index: 12, text: snapshot.snapshotFingerprint)
        db.bind(statement, index: 13, int: Int64(snapshot.byteCount))
        try db.step(statement)
        return snapshot
    }

    private func nextAttemptNumber(db: ChatSQLiteConnection, turnID: UUID) throws -> Int {
        let statement = try db.prepare("SELECT COALESCE(MAX(attempt_number), 0) + 1 FROM chat_attempts WHERE turn_id = ?")
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: turnID.uuidString)
        guard try db.step(statement) == SQLITE_ROW else { throw db.lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func updateAttemptState(attemptID: UUID, generationID: UUID, state: ChatAttemptState, now: Date?) throws {
        let db = try requireDatabase()
        let timestamp = effectiveNow(now)
        let statement = try db.prepare("""
            UPDATE chat_attempts SET state = ?, updated_at = ?
            WHERE id = ? AND generation_id = ? AND state IN ('prepared', 'sending')
              AND EXISTS (
                SELECT 1 FROM chat_conversations AS c
                WHERE c.id = chat_attempts.conversation_id AND c.expires_at > ?
              )
            """)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: state.rawValue)
        db.bind(statement, index: 2, int: ms(timestamp))
        db.bind(statement, index: 3, text: attemptID.uuidString)
        db.bind(statement, index: 4, text: generationID.uuidString)
        db.bind(statement, index: 5, int: ms(timestamp))
        try db.step(statement)
        guard sqlite3_changes(db.handle) == 1 else { throw ChatError.conflict }
    }

    private func scalarUUID(db: ChatSQLiteConnection, sql: String, value: UUID) throws -> UUID {
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        db.bind(statement, index: 1, text: value.uuidString)
        guard try db.step(statement) == SQLITE_ROW,
              let result = UUID(uuidString: db.text(statement, 0) ?? "") else { throw ChatError.storageUnavailable("Invalid UUID row") }
        return result
    }

    private func deleteExpiredLocked(db: ChatSQLiteConnection, now: Date) throws -> [UUID] {
        var ids: [UUID] = []
        do {
            let statement = try db.prepare("SELECT id FROM chat_conversations WHERE expires_at <= ?")
            defer { sqlite3_finalize(statement) }
            db.bind(statement, index: 1, int: ms(now))
            while try db.step(statement) == SQLITE_ROW {
                if let id = UUID(uuidString: db.text(statement, 0) ?? "") { ids.append(id) }
            }
        }
        guard !ids.isEmpty else { return [] }
        try db.execute("BEGIN IMMEDIATE;")
        do {
            let delete = try db.prepare("DELETE FROM chat_conversations WHERE expires_at <= ?")
            defer { sqlite3_finalize(delete) }
            db.bind(delete, index: 1, int: ms(now))
            try db.step(delete)
            try db.execute("COMMIT;")
            return ids
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    private static func derivedTitle(from question: String) -> String {
        let line = question
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? question
        let normalized = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if normalized.count <= 80 { return normalized.isEmpty ? "New Chat" : normalized }
        return String(normalized.prefix(80))
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func sanitizeError(_ message: String?) -> String? {
        guard let message else { return nil }
        let line = message.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return String(line.prefix(512))
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension ChatContextSnapshot {
    init(
        id: UUID,
        conversationID: UUID,
        sourceKind: String,
        documentName: String,
        relativePathAtCapture: String,
        documentSessionID: UUID,
        documentRevision: String,
        hasUnsavedChanges: Bool,
        capturedAt: Date,
        contentText: String,
        contentSHA256: String,
        snapshotFingerprint: String,
        byteCount: Int
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sourceKind = sourceKind
        self.documentName = documentName
        self.relativePathAtCapture = relativePathAtCapture
        self.documentSessionID = documentSessionID
        self.documentRevision = documentRevision
        self.hasUnsavedChanges = hasUnsavedChanges
        self.capturedAt = capturedAt
        self.contentText = contentText
        self.contentSHA256 = contentSHA256
        self.snapshotFingerprint = snapshotFingerprint
        self.byteCount = byteCount
    }
}
