import Foundation
import SQLite3
import Darwin

/// The first schema is deliberately kept in one transaction. Later versions
/// should append migrations rather than rewriting or copying chat content.
enum ChatDatabaseMigrations {
    static let currentVersion = 1

    static let schema = """
    CREATE TABLE IF NOT EXISTS chat_conversations (
        id TEXT PRIMARY KEY NOT NULL,
        workspace_id TEXT,
        note_relative_path TEXT,
        note_display_name TEXT,
        note_resource_identity BLOB,
        title TEXT NOT NULL,
        title_is_custom INTEGER NOT NULL DEFAULT 0 CHECK (title_is_custom IN (0, 1)),
        provider TEXT NOT NULL DEFAULT 'gemini' CHECK (provider = 'gemini'),
        selected_model_id TEXT NOT NULL,
        prompt_version TEXT NOT NULL,
        input_schema_version INTEGER NOT NULL DEFAULT 1 CHECK (input_schema_version = 1),
        draft_text TEXT NOT NULL DEFAULT '',
        draft_version INTEGER NOT NULL DEFAULT 0 CHECK (draft_version >= 0),
        row_version INTEGER NOT NULL DEFAULT 0 CHECK (row_version >= 0),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_activity_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        CHECK (expires_at = created_at + 2592000000),
        CHECK (updated_at >= created_at),
        CHECK (last_activity_at >= created_at),
        CHECK ((note_relative_path IS NULL AND note_display_name IS NULL AND note_resource_identity IS NULL)
            OR (workspace_id IS NOT NULL AND note_relative_path IS NOT NULL AND note_display_name IS NOT NULL))
    );

    CREATE TABLE IF NOT EXISTS chat_context_snapshots (
        id TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL,
        source_kind TEXT NOT NULL CHECK (source_kind = 'active_document'),
        document_name TEXT NOT NULL,
        relative_path_at_capture TEXT NOT NULL,
        document_session_id TEXT NOT NULL,
        document_revision TEXT NOT NULL,
        has_unsaved_changes INTEGER NOT NULL CHECK (has_unsaved_changes IN (0, 1)),
        captured_at INTEGER NOT NULL,
        content_text TEXT NOT NULL,
        content_sha256 TEXT NOT NULL CHECK (length(content_sha256) = 64),
        snapshot_fingerprint TEXT NOT NULL CHECK (length(snapshot_fingerprint) = 64),
        byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
        UNIQUE (conversation_id, id),
        UNIQUE (conversation_id, snapshot_fingerprint),
        FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS chat_turns (
        id TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
        state TEXT NOT NULL CHECK (state IN ('pending', 'completed', 'abandoned')),
        user_text TEXT NOT NULL,
        user_step_json BLOB NOT NULL,
        context_snapshot_id TEXT NOT NULL,
        context_mode TEXT NOT NULL CHECK (context_mode IN ('live_capture', 'saved_snapshot')),
        created_at INTEGER NOT NULL,
        UNIQUE (conversation_id, id),
        UNIQUE (conversation_id, ordinal),
        FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE,
        FOREIGN KEY (conversation_id, context_snapshot_id)
            REFERENCES chat_context_snapshots(conversation_id, id)
    );

    CREATE TABLE IF NOT EXISTS chat_attempts (
        id TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL,
        turn_id TEXT NOT NULL,
        attempt_number INTEGER NOT NULL CHECK (attempt_number >= 1),
        generation_id TEXT NOT NULL UNIQUE,
        requested_model_id TEXT NOT NULL,
        effective_model_id TEXT,
        generation_config_json BLOB NOT NULL,
        request_sha256 TEXT NOT NULL CHECK (length(request_sha256) = 64),
        state TEXT NOT NULL CHECK (state IN ('prepared', 'sending', 'streaming', 'completed', 'failed', 'cancelled', 'interrupted')),
        assistant_text TEXT NOT NULL DEFAULT '',
        replay_steps_json BLOB,
        provider_interaction_id TEXT,
        usage_json BLOB,
        error_code TEXT,
        error_message TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        completed_at INTEGER,
        UNIQUE (turn_id, attempt_number),
        FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE,
        FOREIGN KEY (conversation_id, turn_id) REFERENCES chat_turns(conversation_id, id) ON DELETE CASCADE,
        CHECK ((state = 'completed' AND replay_steps_json IS NOT NULL AND completed_at IS NOT NULL)
            OR (state <> 'completed' AND completed_at IS NULL))
    );

    CREATE INDEX IF NOT EXISTS chat_conversations_expiry ON chat_conversations(expires_at);
    CREATE INDEX IF NOT EXISTS chat_conversations_activity ON chat_conversations(last_activity_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS chat_conversations_workspace_activity ON chat_conversations(workspace_id, last_activity_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS chat_snapshots_conversation ON chat_context_snapshots(conversation_id);
    CREATE INDEX IF NOT EXISTS chat_attempts_turn ON chat_attempts(turn_id, attempt_number);
    CREATE UNIQUE INDEX IF NOT EXISTS chat_one_pending_turn ON chat_turns(conversation_id) WHERE state = 'pending';
    CREATE UNIQUE INDEX IF NOT EXISTS chat_one_active_attempt ON chat_attempts(conversation_id) WHERE state IN ('prepared', 'sending', 'streaming');
    CREATE UNIQUE INDEX IF NOT EXISTS chat_one_completed_attempt ON chat_attempts(turn_id) WHERE state = 'completed';
    CREATE TRIGGER IF NOT EXISTS chat_retention_is_immutable
    BEFORE UPDATE OF created_at, expires_at ON chat_conversations
    WHEN NEW.created_at <> OLD.created_at OR NEW.expires_at <> OLD.expires_at
    BEGIN SELECT RAISE(ABORT, 'Conversation retention is immutable'); END;
    PRAGMA user_version = 1;
    """
}

