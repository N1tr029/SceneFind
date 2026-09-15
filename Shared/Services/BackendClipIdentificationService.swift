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
        let body = try await requestBody(for: sharedRequest)
        let start: SceneFindBackendClient.AnalysisStart
        do {
            start = try await client.startAnalysis(body: encoder.encode(body))
        } catch let error as SceneFindBackendError {
            throw map(error)
        }

        return try await withTaskCancellationHandler {
            try await follow(analysisID: start.id, progress: progress)
        } onCancel: {
            Task { await self.client.cancelAnalysis(id: start.id) }
        }
    }

    /// Follows a started analysis to its result.
    ///
    /// The server keeps running no matter what happens to this connection, and
    /// it holds the user's credit while it runs. Treating a dropped or timed-out
    /// stream as a failure let the server finish and charge for a result the
    /// user never saw. So the stream is reopened instead, and the server replays
    /// every event and the result. Only the server's own verdict ends the run
    /// early. If the stream can't be recovered, the run is cancelled so the held
    /// credit is released before the error reaches the screen.
    private func follow(
        analysisID: String,
        progress: @escaping (AnalysisProgressEvent) -> Void
    ) async throws -> ClipAnalysisResult {
        let delivered = DeliveredEvents()
        var reconnects = 0
        while true {
            do {
                return try await client.analysisEvents(id: analysisID) { event in
                    // A reopened stream replays the backlog; show each step once.
                    if delivered.insert(event.id) { progress(event) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SceneFindBackendError where Self.isVerdict(error) {
                throw map(error)
            } catch {
                try Task.checkCancellation()
                reconnects += 1
                guard reconnects <= Self.maximumReconnects else {
                    await client.cancelAnalysis(id: analysisID)
                    if let backendError = error as? SceneFindBackendError {
                        throw map(backendError)
                    }
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(reconnects) * 1_500_000_000)
            }
        }
    }

    private static let maximumReconnects = 4

    /// The server decided the outcome, such as no match, a provider outage, a
    /// run that no longer exists, or no allowance left. Reconnecting can't
    /// change that. Auth, rate-limit and server errors are transient and worth
    /// another try.
    private static func isVerdict(_ error: SceneFindBackendError) -> Bool {
        guard case .rejected(let code, _) = error else { return false }
        let transient: Set<String> = ["unauthorized", "attestation_required", "rate_limited", "internal"]
        return !transient.contains(code) && !code.hasPrefix("http_5")
    }

    private func requestBody(for request: SharedClipRequest) async throws -> RequestBody {
        let storedURL = store.resolveFileURL(fileName: request.localFileName)
        // Videos are re-encoded to fit the upload limit; the temporary copy is
        // read into memory below and removed before this returns.
        var fileURL = storedURL
        if let storedURL, Self.isVideo(storedURL) {
            fileURL = try await VideoCompressor.uploadableVideo(from: storedURL)
        }
        defer {
            if let fileURL, fileURL != storedURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        let fileData: Data?
        if let fileURL {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= VideoCompressor.backendLimitBytes else {
                throw SceneFindError.mediaTooLarge
            }
            fileData = try Data(contentsOf: fileURL)
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

    private static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
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

/// Event IDs already shown for one analysis, so a reconnect's replayed backlog
/// doesn't duplicate steps in the progress timeline.
private final class DeliveredEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<UUID>()

    func insert(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.insert(id).inserted
    }
}
