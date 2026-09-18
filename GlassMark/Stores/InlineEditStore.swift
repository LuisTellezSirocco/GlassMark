import Foundation

/// Per-window state machine for the inline AI editor. Owns the captured target,
/// the network task, the proposal and its diff, and the single apply transaction.
@MainActor
final class InlineEditStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case needsSetup
        case awaitingInstruction
        case streaming
        case preparingDiff
        case ready
        case unchanged
        case applying
        case stale
        case failed
    }

    enum SetupIssue: Equatable {
        case disabled
        case missingKey
    }

    let windowID: UUID

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var setupIssue: SetupIssue?
    @Published private(set) var target: InlineEditTarget?
    @Published private(set) var scope: InlineEditScope?
    @Published private(set) var anchorRect: CGRect?
    @Published private(set) var containerSize: CGSize?
    @Published var instruction: String = ""
    @Published private(set) var partialText: String = ""
    @Published private(set) var proposal: String?
    @Published private(set) var diffRows: [DiffRow] = []
    @Published private(set) var diffExceedsBudget = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canRetry = false
    @Published private(set) var activeModel: String?
    @Published private(set) var activationToken: UUID?
    @Published private(set) var pendingReplacement: ReplacementRequest?
    @Published private(set) var selectionRestoreRequest: SelectionRestoreRequest?

    private weak var credentials: GeminiCredentialStore?
    private weak var preferences: PreferencesStore?
    private weak var documents: DocumentStore?

    private let generator: GeminiGenerating
    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?
    private var accumulatedText = ""
    private var lastPublishedAt = ContinuousClock.now
    private var lastSubmittedInstruction = ""
    private var applyRequestID: UUID?

    init(windowID: UUID, generator: GeminiGenerating = GeminiClient()) {
        self.windowID = windowID
        self.generator = generator
    }

    func configure(
        credentials: GeminiCredentialStore,
        preferences: PreferencesStore,
        documents: DocumentStore
    ) {
        self.credentials = credentials
        self.preferences = preferences
        self.documents = documents
    }

    var isSessionActive: Bool {
        switch phase {
        case .idle, .needsSetup:
            return false
        default:
            return true
        }
    }

    var isPanelVisible: Bool {
        phase != .idle
    }

    var selectionUTF16Count: Int {
        target?.original.utf16.count ?? 0
    }

    var modelDisplayTitle: String {
        let model = activeModel ?? preferences?.aiModel ?? AIModelCatalog.defaultModelID
        return AIModelCatalog.displayTitle(for: model)
    }

    // MARK: - Activation

    /// Called by the focused scene action. Ignores the request while a session is
    /// live; otherwise starts a fresh capture.
    func activate() {
        switch phase {
        case .awaitingInstruction, .streaming, .preparingDiff, .ready, .unchanged, .applying:
            return
        default:
            break
        }

        reset(restoreSelection: false)

        guard let preferences else { return }
        guard preferences.aiEditingEnabled else {
            setupIssue = .disabled
            phase = .needsSetup
            return
        }
        guard let credentials, credentials.isConfigured else {
            setupIssue = .missingKey
            phase = .needsSetup
            return
        }
        guard documents?.document != nil else { return }
        activationToken = UUID()
    }

    func clearActivationToken(_ token: UUID?) {
        guard let token else {
            activationToken = nil
            return
        }
        if activationToken == token {
            activationToken = nil
        }
    }

    func handleCapture(token: UUID, result: InlineEditCaptureResult) {
        guard activationToken == token else { return }
        activationToken = nil

        switch result {
        case .captured(let capture):
            target = capture.target
            scope = capture.scope
            anchorRect = capture.anchorRect
            containerSize = capture.containerSize
            instruction = ""
            errorMessage = nil
            canRetry = false
            phase = .awaitingInstruction
        case .failed(let reason):
            reset(restoreSelection: false)
            errorMessage = reason
            phase = .failed
        }
    }

    func updateAnchor(rect: CGRect?, containerSize: CGSize) {
        guard isSessionActive || phase == .failed else { return }
        anchorRect = rect
        self.containerSize = containerSize
    }

    // MARK: - Generation

    func submit() {
        guard phase == .awaitingInstruction, let target else { return }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else { return }
        guard currentDocumentMatches(target) else {
            becomeStale()
            return
        }
        guard let credentials, let key = credentials.currentKey() else {
            reset(restoreSelection: false)
            setupIssue = .missingKey
            phase = .needsSetup
            return
        }

        lastSubmittedInstruction = trimmedInstruction
        let model = (preferences?.aiModel ?? AIModelCatalog.defaultModelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let input = GeminiEditInput(
            model: model,
            instruction: trimmedInstruction,
            selection: target.original,
            thinkingLevel: AIModelCatalog.thinkingLevel(for: model)
        )
        start(input: input, apiKey: key, target: target)
    }

    func retry() {
        guard phase == .failed, let target else { return }
        guard currentDocumentMatches(target) else {
            becomeStale()
            return
        }
        guard let credentials, let key = credentials.currentKey() else {
            reset(restoreSelection: false)
            setupIssue = .missingKey
            phase = .needsSetup
            return
        }
        let model = (preferences?.aiModel ?? AIModelCatalog.defaultModelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let input = GeminiEditInput(
            model: model,
            instruction: lastSubmittedInstruction,
            selection: target.original,
            thinkingLevel: AIModelCatalog.thinkingLevel(for: model)
        )
        start(input: input, apiKey: key, target: target)
    }

    private func start(input: GeminiEditInput, apiKey: String, target: InlineEditTarget) {
        generationTask?.cancel()
        let id = UUID()
        generationID = id
        accumulatedText = ""
        partialText = ""
        proposal = nil
        diffRows = []
        diffExceedsBudget = false
        errorMessage = nil
        canRetry = false
        activeModel = input.model
        phase = .streaming
        lastPublishedAt = ContinuousClock.now

        let generator = self.generator
        generationTask = Task { [weak self] in
            do {
                for try await event in generator.streamEdit(input, apiKey: apiKey) {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    self.handle(event: event, generationID: id)
                }
                self?.streamEnded(generationID: id)
            } catch {
                self?.handleFailure(error, generationID: id)
            }
        }
    }

    private func handle(event: GeminiStreamEvent, generationID id: UUID) {
        guard generationID == id, phase == .streaming else { return }
        switch event {
        case .started:
            break
        case .textDelta(let text):
            accumulatedText += text
            let now = ContinuousClock.now
            if now - lastPublishedAt >= InlineEditLimits.partialPublishInterval {
                partialText = accumulatedText
                lastPublishedAt = now
            }
        case .completed:
            partialText = accumulatedText
            phase = .preparingDiff
            prepareDiff(generationID: id)
        }
    }

    private func streamEnded(generationID id: UUID) {
        guard generationID == id, phase == .streaming else { return }
        phase = .failed
        errorMessage = GeminiAPIError.incompleteResponse.userMessage
        canRetry = canRetryCurrentTarget()
    }

    private func handleFailure(_ error: Error, generationID id: UUID) {
        guard generationID == id else { return }
        guard phase == .streaming || phase == .preparingDiff else { return }
        if let apiError = error as? GeminiAPIError, apiError == .cancelled { return }
        phase = .failed
        errorMessage = (error as? GeminiAPIError)?.userMessage ?? error.localizedDescription
        canRetry = canRetryCurrentTarget()
    }

    private func prepareDiff(generationID id: UUID) {
        guard let target else { return }
        let original = target.original
        let proposed = accumulatedText

        guard !proposed.utf16.isEmpty else {
            phase = .failed
            errorMessage = "Gemini returned an empty response."
            canRetry = canRetryCurrentTarget()
            return
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                TextDiff.makeRows(original: original, proposed: proposed)
            }.value

            guard let self, self.generationID == id, self.phase == .preparingDiff else { return }

            if original.isExactlyEqual(to: proposed) {
                self.proposal = nil
                self.diffRows = []
                self.diffExceedsBudget = false
                self.phase = .unchanged
                return
            }
            self.proposal = proposed
            self.diffRows = result.rows
            self.diffExceedsBudget = result.exceedsBudget
            self.phase = .ready
        }
    }

    private func canRetryCurrentTarget() -> Bool {
        guard let target else { return false }
        return currentDocumentMatches(target) && (credentials?.isConfigured ?? false)
    }

    // MARK: - Apply / discard

    func accept() {
        guard phase == .ready, let target, let proposal else { return }
        guard currentDocumentMatches(target) else {
            becomeStale()
            return
        }
        let requestID = UUID()
        applyRequestID = requestID
        phase = .applying
        pendingReplacement = ReplacementRequest(
            id: requestID,
            generationID: generationID ?? UUID(),
            target: target,
            replacement: proposal
        )
    }

    func clearPendingReplacement(_ request: ReplacementRequest?) {
        guard let request else {
            pendingReplacement = nil
            return
        }
        if pendingReplacement?.id == request.id {
            pendingReplacement = nil
        }
    }

    func applicationFinished(requestID: UUID, outcome: InlineEditApplicationOutcome) {
        guard phase == .applying, applyRequestID == requestID else { return }
        pendingReplacement = nil
        applyRequestID = nil

        switch outcome {
        case .applied:
            reset(restoreSelection: false)
        case .rejected(let reason):
            phase = .failed
            errorMessage = reason
            canRetry = false
        }
    }

    func discard() {
        reset(restoreSelection: true)
    }

    func close() {
        reset(restoreSelection: false)
    }

    func clearSelectionRestoreRequest(_ request: SelectionRestoreRequest?) {
        guard let request else {
            selectionRestoreRequest = nil
            return
        }
        if selectionRestoreRequest?.id == request.id {
            selectionRestoreRequest = nil
        }
    }

    // MARK: - Invalidation

    /// Called when the active document content changed (revision advanced).
    /// Any content change invalidates the target in v1; no range re-tracking.
    func documentContentChanged() {
        switch phase {
        case .idle, .needsSetup, .applying, .stale:
            return
        default:
            break
        }
        guard let target, !currentDocumentMatches(target) else { return }
        becomeStale()
    }

    func documentChanged() {
        guard phase != .idle else { return }
        reset(restoreSelection: false)
    }

    func credentialsChanged() {
        guard isSessionActive else { return }
        guard credentials?.isConfigured != true else { return }
        reset(restoreSelection: false)
    }

    func configurationChanged() {
        guard preferences?.aiEditingEnabled == false else { return }
        guard phase != .idle else { return }
        reset(restoreSelection: false)
    }

    func editorDisappeared(editorID: UUID) {
        if let target, target.editorID == editorID {
            reset(restoreSelection: false)
            return
        }
        // A capture may not have arrived yet (e.g. preview mode); drop it.
        if phase == .idle {
            activationToken = nil
        }
    }

    private func becomeStale() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        pendingReplacement = nil
        phase = .stale
        errorMessage = "The document changed, so this proposal can no longer be applied."
        canRetry = false
    }

    private func reset(restoreSelection: Bool) {
        if restoreSelection,
           let target,
           let document = documents?.document,
           document.id == target.documentURL,
           document.sessionID == target.documentSessionID,
           document.revision == target.revision {
            selectionRestoreRequest = SelectionRestoreRequest(
                id: UUID(),
                editorID: target.editorID,
                documentSessionID: target.documentSessionID,
                range: target.range
            )
        } else {
            selectionRestoreRequest = nil
        }

        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        applyRequestID = nil
        accumulatedText = ""
        lastSubmittedInstruction = ""
        phase = .idle
        setupIssue = nil
        target = nil
        scope = nil
        anchorRect = nil
        containerSize = nil
        instruction = ""
        partialText = ""
        proposal = nil
        diffRows = []
        diffExceedsBudget = false
        errorMessage = nil
        canRetry = false
        activeModel = nil
        activationToken = nil
        pendingReplacement = nil
    }

    private func currentDocumentMatches(_ target: InlineEditTarget) -> Bool {
        guard let document = documents?.document else { return false }
        return document.id == target.documentURL
            && document.workspaceID == target.workspaceID
            && document.sessionID == target.documentSessionID
            && document.revision == target.revision
    }
}
