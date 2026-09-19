import UniformTypeIdentifiers
import XCTest
@testable import GlassMark

final class FileTreeDragTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: "/tmp/workspace/folder/note.md")

    func testProviderAdvertisesThePrivateWorkspaceFileType() {
        let provider = FileTreeDrag.provider(for: sourceURL)

        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains(FileTreeDrag.workspaceFile.identifier),
            "The private type drives drop targeting and row highlighting in the tree."
        )
    }

    func testProviderRoundTripsTheSourceURL() {
        let provider = FileTreeDrag.provider(for: sourceURL)

        let loaded = expectation(description: "drag payload loaded")
        provider.loadDataRepresentation(forTypeIdentifier: FileTreeDrag.workspaceFile.identifier) { data, error in
            defer { loaded.fulfill() }
            XCTAssertNil(error)
            guard let data else {
                XCTFail("Expected drag payload data")
                return
            }
            XCTAssertEqual(String(data: data, encoding: .utf8), self.sourceURL.absoluteString)
        }

        wait(for: [loaded], timeout: 2)
    }

    func testProviderStillCarriesPlainTextForExternalDrops() {
        let provider = FileTreeDrag.provider(for: sourceURL)

        XCTAssertTrue(provider.canLoadObject(ofClass: NSString.self))
    }
}
