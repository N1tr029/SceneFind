import Foundation
import Security

enum DeepSeekConfiguration {
    enum SaveResult: Equatable {
        case keychain
        case debugLocalStorage
        case failed(OSStatus)
    }

    enum StorageLocation: Equatable {
        case keychain
        case debugLocalStorage
        case none
    }

    static let model = "deepseek-v4-flash"

    private static let service = "com.example.SceneFind.deepseek"
    private static let account = "episode-verification-api-key"
    private static let debugAPIKey = "debugDeepSeekAPIKey.v1"

    static var apiKey: String? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }

        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: debugAPIKey), !value.isEmpty {
            return value
        }
        #endif
        return nil
    }

    @discardableResult
    static func saveAPIKey(_ rawValue: String?) -> SaveResult {
        clearAPIKey()
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let data = value.data(using: .utf8) else {
            return .failed(errSecParam)
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return .keychain }

        #if DEBUG
        UserDefaults.standard.set(value, forKey: debugAPIKey)
        return .debugLocalStorage
        #else
        return .failed(status)
        #endif
    }

    static var storageLocation: StorageLocation {
        var query: [String: Any] = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return .keychain
        }
        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: debugAPIKey), !value.isEmpty {
            return .debugLocalStorage
        }
        #endif
        return .none
    }

    static func clearAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugAPIKey)
        #endif
    }

    static var isConfigured: Bool { apiKey != nil }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
