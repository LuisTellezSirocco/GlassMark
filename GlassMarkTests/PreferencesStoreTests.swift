import Combine
import XCTest
@testable import GlassMark

@MainActor
final class PreferencesStoreTests: XCTestCase {
    private static let textSizeKey = "textSize"
    private static let showLineNumbersKey = "showLineNumbers"
    private var savedTextSize: Any?
    private var savedShowLineNumbers: Any?

    override func setUp() async throws {
        // PreferencesStore persists through UserDefaults.standard, so keep the
        // real values around and restore them once the test finishes.
        savedTextSize = UserDefaults.standard.object(forKey: Self.textSizeKey)
        UserDefaults.standard.removeObject(forKey: Self.textSizeKey)
        savedShowLineNumbers = UserDefaults.standard.object(forKey: Self.showLineNumbersKey)
        UserDefaults.standard.removeObject(forKey: Self.showLineNumbersKey)
    }

    override func tearDown() async throws {
        if let savedTextSize {
            UserDefaults.standard.set(savedTextSize, forKey: Self.textSizeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.textSizeKey)
        }
        if let savedShowLineNumbers {
            UserDefaults.standard.set(savedShowLineNumbers, forKey: Self.showLineNumbersKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.showLineNumbersKey)
        }
    }

    func testDefaultTextSizeMatchesEditorDefault() {
        let store = PreferencesStore()
        XCTAssertEqual(store.textSize, DocumentTextSize.defaultSize)
        XCTAssertEqual(store.previewZoomScale, 1.0, accuracy: 0.0001)
    }

    func testIncreaseAndDecreaseStepByOnePoint() {
        let store = PreferencesStore()
        store.textSize = DocumentTextSize.defaultSize

        store.increaseTextSize()
        XCTAssertEqual(store.textSize, DocumentTextSize.defaultSize + DocumentTextSize.step)
        XCTAssertGreaterThan(store.previewZoomScale, 1.0)

        store.decreaseTextSize()
        XCTAssertEqual(store.textSize, DocumentTextSize.defaultSize)
    }

    func testTextSizeClampsToBounds() {
        let store = PreferencesStore()

        store.textSize = DocumentTextSize.maximumSize
        XCTAssertFalse(store.canIncreaseTextSize)
        store.increaseTextSize()
        XCTAssertEqual(store.textSize, DocumentTextSize.maximumSize)

        store.textSize = DocumentTextSize.minimumSize
        XCTAssertFalse(store.canDecreaseTextSize)
        store.decreaseTextSize()
        XCTAssertEqual(store.textSize, DocumentTextSize.minimumSize)
    }

    func testTextSizeChangesPublishToObservers() {
        let store = PreferencesStore()
        var notifications = 0
        let cancellable = store.objectWillChange.sink { notifications += 1 }

        store.increaseTextSize()
        store.decreaseTextSize()
        cancellable.cancel()

        XCTAssertGreaterThanOrEqual(notifications, 2)
    }

    func testShowLineNumbersDefaultsToOff() {
        let store = PreferencesStore()
        XCTAssertFalse(store.showLineNumbers)
    }

    func testShowLineNumbersPersistsAcrossStores() {
        let store = PreferencesStore()
        store.showLineNumbers = true
        XCTAssertTrue(PreferencesStore().showLineNumbers)
    }
}
