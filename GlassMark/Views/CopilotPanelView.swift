import AppKit
import SwiftUI

struct CopilotPanelView: View {
    @ObservedObject var store: CopilotWindowStore
    @EnvironmentObject private var documentStore: DocumentStore
    @FocusState private var composerFocused: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Copilot", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Button {
                    store.newChat()
                    composerFocused = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat")
                .disabled(store.isGenerating)
                Button {
                    store.historyVisible.toggle()
                } label: {
                    Label("Chat History", systemImage: "clock.arrow.circlepath")
                }
                .help("Chat History")
                .popover(isPresented: $store.historyVisible, arrowEdge: .bottom) {
                    ChatHistoryView(store: store)
                        .frame(width: 300, height: 420)
                        .task { await store.reloadConversations() }
                }
                Button(action: onClose) {
                    Label("Hide Copilot", systemImage: "xmark")
                }
                .help("Hide Copilot (⌃⌘C)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(12)
            .background(.bar)
            Divider()
            ChatHeaderView(store: store)
            Divider()
            ChatTranscriptView(store: store)
            Divider()
            ChatComposerView(store: store, isFocused: $composerFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("copilot-panel")
        .task {
            await store.start()
            composerFocused = true
        }
        .onChange(of: documentStore.document?.id) {
            store.objectWillChange.send()
            store.scheduleHistoryReload()
        }
    }
}

private struct ChatHistoryView: View {
    @ObservedObject var store: CopilotWindowStore
    @State private var renameTarget: ChatConversation?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                Spacer()
                Button {
                    store.newChat()
                    store.historyVisible = false
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("New Chat")
                .disabled(store.isGenerating)
            }
            .padding(12)
            TextField("Search chats", text: $store.historySearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onChange(of: store.historySearch) {
                    store.scheduleHistoryReload()
                }
            Picker("History scope", selection: $store.historyScopeAllWorkspaces) {
                Text("This workspace").tag(false)
                Text("All chats").tag(true)
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onChange(of: store.historyScopeAllWorkspaces) {
                store.scheduleHistoryReload()
            }
            Divider()
            if store.conversations.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
            } else {
                List(selection: Binding(
                    get: { store.selectedConversation?.id },
                    set: { id in
                        guard let id else { return }
                        Task {
                            await store.selectConversation(id: id)
                            store.historyVisible = false
                        }
                    }
                )) {
                    ForEach(store.conversations) { conversation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title)
                                .lineLimit(1)
                            if let note = conversation.noteDescription {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(conversation.lastActivityAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .tag(conversation.id)
                        .contextMenu {
                            Button("Rename Chat") {
                                renameTarget = conversation
                                renameText = conversation.title
                            }
                            Button("Delete Chat", role: .destructive) {
                                store.deleteConversation(id: conversation.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .disabled(store.isGenerating)
            }
            Divider()
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("Local · 30 days")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .alert("Rename Chat", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Chat title", text: $renameText)
            Button("Rename") {
                if let renameTarget {
                    store.rename(id: renameTarget.id, title: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Choose a local title (up to 120 characters).")
        }
    }
}

private struct ChatHeaderView: View {
    @ObservedObject var store: CopilotWindowStore
    @State private var showingContext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.selectedConversation?.title ?? "New Chat")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if store.selectedConversation != nil {
                    Button(role: .destructive) { store.deleteSelected() } label: {
                        Label("Delete Chat", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .help("Delete Chat")
                }
            }
            if let conversation = store.selectedConversation {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text(conversation.noteDescription ?? "No note linked")
                        .lineLimit(1)
                    if let snapshot = store.currentSnapshot, snapshot.hasUnsavedChanges {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
                Text("Deletes \(conversation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.currentSnapshot != nil {
                    HStack(spacing: 10) {
                        Button("View context") { showingContext = true }
                        Button(store.useSavedSnapshot ? "Use open note" : "Use last captured version") {
                            store.toggleSavedSnapshot()
                        }
                    }
                    .font(.caption)
                }
                if let contextModeMessage = store.contextModeMessage {
                    Label(contextModeMessage, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Open a note, then ask Copilot about it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .sheet(isPresented: $showingContext) {
            if let snapshot = store.currentSnapshot {
                ChatContextSheet(snapshot: snapshot)
            }
        }
    }
}

private struct ChatContextSheet: View {
    let snapshot: ChatContextSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Captured context")
                    .font(.headline)
                Spacer()
                Text(snapshot.capturedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(snapshot.documentName)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Text("\(snapshot.byteCount) bytes")
                Text(snapshot.hasUnsavedChanges ? "Unsaved changes" : "Saved buffer")
                Text("Revision \(snapshot.documentRevision)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ScrollView {
                Text(snapshot.contentText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct ChatTranscriptView: View {
    @ObservedObject var store: CopilotWindowStore
    private let renderer = ChatMarkdownRenderer()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let detail = store.detail {
                        ForEach(detail.turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                MessageBubble(role: "You", text: turn.userText, tint: .blue)
                                ForEach(turn.attempts.filter { $0.state == .completed }) { attempt in
                                MessageBubble(
                                    role: "Gemini · \(attempt.effectiveModelID ?? attempt.requestedModelID)",
                                    text: attempt.assistantText,
                                    tint: .secondary,
                                    rendersMarkdown: true,
                                    copyAction: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(renderer.copyText(attempt.assistantText), forType: .string) }
                                )
                                }
                                if turn.state == .pending {
                                    if let attempt = turn.latestAttempt, !attempt.assistantText.isEmpty {
                                        MessageBubble(
                                            role: "Gemini · incomplete",
                                            text: attempt.assistantText,
                                            tint: .orange,
                                            rendersMarkdown: true
                                        )
                                    }
                                    Text("Response pending — Retry or Discard this turn after the request finishes.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Button("Retry") { store.retryPendingTurn() }
                                        Button("Discard Turn", role: .destructive) { store.discardPendingTurn() }
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    if !store.partialResponse.isEmpty {
                        MessageBubble(
                            role: "Gemini",
                            text: store.partialResponse,
                            tint: .secondary,
                            rendersMarkdown: true
                        )
                            .id("partial")
                    }
                    if store.isGenerating {
                        ProgressView("Generating…")
                            .controlSize(.small)
                            .padding(.leading, 4)
                            .id("latest")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: store.partialResponse) {
                guard store.isGenerating else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct MessageBubble: View {
    let role: String
    let text: String
    let tint: Color
    var rendersMarkdown = false
    var copyAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                if let copyAction {
                    Button("Copy", systemImage: "doc.on.doc", action: copyAction)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            Group {
                if rendersMarkdown {
                    ChatMarkdownText(source: text)
                } else {
                    Text(text)
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Uses Foundation's value-based Markdown parser for the transcript rather
/// than the note preview WebView. It has no URL scheme handler or workspace
/// base URL, so assistant Markdown cannot read local files or load images.
private struct ChatMarkdownText: View {
    let source: String
    private let renderer = ChatMarkdownRenderer()

    var body: some View {
        if let attributed = renderer.renderAttributed(source) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}

private struct ChatComposerView: View {
    @ObservedObject var store: CopilotWindowStore
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Picker("Model", selection: Binding(
                    get: { store.selectedModelID },
                    set: { store.updateModel($0) }
                )) {
                    ForEach(AIModelCatalog.presets) { preset in
                        Text(preset.title.components(separatedBy: " · ").first ?? preset.title)
                            .tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(store.isGenerating)
                Spacer()
                Text("Chat only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $store.draft)
                    .font(.body)
                    .focused($isFocused)
                    .frame(minHeight: 48, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .onSubmit {
                        if !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) {
                            store.send()
                        }
                    }
                if store.isGenerating {
                    Button("Stop", systemImage: "stop.fill") { store.stop() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .help("Stop generation")
                } else {
                        Button("Send", systemImage: "arrow.up.circle.fill") { store.send() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || !store.hasActiveNote
                            )
                            .help("Send (⌘Return)")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.hasActiveNote ? "Unsaved changes are included when you send." : "Open a note to start a chat.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !store.preferences.copilotChatEnabled {
                    Text("Enable Copilot in Settings")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}
