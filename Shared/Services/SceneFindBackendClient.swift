import CryptoKit
import DeviceCheck
import Foundation
import Security

struct BackendEntitlementState: Codable, Equatable, Sendable {
    enum Plan: String, Codable, CaseIterable, Sendable {
        case freeTrial
        case starter
        case pro
        case lifetime

        var name: String {
            switch self {
            case .freeTrial: "Free trial"
            case .starter: "Starter"
            case .pro: "Pro"
            case .lifetime: "Lifetime"
            }
        }
    }

    enum Status: String, Codable, Sendable {
        case active
        case gracePeriod
        case billingRetry
        case expired
        case revoked
        case refunded

        var label: String {
            switch self {
            case .active: "Active"
            case .gracePeriod: "Billing grace period"
            case .billingRetry: "Billing retry — access paused"
            case .expired: "Expired"
            case .revoked: "Revoked"
            case .refunded: "Refunded"
            }
        }
    }

    let plan: Plan
    let status: Status
    let allowance: Int
    let remaining: Int
    let periodStart: Date?
    let periodEnd: Date?
    let renewsAt: Date?
    let canAnalyze: Bool
    let lastSyncedAt: Date

    static let unavailable = BackendEntitlementState(
        plan: .freeTrial,
        status: .active,
        allowance: 2,
        remaining: 0,
        periodStart: nil,
        periodEnd: nil,
        renewsAt: nil,
        canAnalyze: false,
        lastSyncedAt: .distantPast
    )
}

enum SceneFindBackendError: LocalizedError, Equatable {
    case notConfigured
    case attestationUnavailable
    case invalidResponse
    case rejected(code: String, message: String)
    case streamEnded

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "SceneFind's secure analysis service is not configured in this build."
        case .attestationUnavailable:
            "This device could not verify SceneFind with the analysis service."
        case .invalidResponse:
            "SceneFind received an unreadable response from its analysis service."
        case .rejected(_, let message):
            message
        case .streamEnded:
            "The analysis connection ended before a result arrived."
        }
    }
}

final class SceneFindBackendClient: @unchecked Sendable {
    static let shared = SceneFindBackendClient()

    struct AnalysisStart: Decodable {
        let id: String
        let requestID: UUID
        let entitlement: BackendEntitlementState
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private struct ChallengeRequest: Encodable {
        let installationID: String
    }

    private struct RegistrationRequest: Encodable {
        let installationID: String
        let keyID: String
        let challenge: String
        let attestation: String
    }

    private struct ClientData: Encodable {
        let installationID: String
        let keyID: String
        let challenge: String
        let method: String
        let path: String
        let bodySHA256: String
        let timestampMs: Int64
    }

