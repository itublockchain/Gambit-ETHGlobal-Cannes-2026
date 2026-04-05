import Foundation
import Security

/// Minimal Keychain wrapper for storing JWT tokens.
enum KeychainService {
    private static let service = "com.gambit.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Delete existing
        SecItemDelete(query as CFDictionary)

        // Add new
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // Convenience keys — use UserDefaults as fallback for simulator compatibility
    static var sessionToken: String? {
        get {
            load(key: "sessionToken") ?? UserDefaults.standard.string(forKey: "gambit_sessionToken")
        }
        set {
            if let value = newValue {
                save(key: "sessionToken", value: value)
                UserDefaults.standard.set(value, forKey: "gambit_sessionToken")
            } else {
                delete(key: "sessionToken")
                UserDefaults.standard.removeObject(forKey: "gambit_sessionToken")
            }
        }
    }

    static var userId: String? {
        get {
            load(key: "userId") ?? UserDefaults.standard.string(forKey: "gambit_userId")
        }
        set {
            if let value = newValue {
                save(key: "userId", value: value)
                UserDefaults.standard.set(value, forKey: "gambit_userId")
            } else {
                delete(key: "userId")
                UserDefaults.standard.removeObject(forKey: "gambit_userId")
            }
        }
    }
}
