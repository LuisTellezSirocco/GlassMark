import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject var documentStore: DocumentStore
    @ObservedObject var commandStore: CommandStore
    @ObservedObject var preferencesStore: PreferencesStore

    @FocusedValue(\.inlineEdit) private var inlineEditAction
    @FocusedValue(\.copilot) private var copilotAction

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Edit with Gemini…") {
                inlineEditAction?.perform()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(
                inlineEditAction == nil
                    || documentStore.document == nil
                    || preferencesStore.viewMode == .previewOnly
            )

            Button(copilotAction?.isPresented == true ? "Hide Copilot" : "Show Copilot") {
                copilotAction?.perform()
            }
            .keyboardShortcut("c", modifiers: [.control, .command])
            .disabled(copilotAction == nil)
        }

        // Replaces the standard New Item group so ⌘N creates a Markdown file
        // and ⇧⌘N creates a folder (Finder's shortcut) instead of the
        // system-provided "New Window" claiming ⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Markdown File") {
                guard let file = workspaceStore.createMarkdownFile(),
                      let workspace = workspaceStore.activeWorkspace else { return }

                documentStore.open(file, workspace: workspace)
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(workspaceStore.activeWorkspace == nil)

            Button("New Folder") {
                guard let folder = workspaceStore.createFolder() else { return }
                workspaceStore.beginRename(folder)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(workspaceStore.activeWorkspace == nil)

            Button("Open Workspace…") {
                workspaceStore.presentWorkspacePicker()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Button("Save") {
                documentStore.save()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!documentStore.canSave)

            Divider()

            Button("Export as HTML…") {
                guard let document = documentStore.document else { return }
                MarkdownExporter.exportHTML(
                    documentStore.exportHTML(for: document),
                    suggestedName: baseName(for: document)
                )
            }
            .disabled(documentStore.document == nil)

            Button("Export as PDF…") {
                guard let document = documentStore.document else { return }
                MarkdownExporter.exportPDF(
                    html: documentStore.exportHTML(for: document),
                    baseURL: document.file.url.deletingLastPathComponent(),
                    suggestedName: baseName(for: document)
                )
            }
            .disabled(documentStore.document == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Quick Open…") {
                commandStore.presentQuickOpen()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(workspaceStore.activeWorkspace == nil)

            Button(commandStore.isOutlineVisible ? "Hide Outline" : "Show Outline") {
                commandStore.toggleOutline()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(documentStore.document == nil)

            Toggle("Focus Mode", isOn: $preferencesStore.focusModeEnabled)
                .keyboardShortcut("f", modifiers: [.command, .control])
            Toggle("Typewriter Scrolling", isOn: $preferencesStore.typewriterModeEnabled)
            Toggle("Line Numbers", isOn: $preferencesStore.showLineNumbers)
        }

        CommandGroup(after: .sidebar) {
            Button("Refresh Workspace") {
                workspaceStore.refreshFileTree()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(workspaceStore.activeWorkspace == nil)
        }

        CommandMenu("Format") {
            Group {
                Button("Bold") { commandStore.run(.bold) }
                    .keyboardShortcut("b", modifiers: [.command])
                Button("Italic") { commandStore.run(.italic) }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Strikethrough") { commandStore.run(.strikethrough) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Inline Code") { commandStore.run(.inlineCode) }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("Insert Link") { commandStore.run(.link) }
                    .keyboardShortcut("k", modifiers: [.command])

                Divider()

                Button("Heading 1") { commandStore.run(.heading(level: 1)) }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Heading 2") { commandStore.run(.heading(level: 2)) }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Heading 3") { commandStore.run(.heading(level: 3)) }
                    .keyboardShortcut("3", modifiers: [.command, .control])

                Divider()

                Button("Bulleted List") { commandStore.run(.bulletList) }
                Button("Numbered List") { commandStore.run(.numberList) }
            }
            .disabled(documentStore.document == nil)

            Divider()

            // Notes-style text size. The shortcuts mirror Notes: ⇧⌘. bigger, ⇧⌘, smaller.
            Button("Make Text Bigger") { preferencesStore.increaseTextSize() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!preferencesStore.canIncreaseTextSize)

            Button("Make Text Smaller") { preferencesStore.decreaseTextSize() }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                .disabled(!preferencesStore.canDecreaseTextSize)
        }
    }

    private func baseName(for document: EditorDocument) -> String {
        document.file.url.deletingPathExtension().lastPathComponent
    }
}
