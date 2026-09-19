import os
import SwiftUI
import UniformTypeIdentifiers

private let dragLog = Logger(subsystem: "com.recurse.glassmark", category: "FileTreeDrag")

/// Drag payload used while moving files inside the sidebar.
enum FileTreeDrag {
    /// Private type so only drags started by the file tree highlight rows and
    /// perform moves; dropping unrelated text never triggers either.
    static let workspaceFile = UTType(exportedAs: "com.recurse.glassmark.workspace-file")

    /// Item provider for `url`: carries the workspace file type for drops
    /// inside the tree and the path as plain text for drops elsewhere.
    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url.absoluteString as NSString)
        provider.registerDataRepresentation(
            forTypeIdentifier: workspaceFile.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(url.absoluteString.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

struct FileTreeView: View {
    let files: [WorkspaceFile]
    let selectedFileID: WorkspaceFile.ID?
    @Binding var expandedFileIDs: Set<WorkspaceFile.ID>
    /// File currently being dragged inside the tree, tracked so a drop can be
    /// resolved synchronously without round-tripping the item provider.
    @Binding var draggingFile: WorkspaceFile?
    let onSelect: (WorkspaceFile) -> Void
    let onNewMarkdownFile: (WorkspaceFile) -> Void
    let onNewFolder: (WorkspaceFile) -> Void
    let onRename: (WorkspaceFile) -> Void
    let onCut: (WorkspaceFile) -> Void
    let onCopy: (WorkspaceFile) -> Void
    let onPaste: (WorkspaceFile) -> Void
    let canPaste: Bool
    let onDuplicate: (WorkspaceFile) -> Void
    let onRevealInFinder: (WorkspaceFile) -> Void
    let onMoveToTrash: (WorkspaceFile) -> Void
    let onMove: (WorkspaceFile, WorkspaceFile) -> Void
    /// Drops on the empty area below the tree move the file to the workspace
    /// root, so a file can be taken out of a folder even when the root has no
    /// other rows to drop it onto.
    let onMoveToRoot: (WorkspaceFile) -> Void

    @State private var isRootDropTargeted = false

    var body: some View {
        List {
            ForEach(files) { file in
                FileTreeNodeView(
                    file: file,
                    allFiles: files,
                    selectedFileID: selectedFileID,
                    expandedFileIDs: $expandedFileIDs,
                    draggingFile: $draggingFile,
                    onSelect: onSelect,
                    onNewMarkdownFile: onNewMarkdownFile,
                    onNewFolder: onNewFolder,
                    onRename: onRename,
                    onCut: onCut,
                    onCopy: onCopy,
                    onPaste: onPaste,
                    canPaste: canPaste,
                    onDuplicate: onDuplicate,
                    onRevealInFinder: onRevealInFinder,
                    onMoveToTrash: onMoveToTrash,
                    onMove: onMove
                )
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [FileTreeDrag.workspaceFile], isTargeted: $isRootDropTargeted) { providers in
            handleRootDrop(providers: providers)
        }
        .overlay {
            if isRootDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isRootDropTargeted)
    }

    private func handleRootDrop(providers: [NSItemProvider]) -> Bool {
        dragLog.debug("Drop on workspace root background; dragging=\(draggingFile?.relativePath ?? "none", privacy: .public)")

        if let sourceFile = draggingFile {
            draggingFile = nil
            dragLog.debug("Moving \(sourceFile.relativePath, privacy: .public) to workspace root")
            onMoveToRoot(sourceFile)
            return true
        }

        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(FileTreeDrag.workspaceFile.identifier)
        }) else {
            dragLog.debug("Rejected: no workspace-file provider in root drop")
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: FileTreeDrag.workspaceFile.identifier) { data, _ in
            guard let data,
                  let string = String(data: data, encoding: .utf8),
                  let sourceURL = URL(string: string) else { return }

            DispatchQueue.main.async {
                guard let sourceFile = findFile(with: sourceURL, in: files) else { return }
                onMoveToRoot(sourceFile)
            }
        }

        return true
    }
}

private struct FileTreeNodeView: View {
    let file: WorkspaceFile
    let allFiles: [WorkspaceFile]
    let selectedFileID: WorkspaceFile.ID?
    @Binding var expandedFileIDs: Set<WorkspaceFile.ID>
    @Binding var draggingFile: WorkspaceFile?
    let onSelect: (WorkspaceFile) -> Void
    let onNewMarkdownFile: (WorkspaceFile) -> Void
    let onNewFolder: (WorkspaceFile) -> Void
    let onRename: (WorkspaceFile) -> Void
    let onCut: (WorkspaceFile) -> Void
    let onCopy: (WorkspaceFile) -> Void
    let onPaste: (WorkspaceFile) -> Void
    let canPaste: Bool
    let onDuplicate: (WorkspaceFile) -> Void
    let onRevealInFinder: (WorkspaceFile) -> Void
    let onMoveToTrash: (WorkspaceFile) -> Void
    let onMove: (WorkspaceFile, WorkspaceFile) -> Void

    /// True while a file-tree drag hovers this row, so the drop target can be
    /// highlighted before the user releases the mouse button.
    @State private var isDropTargeted = false

    var body: some View {
        if file.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                if let children = file.children, !children.isEmpty {
                    ForEach(children) { child in
                        FileTreeNodeView(
                            file: child,
                            allFiles: allFiles,
                            selectedFileID: selectedFileID,
                            expandedFileIDs: $expandedFileIDs,
                            draggingFile: $draggingFile,
                            onSelect: onSelect,
                            onNewMarkdownFile: onNewMarkdownFile,
                            onNewFolder: onNewFolder,
                            onRename: onRename,
                            onCut: onCut,
                            onCopy: onCopy,
                            onPaste: onPaste,
                            canPaste: canPaste,
                            onDuplicate: onDuplicate,
                            onRevealInFinder: onRevealInFinder,
                            onMoveToTrash: onMoveToTrash,
                            onMove: onMove
                        )
                    }
                } else {
                    Text("Empty")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            } label: {
                rowLabel
            }
            .fileTreeActions(
                file: file,
                allFiles: allFiles,
                selectedFileID: selectedFileID,
                draggingFile: $draggingFile,
                isDropTargeted: $isDropTargeted,
                handleDrop: handleDrop,
                onSelect: onSelect,
                onNewMarkdownFile: onNewMarkdownFile,
                onNewFolder: onNewFolder,
                onRename: onRename,
                onCut: onCut,
                onCopy: onCopy,
                onPaste: onPaste,
                canPaste: canPaste,
                onDuplicate: onDuplicate,
                onRevealInFinder: onRevealInFinder,
                onMoveToTrash: onMoveToTrash
            )
        } else {
            rowLabel
                .fileTreeActions(
                    file: file,
                    allFiles: allFiles,
                    selectedFileID: selectedFileID,
                    draggingFile: $draggingFile,
                    isDropTargeted: $isDropTargeted,
                    handleDrop: handleDrop,
                    onSelect: onSelect,
                    onNewMarkdownFile: onNewMarkdownFile,
                    onNewFolder: onNewFolder,
                    onRename: onRename,
                    onCut: onCut,
                    onCopy: onCopy,
                    onPaste: onPaste,
                    canPaste: canPaste,
                    onDuplicate: onDuplicate,
                    onRevealInFinder: onRevealInFinder,
                    onMoveToTrash: onMoveToTrash
                )
        }
    }

    private var rowLabel: some View {
        FileRow(file: file, isSelected: file.id == selectedFileID, isDropTargeted: isDropTargeted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if file.isDirectory {
                    toggleExpanded()
                } else if file.isEditable {
                    onSelect(file)
                }
            }
            .onTapGesture {
                if file.isEditable {
                    onSelect(file)
                }
            }
            .listRowBackground(rowBackground)
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    private var rowBackground: some View {
        Group {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                    .padding(.vertical, 1)
            } else if file.id == selectedFileID {
                Color.accentColor.opacity(0.18)
            } else {
                Color.clear
            }
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { expandedFileIDs.contains(file.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedFileIDs.insert(file.id)
                } else {
                    expandedFileIDs.remove(file.id)
                }
            }
        )
    }

    private func toggleExpanded() {
        if expandedFileIDs.contains(file.id) {
            expandedFileIDs.remove(file.id)
        } else {
            expandedFileIDs.insert(file.id)
        }
    }

    private func handleDrop(providers: [NSItemProvider], target: WorkspaceFile) -> Bool {
        dragLog.debug("Drop on \(target.relativePath, privacy: .public); dragging=\(draggingFile?.relativePath ?? "none", privacy: .public)")

        // Fast path: a drag started by the tree carries the source file in
        // memory, so the move can be resolved synchronously without loading
        // the item provider payload.
        if let sourceFile = draggingFile {
            draggingFile = nil
            guard target.canAcceptMove(of: sourceFile) else {
                dragLog.debug("Rejected: \(sourceFile.relativePath, privacy: .public) cannot move to \(target.relativePath, privacy: .public)")
                return false
            }

            dragLog.debug("Moving \(sourceFile.relativePath, privacy: .public) to \(target.relativePath, privacy: .public)")
            onMove(sourceFile, target)
            return true
        }

        // Fallback: resolve the source from the drag payload.
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(FileTreeDrag.workspaceFile.identifier)
        }) else {
            dragLog.debug("Rejected: no workspace-file provider in drop")
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: FileTreeDrag.workspaceFile.identifier) { data, error in
            guard let data,
                  let string = String(data: data, encoding: .utf8),
                  let sourceURL = URL(string: string) else {
                dragLog.debug("Rejected: payload load failed (\(error?.localizedDescription ?? "no data", privacy: .public))")
                return
            }
            dragLog.debug("Payload loaded: \(string, privacy: .public)")

            DispatchQueue.main.async {
                guard let sourceFile = findFile(with: sourceURL, in: allFiles),
                      target.canAcceptMove(of: sourceFile) else {
                    dragLog.debug("Rejected: source not found in tree or invalid target")
                    return
                }

                onMove(sourceFile, target)
            }
        }

        return true
    }
}

