import Foundation
import Security

enum OpenAIConfiguration {
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

    private static let service = "com.example.SceneFind.openai"
    private static let account = "prototype-api-key"
    private static let modelKey = "openAIModel"
    private static let debugAPIKey = "debugOpenAIAPIKey"

    static var apiKey: String? {
        get {
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
            return UserDefaults.standard.string(forKey: debugAPIKey)
            #else
            return nil
            #endif
        }
        set {
            _ = saveAPIKey(newValue)
        }
    }

    @discardableResult
    static func saveAPIKey(_ rawValue: String?) -> SaveResult {
        SecItemDelete(baseQuery as CFDictionary)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugAPIKey)
        #endif

        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let data = value.data(using: .utf8) else {
            return .failed(errSecParam)
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return .keychain
        }

        #if DEBUG
        // Unsigned simulator builds can lack the application-identifier entitlement Keychain expects.
        UserDefaults.standard.set(value, forKey: debugAPIKey)
        return .debugLocalStorage
        #else
        return .failed(status)
        #endif
    }

    static var storageLocation: StorageLocation {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = false
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

    static var model: String {
        get {
            UserDefaults.standard.string(forKey: modelKey) ?? "gpt-5"
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(value.isEmpty ? "gpt-5" : value, forKey: modelKey)
        }
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
