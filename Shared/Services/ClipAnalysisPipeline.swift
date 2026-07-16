import Foundation

protocol ClipIdentificationService {
    func identify(request: SharedClipRequest) async throws -> ClipAnalysisResult
}

final class HybridClipIdentificationService: ClipIdentificationService {
    private let metadataService: SocialClipMetadataService
    private let geminiService: GeminiClipIdentificationService

    init(
        metadataService: SocialClipMetadataService = OEmbedSocialClipMetadataService(),
        geminiService: GeminiClipIdentificationService = GeminiClipIdentificationService()
    ) {
        self.metadataService = metadataService
        self.geminiService = geminiService
    }

    func identify(request: SharedClipRequest) async throws -> ClipAnalysisResult {
        let start = Date()
        if let known = KnownClipCatalog.result(for: request) {
            return known
        }

        let metadata: SocialClipMetadata?
        if let url = request.originalURL {
            metadata = try? await metadataService.metadata(for: url)
            if let known = KnownClipCatalog.result(
                for: request,
                metadata: metadata,
                processingDuration: Date().timeIntervalSince(start)
            ) {
                return known
            }
        } else {
            metadata = nil
        }

        guard GeminiConfiguration.isConfigured else { throw SceneFindError.geminiKeyMissing }
        return try await geminiService.identify(request: request, metadata: metadata)
    }
}

final class MockClipIdentificationService: ClipIdentificationService {
    private let pipeline: ClipAnalysisPipeline

    init(pipeline: ClipAnalysisPipeline = ClipAnalysisPipeline()) {
        self.pipeline = pipeline
    }

    func identify(request: SharedClipRequest) async throws -> ClipAnalysisResult {
        try await pipeline.analyze(request: request)
    }
}

final class ClipAnalysisPipeline {
    private let library: [MediaTitle]
    private let subtitleEngine: SubtitleMatchingEngine
    private let transcriptionService: SpeechTranscriptionService
    private let videoService: VideoFrameExtractionService
    private let visualService: VisualMatchingService
    private let store: SharedContainerStore

    init(
        library: [MediaTitle] = MockMediaLibrary.titles,
        subtitleEngine: SubtitleMatchingEngine = SubtitleMatchingEngine(),
        transcriptionService: SpeechTranscriptionService = MockSpeechTranscriptionService(),
        videoService: VideoFrameExtractionService = VideoFrameExtractionService(),
        visualService: VisualMatchingService = MockVisualMatchingService(),
        store: SharedContainerStore = .shared
    ) {
        self.library = library
        self.subtitleEngine = subtitleEngine
        self.transcriptionService = transcriptionService
        self.videoService = videoService
        self.visualService = visualService
        self.store = store
    }

    func analyze(request: SharedClipRequest) async throws -> ClipAnalysisResult {
        let start = Date()
        guard request.sourceType != .unknown else { throw SceneFindError.unsupportedSharedItem }

        let videoURL = store.resolveFileURL(fileName: request.localFileName)
        let frames: [ExtractedFrame]
        if request.sourceType == .video, let videoURL {
            frames = try await videoService.extractFrames(from: videoURL)
        } else {
            frames = []
        }
        let transcription = try await transcriptionService.transcribe(request: request, videoURL: videoURL)
        let subtitleMatches = subtitleEngine.rankedMatches(query: transcription.text, library: library, limit: 12)

        var candidates = buildCandidates(request: request, subtitleMatches: subtitleMatches, detectedDialogue: transcription.text)
        if candidates.isEmpty {
            candidates = fallbackCandidates(request: request)
        }

        let visualScores = try await visualService.compare(requestID: request.id, frames: frames, candidates: candidates)
        let visualByID = Dictionary(uniqueKeysWithValues: visualScores.map { ($0.candidateID, $0.score) })

        let weighted = candidates.map { candidate in
            let visual = visualByID[candidate.id] ?? candidate.visualScore
            let noDialogue = transcription.text.split(separator: " ").count < 3
            let confidence = noDialogue
                ? candidate.subtitleScore * 0.20 + visual * 0.50 + candidate.metadataScore * 0.30
                : candidate.subtitleScore * 0.60 + visual * 0.25 + candidate.metadataScore * 0.15
            return SceneCandidate(
                id: candidate.id,
                mediaTitle: candidate.mediaTitle,
                mediaType: candidate.mediaType,
                releaseYear: candidate.releaseYear,
                seasonNumber: candidate.seasonNumber,
                episodeNumber: candidate.episodeNumber,
                episodeTitle: candidate.episodeTitle,
                sceneTimestampSeconds: candidate.sceneTimestampSeconds,
                matchedSubtitleText: candidate.matchedSubtitleText,
                confidence: min(0.98, max(0.08, confidence)),
                subtitleScore: candidate.subtitleScore,
                visualScore: visual,
                metadataScore: candidate.metadataScore,
                streamingService: candidate.streamingService,
                streamingURL: candidate.streamingURL
            )
        }.sorted { $0.confidence > $1.confidence }

        guard let top = weighted.first, top.confidence > 0.18 else { throw SceneFindError.noLikelyMatch }

        return ClipAnalysisResult(
            id: UUID(),
            requestID: request.id,
            createdAt: Date(),
            detectedDialogue: transcription.text,
            topCandidate: top,
            alternativeCandidates: Array(weighted.dropFirst().prefix(5)),
            analysisDetails: AnalysisDetails(
                sourcePlatform: request.sourcePlatform,
                sourceType: request.sourceType,
                extractedFrameCount: frames.count,
                subtitleCandidatesCompared: library.flatMap(\.episodes).flatMap(\.subtitleSegments).count,
                totalProcessingDuration: Date().timeIntervalSince(start)
            )
        )
    }

