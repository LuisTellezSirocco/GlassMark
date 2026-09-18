import XCTest
@testable import GlassMark

@MainActor
final class InlineEditStoreTests: XCTestCase {
    private var root: URL!
    private var documents: DocumentStore!
    private var preferences: PreferencesStore!
    private var credentials: GeminiCredentialStore!
    private var generator: FakeGeminiGenerator!
    private var store: InlineEditStore!
    private var document: EditorDocument!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassMarkAITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("note.md")
        try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

        let workspace = Workspace(displayName: "Test", rootURL: root, bookmarkData: Data())
        let file = WorkspaceFile(url: fileURL, rootURL: root, kind: .markdown)

        documents = DocumentStore()
        documents.open(file, workspace: workspace)
        document = try XCTUnwrap(documents.document)

        preferences = PreferencesStore()
        preferences.aiEditingEnabled = true
        preferences.aiModel = "gemini-3.5-flash-lite"

        generator = FakeGeminiGenerator()
        let secrets = InMemorySecretStore()
        try secrets.setSecret("test-key", account: GeminiCredentialStore.account)
        credentials = GeminiCredentialStore(secretStore: secrets, environment: [:], generator: generator)

        store = InlineEditStore(windowID: UUID(), generator: generator)
        store.configure(credentials: credentials, preferences: preferences, documents: documents)
    }

    override func tearDownWithError() throws {
        preferences?.aiEditingEnabled = false
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func activateAndCapture(
        range: NSRange = NSRange(location: 0, length: 5),
        original: String = "hello"
    ) throws -> InlineEditTarget {
        store.activate()
        let token = try XCTUnwrap(store.activationToken)
        let target = InlineEditTarget(
            windowID: store.windowID,
            editorID: UUID(),
            workspaceID: document.workspaceID,
            documentURL: document.file.url,
            documentSessionID: document.sessionID,
            revision: document.revision,
            range: range,
            original: original
        )
        store.handleCapture(
            token: token,
            result: .captured(InlineEditCapture(target: target, scope: .selection, anchorRect: nil, containerSize: nil))
        )
        return target
    }

    private func submitAndWaitForReady(proposal: String = "HELLO") async throws {
        generator.enqueue(events: [
            .started(id: "fake"),
            .textDelta(proposal),
            .completed(usage: nil),
        ])
        store.instruction = "Make it uppercase"
        store.submit()
        let reached = await waitFor { self.store.phase == .ready }
        XCTAssertTrue(reached, "phase was \(store.phase)")
    }

    // MARK: - Activation

    func testActivateWithoutEnablementNeedsSetup() throws {
        preferences.aiEditingEnabled = false
        store.activate()
        XCTAssertEqual(store.phase, .needsSetup)
        XCTAssertEqual(store.setupIssue, .disabled)
    }

    func testActivateWithoutKeyNeedsSetup() throws {
        credentials.remove()
        store.activate()
        XCTAssertEqual(store.phase, .needsSetup)
        XCTAssertEqual(store.setupIssue, .missingKey)
    }

    func testActivationIgnoredWhileSessionLive() throws {
        try activateAndCapture()
        XCTAssertEqual(store.phase, .awaitingInstruction)
        store.activate()
        XCTAssertEqual(store.phase, .awaitingInstruction)
        XCTAssertNotNil(store.target)
    }

    func testCaptureFailureShowsFailedState() throws {
        store.activate()
        let token = try XCTUnwrap(store.activationToken)
        store.handleCapture(token: token, result: .failed(reason: "Nothing to edit"))
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.errorMessage, "Nothing to edit")
    }

    // MARK: - Generation

    func testSubmitStreamsAndPreparesDiff() async throws {
        try activateAndCapture()
        try await submitAndWaitForReady()

        XCTAssertEqual(store.proposal, "HELLO")
        XCTAssertEqual(store.activeModel, "gemini-3.5-flash-lite")
        XCTAssertFalse(store.diffRows.isEmpty)

        let input = try XCTUnwrap(generator.receivedInputs.first)
        XCTAssertEqual(input.selection, "hello")
        XCTAssertEqual(input.instruction, "Make it uppercase")
        XCTAssertEqual(input.thinkingLevel, "low")
        XCTAssertEqual(generator.receivedKeys.first, "test-key")
    }

    func testIdenticalProposalShowsUnchanged() async throws {
        try activateAndCapture()
        generator.enqueue(events: [.started(id: "fake"), .textDelta("hello"), .completed(usage: nil)])
        store.instruction = "no-op"
        store.submit()

        let reached = await waitFor { self.store.phase == .unchanged }
        XCTAssertTrue(reached, "phase was \(store.phase)")
        XCTAssertNil(store.proposal)
    }

    func testEmptyProposalFails() async throws {
        try activateAndCapture()
        generator.enqueue(events: [.started(id: "fake"), .completed(usage: nil)])
        store.instruction = "delete everything"
        store.submit()

        let reached = await waitFor { self.store.phase == .failed }
        XCTAssertTrue(reached, "phase was \(store.phase)")
        XCTAssertNotNil(store.errorMessage)
    }

    func testFailureAllowsExplicitRetry() async throws {
        try activateAndCapture()
        generator.enqueue(events: [], error: GeminiAPIError.rateLimited(retryAfter: nil))
        store.instruction = "Fix"
        store.submit()

        let failed = await waitFor { self.store.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(store.canRetry)
        XCTAssertEqual(store.errorMessage, GeminiAPIError.rateLimited(retryAfter: nil).userMessage)

        generator.enqueue(events: [.started(id: "fake"), .textDelta("fixed"), .completed(usage: nil)])
        store.retry()
        let ready = await waitFor { self.store.phase == .ready }
        XCTAssertTrue(ready, "phase was \(store.phase)")
        XCTAssertEqual(store.proposal, "fixed")
    }

    func testSubmitWithChangedDocumentBecomesStale() async throws {
        try activateAndCapture()
        documents.updateText("hello world!")
        XCTAssertEqual(store.phase, .awaitingInstruction)

        store.instruction = "Fix"
        store.submit()
        XCTAssertEqual(store.phase, .stale)
    }

    // MARK: - Apply

    func testAcceptPublishesSingleReplacement() async throws {
        try activateAndCapture()
        try await submitAndWaitForReady()

        store.accept()
        XCTAssertEqual(store.phase, .applying)

        let request = try XCTUnwrap(store.pendingReplacement)
        XCTAssertEqual(request.replacement, "HELLO")
        XCTAssertEqual(request.target.original, "hello")

        store.applicationFinished(requestID: request.id, outcome: .applied)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.pendingReplacement)
        XCTAssertNil(store.target)
    }

    func testApplicationRejectionKeepsProposal() async throws {
        try activateAndCapture()
        try await submitAndWaitForReady()

        store.accept()
        let request = try XCTUnwrap(store.pendingReplacement)
        store.applicationFinished(requestID: request.id, outcome: .rejected(reason: "Text changed"))

        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.errorMessage, "Text changed")
        XCTAssertEqual(store.proposal, "HELLO")
        XCTAssertFalse(store.canRetry)
    }

    func testLateApplicationAckIsIgnored() async throws {
        try activateAndCapture()
        try await submitAndWaitForReady()

        let staleID = UUID()
        store.applicationFinished(requestID: staleID, outcome: .applied)
        XCTAssertEqual(store.phase, .ready)
    }

    // MARK: - Invalidation and cancellation

    func testDocumentChangeInvalidatesReadyProposal() async throws {
        try activateAndCapture()
        try await submitAndWaitForReady()

        documents.updateText("hello world changed")
        store.documentContentChanged()

        XCTAssertEqual(store.phase, .stale)
        store.accept()
        XCTAssertEqual(store.phase, .stale)
        XCTAssertNil(store.pendingReplacement)
    }

    func testDiscardDuringStreamingReturnsToIdle() async throws {
        try activateAndCapture()
        generator.enqueue(events: [.started(id: "fake")], holdOpen: true)
        store.instruction = "Fix"
        store.submit()

        let streaming = await waitFor { self.store.phase == .streaming }
        XCTAssertTrue(streaming)

        store.discard()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.target)
    }

    func testCredentialRemovalCancelsSession() async throws {
        try activateAndCapture()
        generator.enqueue(events: [.started(id: "fake")], holdOpen: true)
        store.instruction = "Fix"
        store.submit()
        let streaming = await waitFor { self.store.phase == .streaming }
        XCTAssertTrue(streaming)

        credentials.remove()
        store.credentialsChanged()
        XCTAssertEqual(store.phase, .idle)
    }

    func testEditorTeardownCancelsSession() throws {
        let target = try activateAndCapture()
        store.editorDisappeared(editorID: UUID())
        XCTAssertEqual(store.phase, .awaitingInstruction)

        store.editorDisappeared(editorID: target.editorID)
        XCTAssertEqual(store.phase, .idle)
    }

    func testDiscardRequestsSelectionRestore() throws {
        try activateAndCapture()
        store.discard()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNotNil(store.selectionRestoreRequest)
    }
}
