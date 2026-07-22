import Foundation

enum AnalysisProgressKind: String, Codable, Hashable, Sendable {
    case requestRead
    case metadataRetrieved
    case mediaRetrieved
    case mediaAnalysisStarted
    case dialogueDetected
    case showIdentified
    case episodeCandidatesFound
    case episodeVerified
    case episodeUnverified
    case providersChecked
    case artworkRetrieved
    case completed
}

struct AnalysisProgressEvent: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: AnalysisProgressKind
    let title: String
    let detail: String?
    let elapsedSeconds: Double

    init(
        id: UUID = UUID(),
        kind: AnalysisProgressKind,
        title: String,
        detail: String? = nil,
        elapsedSeconds: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.elapsedSeconds = elapsedSeconds
    }

    func stamped(elapsedSeconds: Double) -> AnalysisProgressEvent {
        AnalysisProgressEvent(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            elapsedSeconds: elapsedSeconds
        )
    }
}

struct AnalysisStageTiming: Codable, Hashable, Sendable {
    let stage: AnalysisProgressKind
    let durationSeconds: Double
}

struct ClipAnalysisResult: Codable, Identifiable, Hashable {
    let id: UUID
    let requestID: UUID
    let createdAt: Date
    let detectedDialogue: String
    let topCandidate: SceneCandidate
    let alternativeCandidates: [SceneCandidate]
    let analysisDetails: AnalysisDetails
}

struct SceneCandidate: Codable, Identifiable, Hashable {
    let id: UUID
    let mediaTitle: String
    let mediaType: MediaType
    let releaseYear: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
    let sceneTimestampSeconds: Double?
    let clipEndTimestampSeconds: Double?
    let matchedSubtitleText: String?
    let confidence: Double
    let subtitleScore: Double
    let visualScore: Double
    let metadataScore: Double
    let streamingService: String?
    let streamingURL: URL?
    let heroImageURL: URL?
    let watchProviders: [WatchProvider]?

    init(
        id: UUID,
        mediaTitle: String,
        mediaType: MediaType,
        releaseYear: Int,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeTitle: String?,
        sceneTimestampSeconds: Double?,
        clipEndTimestampSeconds: Double? = nil,
        matchedSubtitleText: String?,
        confidence: Double,
        subtitleScore: Double,
        visualScore: Double,
        metadataScore: Double,
        streamingService: String?,
        streamingURL: URL?,
        heroImageURL: URL? = nil,
        watchProviders: [WatchProvider]? = nil
    ) {
        self.id = id
        self.mediaTitle = mediaTitle
        self.mediaType = mediaType
        self.releaseYear = releaseYear
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.sceneTimestampSeconds = sceneTimestampSeconds
        self.clipEndTimestampSeconds = clipEndTimestampSeconds
        self.matchedSubtitleText = matchedSubtitleText
        self.confidence = confidence
        self.subtitleScore = subtitleScore
        self.visualScore = visualScore
        self.metadataScore = metadataScore
        self.streamingService = streamingService
        self.streamingURL = streamingURL
        self.heroImageURL = heroImageURL
        self.watchProviders = watchProviders
    }

    var episodeLine: String {
        switch mediaType {
        case .television:
            guard let seasonNumber, let episodeNumber else { return "TV episode" }
            return "S\(seasonNumber) E\(episodeNumber)"
        case .movie:
            return "Feature film"
        case .other:
            return "Online media"
        }
    }

    var confidenceLabel: String {
        if confidence >= 0.85 { return "High confidence" }
        if confidence >= 0.60 { return "Medium confidence" }
        return "Low confidence"
    }
}

