import Foundation
import UniformTypeIdentifiers

enum ClipIdentificationServiceFactory {
    static func makeDefault() -> ClipIdentificationService {
        #if DEBUG
        HybridClipIdentificationService()
        #else
        BackendClipIdentificationService()
        #endif
    }
}

final class BackendClipIdentificationService: ProgressReportingClipIdentificationService {
    private struct RequestBody: Encodable {
        let sourceURL: String?
        let sourceType: String
        let sourceText: String?
        let sourceDataBase64: String?
        let sourceMimeType: String?
        let platformHint: String
        let region: String
        let idempotencyKey: String
    }

    private let client: SceneFindBackendClient
    private let store: SharedContainerStore
    private let encoder = JSONEncoder()

    init(
        client: SceneFindBackendClient = .shared,
        store: SharedContainerStore = .shared
    ) {
        self.client = client
        self.store = store
    }

    func identify(request: SharedClipRequest) async throws -> ClipAnalysisResult {
        try await identify(request: request, progress: { _ in })
    }

    func identify(
        request sharedRequest: SharedClipRequest,
        progress: @escaping (AnalysisProgressEvent) -> Void
    ) async throws -> ClipAnalysisResult {
        let body = try requestBody(for: sharedRequest)
        let start: SceneFindBackendClient.AnalysisStart
        do {
            start = try await client.startAnalysis(body: encoder.encode(body))
        } catch let error as SceneFindBackendError {
            throw map(error)
        }

        return try await withTaskCancellationHandler {
            do {
                return try await client.analysisEvents(id: start.id, progress: progress)
            } catch let error as SceneFindBackendError {
                throw map(error)
            }
        } onCancel: {
            Task { await self.client.cancelAnalysis(id: start.id) }
        }
    }

    private func requestBody(for request: SharedClipRequest) throws -> RequestBody {
        let fileURL = store.resolveFileURL(fileName: request.localFileName)
        let fileData: Data?
        if let fileURL {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 8_000_000 else {
                throw SceneFindError.mediaTooLarge
            }
            fileData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } else {
            fileData = nil
        }

        let mimeType: String?
        if let fileURL,
           let type = UTType(filenameExtension: fileURL.pathExtension),
           let preferred = type.preferredMIMEType {
            mimeType = preferred
        } else {
            mimeType = nil
        }
        let text = [request.sharedText, request.pageTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return RequestBody(
            sourceURL: request.originalURL?.absoluteString,
            sourceType: request.sourceType.rawValue,
            sourceText: request.originalURL == nil && fileData == nil && !text.isEmpty ? text : nil,
            sourceDataBase64: fileData?.base64EncodedString(),
            sourceMimeType: mimeType,
            platformHint: request.sourcePlatform.rawValue,
            region: Locale.current.region?.identifier ?? "US",
            idempotencyKey: request.id.uuidString.lowercased()
        )
    }

    private func map(_ error: SceneFindBackendError) -> SceneFindError {
        switch error {
        case .rejected(let code, _):
            switch code {
            case "entitlement_exhausted": .identificationAllowanceExhausted
            case "not_found": .noLikelyMatch
            case "rate_limited": .analysisRateLimited
            case "attestation_required", "unauthorized": .deviceVerificationFailed
            default: .productionBackendUnavailable
            }
        case .attestationUnavailable:
            .deviceVerificationFailed
        case .notConfigured:
            .productionBackendUnavailable
        case .invalidResponse, .streamEnded:
            .analysisFailed
        }
    }
}
