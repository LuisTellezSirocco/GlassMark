import SwiftUI

/// Presentation belongs to the editor scene. Hiding the panel retains its
/// conversation and draft; Copilot never creates a separate native window.
@MainActor
final class CopilotPanelController: ObservableObject {
    let ownerWindowID = UUID()
    @Published private(set) var isPresented = false
    @Published private(set) var store: CopilotWindowStore?

    func show(
        workspaceStore: WorkspaceStore,
        documentStore: DocumentStore,
        preferences: PreferencesStore,
        credentials: GeminiCredentialStore,
        coordinator: ChatCoordinator
    ) {
        if store == nil {
            let contextProvider = ActiveDocumentContextProvider(
                ownerWindowID: ownerWindowID,
                documentStore: documentStore,
                workspaceStore: workspaceStore
            )
            store = CopilotWindowStore(
                ownerWindowID: ownerWindowID,
                coordinator: coordinator,
                contextProvider: contextProvider,
                preferences: preferences,
                credentials: credentials
            )
        }
        isPresented = true
    }

    func hide() {
        store?.historyVisible = false
        store?.stop()
        isPresented = false
    }
}
