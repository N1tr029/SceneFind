import Foundation

enum ClipIdentificationServiceFactory {
    static func makeDefault() -> ClipIdentificationService {
        #if DEBUG || SCENEFIND_TESTFLIGHT
        HybridClipIdentificationService()
        #else
        BackendClipIdentificationService()
        #endif
    }
}

final class BackendClipIdentificationService: ClipIdentificationService {
    private struct RequestBody: Encodable {
        let request: SharedClipRequest
    }

    private let session: URLSession
    private let endpointProvider: () -> URL?

    init(
        session: URLSession = .shared,
        endpointProvider: @escaping () -> URL? = {
            (Bundle.main.object(forInfoDictionaryKey: "SCENEFIND_BACKEND_URL") as? String)
                .flatMap(URL.init(string:))
        }
    ) {
        self.session = session
        self.endpointProvider = endpointProvider
    }

    func identify(request sharedRequest: SharedClipRequest) async throws -> ClipAnalysisResult {
        guard let baseURL = endpointProvider(),
              baseURL.scheme?.lowercased() == "https",
              let endpoint = URL(string: "v1/analysis/synchronous", relativeTo: baseURL)?.absoluteURL else {
            throw SceneFindError.productionBackendUnavailable
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(request: sharedRequest))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SceneFindError.analysisFailed
        }
        return try JSONDecoder().decode(ClipAnalysisResult.self, from: data)
    }
}
