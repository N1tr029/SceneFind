import Foundation
import Security

enum GeminiConfiguration {
    enum SaveResult: Equatable {
        case keychain
        case debugLocalStorage
        case failed(OSStatus)
    }

    enum StorageLocation: Equatable {
        case keychain
        case debugLocalStorage
        case bundledDefault
        case none
    }

    private static let service = "com.example.SceneFind.gemini"
    private static let account = "prototype-api-key-v2"
    private static let modelKey = "geminiModel"
    private static let debugAPIKey = "debugGeminiAPIKey.v2"

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
            if let value = UserDefaults.standard.string(forKey: debugAPIKey), !value.isEmpty {
                return value
            }
            #endif
            return bundledAPIKey
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
        if bundledAPIKey != nil {
            return .bundledDefault
        }
        return .none
    }

    static func clearCustomAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugAPIKey)
        #endif
    }

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)
            let resolved = supportedModel(stored ?? "gemini-3.5-flash")
            if stored != nil, stored != resolved {
                UserDefaults.standard.set(resolved, forKey: modelKey)
            }
            return resolved
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(supportedModel(value), forKey: modelKey)
        }
    }

    static func supportedModel(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "", "gemini-2.5-flash-lite", "gemini-2.5-flash":
            return "gemini-3.5-flash"
        default:
            return value
        }
    }

    static var isConfigured: Bool { apiKey != nil }

    private static var bundledAPIKey: String? {
        guard let url = Bundle.main.url(forResource: "PrototypeSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = values["GeminiAPIKey"] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
