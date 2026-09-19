import AppKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var documentStore: DocumentStore
    @EnvironmentObject private var commandStore: CommandStore
    @EnvironmentObject private var preferencesStore: PreferencesStore
    @EnvironmentObject private var inlineEditStore: InlineEditStore

    @State private var editorID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            EditorFormattingToolbarView { command in
                commandStore.run(command)
            }
            Divider()

            if let document = documentStore.document {
                GeometryReader { proxy in
                    MarkdownTextView(
                        text: Binding(
                            get: { documentStore.document?.text ?? document.text },
                            set: { documentStore.updateText($0) }
                        ),
                        pendingCommand: pendingCommandBinding,
                        scrollRequest: scrollRequestBinding,
                        activeLocation: activeLocationBinding,
                        scrollSync: commandStore.scrollSync,
                        onScroll: { commandStore.publishScroll(line: $0, source: .editor) },
                        focusMode: preferencesStore.focusModeEnabled,
                        typewriterMode: preferencesStore.typewriterModeEnabled,
                        showLineNumbers: preferencesStore.showLineNumbers,
                        fontSize: preferencesStore.textSize,
                        logicalLineSpacing: preferencesStore.logicalLineSpacing,
                        editorID: editorID,
                        windowID: inlineEditStore.windowID,
                        workspaceID: document.workspaceID,
                        documentURL: document.file.url,
                        documentSessionID: document.sessionID,
                        documentRevision: document.revision,
                        isInlineEditActive: inlineEditStore.isSessionActive,
                        inlineEditActivation: activationBinding,
                        pendingReplacement: replacementBinding,
                        selectionRestore: selectionRestoreBinding,
                        onInlineEditCapture: { token, result in
                            inlineEditStore.handleCapture(token: token, result: result)
                        },
                        onInlineEditAnchorUpdate: { rect, size in
                            inlineEditStore.updateAnchor(rect: rect, containerSize: size)
                        },
                        onInlineEditApplicationResult: { id, outcome in
                            inlineEditStore.applicationFinished(requestID: id, outcome: outcome)
                        }
                    )
                    .overlay(alignment: .topLeading) {
                        if inlineEditStore.isPanelVisible {
                            InlineEditPanelView(store: inlineEditStore)
                                .offset(panelOffset(in: proxy.size))
                        }
                    }
                }
            }

            Divider()
            EditorStatusBarView()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            inlineEditStore.editorDisappeared(editorID: editorID)
        }
    }

    private func panelOffset(in container: CGSize) -> CGSize {
        let panelWidth: CGFloat = 460
        let panelEstimatedHeight: CGFloat = 320
        let padding: CGFloat = 8

        guard let anchor = inlineEditStore.anchorRect else {
            return CGSize(width: padding, height: padding)
        }

        let x = min(max(padding, anchor.minX), max(padding, container.width - panelWidth - padding))
        var y = anchor.maxY + 8
        if y + panelEstimatedHeight > container.height {
            y = max(padding, anchor.minY - panelEstimatedHeight - 8)
        }
        return CGSize(width: x, height: y)
    }

    private var pendingCommandBinding: Binding<EditorCommandRequest?> {
        Binding(
            get: { commandStore.pendingEditorCommand },
            set: { commandStore.pendingEditorCommand = $0 }
        )
    }

    private var scrollRequestBinding: Binding<OutlineScrollRequest?> {
        Binding(
            get: { commandStore.outlineScrollRequest },
            set: { commandStore.outlineScrollRequest = $0 }
        )
    }

    private var activeLocationBinding: Binding<Int> {
        Binding(
            get: { commandStore.activeOutlineCharacterIndex },
            set: { commandStore.activeOutlineCharacterIndex = $0 }
        )
    }

    private var activationBinding: Binding<UUID?> {
        Binding(
            get: { inlineEditStore.activationToken },
            set: { inlineEditStore.clearActivationToken($0) }
        )
    }

    private var replacementBinding: Binding<ReplacementRequest?> {
        Binding(
            get: { inlineEditStore.pendingReplacement },
            set: { inlineEditStore.clearPendingReplacement($0) }
        )
    }

    private var selectionRestoreBinding: Binding<SelectionRestoreRequest?> {
        Binding(
            get: { inlineEditStore.selectionRestoreRequest },
            set: { inlineEditStore.clearSelectionRestoreRequest($0) }
        )
    }
}

private struct EditorStatusBarView: View {
    @EnvironmentObject private var documentStore: DocumentStore