    private func buildCandidates(request: SharedClipRequest, subtitleMatches: [SubtitleMatch], detectedDialogue: String) -> [SceneCandidate] {
        subtitleMatches.compactMap { match in
            guard let title = library.first(where: { $0.id == match.mediaID }),
                  let episode = title.episodes.first(where: { $0.id == match.episodeID }),
                  let segment = episode.subtitleSegments.first(where: { $0.id == match.segmentID }) else {
                return nil
            }
            let metadata = metadataScore(request: request, title: title, episode: episode)
            return SceneCandidate(
                id: MockMediaLibrary.stableID("\(match.mediaID)-\(match.episodeID)-\(match.segmentID)"),
                mediaTitle: title.title,
                mediaType: title.mediaType,
                releaseYear: title.releaseYear,
                seasonNumber: title.mediaType == .movie ? nil : episode.seasonNumber,
                episodeNumber: title.mediaType == .movie ? nil : episode.episodeNumber,
                episodeTitle: title.mediaType == .movie ? nil : episode.title,
                sceneTimestampSeconds: segment.startSeconds,
                matchedSubtitleText: match.matchedText,
                confidence: 0,
                subtitleScore: match.score,
                visualScore: 0.48,
                metadataScore: metadata,
                streamingService: title.streamingService,
                streamingURL: nil
            )
        }
    }

    private func fallbackCandidates(request: SharedClipRequest) -> [SceneCandidate] {
        library
            .map { title in (title, metadataScore(request: request, title: title, episode: title.episodes[0])) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { title, score in
                let episode = title.episodes[0]
                let segment = episode.subtitleSegments[0]
                return SceneCandidate(
                    id: MockMediaLibrary.stableID("fallback-\(request.id)-\(title.id)"),
                    mediaTitle: title.title,
                    mediaType: title.mediaType,
                    releaseYear: title.releaseYear,
                    seasonNumber: title.mediaType == .movie ? nil : episode.seasonNumber,
                    episodeNumber: title.mediaType == .movie ? nil : episode.episodeNumber,
                    episodeTitle: title.mediaType == .movie ? nil : episode.title,
                    sceneTimestampSeconds: segment.startSeconds,
                    matchedSubtitleText: segment.text,
                    confidence: 0,
                    subtitleScore: 0.18,
                    visualScore: 0.45,
                    metadataScore: max(0.20, score),
                    streamingService: title.streamingService,
                    streamingURL: nil
                )
            }
    }

    private func metadataScore(request: SharedClipRequest, title: MediaTitle, episode: EpisodeRecord) -> Double {
        let text = [
            request.originalURL?.absoluteString,
            request.sharedText,
            request.pageTitle,
            request.localFileName
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !text.isEmpty else {
            return 0.30 + Double(abs("\(request.id)-\(title.id)".hashValue % 20)) / 100.0
        }

        var score = 0.20
        let titleTokens = title.title.lowercased().split(separator: " ").map(String.init)
        for token in titleTokens where text.contains(token) {
            score += 0.20
        }
        for word in title.overview.lowercased().split(separator: " ") where word.count > 5 && text.contains(word) {
            score += 0.08
        }
        if text.contains(episode.title.lowercased()) {
            score += 0.18
        }
        if request.sourcePlatform == .youtube || request.sourcePlatform == .tiktok {
            score += 0.04
        }
        if text.contains("no-match") || text.contains("nomatch") {
            score = 0.05
        }
        return min(1, score)
    }
}
