import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @EnvironmentObject private var documentStore: DocumentStore
    @EnvironmentObject private var preferencesStore: PreferencesStore
    @EnvironmentObject private var commandStore: CommandStore
    @EnvironmentObject private var credentialStore: GeminiCredentialStore
    @EnvironmentObject private var chatCoordinator: ChatCoordinator

    @StateObject private var inlineEditStore = InlineEditStore(windowID: UUID())
    @StateObject private var copilotPanel = CopilotPanelController()

    var body: some View {
        workspaceLayout
        .alert("Workspace Error", isPresented: workspaceErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspaceStore.errorMessage ?? "Unknown workspace error.")
        }
        .alert("Document Error", isPresented: documentErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentStore.errorMessage ?? "Unknown document error.")
        }
        .onChange(of: workspaceStore.activeWorkspace?.id) {
            documentStore.activate(workspace: workspaceStore.activeWorkspace)
            if let workspace = workspaceStore.activeWorkspace {
                documentStore.restoreSession(for: workspace)
            }
        }
        .onAppear {
            documentStore.autosaveEnabled = preferencesStore.autosaveEnabled
            if let workspace = workspaceStore.activeWorkspace {
                documentStore.restoreSession(for: workspace)
            }
        }
        .onChange(of: preferencesStore.autosaveEnabled) {
            documentStore.autosaveEnabled = preferencesStore.autosaveEnabled
        }
        .sheet(isPresented: $commandStore.isQuickOpenPresented) {
            QuickOpenView(files: workspaceStore.fileTree) { file in
                guard let workspace = workspaceStore.activeWorkspace else { return }
                documentStore.open(file, workspace: workspace)
            }
        }
        .environmentObject(inlineEditStore)
        .focusedSceneValue(\.inlineEdit, InlineEditAction {
            guard preferencesStore.viewMode != .previewOnly else { return }
            inlineEditStore.activate()
        })
        .focusedSceneValue(\.copilot, CopilotAction(
            isPresented: copilotPanel.isPresented,
            perform: toggleCopilot
        ))
        .onAppear {
            inlineEditStore.configure(
                credentials: credentialStore,
                preferences: preferencesStore,
                documents: documentStore
            )
        }
        .onChange(of: documentStore.document?.revision) {
            inlineEditStore.documentContentChanged()
        }
        .onChange(of: documentStore.document?.id) {
            inlineEditStore.documentChanged()
        }
        .onChange(of: preferencesStore.aiEditingEnabled) {
            inlineEditStore.configurationChanged()
        }
        .onChange(of: credentialStore.state) {
            inlineEditStore.credentialsChanged()
            chatCoordinator.cancelAll()
        }
        .onChange(of: commandStore.isOutlineVisible) {
            if commandStore.isOutlineVisible {
                copilotPanel.hide()
            }
        }
        .onDisappear {
            copilotPanel.hide()
        }
    }

    private var workspaceLayout: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            GeometryReader { geometry in
                HSplitView {
                    DetailWorkspaceView()
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    if copilotPanel.isPresented, let store = copilotPanel.store {
                        CopilotPanelView(store: store, onClose: copilotPanel.hide)
                            .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $commandStore.isOutlineVisible) {
            OutlineView()
                .inspectorColumnWidth(min: 200, ideal: 240, max: 360)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                guard let file = workspaceStore.createMarkdownFile(),
                      let workspace = workspaceStore.activeWorkspace else { return }
                documentStore.open(file, workspace: workspace)
            } label: {
                Label("New Markdown File", systemImage: "doc.badge.plus")
            }
            .disabled(workspaceStore.activeWorkspace == nil)

            Button {
                guard let folder = workspaceStore.createFolder() else { return }
                workspaceStore.beginRename(folder)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")
            .disabled(workspaceStore.activeWorkspace == nil)

            Button {
                workspaceStore.refreshFileTree()
            } label: {
                Label("Refresh Workspace", systemImage: "arrow.clockwise")
            }
            .disabled(workspaceStore.activeWorkspace == nil)

            Button {
                commandStore.presentQuickOpen()
            } label: {
                Label("Quick Open", systemImage: "magnifyingglass")
            }
            .help("Quick Open (⌘P)")
            .disabled(workspaceStore.activeWorkspace == nil)

            Picker("View Mode", selection: $preferencesStore.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button {
                commandStore.toggleOutline()
            } label: {
                Label("Outline", systemImage: "list.bullet.indent")
            }
            .help("Toggle Outline")
            .disabled(documentStore.document == nil)

            Button("Save") {
                documentStore.save()
            }
            .disabled(!documentStore.canSave)

            Button {
                toggleCopilot()
            } label: {
                Label("Copilot", systemImage: "bubble.left.and.bubble.right")
            }
            .tint(copilotPanel.isPresented ? Color.accentColor : nil)
            .help(copilotPanel.isPresented ? "Hide Copilot (⌃⌘C)" : "Show Copilot (⌃⌘C)")
        }
    }

    private func toggleCopilot() {
        if copilotPanel.isPresented {
            copilotPanel.hide()
            return
        }
        commandStore.isOutlineVisible = false
        copilotPanel.show(
            workspaceStore: workspaceStore,
            documentStore: documentStore,
            preferences: preferencesStore,
            credentials: credentialStore,
            coordinator: chatCoordinator
        )
    }

    private var workspaceErrorBinding: Binding<Bool> {
        Binding(
            get: { workspaceStore.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    workspaceStore.clearError()
                }
            }
        )
    }

    private var documentErrorBinding: Binding<Bool> {
        Binding(
            get: { documentStore.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    documentStore.clearError()
                }
            }
        )
    }
}

