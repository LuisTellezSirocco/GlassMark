import Foundation

/// Shared Interactions model metadata used by inline editing and Copilot.
/// Custom IDs remain available to inline editing and intentionally omit an
/// unverified thinking configuration.
struct AIModelOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let thinkingLevel: String?
}

enum AIModelCatalog {
    static let defaultModelID = "gemini-3.5-flash-lite"

    static let presets: [AIModelOption] = [
        AIModelOption(
            id: "gemini-3.5-flash-lite",
            title: "Gemini 3.5 Flash-Lite · fastest",
            thinkingLevel: "low"
        ),
        AIModelOption(
            id: "gemini-3.8-flash",
            title: "Gemini 3.8 Flash · higher quality",
            thinkingLevel: "low"
        ),
    ]

    static func thinkingLevel(for modelID: String) -> String? {
        presets.first { $0.id == modelID }?.thinkingLevel
    }

    static func displayTitle(for modelID: String) -> String {
        presets.first { $0.id == modelID }?.title ?? modelID
    }
}
