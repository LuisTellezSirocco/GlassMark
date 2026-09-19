import Foundation
import SwiftUI

enum ChatError: Error, Equatable, Sendable {
    case storageUnavailable(String)
    case notFound
    case expired
    case conflict
    case invalidState(String)
    case localLimit(String)
    case invalidPayload(String)
    case noActiveNote
    case contextMismatch
    case chatDisabled
    case credentialUnavailable
    case generationInProgress

    var userMessage: String {
        switch self {
        case .storageUnavailable(let message): "Chat storage could not be opened: \(message)"
        case .notFound: "This chat is no longer available."
        case .expired: "This chat has expired."
        case .conflict: "This chat changed in another window. Reload it and try again."
        case .invalidState(let message), .invalidPayload(let message), .localLimit(let message): message
        case .noActiveNote: "Open a note to start a chat."
        case .contextMismatch: "This chat is linked to another note. Open that note or start a new chat."
        case .chatDisabled: "Enable Copilot in Settings before sending a message."
        case .credentialUnavailable: "Add a Gemini API key in Settings before sending a message."
        case .generationInProgress: "A response is already being generated for this chat."
        }
    }
}

struct ChatDocumentReference: Codable, Equatable, Hashable, Sendable {
    let ownerWindowID: UUID
    let workspaceID: UUID
    let documentURL: URL
    let relativePath: String
    let displayName: String
    let documentSessionID: UUID
    let documentRevision: String
    let resourceIdentity: Data?

    init(
        ownerWindowID: UUID,
        workspaceID: UUID,
        documentURL: URL,
        relativePath: String,
        displayName: String,
        documentSessionID: UUID,
        documentRevision: UInt64,
        resourceIdentity: Data? = nil
    ) {
        self.ownerWindowID = ownerWindowID
        self.workspaceID = workspaceID
        self.documentURL = documentURL
        self.relativePath = relativePath
        self.displayName = displayName
        self.documentSessionID = documentSessionID
        self.documentRevision = String(documentRevision)
        self.resourceIdentity = resourceIdentity
    }
}

struct CapturedDocumentContext: Equatable, Sendable {
    let reference: ChatDocumentReference
    let hasUnsavedChanges: Bool
    let text: String
    let capturedAt: Date
    let contentSHA256: String
    let snapshotFingerprint: String

    init(
        reference: ChatDocumentReference,
        hasUnsavedChanges: Bool,
        text: String,
        capturedAt: Date = .now,
        contentSHA256: String? = nil,
        snapshotFingerprint: String? = nil
    ) {
        self.reference = reference
        self.hasUnsavedChanges = hasUnsavedChanges
        self.text = text
        self.capturedAt = capturedAt
        self.contentSHA256 = contentSHA256 ?? Self.sha256(text)
        self.snapshotFingerprint = snapshotFingerprint ?? Self.fingerprint(
            reference: reference,
            hasUnsavedChanges: hasUnsavedChanges,
            text: text
        )
    }

    private static func sha256(_ text: String) -> String {
        // CryptoKit is not available in every test-only Swift environment. A
        // small, deterministic SHA-256 implementation lives in ChatHash.swift.
        ChatHash.sha256(Data(text.utf8))
    }

    private static func fingerprint(
        reference: ChatDocumentReference,
        hasUnsavedChanges: Bool,
        text: String
    ) -> String {
        var bytes = Data()
        func append(_ value: String) {
            bytes.append(Data(value.utf8))
            bytes.append(0)
        }
        append(reference.workspaceID.uuidString)
        append(reference.relativePath)
        append(reference.displayName)
        append(reference.documentSessionID.uuidString)
        append(reference.documentRevision)
        append(reference.resourceIdentity?.base64EncodedString() ?? "")
        append(hasUnsavedChanges ? "1" : "0")
        bytes.append(Data(text.utf8))
        return ChatHash.sha256(bytes)
    }
}

enum ChatContextMode: String, Codable, Sendable {
    case liveCapture = "live_capture"
    case savedSnapshot = "saved_snapshot"
}

struct ChatContextSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let sourceKind: String
    let documentName: String
    let relativePathAtCapture: String
    let documentSessionID: UUID
    let documentRevision: String
    let hasUnsavedChanges: Bool
    let capturedAt: Date
    let contentText: String
    let contentSHA256: String
    let snapshotFingerprint: String
    let byteCount: Int

    init(id: UUID = UUID(), conversationID: UUID, context: CapturedDocumentContext) {
        self.id = id
        self.conversationID = conversationID
        self.sourceKind = "active_document"
        self.documentName = context.reference.displayName
        self.relativePathAtCapture = context.reference.relativePath
        self.documentSessionID = context.reference.documentSessionID
        self.documentRevision = context.reference.documentRevision
        self.hasUnsavedChanges = context.hasUnsavedChanges
        self.capturedAt = context.capturedAt
        self.contentText = context.text
        self.contentSHA256 = context.contentSHA256
        self.snapshotFingerprint = context.snapshotFingerprint
        self.byteCount = ChatLimits.byteCount(context.text)
    }
}

enum ChatTurnState: String, Codable, Sendable {
    case pending
    case completed
    case abandoned
}

