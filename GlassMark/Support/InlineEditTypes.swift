import CoreGraphics
import Foundation
import SwiftUI

/// Identifies the exact editor and document revision an inline AI edit targets.
/// Visual geometry is deliberately kept out of the target; see `InlineEditCapture`.
struct InlineEditTarget: Equatable, Sendable {
    let windowID: UUID
    let editorID: UUID
    let workspaceID: UUID
    let documentURL: URL
    let documentSessionID: UUID
    let revision: UInt64
    let range: NSRange
    let original: String
}

enum InlineEditScope: Equatable, Sendable {
    case selection
    case paragraph
}

/// A captured destination plus the geometry used to anchor the panel.
struct InlineEditCapture: Equatable, Sendable {
    let target: InlineEditTarget
    let scope: InlineEditScope
    let anchorRect: CGRect?
    let containerSize: CGSize?
}

enum InlineEditCaptureResult: Equatable, Sendable {
    case captured(InlineEditCapture)
    case failed(reason: String)
}

/// Published by the store and consumed exactly once by the editor bridge.
struct ReplacementRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let generationID: UUID
    let target: InlineEditTarget
    let replacement: String
}

enum InlineEditApplicationOutcome: Equatable, Sendable {
    case applied
    case rejected(reason: String)
}

/// Asks the editor to restore the selection captured before an AI session.
struct SelectionRestoreRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let editorID: UUID
    let documentSessionID: UUID
    let range: NSRange
}

/// Product limits for the inline AI editor. These are not published Gemini limits.
enum InlineEditLimits {
    static let maxSelectionUTF16 = 12_000
    static let maxInstructionUTF16 = 2_000
    static let maxProposalUTF16 = 24_000
    static let maxSSEMessageBytes = 256 * 1024
    static let maxSSETotalBytes = 2 * 1024 * 1024
    static let maxErrorBodyBytes = 16 * 1024
    static let diffMaxLines = 2_000
    static let diffMaxLineProduct = 250_000
    static let partialPublishInterval: Duration = .milliseconds(50)
}

extension String {
    /// Exact UTF-16 comparison. `String ==` applies Unicode canonical equivalence,
    /// which is too loose for edit fidelity checks.
    func isExactlyEqual(to other: String) -> Bool {
        utf16.elementsEqual(other.utf16)
    }
}

// MARK: - Focused scene action

/// Routed through `focusedSceneValue` so ⌃⌘I only reaches the active window.
struct InlineEditAction {
    let perform: () -> Void
}

struct InlineEditActionKey: FocusedValueKey {
    typealias Value = InlineEditAction
}

extension FocusedValues {
    var inlineEdit: InlineEditAction? {
        get { self[InlineEditActionKey.self] }
        set { self[InlineEditActionKey.self] = newValue }
    }
}
