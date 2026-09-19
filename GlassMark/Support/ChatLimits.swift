import Foundation

/// Product limits for Copilot chat. These are intentionally separate from the
/// limits used by the inline editor: a note conversation has a different
/// retention and replay profile.
enum ChatLimits {
    static let retentionDuration: TimeInterval = 30 * 24 * 60 * 60
    static let maxQuestionBytes = 32 * 1024
    static let maxSnapshotBytes = 256 * 1024
    static let maxPayloadBytes = 2 * 1024 * 1024
    static let maxTurns = 200
    static let maxAttemptsPerTurn = 5
    static let maxVisibleResponseBytes = 256 * 1024
    static let maxSSEMessageBytes = 1 * 1024 * 1024
    static let maxSSETotalBytes = 8 * 1024 * 1024
    static let maxReplayStepsBytes = 2 * 1024 * 1024
    static let maxErrorBodyBytes = 16 * 1024
    static let maxConcurrentGenerations = 2
    static let requestInactivityTimeout: TimeInterval = 60
    static let requestTotalTimeout: TimeInterval = 180
    static let maxStoredLogicalBytes = 250 * 1024 * 1024
    static let uiPublishInterval: Duration = .milliseconds(50)
    static let checkpointInterval: Duration = .seconds(1)

    static func byteCount(_ value: String) -> Int {
        value.utf8.count
    }

    static func validateQuestion(_ value: String) throws {
        guard byteCount(value) <= maxQuestionBytes else {
            throw ChatError.localLimit("The question is too large (limit 32 KiB).")
        }
    }

    static func validateSnapshot(_ value: String) throws {
        guard byteCount(value) <= maxSnapshotBytes else {
            throw ChatError.localLimit("The note is too large for Copilot (limit 256 KiB).")
        }
    }
}
