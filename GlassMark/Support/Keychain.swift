import Foundation
import Security

enum SecretStoreError: Error, Equatable {
    case accessDenied
    case missingEntitlement
    case unexpected(OSStatus)
}

extension SecretStoreError {
    /// True when the Data Protection keychain is unusable in this build and the
    /// legacy keychain should be tried instead.
    var isEntitlementIssue: Bool {
        switch self {
        case .missingEntitlement:
            return true
        case .unexpected(let status):
            return status == errSecParam
        case .accessDenied:
            return false
        }
    }
}

/// Storage abstraction so credential logic can be tested without touching the
/// real keychain.
protocol SecretStoring: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, account: String) throws
    func removeSecret(account: String) throws
}

/// Keychain-backed secret storage. Tries the Data Protection keychain first
/// (the modern API); callers can fall back to the legacy keychain for builds
/// whose signing does not support it.
struct KeychainSecretStore: SecretStoring {
    let service: String
    let useDataProtection: Bool

    init(service: String = "com.recurse.glassmark", useDataProtection: Bool = true) {
        self.service = service
        self.useDataProtection = useDataProtection
    }

    func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.unexpected(status)
            }
            return secret
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw SecretStoreError.accessDenied
        case errSecMissingEntitlement:
            throw SecretStoreError.missingEntitlement
        default:
            throw SecretStoreError.unexpected(status)
        }
    }

    func setSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw map(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw map(addStatus) }
    }

    func removeSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw map(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func map(_ status: OSStatus) -> SecretStoreError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return .accessDenied
        case errSecMissingEntitlement:
            return .missingEntitlement
        default:
            return .unexpected(status)
        }
    }
}
