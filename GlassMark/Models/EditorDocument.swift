import Foundation

struct EditorDocument: Identifiable, Equatable {
    var file: WorkspaceFile
    var workspaceID: Workspace.ID
    var workspaceRootURL: URL
    var text: String
    var savedText: String
    var loadedAt: Date
    /// New each time the file is opened; distinguishes reopenings of the same URL.
    var sessionID: UUID = UUID()
    /// Advances whenever the UTF-16 content actually changes (including undo/redo).
    var revision: UInt64 = 0

    var id: WorkspaceFile.ID {
        file.id
    }

    var isDirty: Bool {
        !text.isExactlyEqual(to: savedText)
    }
}