/// Small SQLite wrapper used only from ChatRepository's actor. Keeping all C
/// pointers here makes it difficult to accidentally move a connection across
/// isolation domains.
final class ChatSQLiteConnection {
    private(set) var handle: OpaquePointer?
    private let lockDescriptor: Int32

    init(url: URL) throws {
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        // A second app/test process must report unavailable storage instead of
        // blocking the main thread indefinitely during application startup.
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else {
            throw ChatError.storageUnavailable("Another GlassMark process is using Copilot chat storage")
        }
        lockDescriptor = descriptor
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: lockURL.path
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let db { sqlite3_close(db) }
            Darwin.close(descriptor)
            throw ChatError.storageUnavailable(message)
        }
        handle = db
        do {
            try execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA secure_delete = ON; PRAGMA temp_store = MEMORY; PRAGMA busy_timeout = 3000;")
            let existingVersion = try scalarInt("PRAGMA user_version")
            guard existingVersion <= Int64(ChatDatabaseMigrations.currentVersion) else {
                throw ChatError.storageUnavailable("Copilot chat storage was created by a newer version of GlassMark")
            }
            try execute("BEGIN IMMEDIATE; \(ChatDatabaseMigrations.schema) COMMIT;")
            try validatePragmas()
        } catch {
            sqlite3_close(db)
            handle = nil
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        Darwin.close(lockDescriptor)
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw ChatError.storageUnavailable("Database is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw ChatError.storageUnavailable(message)
        }
    }

    func validatePragmas() throws {
        let foreignKeys = try scalarInt("PRAGMA foreign_keys")
        guard foreignKeys == 1 else { throw ChatError.storageUnavailable("SQLite foreign keys are disabled") }
        let journal = try scalarString("PRAGMA journal_mode")?.lowercased()
        guard journal == "delete" else { throw ChatError.storageUnavailable("SQLite journal mode could not be configured") }
        guard try scalarInt("PRAGMA synchronous") == 2,
              try scalarInt("PRAGMA secure_delete") == 1,
              try scalarInt("PRAGMA temp_store") == 2,
              try scalarInt("PRAGMA busy_timeout") == 3000 else {
            throw ChatError.storageUnavailable("SQLite safety settings could not be configured")
        }
        guard try scalarString("PRAGMA quick_check")?.lowercased() == "ok" else {
            throw ChatError.storageUnavailable("SQLite integrity check failed")
        }
        let statement = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ChatError.storageUnavailable("SQLite foreign-key check failed")
        }
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return sqlite3_column_int64(statement, 0)
    }

    func scalarString(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return text(statement, 0)
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw ChatError.storageUnavailable("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw lastError() }
        return statement
    }

    func lastError() -> ChatError {
        guard let handle else { return .storageUnavailable("Database is closed") }
        return .storageUnavailable(String(cString: sqlite3_errmsg(handle)))
    }

    func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func bind(_ statement: OpaquePointer, index: Int32, text: String?) {
        if let text {
            sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ statement: OpaquePointer, index: Int32, data: Data?) {
        guard let data else { sqlite3_bind_null(statement, index); return }
        data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    func bind(_ statement: OpaquePointer, index: Int32, int: Int64) {
        sqlite3_bind_int64(statement, index, int)
    }

    func bind(_ statement: OpaquePointer, index: Int32, bool: Bool) {
        sqlite3_bind_int(statement, index, bool ? 1 : 0)
    }

    func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result
    }
}
