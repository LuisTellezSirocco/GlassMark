import AppKit
import XCTest
@testable import GlassMark

@MainActor
final class CopilotPanelControllerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassMarkPanelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReopeningPanelPreservesSelectedChatAndDraftWithoutCreatingAWindow() async throws {
        let repository = ChatRepository(databaseURL: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ChatCoordinator(repository: repository)
        let older = try await repository.createDraft(now: .now.addingTimeInterval(-60))
        _ = try await repository.createDraft()
        let panel = CopilotPanelController()
        let workspaces = WorkspaceStore()
        let documents = DocumentStore()
        let preferences = PreferencesStore()
        let credentials = GeminiCredentialStore(secretStore: InMemorySecretStore(), environment: [:])
        let windowCount = NSApp.windows.count

        panel.show(workspaceStore: workspaces, documentStore: documents,
                   preferences: preferences, credentials: credentials, coordinator: coordinator)
        let store = try XCTUnwrap(panel.store)
        await store.start()
        await store.selectConversation(id: older.id)
        store.draft = "Keep this unsent question"

        panel.hide()
        XCTAssertFalse(panel.isPresented)
        panel.show(workspaceStore: workspaces, documentStore: documents,
                   preferences: preferences, credentials: credentials, coordinator: coordinator)
        await store.start()

        XCTAssertTrue(panel.isPresented)
        XCTAssertTrue(panel.store === store)
        XCTAssertEqual(store.selectedConversation?.id, older.id)
        XCTAssertEqual(store.draft, "Keep this unsent question")
        XCTAssertEqual(NSApp.windows.count, windowCount, "Copilot must be hosted inside the editor scene.")
        store.newChat() // Cancel the test-only pending draft debounce.
    }

    func testPanelsHaveIndependentPresentationAndOwners() throws {
        let coordinator = ChatCoordinator(repository: ChatRepository(databaseURL: root.appendingPathComponent("chat.sqlite")))
        let workspaces = WorkspaceStore()
        let documents = DocumentStore()
        let preferences = PreferencesStore()
        let credentials = GeminiCredentialStore(secretStore: InMemorySecretStore(), environment: [:])
        let first = CopilotPanelController()
        let second = CopilotPanelController()
        for panel in [first, second] {
            panel.show(workspaceStore: workspaces, documentStore: documents,
                       preferences: preferences, credentials: credentials, coordinator: coordinator)
        }

        XCTAssertNotEqual(first.ownerWindowID, second.ownerWindowID)
        XCTAssertFalse(first.store === second.store)
        first.hide()
        XCTAssertFalse(first.isPresented)
        XCTAssertTrue(second.isPresented)
        XCTAssertEqual(second.store?.contextProvider.ownerWindowID, second.ownerWindowID)
    }
}
