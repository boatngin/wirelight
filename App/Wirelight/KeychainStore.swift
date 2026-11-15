import Foundation
import Security

/// Stores whole tunnel configs (they contain the private key) in the login keychain.
enum KeychainStore {
    static let service = "io.github.boatngin.wirelight"
    /// Service name used before the identifier rename; read once and migrated.
    static let legacyService = "com.thanaboat.wgbar"

    enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        var description: String {
            if case let .status(s) = self {
                return (SecCopyErrorMessageString(s, nil) as String?) ?? "keychain error \(s)"
            }
            return "keychain error"
        }
    }

    private static func baseQuery(_ account: String, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ text: String, account: String) throws {
        let data = Data(text.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Wirelight tunnel \(account)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func load(_ account: String) -> String? {
        if let text = read(account, service: service) { return text }
        // Move a config saved under the legacy service; keep the old item if the copy fails.
        guard let text = read(account, service: legacyService) else { return nil }
        if (try? save(text, account: account)) != nil {
            SecItemDelete(baseQuery(account, service: legacyService) as CFDictionary)
        }
        return text
    }

    private static func read(_ account: String, service: String) -> String? {
        var q = baseQuery(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
