import Foundation
import Security

public protocol PasswordStoring: Sendable {
    func save(_ password: Password) throws
    func load() throws -> Password?
    func delete() throws
}

public enum PasswordStoreError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case corruptedEntry

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "キーチェーンの操作に失敗しました: \(detail)"
        case .corruptedEntry:
            return "キーチェーンに保存されたパスワードを読み取れませんでした。"
        }
    }
}

/// Stores the pre-configured password in the login keychain.
///
/// Nothing is written unless the user explicitly asks for it — the password otherwise
/// lives only in memory for the session, and never in `UserDefaults` or any plist.
public struct KeychainPasswordStore: PasswordStoring {
    public static let defaultService = "com.local.sevenzip-compressor.default-password"

    private let service: String
    private let account: String

    public init(service: String = KeychainPasswordStore.defaultService, account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ password: Password) throws {
        let data = Data(password.value.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // Available only while the device is unlocked, and never synced to iCloud.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw PasswordStoreError.keychain(updateStatus) }
        default:
            throw PasswordStoreError.keychain(status)
        }
    }

    public func load() throws -> Password? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
                throw PasswordStoreError.corruptedEntry
            }
            // A stored value could have been edited outside the app, so it is re-validated.
            guard let password = try? Password(text) else { throw PasswordStoreError.corruptedEntry }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw PasswordStoreError.keychain(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }
    }
}
