import Foundation
@testable import GlassMark

/// In-memory secret storage double; the real keychain is exercised manually.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    var failReadsWith: SecretStoreError?

    func secret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let failReadsWith { throw failReadsWith }
        return storage[account]
    }

    func setSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = secret
    }

    func removeSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
    }
}

/// Scripted generator used by store and credential tests.
final class FakeGeminiGenerator: GeminiGenerating, @unchecked Sendable {
    struct Response {
        var events: [GeminiStreamEvent]
        var error: Error?
        var holdOpen = false
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private var _receivedInputs: [GeminiEditInput] = []
    private var _receivedKeys: [String] = []

    var receivedInputs: [GeminiEditInput] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedInputs
    }

    var receivedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedKeys
    }

    func enqueue(events: [GeminiStreamEvent], error: Error? = nil, holdOpen: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(Response(events: events, error: error, holdOpen: holdOpen))
    }

    func streamEdit(_ input: GeminiEditInput, apiKey: String) -> AsyncThrowingStream<GeminiStreamEvent, Error> {
        lock.lock()
        _receivedInputs.append(input)
        _receivedKeys.append(apiKey)
        let response = responses.isEmpty
            ? Response(events: [.started(id: "fake"), .completed(usage: nil)])
            : responses.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            for event in response.events {
                continuation.yield(event)
            }
            if let error = response.error {
                continuation.finish(throwing: error)
            } else if !response.holdOpen {
                continuation.finish()
            }
        }
    }
}

@MainActor
func waitFor(
    timeout: TimeInterval = 3,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
