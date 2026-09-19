import Foundation
import SwiftUI

/// Best-effort in-process retention scheduler. The repository still filters by
/// `expires_at` on every read, so sleeping/closing the app cannot expose stale
/// content; this service removes it at the next opportunity.
@MainActor
final class ChatRetentionService: ObservableObject {
    private let repository: ChatRepository
    private weak var coordinator: ChatCoordinator?
    private var task: Task<Void, Never>?

    init(repository: ChatRepository, coordinator: ChatCoordinator? = nil) {
        self.repository = repository
        self.coordinator = coordinator
    }

    func start() {
        guard task == nil else { return }
        let coordinator = self.coordinator
        task = Task { [repository, weak coordinator] in
            try? await repository.recoverInterruptedAttempts()
            while !Task.isCancelled {
                if let expired = try? await repository.deleteExpired() {
                    coordinator?.cancel(conversations: expired)
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
