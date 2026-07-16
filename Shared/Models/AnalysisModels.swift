import Foundation

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

    var supportsSceneDeepLink: Bool { sceneURL != nil }
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
}

struct VisualMatchScore: Codable, Hashable {
    let candidateID: UUID
    let score: Double
}
