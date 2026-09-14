import Foundation
import Security

/// Stores ssh passwords in the login keychain (one generic-password item per host profile).
enum KeychainStore {
    static let service = "com.yterm.ssh-password"
    /// Service name used before the app was renamed; items are moved over on first read.
    static let legacyService = "com.rsync-enhance.ssh-password"

    static func save(password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = "YTerm SSH 密碼"
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw AppError.general("無法寫入鑰匙圈：\(message)")
        }
    }

    static func load(account: String) -> String? {
        if let password = load(account: account, service: service) { return password }
        guard let legacy = load(account: account, service: legacyService) else { return nil }
        if (try? save(password: legacy, account: account)) != nil {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: account] as CFDictionary)
        }
        return legacy
    }

    private static func load(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