private struct DetailWorkspaceView: View {
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @EnvironmentObject private var documentStore: DocumentStore
    @EnvironmentObject private var preferencesStore: PreferencesStore

    var body: some View {
        Group {
            if workspaceStore.activeWorkspace == nil {
                WorkspaceWelcomeView()
            } else {
                VStack(spacing: 0) {
                    if !documentStore.openDocuments.isEmpty {
                        DocumentTabBarView()
                        Divider()
                    }

                    if documentStore.document == nil {
                        EmptyFileSelectionView()
                    } else {
                        EditorPreviewContainerView()
                    }
                }
            }
        }
        .navigationTitle(documentStore.document?.file.name ?? workspaceStore.activeWorkspace?.displayName ?? "Glassmark")
    }
}

private struct DocumentTabBarView: View {
    @EnvironmentObject private var documentStore: DocumentStore
    @State private var pendingCloseDocument: EditorDocument?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(documentStore.openDocuments) { document in
                    DocumentTabView(
                        document: document,
                        isSelected: documentStore.document?.id == document.id,
                        onSelect: {
                            documentStore.selectDocument(id: document.id)
                        },
                        onClose: {
                            if document.isDirty {
                                pendingCloseDocument = document
                            } else {
                                documentStore.closeDocument(id: document.id)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
        .alert("Close Unsaved File?", isPresented: pendingCloseBinding, presenting: pendingCloseDocument) { document in
            Button("Close Without Saving", role: .destructive) {
                documentStore.closeDocument(id: document.id)
                pendingCloseDocument = nil
            }

            Button("Cancel", role: .cancel) {
                pendingCloseDocument = nil
            }
        } message: { document in
            Text("\(document.file.name) has unsaved changes.")
        }
    }

    private var pendingCloseBinding: Binding<Bool> {
        Binding(
            get: { pendingCloseDocument != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCloseDocument = nil
                }
            }
        )
    }
}

private struct DocumentTabView: View {
    let document: EditorDocument
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(document.file.name)
                .font(.callout)
                .lineLimit(1)

            if document.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 220)
        .background(isSelected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.primary.opacity(0.16) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
    }
}

private struct WorkspaceWelcomeView: View {
    @EnvironmentObject private var workspaceStore: WorkspaceStore

    var body: some View {
        ContentUnavailableView {
            Label("Open a Workspace", systemImage: "folder")
        } description: {
            Text("Choose a local folder containing Markdown files.")
        } actions: {
            Button("Open Workspace…") {
                workspaceStore.presentWorkspacePicker()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}

private struct EmptyFileSelectionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Select a File", systemImage: "doc.text")
        } description: {
            Text("Choose a Markdown file from the sidebar to start editing.")
        }
    }
}

private struct EditorPreviewContainerView: View {
    @EnvironmentObject private var preferencesStore: PreferencesStore

    var body: some View {
        switch preferencesStore.viewMode {
        case .editorOnly:
            EditorView()
        case .split:
            GeometryReader { geometry in
                if geometry.size.width >= 720 {
                    HSplitView {
                        EditorView()
                            .frame(minWidth: 360)
                        PreviewView()
                            .frame(minWidth: 360)
                    }
                } else {
                    // Copilot can leave too little width for two readable
                    // document columns. Keep both views inside the editor area.
                    VSplitView {
                        EditorView()
                            .frame(minHeight: 160)
                        PreviewView()
                            .frame(minHeight: 160)
                    }
                }
            }
        case .previewOnly:
            PreviewView()
        }
    }
}
