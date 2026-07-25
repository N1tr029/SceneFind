import Foundation
import Security

/// Optional search-API key used to find real episode pages on streaming services.
///
/// Provider content ids (Apple TV's `umc.cmc…`, Peacock's episode UUID) can't be
/// derived from a title, but they are indexed in public search results. Reading
/// them keylessly works only intermittently — DuckDuckGo's HTML endpoint answered
/// one request then bot-challenged the next two — so a key makes the "open in
/// <service>" button dependable instead of occasional.
///
/// Without a key SceneFind still works: it falls back to the keyless attempt and
/// then to the service's own search page. Nothing here is required.
enum WebSearchConfiguration {
    /// Which search service a key belongs to, decided by its shape.
    ///
    /// One Settings field is friendlier than making someone pick a provider from
    /// a menu, and these two key formats cannot be confused: Brave issues keys
    /// prefixed `BSA`, SerpApi issues 64 hexadecimal characters.
    enum Provider: Equatable {
        case brave
        case serpAPI

        var label: String {
            switch self {
            case .brave: "Brave Search"
            case .serpAPI: "SerpApi"
            }
        }
    }

    static func provider(for key: String) -> Provider? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("BSA") { return .brave }
        if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) { return .serpAPI }
        return nil
    }

    /// The configured key and the service it belongs to, when both are known.
    static var credentials: (key: String, provider: Provider)? {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              let provider = provider(for: key) else { return nil }
        return (key, provider)
    }

    private static let service = "com.example.SceneFind.websearch"
    private static let account = "episode-link-search-api-key"
    private static let debugAPIKey = "debugWebSearchAPIKey.v1"

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
        return bundledAPIKey
    }

    @discardableResult
    static func saveAPIKey(_ rawValue: String?) -> Bool {
        clearAPIKey()
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let data = value.data(using: .utf8) else { return false }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return true }

        #if DEBUG
        UserDefaults.standard.set(value, forKey: debugAPIKey)
        return true
        #else
        return false
        #endif
    }

    static func clearAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugAPIKey)
        #endif
    }

    static var isConfigured: Bool { apiKey?.isEmpty == false }

    private static var bundledAPIKey: String? {
        guard let url = Bundle.main.url(forResource: "PrototypeSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        // `SearchAPIKey` is the provider-neutral name; the Brave-specific one is
        // still read so an existing secrets file keeps working.
        for key in ["SearchAPIKey", "BraveSearchAPIKey"] {
            guard let value = values[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