    private struct BackendErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: String
            let message: String
        }
        let error: Payload
    }

    private let session: URLSession
    private let endpointProvider: () -> URL?
    private let keychain: BackendKeychain
    private let appAttest: DCAppAttestService
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let registration = AppAttestRegistrationCoordinator()

    init(
        session: URLSession = .shared,
        endpointProvider: @escaping () -> URL? = SceneFindBackendClient.configuredEndpoint,
        keychain: BackendKeychain = BackendKeychain(),
        appAttest: DCAppAttestService = .shared
    ) {
        self.session = session
        self.endpointProvider = endpointProvider
        self.keychain = keychain
        self.appAttest = appAttest
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601DateFormatter.sceneFind.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
    }

    var installationUUID: UUID {
        if let value = keychain.string(for: .installationID), let id = UUID(uuidString: value) {
            return id
        }
        let value = UUID()
        _ = keychain.set(value.uuidString, for: .installationID)
        return value
    }

    func entitlement() async throws -> BackendEntitlementState {
        let request = try request(path: "v1/entitlement", method: "GET")
        return try await sendAuthorized(request, as: BackendEntitlementState.self)
    }

    func submit(signedTransaction: String) async throws -> BackendEntitlementState {
        struct Body: Encodable { let signedTransaction: String }
        var request = try request(path: "v1/storekit/transaction", method: "POST")
        request.httpBody = try encoder.encode(Body(signedTransaction: signedTransaction))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await sendAuthorized(request, as: BackendEntitlementState.self)
    }

    func startAnalysis(body: Data) async throws -> AnalysisStart {
        var request = try request(path: "v1/analysis", method: "POST")
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await sendAuthorized(request, as: AnalysisStart.self)
    }

    func analysisEvents(
        id: String,
        progress: @escaping (AnalysisProgressEvent) -> Void
    ) async throws -> ClipAnalysisResult {
        var request = try request(path: "v1/analysis/\(id)/events", method: "GET")
        request.timeoutInterval = 40
        request = try await authorized(request)
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response, data: nil)

        var eventName = "message"
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            if eventName == "error" {
                let code = (try? JSONDecoder().decode([String: String].self, from: data)["code"])
                    ?? "provider_unavailable"
                throw SceneFindBackendError.rejected(
                    code: code,
                    message: code == "not_found"
                        ? "No reliable match was found for this clip."
                        : "The analysis service was temporarily unavailable."
                )
            }
            eventName = "message"
            let event = try decoder.decode(AnalysisProgressEvent.self, from: data)
            if event.kind == .completed, let detail = event.detail?.data(using: .utf8) {
                return try decoder.decode(ClipAnalysisResult.self, from: detail)
            }
            progress(event)
        }
        throw SceneFindBackendError.streamEnded
    }

    func cancelAnalysis(id: String) async {
        guard var request = try? request(path: "v1/analysis/\(id)", method: "DELETE"),
              let authorized = try? await authorized(request) else { return }
        request = authorized
        _ = try? await session.data(for: request)
    }

    private func sendAuthorized<T: Decodable>(
        _ request: URLRequest,
        as type: T.Type
    ) async throws -> T {
        let authorizedRequest = try await authorized(request)
        let (data, response) = try await session.data(for: authorizedRequest)
        try validate(response: response, data: data)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SceneFindBackendError.invalidResponse
        }
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        let installationID = installationUUID.uuidString.lowercased()
        request.setValue(installationID, forHTTPHeaderField: "X-SceneFind-Install")
        guard appAttest.isSupported else {
            #if DEBUG && targetEnvironment(simulator)
            return request
            #else
            throw SceneFindBackendError.attestationUnavailable
            #endif
        }
        guard let keyID = try await registeredKeyID() else {
            throw SceneFindBackendError.attestationUnavailable
        }
        let challenge = try await fetchChallenge()
        let path = request.url?.path(percentEncoded: false) ?? "/"
        let clientData = ClientData(
            installationID: installationID,
            keyID: keyID,
            challenge: challenge,
            method: request.httpMethod ?? "GET",
            path: path,
            bodySHA256: Data(SHA256.hash(data: request.httpBody ?? Data())).base64URLEncodedString(),
            timestampMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let data = try encoder.encode(clientData)
        let assertion = try await appAttest.generateAssertion(
            keyID,
            clientDataHash: Data(SHA256.hash(data: data))
        )
        request.setValue(keyID, forHTTPHeaderField: "X-SceneFind-Key-ID")
        request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-SceneFind-Assertion")
        request.setValue(data.base64EncodedString(), forHTTPHeaderField: "X-SceneFind-Client-Data")
        return request
    }

    private func registeredKeyID() async throws -> String? {
        if let keyID = keychain.string(for: .appAttestKeyID), !keyID.isEmpty { return keyID }

        return try await registration.value { [weak self] in
            guard let self else { return nil }
            let challenge = try await fetchChallenge()
            let keyID = try await appAttest.generateKey()
            let attestation = try await appAttest.attestKey(
                keyID,
                clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8)))
            )
            var request = try request(path: "v1/attest/register", method: "POST")
            request.httpBody = try encoder.encode(RegistrationRequest(
                installationID: installationUUID.uuidString.lowercased(),
                keyID: keyID,
                challenge: challenge,
                attestation: attestation.base64EncodedString()
            ))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            guard keychain.set(keyID, for: .appAttestKeyID) else {
                throw SceneFindBackendError.attestationUnavailable
            }
            return keyID
        }
    }

    private func fetchChallenge() async throws -> String {
        var request = try request(path: "v1/attest/challenge", method: "POST")
        request.httpBody = try encoder.encode(ChallengeRequest(
            installationID: installationUUID.uuidString.lowercased()
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(ChallengeResponse.self, from: data).challenge
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let base = endpointProvider(),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https" else {
            throw SceneFindBackendError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let response = response as? HTTPURLResponse else {
            throw SceneFindBackendError.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            if let data,
               let envelope = try? decoder.decode(BackendErrorEnvelope.self, from: data) {
                throw SceneFindBackendError.rejected(
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw SceneFindBackendError.rejected(
                code: "http_\(response.statusCode)",
                message: "The analysis service returned an error."
            )
        }
    }

    private static func configuredEndpoint() -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SCENEFIND_BACKEND_URL") as? String,
              !value.contains("$("),
              var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https" else { return nil }
        if !components.path.hasSuffix("/") { components.path += "/" }
        return components.url
    }
}

private actor AppAttestRegistrationCoordinator {
    private var task: Task<String?, Error>?

    func value(
        start: @escaping @Sendable () async throws -> String?
    ) async throws -> String? {
        if let task {
            return try await task.value
        }
        let task = Task { try await start() }
        self.task = task
        defer { self.task = nil }
        return try await task.value
    }
}

struct BackendKeychain: Sendable {
    enum Key: String {
        case installationID = "installation-id.v1"
        case appAttestKeyID = "app-attest-key-id.v1"
    }

    private let service = "com.kavigandham.scenefind.backend"

    func string(for key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, for key: Key) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension ISO8601DateFormatter {
    static let sceneFind: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