struct WatchProvider: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let offer: String
    let episodeURL: URL
    let sceneURL: URL?
    let symbolName: String
    let brandColorHex: String
    let destinationLevel: StreamingDestinationLevel?
    let destinationDiagnostic: String?

    init(
        id: String,
        name: String,
        offer: String,
        episodeURL: URL,
        sceneURL: URL?,
        symbolName: String,
        brandColorHex: String,
        destinationLevel: StreamingDestinationLevel? = nil,
        destinationDiagnostic: String? = nil
    ) {
        self.id = id
        self.name = name
        self.offer = offer
        self.episodeURL = episodeURL
        self.sceneURL = sceneURL
        self.symbolName = symbolName
        self.brandColorHex = brandColorHex
        self.destinationLevel = destinationLevel
        self.destinationDiagnostic = destinationDiagnostic
    }

    var supportsSceneDeepLink: Bool { sceneURL != nil }
}

enum StreamingDestinationLevel: String, Codable, Hashable {
    case exactEpisode
    case show
    case search

    var actionLabel: String {
        switch self {
        case .exactEpisode: "Watch episode"
        case .show: "Open show"
        case .search: "Search"
        }
    }
}

enum WatchStartChoice: String, Hashable {
    case beginning
    case afterClip
}

struct AnalysisDetails: Codable, Hashable {
    let sourcePlatform: SharedPlatform
    let sourceType: SharedSourceType
    let extractedFrameCount: Int
    let subtitleCandidatesCompared: Int
    let totalProcessingDuration: Double
    let directMediaAnalyzed: Bool?
    let visualEvidence: [String]?
    let episodeVerificationEvidence: String?
    let progressEvents: [AnalysisProgressEvent]?
    let stageTimings: [AnalysisStageTiming]?

    init(
        sourcePlatform: SharedPlatform,
        sourceType: SharedSourceType,
        extractedFrameCount: Int,
        subtitleCandidatesCompared: Int,
        totalProcessingDuration: Double,
        directMediaAnalyzed: Bool? = nil,
        visualEvidence: [String]? = nil,
        episodeVerificationEvidence: String? = nil,
        progressEvents: [AnalysisProgressEvent]? = nil,
        stageTimings: [AnalysisStageTiming]? = nil
    ) {
        self.sourcePlatform = sourcePlatform
        self.sourceType = sourceType
        self.extractedFrameCount = extractedFrameCount
        self.subtitleCandidatesCompared = subtitleCandidatesCompared
        self.totalProcessingDuration = totalProcessingDuration
        self.directMediaAnalyzed = directMediaAnalyzed
        self.visualEvidence = visualEvidence
        self.episodeVerificationEvidence = episodeVerificationEvidence
        self.progressEvents = progressEvents
        self.stageTimings = stageTimings
    }
}

extension ClipAnalysisResult {
    func recordingProgress(
        _ events: [AnalysisProgressEvent],
        totalDuration: Double
    ) -> ClipAnalysisResult {
        let timings = zip(events, events.dropFirst()).map { current, next in
            AnalysisStageTiming(
                stage: current.kind,
                durationSeconds: max(0, next.elapsedSeconds - current.elapsedSeconds)
            )
        }
        let details = AnalysisDetails(
            sourcePlatform: analysisDetails.sourcePlatform,
            sourceType: analysisDetails.sourceType,
            extractedFrameCount: analysisDetails.extractedFrameCount,
            subtitleCandidatesCompared: analysisDetails.subtitleCandidatesCompared,
            totalProcessingDuration: totalDuration,
            directMediaAnalyzed: analysisDetails.directMediaAnalyzed,
            visualEvidence: analysisDetails.visualEvidence,
            episodeVerificationEvidence: analysisDetails.episodeVerificationEvidence,
            progressEvents: events,
            stageTimings: timings
        )
        return ClipAnalysisResult(
            id: id,
            requestID: requestID,
            createdAt: createdAt,
            detectedDialogue: detectedDialogue,
            topCandidate: topCandidate,
            alternativeCandidates: alternativeCandidates,
            analysisDetails: details
        )
    }
}

struct VisualMatchScore: Codable, Hashable {
    let candidateID: UUID
    let score: Double
}
