import XCTest
@testable import GlassMark

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private var root: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassMarkStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        store = WorkspaceStore()
        store.activeWorkspace = Workspace(
            displayName: "Test Workspace",
            rootURL: root,
            bookmarkData: Data()
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateFolderCreatesFolderAtWorkspaceRoot() throws {
        let folder = try XCTUnwrap(store.createFolder())

        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.name, "New Folder")
        XCTAssertEqual(folder.url.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertNil(store.errorMessage)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCreateFolderNextToFolderNestsInsideIt() throws {
        let parent = try XCTUnwrap(store.createFolder())
        let child = try XCTUnwrap(store.createFolder(nextTo: parent))

        XCTAssertEqual(
            child.url.deletingLastPathComponent().standardizedFileURL.path,
            parent.url.standardizedFileURL.path
        )
        XCTAssertNil(store.errorMessage)
    }

    func testCreateFolderWithoutWorkspaceReturnsNil() {
        store.activeWorkspace = nil
        XCTAssertNil(store.createFolder())
    }

    func testMoveFileBackToWorkspaceRootTakesItOutOfItsFolder() throws {
        let folder = try XCTUnwrap(store.createFolder())
        let nested = try XCTUnwrap(store.createMarkdownFile(nextTo: folder))
        XCTAssertEqual(
            nested.url.deletingLastPathComponent().standardizedFileURL.path,
            folder.url.standardizedFileURL.path
        )

        let rootTarget = WorkspaceFile(url: root, rootURL: root, kind: .folder)
        let moved = try XCTUnwrap(store.move(nested, to: rootTarget))

        XCTAssertEqual(moved.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.url.path))
    }

    func testBeginAndCommitRenameRenamesFile() throws {
        let fileURL = root.appendingPathComponent("note.md")
        try "# Note".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = WorkspaceFile(url: fileURL, rootURL: root, kind: .markdown)

        store.beginRename(file)
        XCTAssertEqual(store.pendingRenameFile, file)
        XCTAssertEqual(store.pendingRenameText, "note.md")

        store.pendingRenameText = "renamed.md"
        store.commitRename()

        XCTAssertNil(store.pendingRenameFile)
        XCTAssertEqual(store.pendingRenameText, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCancelRenameClearsPendingStateAndKeepsFile() throws {
        let fileURL = root.appendingPathComponent("note.md")
        try "# Note".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = WorkspaceFile(url: fileURL, rootURL: root, kind: .markdown)

        store.beginRename(file)
        store.cancelRename()

        XCTAssertNil(store.pendingRenameFile)
        XCTAssertEqual(store.pendingRenameText, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
