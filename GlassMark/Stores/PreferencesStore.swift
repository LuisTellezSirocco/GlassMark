import AppKit
import SwiftUI

@MainActor
final class PreferencesStore: ObservableObject {
    @AppStorage("viewMode") var viewMode: ViewMode = .split
    @AppStorage("appearancePreference") var appearancePreference: AppearancePreference = .system
    @AppStorage("autosaveEnabled") var autosaveEnabled = false
    @AppStorage("previewTheme") var previewTheme: PreviewTheme = .system
    @AppStorage("customPreviewCSS") var customPreviewCSS = ""
    @AppStorage("focusModeEnabled") var focusModeEnabled = false
    @AppStorage("typewriterModeEnabled") var typewriterModeEnabled = false
    /// Shows a quiet gutter of logical line numbers in the editor (View ▸ Line Numbers).
    @AppStorage("showLineNumbers") var showLineNumbers = false
    /// Document text size, adjusted with the Notes-style "Make Text Bigger/Smaller"
    /// commands (⇧⌘. / ⇧⌘,). Scales the editor text and the preview alike.
    @AppStorage("textSize") var textSize: Double = DocumentTextSize.defaultSize
    @AppStorage("logicalLineSpacing")
    private var storedLogicalLineSpacing = DocumentLogicalLineSpacing.defaultValue
    /// Inline AI editing is opt-in. The API key lives in the keychain, never here.
    @AppStorage("aiEditingEnabled") var aiEditingEnabled = false
    /// Any Interactions API model ID can be typed here; presets are offered in Settings.
    @AppStorage("aiModel") var aiModel = AIModelCatalog.defaultModelID
    /// Copilot chat is independently opt-in from inline AI editing.
    @AppStorage("copilotChatEnabled") var copilotChatEnabled = false
    /// Model copied into newly-created chat conversations.
    @AppStorage("copilotDefaultModelID") var copilotDefaultModelID = AIModelCatalog.defaultModelID
    /// Transient request to focus a specific Settings tab ("Open AI Settings").
    @Published var requestedSettingsTab: SettingsTab?

    /// Extra space, in AppKit points, between separate Markdown source lines.
    /// The effective value is always normalized before it reaches the editor.
    var logicalLineSpacing: Double {
        get { DocumentLogicalLineSpacing.normalized(storedLogicalLineSpacing) }
        set { storedLogicalLineSpacing = DocumentLogicalLineSpacing.normalized(newValue) }
    }

    var resolvedColorScheme: ColorScheme? {
        switch appearancePreference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var canIncreaseTextSize: Bool {
        textSize < DocumentTextSize.maximumSize
    }

    var canDecreaseTextSize: Bool {
        textSize > DocumentTextSize.minimumSize
    }

    /// Scales the web preview so its text grows and shrinks with the editor.
    var previewZoomScale: Double {
        textSize / DocumentTextSize.defaultSize
    }

    func increaseTextSize() {
        textSize = DocumentTextSize.increased(textSize)
    }

    func decreaseTextSize() {
        textSize = DocumentTextSize.decreased(textSize)
    }
}

/// Bounds and stepping for the user-adjustable document text size.
enum DocumentTextSize {
    /// Matches the font size the editor has always used by default.
    static let defaultSize = Double(NSFont.systemFontSize)
    static let minimumSize = 9.0
    static let maximumSize = 32.0
    static let step = 1.0

    static func increased(_ size: Double) -> Double {
        min(size + step, maximumSize)
    }

    static func decreased(_ size: Double) -> Double {
        max(size - step, minimumSize)
    }
}

/// Bounds and normalization for the editor's logical-line paragraph spacing.
enum DocumentLogicalLineSpacing {
    static let defaultValue = 0.0
    static let minimumValue = 0.0
    static let maximumValue = 100.0
    static let step = 1.0

    /// Returns a finite value inside the supported closed interval without
    /// rounding valid fractional values.
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, minimumValue), maximumValue)
    }
}

enum SettingsTab: Hashable {
    case general
    case editor
    case preview
    case ai
}

/// Preview stylesheet themes layered on top of the base GitHub-style CSS.
enum PreviewTheme: String, CaseIterable, Codable, Identifiable {
    case system
    case sepia
    case highContrast
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .sepia: "Sepia"
        case .highContrast: "High Contrast"
        case .dark: "Dark"
        }
    }

    /// CSS overrides applied after the base stylesheet.
    var css: String {
        switch self {
        case .system:
            return ""
        case .sepia:
            return """
            body { background: #f4ecd8; color: #5b4636; }
            a { color: #8a5a2b; }
            pre, code { background: #eadfc4; }
            th { background: #eadfc4; }
            """
        case .highContrast:
            return """
            body { background: #ffffff; color: #000000; }
            a { color: #0000ee; }
            pre, code { background: #f0f0f0; border-color: #000; }
            h2 { border-bottom-color: #000; }
            """
        case .dark:
            return """
            body { background: #1e1e1e; color: #e6e6e6; }
            a { color: #6cb6ff; }
            pre { background: #2a2a2a; border-color: #3a3a3a; }
            code { background: #2a2a2a; }
            th { background: #2a2a2a; }
            """
        }
    }
}

enum AppearancePreference: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
