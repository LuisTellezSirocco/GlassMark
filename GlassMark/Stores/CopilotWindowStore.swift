import Foundation
import SwiftUI

@MainActor
final class CopilotWindowStore: ObservableObject {
    let ownerWindowID: UUID
    let coordinator: ChatCoordinator
    let contextProvider: ActiveDocumentContextProvider
    let preferences: PreferencesStore
    let credentials: GeminiCredentialStore

    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var detail: ChatConversationDetail?
    @Published var draft = "" {
        didSet { scheduleDraftSave() }
    }
    @Published var selectedModelID: String
    @Published private(set) var partialResponse = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var generationID: UUID?
    @Published var errorMessage: String?
    @Published var historyVisible = false
    @Published private(set) var isLoading = false
    @Published private(set) var contextModeMessage: String?
    @Published var historySearch = ""
    @Published var historyScopeAllWorkspaces = false
    @Published var useSavedSnapshot = false

    private var selectedConversationID: UUID?
    private var generationTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var isApplyingDraft = false
    private var hasStarted = false

    init(
        ownerWindowID: UUID,
        coordinator: ChatCoordinator,
        contextProvider: ActiveDocumentContextProvider,
        preferences: PreferencesStore,
        credentials: GeminiCredentialStore
    ) {
        self.ownerWindowID = ownerWindowID
        self.coordinator = coordinator
        self.contextProvider = contextProvider
        self.preferences = preferences
        self.credentials = credentials
        self.selectedModelID = preferences.copilotDefaultModelID
    }

    var selectedConversation: ChatConversation? { detail?.conversation }
    var currentSnapshot: ChatContextSnapshot? {
        guard let detail else { return nil }
        if let snapshot = detail.turns.reversed()
            .first(where: { $0.state != .abandoned })
            .flatMap({ turn in detail.snapshots.first { $0.id == turn.contextSnapshotID } }) {
            return snapshot
        }
        return detail.turns.isEmpty ? detail.snapshots.last : nil
    }
    var isExpired: Bool { detail?.conversation.expiresAt ?? .distantPast <= .now }
    var hasActiveNote: Bool { contextProvider.hasActiveNote }

    func start() async {
        guard !hasStarted else {
            await reloadConversations()
            return
        }
        hasStarted = true
        await reloadConversations()
        if let first = conversations.first {
            await selectConversation(id: first.id)
        } else {
            newChat()
        }
    }

