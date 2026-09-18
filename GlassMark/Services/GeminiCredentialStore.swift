import Foundation
import Security

/// Observable state of the Gemini credential. The secret itself is read lazily
/// and never published, logged, or persisted outside the keychain.
@MainActor
final class GeminiCredentialStore: ObservableObject {
    enum Source: Equatable {
        case keychain
        case developmentEnvironment
    }

    enum AccessState: Equatable {
        case unknown
        case missing
        case available(Source)
        case denied
        case failed(String)
    }

    static let account = "gemini-api-key"
    static let service = "com.recurse.glassmark"

    @Published private(set) var state: AccessState = .unknown
    @Published private(set) var lastErrorMessage: String?

    private var secretStore: SecretStoring
    private let environment: [String: String]
    private let generator: GeminiGenerating
    private var cachedSecret: String?

    init(
        secretStore: SecretStoring = KeychainSecretStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        generator: GeminiGenerating = GeminiClient()
    ) {
        self.secretStore = secretStore
        self.environment = environment
        self.generator = generator
        reloadWithFallback()
    }

    var isConfigured: Bool {
        if case .available = state { return true }
        return false
    }

    var isDevelopmentOverride: Bool {
        state == .available(.developmentEnvironment)
    }

    /// Reads the key for an outgoing request. Returns `nil` when unavailable;
    /// it deliberately does not fall back after a keychain access denial.
    func currentKey() -> String? {
        if cachedSecret == nil {
            reloadWithFallback()
        }
        return cachedSecret
    }

    func refresh() {
        reloadWithFallback()
    }

    func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastErrorMessage = "The API key is empty."
            return
        }
        do {
            try secretStore.setSecret(trimmed, account: Self.account)
            lastErrorMessage = nil
            reloadWithFallback()
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
    }

    func remove() {
        do {
            try secretStore.removeSecret(account: Self.account)
            lastErrorMessage = nil
            reloadWithFallback()
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
    }

    /// Explicit, user-initiated connectivity check with synthetic content.
    /// Never called automatically; it may consume quota.
    func testConnection(model: String) async -> Result<Void, GeminiAPIError> {
        guard let key = currentKey() else {
            return .failure(.authentication)
        }
        let input = GeminiEditInput(
            model: model,
            instruction: "Reply with the single word: ok",
            selection: "connection test",
            thinkingLevel: AIModelCatalog.thinkingLevel(for: model),
            maxOutputTokens: 64
        )
        do {
            for try await event in generator.streamEdit(input, apiKey: key) {
                if case .completed = event {
                    return .success(())
                }
            }
            return .failure(.incompleteResponse)
        } catch let error as GeminiAPIError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Loading

    private func reloadWithFallback() {
        do {
            try load(from: secretStore)
        } catch SecretStoreError.missingEntitlement {
            fallBackToLegacyKeychain()
        } catch SecretStoreError.unexpected(let status) where status == errSecParam {
            fallBackToLegacyKeychain()
        } catch SecretStoreError.accessDenied {
            cachedSecret = nil
            state = .denied
        } catch {
            cachedSecret = nil
            state = .failed(Self.message(for: error))
        }
    }

    private func fallBackToLegacyKeychain() {
        let legacy = KeychainSecretStore(service: Self.service, useDataProtection: false)
        secretStore = legacy
        do {
            try load(from: legacy)
        } catch {
            cachedSecret = nil
            state = .failed(Self.message(for: error))
        }
    }

    private func load(from store: SecretStoring) throws {
        do {
            if let secret = try store.secret(for: Self.account), !secret.isEmpty {
                cachedSecret = secret
                state = .available(.keychain)
                return
            }
        } catch let error as SecretStoreError {
            throw error
        }

        if let override = Self.developmentOverride(in: environment) {
            cachedSecret = override
            state = .available(.developmentEnvironment)
        } else {
            cachedSecret = nil
            state = .missing
        }
    }

    private static func developmentOverride(in environment: [String: String]) -> String? {
        #if DEBUG
        guard let value = environment["GEMINI_API_KEY"], !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SecretStoreError.accessDenied:
            return "Keychain access was denied. Unlock the login keychain and try again."
        case SecretStoreError.missingEntitlement:
            return "This build cannot access the keychain (missing entitlement)."
        case SecretStoreError.unexpected(let status):
            return "Keychain error (\(status))."
        default:
            return error.localizedDescription
        }
    }
}
