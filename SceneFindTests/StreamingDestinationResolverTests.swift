import XCTest

final class StreamingDestinationResolverTests: XCTestCase {
    override func tearDown() {
        StreamingStubURLProtocol.requestHandler = nil
        super.tearDown()
    }

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

    func testHuluWebWatchURLBecomesNativeEpisodeRoute() async throws {
        let hulu = WatchProvider(
            id: "hulu",
            name: "Hulu",
            offer: "Subscription",
            episodeURL: try XCTUnwrap(URL(string: "https://www.hulu.com/watch/008ab86a-f287-4275-83d2-d2d7aa605bb5")),
            sceneURL: nil,
            symbolName: "play.tv.fill",
            brandColorHex: "1CE783"
        )

        let destination = await StreamingDestinationResolver().destination(
            for: hulu,
            candidate: candidate(title: "Any Show", season: 4, episode: 4, episodeTitle: "Episode Four")
        )

        XCTAssertEqual(
            destination?.primaryURL.absoluteString,
            "hulu://watch/008ab86a-f287-4275-83d2-d2d7aa605bb5"
        )
    }

    func testHuluSeriesPageIsAcceptedForDynamicEpisodeResolution() throws {
        let hulu = provider(
            name: "Hulu",
            url: "https://www.hulu.com/series/any-show-1138ee62-b9d9-4561-8094-3f7cda4bbd22"
        )
        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "Any Show", season: 6, episode: 2, episodeTitle: "The Episode"),
            supplied: [hulu]
        )

        XCTAssertEqual(providers.map(\.name), ["Hulu"])
    }

    func testHuluSeriesPageResolvesRequestedSeasonAndEpisode() async throws {
        let payload: [String: Any] = [
            "props": ["episodes": [[
                "id": "resolved-episode-id",
                "type": "episode",
                "season": 12,
                "number": 8
            ]]]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let html = Data("<script id=\"__NEXT_DATA__\" type=\"application/json\">\(jsonText)</script>".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        StreamingStubURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, html)
        }

        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: provider(name: "Hulu", url: "https://www.hulu.com/series/a-show-series-id"),
            candidate: candidate(title: "A Show", season: 12, episode: 8, episodeTitle: "Episode Eight")
        )

        XCTAssertEqual(destination?.primaryURL.absoluteString, "hulu://watch/resolved-episode-id")
    }

    func testExactEpisodeRoutesAreAcceptedAcrossProviders() throws {
        let supplied = [
            provider(name: "Netflix", url: "https://www.netflix.com/watch/81234567"),
            provider(name: "Apple TV", url: "https://tv.apple.com/us/episode/example/umc.cmc.episode"),
            provider(name: "Disney+", url: "https://www.disneyplus.com/video/episode-uuid"),
            provider(name: "Prime Video", url: "https://www.amazon.com/gp/video/detail/B012345678"),
            provider(name: "Max", url: "https://play.max.com/video/watch/episode-id"),
            provider(name: "Peacock", url: "https://www.peacocktv.com/watch-online/tv/show/seasons/1/episodes/pilot/episode-id"),
            provider(name: "Paramount+", url: "https://www.paramountplus.com/shows/video/episode-id"),
            provider(name: "YouTube", url: "https://www.youtube.com/watch?v=episode-id")
        ]

        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode"),
            supplied: supplied
        )

        XCTAssertEqual(providers.map(\.name), supplied.map(\.name))
    }

    func testShowAndSearchPagesAreNotPresentedAsEpisodeLinks() throws {
        let supplied = [
            provider(name: "Netflix", url: "https://www.netflix.com/title/81234567"),
            provider(name: "Apple TV", url: "https://tv.apple.com/us/show/example/umc.cmc.show"),
            provider(name: "Disney+", url: "https://www.disneyplus.com/browse/entity-series-id"),
            provider(name: "Max", url: "https://play.max.com/show/show-id"),
            provider(name: "Prime Video", url: "https://www.amazon.com/s?k=show+episode"),
            provider(name: "YouTube", url: "https://www.youtube.com/results?search_query=show+episode")
        ]

        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode"),
            supplied: supplied
        )

        XCTAssertTrue(providers.isEmpty)
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

    private func provider(name: String, url: String) -> WatchProvider {
        WatchProvider(
            id: name.lowercased(),
            name: name,
            offer: "Subscription",
            episodeURL: URL(string: url)!,
            sceneURL: nil,
            symbolName: "play.tv.fill",
            brandColorHex: "FFFFFF"
        )
    }
}

private final class StreamingStubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("StreamingStubURLProtocol received a request without a handler")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
