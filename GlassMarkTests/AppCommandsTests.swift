import AppKit
import XCTest
@testable import GlassMark

/// Guards the Notes-style text size commands (⇧⌘. bigger, ⇧⌘, smaller) that the
/// Format menu exposes. These tests inspect the real main menu and dispatch a
/// synthetic key event through `NSApp.sendEvent`, which is the same path a
/// hardware key press takes.
@MainActor
final class AppCommandsTests: XCTestCase {
    func testTextSizeCommandsUseNotesShortcuts() throws {
        let formatMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.first { $0.title == "Format" }?.submenu,
            "The Format menu should exist once the app has launched."
        )

        let bigger = try XCTUnwrap(formatMenu.items.first { $0.title == "Make Text Bigger" })
        XCTAssertEqual(bigger.keyEquivalent, ".")
        XCTAssertEqual(bigger.keyEquivalentModifierMask.intersection([.command, .shift]), [.command, .shift])

        let smaller = try XCTUnwrap(formatMenu.items.first { $0.title == "Make Text Smaller" })
        XCTAssertEqual(smaller.keyEquivalent, ",")
        XCTAssertEqual(smaller.keyEquivalentModifierMask.intersection([.command, .shift]), [.command, .shift])
    }

    func testNewFolderCommandUsesFinderShortcut() throws {
        let fileMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu,
            "The File menu should exist once the app has launched."
        )

        let newFolder = try XCTUnwrap(fileMenu.items.first { $0.title == "New Folder" })
        XCTAssertEqual(newFolder.keyEquivalent, "n")
        XCTAssertEqual(newFolder.keyEquivalentModifierMask.intersection([.command, .shift]), [.command, .shift])

        // Replacing the system's New Item group keeps ⌘N for creating notes
        // instead of leaving it to the default "New Window" command.
        let newFile = try XCTUnwrap(fileMenu.items.first { $0.title == "New Markdown File" })
        XCTAssertEqual(newFile.keyEquivalent, "n")
        XCTAssertEqual(newFile.keyEquivalentModifierMask.intersection([.command, .shift]), [.command])
        XCTAssertFalse(fileMenu.items.contains { $0.title == "New Window" })
    }

    func testTextSizeShortcutChangesThePreference() throws {
        let key = "textSize"
        let savedValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let current = (UserDefaults.standard.object(forKey: key) as? Double) ?? DocumentTextSize.defaultSize
        // At the maximum, "Make Text Bigger" is disabled; shrink instead so the
        // test works no matter where the preference currently sits.
        let increasing = current < DocumentTextSize.maximumSize
        let keyCode: CGKeyCode = increasing ? 47 : 43 // kVK_ANSI_Period / kVK_ANSI_Comma

        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            XCTFail("Could not create a keyboard event.")
            return
        }
        cgEvent.flags = [.maskCommand, .maskShift]
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertEqual(event.charactersIgnoringModifiers?.count, 1, "Expected a single-character key event.")

        NSApp.sendEvent(event)

        let updated = (UserDefaults.standard.object(forKey: key) as? Double) ?? DocumentTextSize.defaultSize
        let expected = increasing ? DocumentTextSize.increased(current) : DocumentTextSize.decreased(current)
        XCTAssertEqual(updated, expected, "⇧⌘. / ⇧⌘, should adjust the document text size.")
    }
}