enum ChatAttemptState: String, Codable, Sendable {
    case prepared
    case sending
    case streaming
    case completed
    case failed
    case cancelled
    case interrupted

    var isActive: Bool {
        switch self {
        case .prepared, .sending, .streaming: true
        default: false
        }
    }
}

struct ChatConversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var workspaceID: UUID?
    var noteRelativePath: String?
    var noteDisplayName: String?
    var noteResourceIdentity: Data?
    var title: String
    var titleIsCustom: Bool
    var provider: String
    var selectedModelID: String
    var promptVersion: String
    var inputSchemaVersion: Int
    var draftText: String
    var draftVersion: Int64
    var rowVersion: Int64
    let createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
    var noteDescription: String? {
        guard let noteRelativePath else { return nil }
        return noteDisplayName ?? noteRelativePath
    }
}

struct ChatAttempt: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let turnID: UUID
    let attemptNumber: Int
    let generationID: UUID
    let requestedModelID: String
    var effectiveModelID: String?
    let generationConfigJSON: Data
    let requestSHA256: String
    var state: ChatAttemptState
    var assistantText: String
    var replayStepsJSON: Data?
    var providerInteractionID: String?
    var usageJSON: Data?
    var errorCode: String?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
}

struct ChatTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let ordinal: Int
    var state: ChatTurnState
    let userText: String
    let userStepJSON: Data
    let contextSnapshotID: UUID
    let contextMode: ChatContextMode
    let createdAt: Date
    var attempts: [ChatAttempt]

    var completedAttempt: ChatAttempt? {
        attempts.first { $0.state == .completed }
    }

    var latestAttempt: ChatAttempt? {
        attempts.max { $0.attemptNumber < $1.attemptNumber }
    }
}

struct ChatConversationDetail: Sendable, Equatable {
    var conversation: ChatConversation
    var snapshots: [ChatContextSnapshot]
    var turns: [ChatTurn]
}

struct ChatConversationFilter: Sendable, Equatable {
    var workspaceID: UUID?
    var noteRelativePath: String?
    var searchText: String?
    var includeAllWorkspaces = true
    var limit = 50
    var cursor: ChatConversationCursor?

    init(
        workspaceID: UUID? = nil,
        noteRelativePath: String? = nil,
        searchText: String? = nil,
        includeAllWorkspaces: Bool = true,
        limit: Int = 50,
        cursor: ChatConversationCursor? = nil
    ) {
        self.workspaceID = workspaceID
        self.noteRelativePath = noteRelativePath
        self.searchText = searchText
        self.includeAllWorkspaces = includeAllWorkspaces
        self.limit = min(max(limit, 1), 200)
        self.cursor = cursor
    }
}

struct ChatConversationCursor: Sendable, Equatable {
    let lastActivityAt: Date
    let id: UUID
}

struct ChatGenerationUsage: Codable, Equatable, Sendable {
    var totalTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var cachedTokens: Int?

    init(
        totalTokens: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cachedTokens: Int? = nil
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
    }
}

struct ChatGenerationResult: Sendable, Equatable {
    let visibleText: String
    let replayStepsJSON: Data
    let usage: ChatGenerationUsage?
    let providerInteractionID: String?
    let effectiveModelID: String?
}

enum ChatGenerationEvent: Sendable, Equatable {
    case started(providerInteractionID: String, effectiveModelID: String?)
    case textDelta(String)
    case completed(ChatGenerationResult)
}

protocol ChatGenerating: Sendable {
    func streamChat(
        _ request: PreparedChatRequest,
        apiKey: String
    ) -> AsyncThrowingStream<ChatGenerationEvent, Error>
}

struct PreparedChatRequest: Sendable, Equatable {
    let conversationID: UUID
    let turnID: UUID
    let attemptID: UUID
    let generationID: UUID
    let modelID: String
    let promptVersion: String
    let inputSchemaVersion: Int
    let systemInstruction: String
    let inputStepsJSON: Data
    let generationConfigJSON: Data
    let bodyJSON: Data
    let requestSHA256: String
    let expiresAt: Date
}

struct ChatPrepareResult: Sendable, Equatable {
    let detail: ChatConversationDetail
    let preparedRequest: PreparedChatRequest
    let attempt: ChatAttempt
}

struct CopilotAction {
    let isPresented: Bool
    let perform: () -> Void
}

struct CopilotActionKey: FocusedValueKey {
    typealias Value = CopilotAction
}

extension FocusedValues {
    var copilot: CopilotAction? {
        get { self[CopilotActionKey.self] }
        set { self[CopilotActionKey.self] = newValue }
    }
}

struct ChatHash {
    /// SHA-256 (FIPS 180-4), kept dependency-free so model/repository tests can
    /// run without importing CryptoKit in older command-line SDKs.
    static func sha256(_ data: Data) -> String {
        var message = Array(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
            0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
            0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
            0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
            0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let offset = chunkStart + i * 4
                w[i] = UInt32(message[offset]) << 24 | UInt32(message[offset + 1]) << 16
                    | UInt32(message[offset + 2]) << 8 | UInt32(message[offset + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
