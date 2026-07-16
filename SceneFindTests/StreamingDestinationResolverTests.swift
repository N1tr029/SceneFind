import XCTest

final class StreamingDestinationResolverTests: XCTestCase {
    func testHuluPageParserFindsExactEpisode() throws {
        let payload: [String: Any] = [
            "props": [
                "pageProps": [
                    "collections": [[
                        "id": "wrong-season",
                        "type": "episode",
                        "name": "Episode Four",
                        "season": 7,
                        "number": 4
                    ], [
                        "id": "correct-episode-id",
                        "type": "episode",
                        "name": "The Butler's Escape",
                        "season": 4,
                        "number": 4
                    ]]
                ]
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let html = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(jsonText)</script></html>"

        XCTAssertEqual(
            HuluEpisodePageParser.episodeID(
                in: Data(html.utf8),
                season: 4,
                episode: 4,
                title: "The Butler's Escape"
            ),
            "correct-episode-id"
        )
    }

    func testModernFamilyReplacesWrongHuluEpisodeURL() throws {
        let wrongHulu = WatchProvider(
            id: "generated-hulu",
            name: "Hulu",
            offer: "Subscription",
            episodeURL: try XCTUnwrap(URL(string: "https://www.hulu.com/watch/856225")),
            sceneURL: nil,
            symbolName: "play.tv.fill",
            brandColorHex: "1CE783"
        )

        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "Modern Family", season: 4, episode: 4, episodeTitle: "The Butler's Escape"),
            supplied: [wrongHulu]
        )

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].id, "hulu")
        XCTAssertEqual(
            providers[0].episodeURL.absoluteString,
            "hulu://watch/008ab86a-f287-4275-83d2-d2d7aa605bb5"
        )
    }

    func testTheRookieGetsHuluWhenModelReturnsNoProviders() {
        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "The Rookie", season: 6, episode: 2, episodeTitle: "The Hammer"),
            supplied: []
        )

        XCTAssertEqual(providers.map(\.name), ["Hulu"])
        XCTAssertTrue(providers[0].episodeURL.absoluteString.contains("the-rookie-1138ee62"))
    }

    func testTheRookieUsesExactHuluEpisodeAndRemovesUnavailableAppleTV() throws {
        let appleTV = WatchProvider(
            id: "apple-tv",
            name: "Apple TV",
            offer: "Purchase",
            episodeURL: try XCTUnwrap(URL(string: "https://tv.apple.com/us/show/the-rookie/example")),
            sceneURL: nil,
            symbolName: "appletv.fill",
            brandColorHex: "FFFFFF"
        )

        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "The Rookie", season: 5, episode: 10, episodeTitle: "The List"),
            supplied: [appleTV]
        )

        XCTAssertEqual(providers.map(\.name), ["Hulu"])
        XCTAssertEqual(
            providers[0].episodeURL.absoluteString,
            "hulu://watch/e4650184-87a5-4ff3-ba6e-aae2a7e2807a"
        )
    }

    private func candidate(
        title: String,
        season: Int,
        episode: Int,
        episodeTitle: String
    ) -> SceneCandidate {
        SceneCandidate(
            id: UUID(),
            mediaTitle: title,
            mediaType: .television,
            releaseYear: 2018,
            seasonNumber: season,
            episodeNumber: episode,
            episodeTitle: episodeTitle,
            sceneTimestampSeconds: 600,
            matchedSubtitleText: nil,
            confidence: 0.9,
            subtitleScore: 0.8,
            visualScore: 0.8,
            metadataScore: 0.8,
            streamingService: nil,
            streamingURL: nil
        )
    }
}
