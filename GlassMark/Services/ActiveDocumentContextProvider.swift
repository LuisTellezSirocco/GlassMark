import Foundation

/// Captures the exact in-memory editor buffer. This type is main-actor bound so
/// a send cannot race a SwiftUI/editor update while the reference is assembled.
@MainActor
final class ActiveDocumentContextProvider {
    private weak var documentStore: DocumentStore?
    private weak var workspaceStore: WorkspaceStore?
    let ownerWindowID: UUID

    init(
        ownerWindowID: UUID,
        documentStore: DocumentStore,
        workspaceStore: WorkspaceStore
    ) {
        self.ownerWindowID = ownerWindowID
        self.documentStore = documentStore
        self.workspaceStore = workspaceStore
    }

    var activeWorkspaceID: UUID? {
        workspaceStore?.activeWorkspace?.id
    }

    var hasActiveNote: Bool {
        guard let document = documentStore?.document,
              let workspaceID = workspaceStore?.activeWorkspace?.id else { return false }
        return document.workspaceID == workspaceID
    }

    func captureActiveNote(expectedBinding: ChatDocumentReference? = nil) throws -> CapturedDocumentContext {
        guard let document = documentStore?.document else { throw ChatError.noActiveNote }
        guard let workspace = workspaceStore?.activeWorkspace,
              workspace.id == document.workspaceID else {
            throw ChatError.noActiveNote
        }

        let reference = ChatDocumentReference(
            ownerWindowID: ownerWindowID,
            workspaceID: document.workspaceID,
            documentURL: document.file.url,
            relativePath: document.file.relativePath,
            displayName: document.file.name,
            documentSessionID: document.sessionID,
            documentRevision: document.revision
        )

        if let expectedBinding {
            guard expectedBinding.workspaceID == reference.workspaceID,
                  expectedBinding.relativePath == reference.relativePath,
                  expectedBinding.documentURL.standardizedFileURL == reference.documentURL.standardizedFileURL,
                  expectedBinding.ownerWindowID == ownerWindowID else {
                throw ChatError.contextMismatch
            }
        }

        let context = CapturedDocumentContext(
            reference: reference,
            hasUnsavedChanges: document.isDirty,
            text: document.text
        )
        try ChatLimits.validateSnapshot(context.text)
        return context
    }
}
