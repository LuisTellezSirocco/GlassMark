import SwiftUI

@main
struct GlassMarkApp: App {
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var documentStore = DocumentStore()
    @StateObject private var preferencesStore = PreferencesStore()
    @StateObject private var commandStore = CommandStore()
    @StateObject private var credentialStore = GeminiCredentialStore()
    @StateObject private var chatCoordinator: ChatCoordinator
    @StateObject private var chatRetentionService: ChatRetentionService

    init() {
        let coordinator = ChatCoordinator()
        _chatCoordinator = StateObject(wrappedValue: coordinator)
        _chatRetentionService = StateObject(wrappedValue: ChatRetentionService(
            repository: coordinator.repository,
            coordinator: coordinator
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspaceStore)
                .environmentObject(documentStore)
                .environmentObject(preferencesStore)
                .environmentObject(commandStore)
                .environmentObject(credentialStore)
                .environmentObject(chatCoordinator)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(preferencesStore.resolvedColorScheme)
                .task {
                    workspaceStore.restoreKnownWorkspaces()
                    chatRetentionService.start()
                }
        }
        .commands {
            AppCommands(
                workspaceStore: workspaceStore,
                documentStore: documentStore,
                commandStore: commandStore,
                preferencesStore: preferencesStore
            )
        }

        Settings {
            SettingsView()
                .environmentObject(preferencesStore)
                .environmentObject(credentialStore)
                .environmentObject(chatCoordinator)
        }
    }
}
