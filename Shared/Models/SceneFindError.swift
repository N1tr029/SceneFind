import Foundation

enum SceneFindError: LocalizedError {
    case unsupportedSharedItem
    case sharedFileMissing
    case invalidURL
    case thumbnailFailed
    case analysisFailed
    case noLikelyMatch
    case permissionDenied
    case requestExpired
    case appGroupUnavailable
    case requestNotFound
    case openAIKeyMissing
    case openAIAuthenticationFailed
    case openAIQuotaExceeded
    case openAIInvalidResponse
    case openAIRequestFailed(String)
    case geminiKeyMissing
    case geminiAuthenticationFailed
    case geminiFreeTierLimitReached
    case geminiCreditsDepleted
    case geminiServiceBusy
    case geminiRequestTimedOut
    case directVideoUnavailable
    case geminiInvalidResponse
    case geminiRequestFailed(String)
    case productionBackendUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedSharedItem: "SceneFind could not read that shared item."
        case .sharedFileMissing: "The shared file is no longer available."
        case .invalidURL: "Enter a valid link to analyze."
        case .thumbnailFailed: "SceneFind could not create a thumbnail."
        case .analysisFailed: "Analysis failed. Try another clip."
        case .noLikelyMatch: "SceneFind could not find a likely match."
        case .permissionDenied: "SceneFind does not have permission to read that item."
        case .requestExpired: "That shared request has expired."
        case .appGroupUnavailable: "The shared SceneFind container is unavailable."
        case .requestNotFound: "SceneFind could not find that request."
        case .openAIKeyMissing: "Add your OpenAI API key in Settings to identify new links."
        case .openAIAuthenticationFailed: "OpenAI rejected this API key. Check the key in Settings and try again."
        case .openAIQuotaExceeded: "This OpenAI API account has no available quota. Add API billing or credits, then try again."
        case .openAIInvalidResponse: "OpenAI returned a result SceneFind could not read. Try again."
        case .openAIRequestFailed(let message): "OpenAI request failed: \(message)"
        case .geminiKeyMissing: "Add your free Gemini API key in Settings to identify new links."
        case .geminiAuthenticationFailed: "Gemini rejected this API key. Check the key in Settings and try again."
        case .geminiFreeTierLimitReached: "The Gemini free-tier limit has been reached. Try again after the limit resets."
        case .geminiCreditsDepleted: "This Gemini key belongs to a project with depleted prepaid credits. Replace it with a key from a free-tier AI Studio project or add credits."
        case .geminiServiceBusy: "Gemini is temporarily busy. SceneFind tried the available fallback models; wait a moment and try again."
        case .geminiRequestTimedOut: "Gemini took too long to analyze this video. Try again or use a shorter public clip."
        case .directVideoUnavailable: "SceneFind could not read the TikTok video itself, so it stopped instead of guessing from its caption. Try again or import the clip."
        case .geminiInvalidResponse: "Gemini answered, but SceneFind could not finish reading the result. Try again."
        case .geminiRequestFailed(let message): "Gemini request failed: \(message)"
        case .productionBackendUnavailable: "SceneFind's production analysis service is not configured in this build."
        }
    }

    var failureTitle: String {
        switch self {
        case .noLikelyMatch: "No likely match"
        case .openAIKeyMissing: "Setup needed"
        case .openAIAuthenticationFailed: "API key rejected"
        case .openAIQuotaExceeded: "API billing required"
        case .openAIInvalidResponse, .openAIRequestFailed: "OpenAI unavailable"
        case .geminiKeyMissing: "Setup needed"
        case .geminiAuthenticationFailed: "Gemini key rejected"
        case .geminiFreeTierLimitReached: "Free-tier limit reached"
        case .geminiCreditsDepleted: "Gemini project needs credits"
        case .geminiServiceBusy: "Gemini is busy"
        case .geminiRequestTimedOut: "Video analysis timed out"
        case .directVideoUnavailable: "Video unavailable"
        case .geminiInvalidResponse: "Couldn't read the result"
        case .geminiRequestFailed: "Gemini unavailable"
        case .productionBackendUnavailable: "Service unavailable"
        default: "Analysis failed"
        }
    }
}
