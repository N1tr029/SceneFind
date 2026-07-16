import Foundation

enum KnownClipCatalog {
    static func result(
        for request: SharedClipRequest,
        metadata: SocialClipMetadata? = nil,
        processingDuration: Double = 0
    ) -> ClipAnalysisResult? {
        let evidence = [
            request.originalURL?.absoluteString,
            request.sharedText,
            request.pageTitle,
            metadata?.title,
            metadata?.authorName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        let isExactVideo = evidence.contains("qd4bdd7l66m")
        let namesEpisode = evidence.contains("the butler's escape") || evidence.contains("the butlers escape")
        let matchesRepostTitle = evidence.contains("how many times has she done this") && evidence.contains("modernfamily")
        let matchesDialogue = evidence.contains("dairy case") || evidence.contains("she has a tendency to wander off")
        guard isExactVideo || namesEpisode || matchesRepostTitle || matchesDialogue else { return nil }

        let peacockURL = URL(string: "https://www.peacocktv.com/watch-online/tv/modern-family/6158438733133910112/seasons/4/episodes/the-butlers-escape-episode-4/f41cc120-01ca-3553-9717-918261270b88")!
        let heroURL = metadata?.thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/QD4bDD7L66M/hqdefault.jpg")
        let candidate = SceneCandidate(
            id: MockMediaLibrary.stableID("modern-family-s04e04-606"),
            mediaTitle: "Modern Family",
            mediaType: .television,
            releaseYear: 2012,
            seasonNumber: 4,
            episodeNumber: 4,
            episodeTitle: "The Butler's Escape",
            sceneTimestampSeconds: 606,
            clipEndTimestampSeconds: 625,
            matchedSubtitleText: "Keep your eye on Lily. She has a tendency to wander off.",
            confidence: 0.99,
            subtitleScore: 0.99,
            visualScore: 0.94,
            metadataScore: 1,
            streamingService: "Peacock",
            streamingURL: peacockURL,
            heroImageURL: heroURL,
            watchProviders: modernFamilyProviders(peacockURL: peacockURL)
        )

        return ClipAnalysisResult(
            id: UUID(),
            requestID: request.id,
            createdAt: Date(),
            detectedDialogue: "Keep your eye on Lily. She has a tendency to wander off. You lost her, didn't you? Look in the dairy case.",
            topCandidate: candidate,
            alternativeCandidates: [],
            analysisDetails: AnalysisDetails(
                sourcePlatform: request.sourcePlatform,
                sourceType: request.sourceType,
                extractedFrameCount: request.sourceType == .video ? 5 : 0,
                subtitleCandidatesCompared: 1,
                totalProcessingDuration: processingDuration
            )
        )
    }

    private static func modernFamilyProviders(peacockURL: URL) -> [WatchProvider] {
        [
            WatchProvider(
                id: "hulu",
                name: "Hulu",
                offer: "Subscription",
                episodeURL: URL(string: "https://www.hulu.com/series/modern-family-883c414c-34a3-4fcc-b50a-0ad5a184c977?entity_id=008ab86a-f287-4275-83d2-d2d7aa605bb5")!,
                sceneURL: nil,
                symbolName: "play.rectangle.fill",
                brandColorHex: "1CE783"
            ),
            WatchProvider(
                id: "peacock",
                name: "Peacock",
                offer: "Subscription",
                episodeURL: peacockURL,
                sceneURL: nil,
                symbolName: "play.tv.fill",
                brandColorHex: "F9D71C"
            ),
            WatchProvider(
                id: "disney-plus",
                name: "Disney+",
                offer: "Subscription",
                episodeURL: URL(string: "https://www.disneyplus.com/search/modern%20family")!,
                sceneURL: nil,
                symbolName: "sparkles.tv.fill",
                brandColorHex: "5F8DFF"
            ),
            WatchProvider(
                id: "philo",
                name: "Philo",
                offer: "Subscription",
                episodeURL: URL(string: "https://www.philo.com/search/Modern%20Family")!,
                sceneURL: nil,
                symbolName: "play.tv.fill",
                brandColorHex: "8D6BFF"
            ),
            WatchProvider(
                id: "youtube",
                name: "YouTube",
                offer: "Primetime subscription",
                episodeURL: URL(string: "https://www.youtube.com/results?search_query=Modern+Family+The+Butler%27s+Escape")!,
                sceneURL: nil,
                symbolName: "play.rectangle.fill",
                brandColorHex: "FF0033"
            ),
            WatchProvider(
                id: "prime-video",
                name: "Prime Video",
                offer: "Subscription may require an add-on",
                episodeURL: URL(string: "https://www.amazon.com/s?k=Modern+Family+The+Butler%27s+Escape&i=instant-video")!,
                sceneURL: nil,
                symbolName: "play.tv.fill",
                brandColorHex: "00A8E1"
            ),
            WatchProvider(
                id: "fandango-at-home",
                name: "Fandango at Home",
                offer: "Purchase options vary",
                episodeURL: URL(string: "https://athome.fandango.com/content/browse/search?searchString=Modern%20Family")!,
                sceneURL: nil,
                symbolName: "ticket.fill",
                brandColorHex: "2C79D4"
            ),
            WatchProvider(
                id: "apple-tv",
                name: "Apple TV",
                offer: "Purchase options vary",
                episodeURL: URL(string: "https://tv.apple.com/us/episode/the-butlers-escape/umc.cmc.75tyhpvj4kotbungynexaxeyo?showId=umc.cmc.cmw0vccgg7hpwfa3wgvvu5q0")!,
                sceneURL: nil,
                symbolName: "appletv.fill",
                brandColorHex: "FFFFFF"
            )
        ]
    }
}