    var body: some View {
        let statistics = documentStore.statistics

        HStack(spacing: 10) {
            Text(documentStore.document?.file.relativePath ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            saveStatus

            Text("\(statistics.words) words")
            Text("\(statistics.characters) chars")
            Text("\(statistics.lines) lines")
            if statistics.readingMinutes > 0 {
                Text("~\(statistics.readingMinutes) min read")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder
    private var saveStatus: some View {
        if documentStore.document?.isDirty == true {
            HStack(spacing: 5) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("Unsaved")
            }
        } else if let saveMessage = documentStore.saveMessage {
            Text(saveMessage)
        } else if documentStore.document != nil {
            Text("Saved")
        }
    }
}

private struct EditorFormattingToolbarView: View {
    let perform: (EditorCommand) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                button("Undo", systemImage: "arrow.uturn.backward") { perform(.undo) }
                button("Redo", systemImage: "arrow.uturn.forward") { perform(.redo) }

                divider

                textButton("H1") { perform(.heading(level: 1)) }
                textButton("H2") { perform(.heading(level: 2)) }
                textButton("H3") { perform(.heading(level: 3)) }

                divider

                button("Bold", systemImage: "bold") { perform(.bold) }
                button("Italic", systemImage: "italic") { perform(.italic) }
                button("Strikethrough", systemImage: "strikethrough") { perform(.strikethrough) }
                button("Inline Code", systemImage: "chevron.left.forwardslash.chevron.right") { perform(.inlineCode) }
                button("Link", systemImage: "link") { perform(.link) }

                divider

                button("Bulleted List", systemImage: "list.bullet") { perform(.bulletList) }
                button("Numbered List", systemImage: "list.number") { perform(.numberList) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private var divider: some View {
        Divider().frame(height: 20)
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(title)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).frame(minWidth: 28)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Heading \(title.dropFirst())")
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var pendingCommand: EditorCommandRequest?
    @Binding var scrollRequest: OutlineScrollRequest?
    @Binding var activeLocation: Int
    let scrollSync: ScrollSync?
    let onScroll: (Int) -> Void
    let focusMode: Bool
    let typewriterMode: Bool
    /// Shows the faint logical-line-number gutter (View ▸ Line Numbers).
    let showLineNumbers: Bool
    /// Base editor text size, controlled by "Make Text Bigger/Smaller" (⇧⌘. / ⇧⌘,).
    let fontSize: Double
    /// Extra paragraph spacing between separate Markdown source lines.
    let logicalLineSpacing: Double

    let editorID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let documentURL: URL
    let documentSessionID: UUID
    let documentRevision: UInt64
    let isInlineEditActive: Bool
    @Binding var inlineEditActivation: UUID?
    @Binding var pendingReplacement: ReplacementRequest?
    @Binding var selectionRestore: SelectionRestoreRequest?
    let onInlineEditCapture: (UUID, InlineEditCaptureResult) -> Void
    let onInlineEditAnchorUpdate: (CGRect?, CGSize) -> Void
    let onInlineEditApplicationResult: (UUID, InlineEditApplicationOutcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, activeLocation: $activeLocation)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.string = text
        scrollView.documentView = textView

        // The gutter lives beside the scroll view — never as an NSRulerView,
        // whose clip-view compensation stops the text view from drawing on
        // macOS 26. It stays attached for the editor's lifetime; the preference
        // only toggles its visibility so switching is instant.
        let gutter = LineNumberGutterView(textView: textView)
        gutter.textSize = CGFloat(fontSize)
        let container = EditorContainerView(scrollView: scrollView, gutter: gutter)
        context.coordinator.gutterView = gutter
        context.coordinator.containerView = container
        context.coordinator.setLineNumbersVisible(showLineNumbers, in: container)
        context.coordinator.refreshGutter()

        context.coordinator.textView = textView
        context.coordinator.onScroll = onScroll
        context.coordinator.focusMode = focusMode
        context.coordinator.typewriterMode = typewriterMode
        context.coordinator.setFontSize(CGFloat(fontSize))
        context.coordinator.setLogicalLineSpacing(CGFloat(logicalLineSpacing))
        context.coordinator.applyInlineEditConfiguration(self)
        context.coordinator.observeScrolling(of: scrollView)
        context.coordinator.applyHighlighting()
        context.coordinator.syncedSessionID = documentSessionID
        context.coordinator.syncedRevision = documentRevision
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.text = $text
        context.coordinator.activeLocation = $activeLocation
        context.coordinator.onScroll = onScroll
        context.coordinator.applyInlineEditConfiguration(self)
        context.coordinator.setLineNumbersVisible(showLineNumbers, in: container)

        let fontChanged = context.coordinator.setFontSize(CGFloat(fontSize))
        let spacingChanged = context.coordinator.setLogicalLineSpacing(CGFloat(logicalLineSpacing))
        if fontChanged || spacingChanged {
            context.coordinator.applyHighlighting()
        }

        if context.coordinator.focusMode != focusMode || context.coordinator.typewriterMode != typewriterMode {
            context.coordinator.focusMode = focusMode
            context.coordinator.typewriterMode = typewriterMode
            context.coordinator.applyHighlighting()
        }

        if let scrollSync, scrollSync.source == .preview,
           context.coordinator.lastHandledSyncToken != scrollSync.token {
            context.coordinator.lastHandledSyncToken = scrollSync.token
            context.coordinator.applyExternalScroll(toLine: scrollSync.line)
        }

        if context.coordinator.syncedSessionID != documentSessionID || context.coordinator.syncedRevision != documentRevision {
            context.coordinator.syncedSessionID = documentSessionID
            context.coordinator.syncedRevision = documentRevision
            if !textView.string.isExactlyEqual(to: text) {
                let selectedRanges = textView.selectedRanges
                textView.string = text
                textView.selectedRanges = selectedRanges
                context.coordinator.applyHighlighting()
            }
        }

        if let pendingCommand, context.coordinator.lastHandledCommandID != pendingCommand.id {
            context.coordinator.lastHandledCommandID = pendingCommand.id
            context.coordinator.perform(pendingCommand.command)
            DispatchQueue.main.async { self.pendingCommand = nil }
        }

        if let scrollRequest, context.coordinator.lastHandledScrollID != scrollRequest.id {
            context.coordinator.lastHandledScrollID = scrollRequest.id
            context.coordinator.scroll(toCharacterIndex: scrollRequest.characterIndex)
        }

        if let token = inlineEditActivation, context.coordinator.lastHandledActivationToken != token {
            context.coordinator.lastHandledActivationToken = token
            DispatchQueue.main.async { context.coordinator.captureInlineEditSelection(token: token) }
        }

        if let request = pendingReplacement, context.coordinator.lastHandledReplacementID != request.id {
            context.coordinator.lastHandledReplacementID = request.id
            DispatchQueue.main.async { context.coordinator.processPendingReplacement(request) }
        }

        if let request = selectionRestore, context.coordinator.lastHandledSelectionRestoreID != request.id {
            context.coordinator.lastHandledSelectionRestoreID = request.id
            DispatchQueue.main.async { context.coordinator.processSelectionRestore(request) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var activeLocation: Binding<Int>
        var onScroll: ((Int) -> Void)?
        private var lastPublishedLine = -1
        var syncedSessionID: UUID?
        var syncedRevision: UInt64?
        private var cachedLineStarts = [0]
        weak var textView: NSTextView?
        var lastHandledCommandID: UUID?
        var lastHandledScrollID: UUID?
        var lastHandledSyncToken: Int?
        var focusMode = false
        var typewriterMode = false
        var gutterView: LineNumberGutterView?
        weak var containerView: EditorContainerView?
        private var lineNumbersVisible = false

        // Inline AI edit bridge
        var editorID = UUID()
        var windowID = UUID()
        var workspaceID = UUID()
        var documentURL = URL(fileURLWithPath: "/")
        var documentSessionID = UUID()
        var documentRevision: UInt64 = 0
        var isInlineEditActive = false
        var inlineEditActivation: Binding<UUID?>?
        var pendingReplacement: Binding<ReplacementRequest?>?
        var selectionRestore: Binding<SelectionRestoreRequest?>?
        var onInlineEditCapture: ((UUID, InlineEditCaptureResult) -> Void)?
        var onInlineEditAnchorUpdate: ((CGRect?, CGSize) -> Void)?
        var onInlineEditApplicationResult: ((UUID, InlineEditApplicationOutcome) -> Void)?
        var lastHandledActivationToken: UUID?
        var lastHandledReplacementID: UUID?
        var lastHandledSelectionRestoreID: UUID?
        let editorUndoManager = UndoManager()
        private var lastSelectionRange: NSRange?
        private var anchorWorkItem: DispatchWorkItem?
        private var isApplyingInlineReplacement = false

        private var highlightCache = MarkdownHighlightCache()
        private var fontSize = CGFloat(DocumentTextSize.defaultSize)
        private var logicalLineSpacing = CGFloat(DocumentLogicalLineSpacing.defaultValue)
        private var baseFont: NSFont {
            NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        private var baseParagraphStyle: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 0
            style.paragraphSpacing = logicalLineSpacing
            return style.copy() as! NSParagraphStyle
        }
        private var isObservingScrolling = false
        private var isApplyingExternalScroll = false
        private var highlightWorkItem: DispatchWorkItem?

        init(text: Binding<String>, activeLocation: Binding<Int>) {
            self.text = text
            self.activeLocation = activeLocation
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observeScrolling(of scrollView: NSScrollView) {
            guard !isObservingScrolling else { return }
            isObservingScrolling = true
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleBoundsChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        @objc private func handleBoundsChange() {
            updateActiveLocation()
            scheduleInlineEditAnchorUpdate()
            gutterView?.needsDisplay = true
            guard !isApplyingExternalScroll else { return }
            publishScrollFraction()
        }

        private func publishScrollFraction() {
            let line = topVisibleLine()
            guard line != lastPublishedLine else { return }
            lastPublishedLine = line
            onScroll?(line)
        }

        /// Shows or hides the line-number gutter; the layout hands its strip of
        /// width to the editor when hidden.
        func setLineNumbersVisible(_ visible: Bool, in container: EditorContainerView) {
            guard lineNumbersVisible != visible else { return }
            lineNumbersVisible = visible
            container.setGutterVisible(visible)
        }

        /// Recomputes the gutter's line cache, font and width.
        func refreshGutter(lineStarts: [Int]? = nil) {
            if let lineStarts {
                cachedLineStarts = lineStarts
            } else if let textView {
                cachedLineStarts = LineIndex.lineStarts(in: textView.string as NSString)
            }
            gutterView?.refresh(lineStarts: cachedLineStarts)
            containerView?.gutterWidthChanged()
        }

        /// Source line (0-based) nearest the top of the editor viewport.
        private func topVisibleLine() -> Int {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return 0 }
            let visibleRect = textView.visibleRect
            let containerY = max(0, visibleRect.minY - textView.textContainerInset.height + 1)
            let glyphIndex = layoutManager.glyphIndex(for: NSPoint(x: 0, y: containerY), in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            return LineIndex.lineNumber(forCharacterAt: charIndex, lineStarts: cachedLineStarts) - 1
        }

        func applyExternalScroll(toLine line: Int) {
            isApplyingExternalScroll = true
            scrollCharacterToTop(characterIndex(forLine: line), margin: 0, moveSelection: false)
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingExternalScroll = false
            }
        }

        func characterIndex(forLine line: Int) -> Int {
            cachedLineStarts[min(max(0, line), cachedLineStarts.count - 1)]
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            scheduleHighlighting()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editorUndoManager
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let view = notification.object as? NSTextView {
                lastSelectionRange = view.selectedRange()
            }
            updateActiveLocation()
            if focusMode { applyHighlighting() }
            if typewriterMode { centerCaret() }
        }

        /// Highlighting runs synchronously for everyday documents so characters are
        /// drawn with their final attributes in the same cycle they are typed in
        /// (no small-then-growing font flash). Only very large documents keep the
        /// debounced path to protect typing responsiveness.
        private static let synchronousHighlightLimit = 100_000

        private func scheduleHighlighting() {
            highlightWorkItem?.cancel()
            let length = textView?.textStorage?.length ?? 0
            if length <= Self.synchronousHighlightLimit {
                applyHighlighting(incremental: true)
                return
            }
            // Scroll mapping must reflect edits even while styling is deferred.
            refreshGutter()
            let workItem = DispatchWorkItem { [weak self] in self?.applyHighlighting(incremental: true) }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }

        // MARK: - Key handling (auto-pairing, lists, tables)

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if isApplyingInlineReplacement || editorUndoManager.isUndoing || editorUndoManager.isRedoing {
                return true
            }
            guard let replacementString else { return true }
            return handleAutoPairing(in: textView, range: affectedCharRange, replacement: replacementString)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return continueListIfNeeded(in: textView)
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                if changeIndentOfSelection(in: textView, outdent: false) { return true }
                if moveToTableCell(in: textView, forward: true) { return true }
                return insertIndent(in: textView)
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                if changeIndentOfSelection(in: textView, outdent: true) { return true }
                if moveToTableCell(in: textView, forward: false) { return true }
                return outdentCurrentLine(in: textView)
            }
            return false
        }

        // MARK: - Auto-pairing

        private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "`": "`"]
        private static let wrappers: [Character: (String, String)] = [
            "(": ("(", ")"), "[": ("[", "]"), "{": ("{", "}"),
            "`": ("`", "`"), "*": ("*", "*"), "_": ("_", "_"), "~": ("~", "~")
        ]

        private func handleAutoPairing(in textView: NSTextView, range: NSRange, replacement: String) -> Bool {
            guard replacement.count == 1, let character = replacement.first else { return true }
            let nsString = textView.string as NSString

            // Wrap a non-empty selection with the matching delimiters.
            if range.length > 0, let wrapper = Self.wrappers[character] {
                let selected = nsString.substring(with: range)
                let wrapped = "\(wrapper.0)\(selected)\(wrapper.1)"
                textView.insertText(wrapped, replacementRange: range)
                textView.setSelectedRange(NSRange(location: range.location + wrapper.0.utf16.count, length: (selected as NSString).length))
                return false
            }

            guard range.length == 0 else { return true }

            // Skip over an existing closing character instead of inserting a duplicate.
            if character == ")" || character == "]" || character == "}" || character == "`" {
                if range.location < nsString.length,
                   nsString.substring(with: NSRange(location: range.location, length: 1)) == String(character) {
                    textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                    return false
                }
            }

            // Auto-close brackets and backticks (not * or _, which fight bold/italic typing).
            if let close = Self.pairs[character] {
                textView.insertText("\(character)\(close)", replacementRange: range)
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }

            return true
        }

        // MARK: - Table navigation

        private func moveToTableCell(in textView: NSTextView, forward: Bool) -> Bool {
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            let lineRange = nsString.lineRange(for: NSRange(location: caret, length: 0))
            let line = nsString.substring(with: lineRange)
            guard line.contains("|") else { return false }

            if forward {
                // Find the next pipe at or after the caret on this line.
                let searchStart = caret
                let searchRange = NSRange(location: searchStart, length: lineRange.location + lineRange.length - searchStart)
                let pipe = nsString.range(of: "|", range: searchRange)
                guard pipe.location != NSNotFound else { return false }
                var cellStart = pipe.location + 1
                while cellStart < nsString.length,
                      nsString.substring(with: NSRange(location: cellStart, length: 1)) == " " {
                    cellStart += 1
                }
                textView.setSelectedRange(NSRange(location: min(cellStart, nsString.length), length: 0))
                return true
            } else {
                // Move to the start of the previous cell.
                let before = NSRange(location: lineRange.location, length: max(0, caret - lineRange.location))
                let beforeText = nsString.substring(with: before)
                guard let lastPipe = beforeText.range(of: "|", options: .backwards) else { return false }
                let pipeOffset = beforeText.distance(from: beforeText.startIndex, to: lastPipe.lowerBound)
                textView.setSelectedRange(NSRange(location: lineRange.location + pipeOffset, length: 0))
                return true
            }
        }

        // MARK: - Indentation

        /// One indent level: four spaces are exactly what Markdown reads as an
        /// indented (code) block, and they nest list items consistently. Literal
        /// tabs are avoided because renderers disagree on how to expand them.
        private static let indentUnit = "    "
        private static let tabWidth = 4

        private struct IndentEdit {
            let start: Int
            let removed: Int
            let inserted: Int
        }

        /// Indents (four spaces) or outdents (up to one level) every line the
        /// selection touches, keeping the selection over the same text so
        /// repeated presses keep editing the same block. Returns false when there
        /// is no selection, so the caller can fall back to single-line behavior.
        private func changeIndentOfSelection(in textView: NSTextView, outdent: Bool) -> Bool {
            let nsString = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length > 0, nsString.length > 0 else { return false }

            let contentEnd = min(selection.location + selection.length, nsString.length)
            let lastCharacter = max(0, contentEnd - 1)
            let firstLine = nsString.lineRange(
                for: NSRange(location: min(selection.location, nsString.length - 1), length: 0)
            )
            let lastLine = nsString.lineRange(
                for: NSRange(location: min(lastCharacter, nsString.length - 1), length: 0)
            )

            var lineRanges: [NSRange] = []
            var cursor = firstLine.location
            while cursor <= lastLine.location, cursor < nsString.length {
                let range = nsString.lineRange(for: NSRange(location: cursor, length: 0))
                lineRanges.append(range)
                let next = range.location + range.length
                if next <= cursor { break }
                cursor = next
            }
            guard !lineRanges.isEmpty else { return false }

            var lines: [String] = []
            var edits: [IndentEdit] = []
            for range in lineRanges {
                let content = nsString.substring(with: range)
                var body = content
                var newline = ""
                if body.hasSuffix("\n") {
                    body.removeLast()
                    newline = "\n"
                }

                var newBody = body
                var removed = 0
                var inserted = 0
                if outdent {
                    removed = Self.indentCharactersToRemove(from: body)
                    if removed > 0 { newBody = String(body.dropFirst(removed)) }
                } else if !body.isEmpty {
                    inserted = Self.indentUnit.utf16.count
                    newBody = Self.indentUnit + body
                }

                if removed > 0 || inserted > 0 {
                    edits.append(IndentEdit(start: range.location, removed: removed, inserted: inserted))
                }
                lines.append(newBody + newline)
            }
            guard !edits.isEmpty else { return true }

            let blockRange = NSRange(
                location: firstLine.location,
                length: lastLine.location + lastLine.length - firstLine.location
            )
            textView.insertText(lines.joined(), replacementRange: blockRange)

            let newLocation = Self.mappedOffset(selection.location, through: edits)
            let newEnd = Self.mappedOffset(contentEnd, through: edits)
            let length = (textView.string as NSString).length
            let clampedLocation = min(max(0, newLocation), length)
            let clampedEnd = min(max(clampedLocation, newEnd), length)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedEnd - clampedLocation))
            return true
        }

        /// Bare Tab inserts soft spaces up to the next four-column stop, so a Tab
        /// at the start of a line produces an exact Markdown indent instead of a
        /// literal tab character.
        private func insertIndent(in textView: NSTextView) -> Bool {
            let nsString = textView.string as NSString
            let selection = textView.selectedRange()
            let lineStart: Int
            if nsString.length == 0 {
                lineStart = 0
            } else {
                lineStart = nsString.lineRange(
                    for: NSRange(location: min(selection.location, nsString.length - 1), length: 0)
                ).location
            }
            let spaces = Self.tabWidth - ((selection.location - lineStart) % Self.tabWidth)
            textView.insertText(String(repeating: " ", count: spaces), replacementRange: selection)
            return true
        }

        /// Shift-Tab with no selection removes one indent level from the current
        /// line and leaves the caret over the same text.
        private func outdentCurrentLine(in textView: NSTextView) -> Bool {
            let nsString = textView.string as NSString
            guard nsString.length > 0 else { return true }
            let selection = textView.selectedRange()
            let lineRange = nsString.lineRange(
                for: NSRange(location: min(selection.location, nsString.length - 1), length: 0)
            )
            let content = nsString.substring(with: lineRange)
            let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
            let removed = Self.indentCharactersToRemove(from: body)
            guard removed > 0 else { return true }

            textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: removed))
            if selection.location > lineRange.location {
                let newLocation = max(lineRange.location, selection.location - removed)
                textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            }
            return true
        }

