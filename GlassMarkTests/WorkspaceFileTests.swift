import XCTest
@testable import GlassMark

final class WorkspaceFileTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/workspace")

    func testRelativePathIsComputedFromRoot() {
        let file = WorkspaceFile(url: root.appendingPathComponent("docs/note.md"), rootURL: root, kind: .markdown)
        XCTAssertEqual(file.relativePath, "docs/note.md")
        XCTAssertEqual(file.name, "note.md")
    }

    func testEditabilityByKind() {
        XCTAssertTrue(WorkspaceFile(url: root.appendingPathComponent("a.md"), rootURL: root, kind: .markdown).isEditable)
        XCTAssertTrue(WorkspaceFile(url: root.appendingPathComponent("a.txt"), rootURL: root, kind: .text).isEditable)
        XCTAssertFalse(WorkspaceFile(url: root.appendingPathComponent("a.png"), rootURL: root, kind: .other).isEditable)
        XCTAssertFalse(WorkspaceFile(url: root.appendingPathComponent("dir"), rootURL: root, kind: .folder).isEditable)
    }

    func testDirectoryFlag() {
        XCTAssertTrue(WorkspaceFile(url: root.appendingPathComponent("dir"), rootURL: root, kind: .folder).isDirectory)
        XCTAssertFalse(WorkspaceFile(url: root.appendingPathComponent("a.md"), rootURL: root, kind: .markdown).isDirectory)
    }

    func testMoveValidationBlocksSelfAndOwnDescendants() {
        let folder = WorkspaceFile(url: root.appendingPathComponent("docs"), rootURL: root, kind: .folder)
        let child = WorkspaceFile(url: root.appendingPathComponent("docs/child.md"), rootURL: root, kind: .markdown)
        let sibling = WorkspaceFile(url: root.appendingPathComponent("note.md"), rootURL: root, kind: .markdown)

        XCTAssertTrue(folder.canAcceptMove(of: sibling))
        XCTAssertTrue(folder.canAcceptMove(of: child), "moving a child onto its own folder is a no-op, not a cycle")
        XCTAssertFalse(folder.canAcceptMove(of: folder), "an item cannot be dropped onto itself")
        XCTAssertFalse(child.canAcceptMove(of: folder), "a folder cannot be moved into its own descendant")
    }

    func testWorkspaceDecodesLenidentlyWithoutAdditiveFields() throws {
        // A blob saved by an older build that predates isPinned / colorName.
        let json = """
        {"id":"\(UUID().uuidString)","displayName":"Legacy","rootURL":"file:///tmp/legacy","bookmarkData":"","lastOpenedAt":0}
        """.data(using: .utf8)!
        let workspace = try JSONDecoder().decode(Workspace.self, from: json)
        XCTAssertEqual(workspace.displayName, "Legacy")
        XCTAssertFalse(workspace.isPinned)
        XCTAssertTrue(WorkspaceColorName.allCases.contains(workspace.colorName))
    }

    func testFileTypeDetection() {
        XCTAssertEqual(FileType(url: URL(fileURLWithPath: "/x/a.md"))?.workspaceKind, .markdown)
        XCTAssertEqual(FileType(url: URL(fileURLWithPath: "/x/a.markdown"))?.workspaceKind, .markdown)
        XCTAssertEqual(FileType(url: URL(fileURLWithPath: "/x/a.txt"))?.workspaceKind, .text)
        XCTAssertEqual(FileType(url: URL(fileURLWithPath: "/x/a.png"))?.workspaceKind, .other)
        XCTAssertFalse(FileType(url: URL(fileURLWithPath: "/x/a.png"))?.shouldShowInSidebar ?? true)
    }

    func testSearchIndexSortsNestedFilesAndMatchesAllTerms() {
        let children = ["note10.md", "note2.md", "Other.txt"].map {
            WorkspaceFile(url: root.appendingPathComponent("docs/\($0)"), rootURL: root, kind: .markdown)
        }
        let folder = WorkspaceFile(url: root.appendingPathComponent("docs"), rootURL: root, kind: .folder, children: children)
        let image = WorkspaceFile(url: root.appendingPathComponent("image.png"), rootURL: root, kind: .other)
        let index = WorkspaceSearchIndex(files: [folder, image])
        XCTAssertEqual(index.results(for: "  ").map(\.name), ["note2.md", "note10.md", "Other.txt"])
        XCTAssertEqual(index.results(for: "DOCS  NOTE2").map(\.name), ["note2.md"])
        XCTAssertTrue(index.results(for: "absent").isEmpty)
        XCTAssertTrue(index.results(for: "image").isEmpty)
    }

    func testSearchIndexCapsResults() {
        let files = (0..<100).map {
            WorkspaceFile(url: root.appendingPathComponent("note\($0).md"), rootURL: root, kind: .markdown)
        }
        let index = WorkspaceSearchIndex(files: files)
        XCTAssertEqual(index.results(for: "").count, 30)
        XCTAssertEqual(index.results(for: "note").count, 40)
        XCTAssertEqual(index.results(for: "note99").first?.name, "note99.md")
    }
}