    func reloadConversations() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let workspaceID = contextProvider.activeWorkspaceID
            let filter = ChatConversationFilter(
                workspaceID: historyScopeAllWorkspaces ? nil : workspaceID,
                searchText: historySearch,
                includeAllWorkspaces: historyScopeAllWorkspaces || workspaceID == nil
            )
            conversations = try await coordinator.listConversations(filter: filter)
        } catch {
            errorMessage = (error as? ChatError)?.userMessage ?? error.localizedDescription
        }
    }

    func scheduleHistoryReload() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            await reloadConversations()
        }
    }

    func newChat() {
        generationTask?.cancel()
        draftTask?.cancel()
        selectedConversationID = nil
        detail = nil
        isApplyingDraft = true
        draft = ""
        isApplyingDraft = false
        selectedModelID = preferences.copilotDefaultModelID
        partialResponse = ""
        contextModeMessage = nil
        errorMessage = nil
        useSavedSnapshot = false
    }

    func selectConversation(id: UUID) async {
        guard !isGenerating || selectedConversationID == id else { return }
        do {
            let loaded = try await coordinator.loadConversation(id: id)
            selectedConversationID = id
            detail = loaded
            selectedModelID = loaded.conversation.selectedModelID
            isApplyingDraft = true
            draft = loaded.conversation.draftText
            isApplyingDraft = false
            partialResponse = ""
            contextModeMessage = nil
            errorMessage = nil
            useSavedSnapshot = false
        } catch let error as ChatError {
            errorMessage = error.userMessage
            await reloadConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateModel(_ modelID: String) {
        selectedModelID = modelID
        guard let id = selectedConversationID, !isGenerating else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await coordinator.repository.updateSelectedModel(id: id, modelID: modelID)
                if detail != nil { detail?.conversation = updated }
            } catch {
                errorMessage = (error as? ChatError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    func rename(id: UUID, title: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let renamed = try await coordinator.rename(id: id, title: title)
                if detail?.conversation.id == id {
                    detail?.conversation = renamed
                }
                if let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index] = renamed
                }
            } catch {
                errorMessage = (error as? ChatError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    func send() {
        guard !isGenerating else { return }
        let question = draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard preferences.copilotChatEnabled else {
            errorMessage = ChatError.chatDisabled.userMessage
            return
        }
        guard let apiKey = credentials.currentKey() else {
            errorMessage = ChatError.credentialUnavailable.userMessage
            return
        }

        let captured: CapturedDocumentContext
        do {
            if useSavedSnapshot, let snapshot = currentSnapshot {
                let reference = ChatDocumentReference(
                    ownerWindowID: ownerWindowID,
                    workspaceID: detail?.conversation.workspaceID ?? UUID(),
                    documentURL: URL(fileURLWithPath: snapshot.relativePathAtCapture),
                    relativePath: snapshot.relativePathAtCapture,
                    displayName: snapshot.documentName,
                    documentSessionID: snapshot.documentSessionID,
                    documentRevision: UInt64(snapshot.documentRevision) ?? 0
                )
                captured = CapturedDocumentContext(
                    reference: reference,
                    hasUnsavedChanges: snapshot.hasUnsavedChanges,
                    text: snapshot.contentText,
                    capturedAt: snapshot.capturedAt,
                    contentSHA256: snapshot.contentSHA256,
                    snapshotFingerprint: snapshot.snapshotFingerprint
                )
                contextModeMessage = "Using the last captured note version."
            } else {
                captured = try contextProvider.captureActiveNote()
            }
        } catch let error as ChatError {
            errorMessage = error.userMessage
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if let conversation = detail?.conversation,
           let workspaceID = conversation.workspaceID,
           let path = conversation.noteRelativePath,
           (captured.reference.workspaceID != workspaceID || captured.reference.relativePath != path) {
            errorMessage = ChatError.contextMismatch.userMessage
            return
        }

        isApplyingDraft = true
        draft = ""
        isApplyingDraft = false
        partialResponse = ""
        contextModeMessage = useSavedSnapshot ? "Using the last captured note version." : nil
        errorMessage = nil
        isGenerating = true

        draftTask?.cancel()
        let conversationID = selectedConversationID
        let rowVersion = detail?.conversation.rowVersion
        let draftVersion = detail?.conversation.draftVersion
        let stream = coordinator.streamChat(
            conversationID: conversationID,
            question: question,
            context: captured,
            selectedModelID: selectedModelID,
            expectedRowVersion: rowVersion,
            expectedDraftVersion: draftVersion,
            apiKey: apiKey
        )
        generationTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                handle(event)
            }
            isGenerating = false
            generationID = nil
            await reloadConversations()
            if let selectedConversationID,
               let refreshed = try? await coordinator.loadConversation(id: selectedConversationID) {
                detail = refreshed
            }
        }
    }

    func toggleSavedSnapshot() {
        guard currentSnapshot != nil else { return }
        useSavedSnapshot.toggle()
        contextModeMessage = useSavedSnapshot
            ? "Using the last captured note version."
            : "The open note will be captured on Send."
    }

    func stop() {
        if let selectedConversationID, isGenerating {
            coordinator.cancelConversation(selectedConversationID)
        }
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    func retryPendingTurn() {
        guard !isGenerating,
              let selectedDetail = detail,
              let turn = selectedDetail.turns.last(where: { $0.state == .pending }),
              let apiKey = credentials.currentKey() else { return }
        isGenerating = true
        partialResponse = ""
        errorMessage = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await coordinator.repository.prepareRetry(
                    turnID: turn.id,
                    selectedModelID: selectedModelID,
                    expectedRowVersion: selectedDetail.conversation.rowVersion
                )
                let stream = coordinator.streamPrepared(prepared, apiKey: apiKey)
                for await event in stream { handle(event) }
            } catch let error as ChatError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
            generationID = nil
            await reloadConversations()
            if let selectedConversationID,
               let refreshed = try? await coordinator.loadConversation(id: selectedConversationID) {
                detail = refreshed
            }
        }
    }

    func discardPendingTurn() {
        guard !isGenerating, let turn = detail?.turns.last(where: { $0.state == .pending }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.repository.abandonPendingTurn(turnID: turn.id)
                detail = try await coordinator.loadConversation(id: turn.conversationID)
                await reloadConversations()
            } catch {
                errorMessage = (error as? ChatError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    func deleteSelected() {
        guard let id = selectedConversationID else { return }
        deleteConversation(id: id)
    }

    func deleteConversation(id: UUID) {
        if selectedConversationID == id {
            generationTask?.cancel()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.delete(id: id)
                if selectedConversationID == id { newChat() }
                await reloadConversations()
            } catch {
                errorMessage = (error as? ChatError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func handle(_ event: ChatCoordinatorEvent) {
        switch event {
        case .prepared(let prepared):
            selectedConversationID = prepared.detail.conversation.id
            detail = prepared.detail
            generationID = prepared.preparedRequest.generationID
        case .started:
            break
        case .textDelta(_, let text):
            partialResponse.append(text)
        case .completed(_, _, let newDetail):
            detail = newDetail
            selectedConversationID = newDetail.conversation.id
            partialResponse = ""
        case .failed(_, let message, _):
            errorMessage = message
        }
    }

    private func scheduleDraftSave() {
        guard !isApplyingDraft else { return }
        draftTask?.cancel()
        let text = draft
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            do {
                if let id = selectedConversationID {
                    let expectedVersion = detail?.conversation.draftVersion ?? 0
                    let updated = try await coordinator.saveDraft(id: id, expectedVersion: expectedVersion, text: text)
                    if detail?.conversation.id == id { detail?.conversation = updated }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let created = try await coordinator.createDraft(
                        workspaceID: contextProvider.activeWorkspaceID,
                        modelID: selectedModelID
                    )
                    let updated = try await coordinator.saveDraft(
                        id: created.id, expectedVersion: created.draftVersion, text: text
                    )
                    selectedConversationID = created.id
                    detail = ChatConversationDetail(conversation: updated, snapshots: [], turns: [])
                    conversations.insert(updated, at: 0)
                }
            } catch { }
        }
    }
}
