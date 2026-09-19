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
    private static let backendDefaultsKey = "geminiKeychainBackend"

    @Published private(set) var state: AccessState = .unknown
    @Published private(set) var lastErrorMessage: String?

    private let environment: [String: String]
    private let generator: GeminiGenerating
    private let chatGenerator: ChatGenerating
    private let defaults: UserDefaults
    private let legacyStoreFactory: () -> SecretStoring
    private var secretStore: SecretStoring
    private var usingLegacyStore: Bool
    private var cachedSecret: String?

    init(
        secretStore: SecretStoring? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        generator: GeminiGenerating = GeminiClient(),
        chatGenerator: ChatGenerating = GeminiChatClient(),
        defaults: UserDefaults = .standard,
        legacyStoreFactory: (() -> SecretStoring)? = nil
    ) {
        self.environment = environment
        self.generator = generator
        self.chatGenerator = chatGenerator
        self.defaults = defaults
        self.legacyStoreFactory = legacyStoreFactory ?? {
            KeychainSecretStore(service: GeminiCredentialStore.service, useDataProtection: false)
        }
        let persistedLegacy = defaults.bool(forKey: Self.backendDefaultsKey)
        self.usingLegacyStore = persistedLegacy
        if let secretStore {
            self.secretStore = secretStore
        } else if persistedLegacy {
            self.secretStore = KeychainSecretStore(service: Self.service, useDataProtection: false)
        } else {
            self.secretStore = KeychainSecretStore(service: Self.service, useDataProtection: true)
        }
        refresh()
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
            refresh()
        }
        return cachedSecret
    }

    func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastErrorMessage = "The API key is empty."
            return
        }
        do {
            try performWithFallback { try $0.setSecret(trimmed, account: Self.account) }
            lastErrorMessage = nil
            refresh()
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
    }

    func remove() {
        do {
            try performWithFallback { try $0.removeSecret(account: Self.account) }
            lastErrorMessage = nil
            refresh()
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

    /// Chat-specific synthetic connectivity check. It never reads a document
    /// or reuses an inline-edit prompt.
    func testChatConnection(model: String) async -> Result<Void, GeminiAPIError> {
        guard let key = currentKey() else { return .failure(.authentication) }
        do {
            let request = try GeminiChatClient.syntheticRequest(modelID: model)
            for try await event in chatGenerator.streamChat(request, apiKey: key) {
                if case .completed = event { return .success(()) }
            }
            return .failure(.incompleteResponse)
        } catch let error as GeminiAPIError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Loading

    func refresh() {
        do {
            let secret = try performWithFallback { try $0.secret(for: Self.account) }
            if let secret, !secret.isEmpty {
                cachedSecret = secret
                state = .available(.keychain)
                return
            }
        } catch let error as SecretStoreError {
            cachedSecret = nil
            switch error {
            case .accessDenied:
                state = .denied
            default:
                state = .failed(Self.message(for: error))
            }
            return
        } catch {
            cachedSecret = nil
            state = .failed(Self.message(for: error))
            return
        }

        if let override = Self.developmentOverride(in: environment) {
            cachedSecret = override
            state = .available(.developmentEnvironment)
        } else {
            cachedSecret = nil
            state = .missing
        }
    }

    /// The Data Protection keychain needs entitlements that ad-hoc development
    /// builds do not carry (errSecMissingEntitlement on write). When that shows
    /// up, switch to the legacy keychain once and remember the choice.
    private func performWithFallback<T>(_ operation: (SecretStoring) throws -> T) throws -> T {
        do {
            return try operation(secretStore)
        } catch let error as SecretStoreError where error.isEntitlementIssue {
            guard switchToLegacyStore() else { throw error }
            return try operation(secretStore)
        }
    }

    @discardableResult
    private func switchToLegacyStore() -> Bool {
        guard !usingLegacyStore else { return false }
        usingLegacyStore = true
        defaults.set(true, forKey: Self.backendDefaultsKey)
        secretStore = legacyStoreFactory()
        return true
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
        let hint = developmentHint.map { " \($0)" } ?? ""
        switch error {
        case SecretStoreError.accessDenied:
            return "Keychain access was denied. Unlock the login keychain (or choose Always Allow) and try again."
        case SecretStoreError.missingEntitlement:
            return "Keychain is unavailable in this build." + hint
        case SecretStoreError.unexpected(let status):
            return "Keychain error (\(status))." + hint
        default:
            return error.localizedDescription
        }
    }

    private static var developmentHint: String? {
        #if DEBUG
        return "For development you can set GEMINI_API_KEY in .env and launch with script/build_and_run.sh."
        #else
        return nil
        #endif
    }
}