private func findFile(with url: URL, in files: [WorkspaceFile]) -> WorkspaceFile? {
    for file in files {
        if file.url == url {
            return file
        }

        if let children = file.children,
           let match = findFile(with: url, in: children) {
            return match
        }
    }

    return nil
}

private extension View {
    func fileTreeActions(
        file: WorkspaceFile,
        allFiles: [WorkspaceFile],
        selectedFileID: WorkspaceFile.ID?,
        draggingFile: Binding<WorkspaceFile?>,
        isDropTargeted: Binding<Bool>,
        handleDrop: @escaping ([NSItemProvider], WorkspaceFile) -> Bool,
        onSelect: @escaping (WorkspaceFile) -> Void,
        onNewMarkdownFile: @escaping (WorkspaceFile) -> Void,
        onNewFolder: @escaping (WorkspaceFile) -> Void,
        onRename: @escaping (WorkspaceFile) -> Void,
        onCut: @escaping (WorkspaceFile) -> Void,
        onCopy: @escaping (WorkspaceFile) -> Void,
        onPaste: @escaping (WorkspaceFile) -> Void,
        canPaste: Bool,
        onDuplicate: @escaping (WorkspaceFile) -> Void,
        onRevealInFinder: @escaping (WorkspaceFile) -> Void,
        onMoveToTrash: @escaping (WorkspaceFile) -> Void
    ) -> some View {
        self
            .onDrag {
                dragLog.debug("Drag started: \(file.relativePath, privacy: .public)")
                draggingFile.wrappedValue = file
                return FileTreeDrag.provider(for: file.url)
            }
            .onDrop(of: [FileTreeDrag.workspaceFile], isTargeted: isDropTargeted) { providers in
                handleDrop(providers, file)
            }
            .contextMenu {
                if file.isEditable {
                    Button("Open") {
                        onSelect(file)
                    }

                    Divider()
                }

                Button("New Markdown File") {
                    onNewMarkdownFile(file)
                }

                Button("New Folder") {
                    onNewFolder(file)
                }

                Button("Rename…") {
                    onRename(file)
                }

                Divider()

                Button("Cut") {
                    onCut(file)
                }

                Button("Copy") {
                    onCopy(file)
                }

                Button("Paste") {
                    onPaste(file)
                }
                .disabled(!canPaste)

                Button("Duplicate") {
                    onDuplicate(file)
                }

                Divider()

                Button("Reveal in Finder") {
                    onRevealInFinder(file)
                }

                Divider()

                Button("Move to Trash", role: .destructive) {
                    onMoveToTrash(file)
                }
            }
    }
}

private struct FileRow: View {
    let file: WorkspaceFile
    let isSelected: Bool
    let isDropTargeted: Bool

    var body: some View {
        Label {
            Text(file.name)
                .lineLimit(1)
                .fontWeight(isSelected || isDropTargeted ? .semibold : .regular)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(isSelected || isDropTargeted ? Color.accentColor : file.isDirectory ? Color.secondary : Color.primary)
        }
    }

    private var iconName: String {
        switch file.kind {
        case .folder: "folder"
        case .markdown: "doc.richtext"
        case .text: "doc.text"
        case .other: "doc"
        }
    }
}
