import Foundation

enum MediaType: String, Codable, CaseIterable, Hashable {
    case movie
    case television
    case other

    init(apiValue: String) {
        switch apiValue.lowercased() {
        case "movie", "film": self = .movie
        case "tv", "television", "episode": self = .television
        default: self = .other
        }
    }
}

struct MediaTitle: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let mediaType: MediaType
    let releaseYear: Int
    let overview: String
    let posterAssetName: String?
    let streamingService: String?
    let episodes: [EpisodeRecord]
}

struct EpisodeRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String
    let runtimeSeconds: Int
    let subtitleSegments: [SubtitleSegment]
}

struct SubtitleSegment: Codable, Identifiable, Hashable {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

struct SubtitleMatch: Codable, Hashable {
    let mediaID: UUID
    let episodeID: UUID
    let segmentID: UUID
    let score: Double
    let matchedText: String
}

struct TranscriptionResult: Codable, Hashable {
    let text: String
    let confidence: Double
}

struct ExtractedFrame: Identifiable, Hashable {
    let id: UUID
    let timestamp: Double
    let imageURL: URL
}