        /// Number of leading characters to drop for one outdent step: up to four
        /// columns, with a tab counting as four. Returns 0 when the line does not
        /// start with indentation.
        private static func indentCharactersToRemove(from line: String) -> Int {
            var columns = 0
            var characters = 0
            for character in line {
                if columns >= Self.tabWidth { break }
                if character == " " {
                    columns += 1
                } else if character == "\t" {
                    columns += Self.tabWidth - (columns % Self.tabWidth)
                } else {
                    break
                }
                characters += 1
            }
            return columns > 0 ? characters : 0
        }

        /// Maps an original UTF-16 offset through the per-line edits, so the
        /// selection can be restored over the same text after re-indenting.
        private static func mappedOffset(_ offset: Int, through edits: [IndentEdit]) -> Int {
            var delta = 0
            for edit in edits {
                if edit.removed == 0 {
                    if offset >= edit.start { delta += edit.inserted }
                } else if offset > edit.start {
                    if offset >= edit.start + edit.removed {
                        delta -= edit.removed
                    } else {
                        delta += edit.start - offset
                    }
                }
            }
            return offset + delta
        }

        // MARK: - List continuation

        private func continueListIfNeeded(in textView: NSTextView) -> Bool {
            let nsString = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let lineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let line = nsString.substring(with: lineRange).trimmingCharacters(in: .newlines)

            guard let marker = listContinuation(for: line) else { return false }

            if marker.isItemEmpty {
                // Empty list item: remove the marker and break out of the list.
                textView.insertText("", replacementRange: lineRange)
                return true
            }

            textView.insertText("\n\(marker.next)", replacementRange: selectedRange)
            return true
        }

        private func listContinuation(for line: String) -> (next: String, isItemEmpty: Bool)? {
            let indentCount = line.prefix(while: { $0 == " " }).count
            let indent = String(repeating: " ", count: indentCount)
            let trimmed = line.dropFirst(indentCount)

            // Task item.
            for token in ["- [ ] ", "- [x] ", "* [ ] ", "* [x] "] where trimmed.hasPrefix(token) {
                let isEmpty = trimmed.count == token.count
                return ("\(indent)- [ ] ", isEmpty)
            }

            // Unordered.
            for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
                let isEmpty = trimmed.count == bullet.count
                return ("\(indent)\(bullet)", isEmpty)
            }

            // Ordered.
            let chars = Array(trimmed)
            var cursor = 0
            while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
            if cursor > 0, cursor < chars.count, chars[cursor] == "." || chars[cursor] == ")",
               cursor + 1 < chars.count, chars[cursor + 1] == " " {
                let number = Int(String(chars[0..<cursor])) ?? 1
                let separator = chars[cursor]
                let isEmpty = chars.count == cursor + 2
                return ("\(indent)\(number + 1)\(separator) ", isEmpty)
            }

            return nil
        }

        // MARK: - Commands

        func perform(_ command: EditorCommand) {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)

            switch command {
            case .undo: textView.undoManager?.undo()
            case .redo: textView.undoManager?.redo()
            case .copy: textView.copy(nil)
            case .paste: textView.paste(nil)
            case .bold: wrapSelection(prefix: "**", suffix: "**", placeholder: "bold text")
            case .italic: wrapSelection(prefix: "_", suffix: "_", placeholder: "italic text")
            case .inlineCode: wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
            case .strikethrough: wrapSelection(prefix: "~~", suffix: "~~", placeholder: "text")
            case .link: insertLink()
            case .heading(let level): applyLinePrefix(String(repeating: "#", count: level) + " ")
            case .bulletList: applyLinePrefix("- ")
            case .numberList: applyLinePrefix("1. ")
            }

            text.wrappedValue = textView.string
            applyHighlighting()
        }

        private func insertLink() {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let selectedText = selectedRange.length > 0 ? nsString.substring(with: selectedRange) : "link text"
            let replacement = "[\(selectedText)](url)"
            textView.insertText(replacement, replacementRange: selectedRange)

            // Select the "url" placeholder for quick replacement.
            let urlLocation = selectedRange.location + selectedText.utf16.count + 3
            textView.setSelectedRange(NSRange(location: urlLocation, length: 3))
        }

        private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let selectedText = selectedRange.length > 0 ? nsString.substring(with: selectedRange) : placeholder
            let replacement = "\(prefix)\(selectedText)\(suffix)"
            textView.insertText(replacement, replacementRange: selectedRange)

            if selectedRange.length == 0 {
                textView.setSelectedRange(NSRange(location: selectedRange.location + prefix.utf16.count, length: placeholder.utf16.count))
            } else {
                textView.setSelectedRange(NSRange(location: selectedRange.location, length: replacement.utf16.count))
            }
        }

        private func applyLinePrefix(_ prefix: String) {
            guard let textView else { return }
            let string = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let lineRange = string.lineRange(for: selectedRange)
            let selectedLines = string.substring(with: lineRange)
            let lineComponents = selectedLines.components(separatedBy: .newlines)
            let replacement = lineComponents
                .enumerated()
                .map { index, line -> String in
                    guard !line.isEmpty || index < lineComponents.count - 1 else { return line }
                    let trimmedLine = line.replacingOccurrences(
                        of: #"^(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)"#,
                        with: "",
                        options: .regularExpression
                    )
                    return prefix + trimmedLine
                }
                .joined(separator: "\n")

            textView.insertText(replacement, replacementRange: lineRange)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
        }

        // MARK: - Navigation

        func scroll(toCharacterIndex index: Int) {
            scrollCharacterToTop(index, margin: 12, moveSelection: true)
        }

        private func scrollCharacterToTop(_ index: Int, margin: CGFloat, moveSelection: Bool) {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return }

            let length = (textView.string as NSString).length
            let location = min(max(0, index), length)

            layoutManager.ensureLayout(for: textContainer)

            let targetY: CGFloat
            if length == 0 || layoutManager.numberOfGlyphs == 0 {
                targetY = 0
            } else {
                let probe = NSRange(location: location, length: min(1, max(0, length - location)))
                let glyphRange = layoutManager.glyphRange(forCharacterRange: probe, actualCharacterRange: nil)
                let glyph = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                targetY = max(0, lineRect.minY + textView.textContainerInset.height - margin)
            }

            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            if moveSelection {
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.window?.makeFirstResponder(textView)
            }
        }

        /// Reports the heading nearest the top of the viewport so the outline can
        /// highlight the active section.
        func updateActiveLocation() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let visibleRect = textView.visibleRect
            let containerY = max(0, visibleRect.minY - textView.textContainerInset.height + 1)
            let point = NSPoint(x: 0, y: containerY)
            let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            guard activeLocation.wrappedValue != characterIndex else { return }
            let binding = activeLocation
            DispatchQueue.main.async { binding.wrappedValue = characterIndex }
        }

        // MARK: - Inline AI edit bridge

        func applyInlineEditConfiguration(_ configuration: MarkdownTextView) {
            editorID = configuration.editorID
            windowID = configuration.windowID
            workspaceID = configuration.workspaceID
            documentURL = configuration.documentURL
            if documentSessionID != configuration.documentSessionID {
                editorUndoManager.removeAllActions()
                documentSessionID = configuration.documentSessionID
            }
            documentRevision = configuration.documentRevision
            isInlineEditActive = configuration.isInlineEditActive
            inlineEditActivation = configuration.$inlineEditActivation
            pendingReplacement = configuration.$pendingReplacement
            selectionRestore = configuration.$selectionRestore
            onInlineEditCapture = configuration.onInlineEditCapture
            onInlineEditAnchorUpdate = configuration.onInlineEditAnchorUpdate
            onInlineEditApplicationResult = configuration.onInlineEditApplicationResult
        }

        func captureInlineEditSelection(token: UUID) {
            guard let textView else {
                onInlineEditCapture?(token, .failed(reason: "The editor is not available."))
                return
            }
            guard !textView.hasMarkedText() else {
                onInlineEditCapture?(token, .failed(reason: "Finish composing text first."))
                return
            }
            let ranges = textView.selectedRanges
            guard ranges.count == 1, let selectedValue = ranges.first else {
                onInlineEditCapture?(token, .failed(reason: "Select one continuous range of text."))
                return
            }

            let text = textView.string
            let nsString = text as NSString
            var range = selectedValue.rangeValue
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  range.location + range.length <= nsString.length else {
                onInlineEditCapture?(token, .failed(reason: "The selection is not valid."))
                return
            }

            var scope: InlineEditScope = .selection
            if range.length == 0 {
                scope = .paragraph
                range = nsString.paragraphRange(for: NSRange(location: min(range.location, nsString.length), length: 0))
                var end = range.location + range.length
                if end > range.location,
                   nsString.substring(with: NSRange(location: end - 1, length: 1)) == "\n" {
                    end -= 1
                    if end > range.location,
                       nsString.substring(with: NSRange(location: end - 1, length: 1)) == "\r" {
                        end -= 1
                    }
                }
                range = NSRange(location: range.location, length: max(0, end - range.location))
            }

            guard range.length > 0 else {
                onInlineEditCapture?(token, .failed(reason: "There is nothing to edit here."))
                return
            }
            guard range.length <= InlineEditLimits.maxSelectionUTF16 else {
                onInlineEditCapture?(token, .failed(reason: "The selection is too large for AI editing."))
                return
            }
            let composed = nsString.rangeOfComposedCharacterSequences(for: range)
            guard composed.location == range.location, composed.length == range.length else {
                onInlineEditCapture?(token, .failed(reason: "The selection splits a character."))
                return
            }

            lastSelectionRange = range
            let anchor = inlineEditAnchor(for: range)
            let target = InlineEditTarget(
                windowID: windowID,
                editorID: editorID,
                workspaceID: workspaceID,
                documentURL: documentURL,
                documentSessionID: documentSessionID,
                revision: documentRevision,
                range: range,
                original: nsString.substring(with: range)
            )
            let capture = InlineEditCapture(
                target: target,
                scope: scope,
                anchorRect: anchor?.rect,
                containerSize: anchor?.containerSize
            )
            onInlineEditCapture?(token, .captured(capture))
        }

        func processPendingReplacement(_ request: ReplacementRequest) {
            pendingReplacement?.wrappedValue = nil
            guard let onInlineEditApplicationResult else { return }
            onInlineEditApplicationResult(request.id, applyInlineReplacement(request))
        }

        func applyInlineReplacement(_ request: ReplacementRequest) -> InlineEditApplicationOutcome {
            guard let textView else {
                return .rejected(reason: "The editor is not available.")
            }
            let target = request.target
            guard target.windowID == windowID, target.editorID == editorID else {
                return .rejected(reason: "This proposal belongs to another editor.")
            }
            guard target.documentSessionID == documentSessionID, target.revision == documentRevision else {
                return .rejected(reason: "The document changed while the proposal was being prepared.")
            }
            guard !textView.hasMarkedText() else {
                return .rejected(reason: "Finish composing text first.")
            }
            let currentText = textView.string
            guard currentText.isExactlyEqual(to: text.wrappedValue) else {
                return .rejected(reason: "The editor content changed.")
            }
            let nsString = currentText as NSString
            guard target.range.location >= 0,
                  target.range.length >= 0,
                  target.range.location + target.range.length <= nsString.length,
                  nsString.substring(with: target.range).isExactlyEqual(to: target.original) else {
                return .rejected(reason: "The text changed while the proposal was being prepared.")
            }

            isApplyingInlineReplacement = true
            defer { isApplyingInlineReplacement = false }
            textView.breakUndoCoalescing()
            editorUndoManager.beginUndoGrouping()
            let applied = textView.performValidatedReplacement(
                in: target.range,
                with: NSAttributedString(string: request.replacement)
            )
            if applied {
                editorUndoManager.setActionName("Edit with Gemini")
            }
            editorUndoManager.endUndoGrouping()
            textView.breakUndoCoalescing()

            guard applied else {
                return .rejected(reason: "The editor rejected the replacement.")
            }
            textView.setSelectedRange(
                NSRange(location: target.range.location, length: (request.replacement as NSString).length)
            )
            textView.window?.makeFirstResponder(textView)
            return .applied
        }

        func processSelectionRestore(_ request: SelectionRestoreRequest) {
            selectionRestore?.wrappedValue = nil
            guard let textView,
                  request.editorID == editorID,
                  request.documentSessionID == documentSessionID else { return }
            let nsString = textView.string as NSString
            guard request.range.location >= 0,
                  request.range.length >= 0,
                  request.range.location + request.range.length <= nsString.length else { return }
            textView.setSelectedRange(request.range)
            textView.window?.makeFirstResponder(textView)
        }

        private func scheduleInlineEditAnchorUpdate() {
            guard isInlineEditActive else { return }
            anchorWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isInlineEditActive, let range = self.lastSelectionRange else { return }
                if let anchor = self.inlineEditAnchor(for: range) {
                    self.onInlineEditAnchorUpdate?(anchor.rect, anchor.containerSize)
                }
            }
            anchorWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
        }

        private func inlineEditAnchor(for range: NSRange) -> (rect: CGRect, containerSize: CGSize)? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return nil }

            let length = (textView.string as NSString).length
            let location = min(max(0, range.location), length)
            let characterRange = NSRange(location: location, length: min(range.length, max(0, length - location)))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
                return nil
            }
            guard textView.visibleRect.intersects(rect) else { return nil }

            let containerSize = scrollView.bounds.size
            let rectInScrollView = textView.convert(rect, to: scrollView)
            let topY: CGFloat = scrollView.isFlipped
                ? rectInScrollView.minY
                : containerSize.height - rectInScrollView.maxY
            let clampedX = min(max(0, rectInScrollView.minX), max(0, containerSize.width - 1))
            let anchor = CGRect(
                x: clampedX,
                y: max(0, min(topY, containerSize.height)),
                width: min(rectInScrollView.width, containerSize.width),
                height: rectInScrollView.height
            )
            return (anchor, containerSize)
        }

        /// Records the user's text size. Returns true when it changed, so callers
        /// can re-run highlighting with the new font metrics.
        @discardableResult
        func setFontSize(_ newSize: CGFloat) -> Bool {
            guard abs(fontSize - newSize) > 0.001 else { return false }
            fontSize = newSize
            gutterView?.textSize = newSize
            containerView?.gutterWidthChanged()
            return true
        }

        /// Records the user's logical-line spacing after passing it through the
        /// same finite/clamped boundary as the preferences store.
        @discardableResult
        func setLogicalLineSpacing(_ newValue: CGFloat) -> Bool {
            let normalized = CGFloat(
                DocumentLogicalLineSpacing.normalized(Double(newValue))
            )
            guard abs(logicalLineSpacing - normalized) > 0.001 else { return false }
            logicalLineSpacing = normalized
            return true
        }

        // MARK: - Highlighting

        func applyHighlighting(incremental: Bool = false) {
            guard let textView, let textStorage = textView.textStorage else { return }
            guard !textView.hasMarkedText() else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            let update: MarkdownHighlightCache.Update?
            if textStorage.length <= 200_000 {
                update = highlightCache.update(textView.string, forceFull: !incremental || focusMode)
            } else {
                highlightCache = MarkdownHighlightCache()
                update = nil
            }
            textStorage.beginEditing()
            let paragraphStyle = baseParagraphStyle
            textStorage.setAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraphStyle
                ],
                range: update?.range ?? fullRange
            )

            // Skip detailed highlighting for very large documents to stay responsive.
            if let update {
                for token in update.tokens {
                    guard token.range.location + token.range.length <= textStorage.length else { continue }
                    apply(token, to: textStorage)
                }
            }

            if focusMode {
                applyFocusDim(to: textStorage, textView: textView)
            }

            textStorage.endEditing()
            syncTypingAttributes()
            // The text (or its metrics) may have shifted the logical lines.
            refreshGutter(lineStarts: update?.lineStarts)
        }

        /// Keeps the insertion font in sync with the highlighted text so newly typed
        /// characters are drawn at their final size right away instead of being
        /// restyled a moment later (which read as a small-then-growing font flash).
        private func syncTypingAttributes() {
            guard let textView else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: baseParagraphStyle
            ]
            if let storage = textView.textStorage, storage.length > 0 {
                let caret = min(max(0, textView.selectedRange().location), storage.length)
                let index = min(caret > 0 ? caret - 1 : 0, storage.length - 1)
                let source = storage.attributes(at: index, effectiveRange: nil)
                if let font = source[.font] as? NSFont { attributes[.font] = font }
                if let color = source[.foregroundColor] as? NSColor { attributes[.foregroundColor] = color }
            } else {
                textView.font = baseFont
            }
            textView.typingAttributes = attributes
        }

        /// Dims everything except the paragraph containing the caret.
        private func applyFocusDim(to storage: NSTextStorage, textView: NSTextView) {
            let nsString = textView.string as NSString
            guard nsString.length > 0 else { return }
            let caret = min(textView.selectedRange().location, nsString.length)
            let focusRange = nsString.paragraphRange(for: NSRange(location: caret, length: 0))

            let dim = NSColor.textColor.withAlphaComponent(0.32)
            if focusRange.location > 0 {
                storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: 0, length: focusRange.location))
            }
            let tailStart = focusRange.location + focusRange.length
            if tailStart < nsString.length {
                storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: tailStart, length: nsString.length - tailStart))
            }
        }

        /// Keeps the caret line vertically centered (typewriter scrolling).
        private func centerCaret() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let scrollView = textView.enclosingScrollView else { return }
            let caret = textView.selectedRange().location
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: caret, length: 0), actualCharacterRange: nil)
            let caretRect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphRange.location, max(0, layoutManager.numberOfGlyphs - 1)), effectiveRange: nil)
            let clipHeight = scrollView.contentView.bounds.height
            let targetY = caretRect.midY + textView.textContainerInset.height - clipHeight / 2
            let documentHeight = (scrollView.documentView?.frame.height ?? clipHeight)
            let clampedY = max(0, min(targetY, max(0, documentHeight - clipHeight)))
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: clampedY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func apply(_ token: MarkdownToken, to storage: NSTextStorage) {
            switch token.style {
            case .heading(let level):
                let size = fontSize + CGFloat(max(0, 5 - level)) * 1.5
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .bold), range: token.range)
            case .strong:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold), range: token.range)
            case .emphasis:
                storage.addAttribute(.obliqueness, value: 0.18, range: token.range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: token.range)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: token.range)
            case .inlineCode, .codeBlock:
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: token.range)
            case .blockquote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: token.range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: token.range)
            case .link:
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: token.range)
            case .delimiter:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: token.range)
            }
        }
    }
}
