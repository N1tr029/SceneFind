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

    /// Checked live on 2026-07-24. `www.hulu.com` is being folded into Disney+
    /// and `302`s every path — including this real episode UUID — to the Disney+
    /// home page with the path discarded, so its episode pages can no longer be
    /// fetched or verified. `dl.hulu.com` is separate and still publishes an
    /// apple-app-site-association listing `/watch/*` for `com.hulu.plus`, and
    /// iOS resolves a Universal Link against that file before making any web
    /// request — so this URL still opens the app at the episode.
    ///
    /// Treating the web redirect as proof the service was dead is what broke
    /// previously-working saved links: the resolver tried to verify a page that
    /// no longer exists, failed, and returned nothing.
    func testHuluEpisodeUUIDStillDeepLinksWithoutProbingTheDeadWebPage() async throws {
        // No handler is installed on purpose: `StreamingStubURLProtocol` fails
        // the test if a request arrives, which proves the UUID is trusted
        // directly rather than re-verified against a page that now redirects.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        let hulu = provider(
            name: "Hulu",
            url: "https://www.hulu.com/watch/46ed69ca-03a6-47f3-a97b-fc59765405b9"
        )

        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: hulu,
            candidate: candidate(title: "The Rookie", season: 1, episode: 7, episodeTitle: "The Ride Along")
        )

        let resolved = try XCTUnwrap(destination)
        XCTAssertEqual(resolved.level, .exactEpisode)
        // The deep-linkable host, not the one that drops the path.
        XCTAssertEqual(resolved.primaryURL.host, "dl.hulu.com")
        XCTAssertEqual(resolved.primaryURL.path, "/watch/46ed69ca-03a6-47f3-a97b-fc59765405b9")
        XCTAssertEqual(resolved.webFallbackURL?.scheme, "hulu")
    }

    /// A service that *is* still reachable degrades to its own official search
    /// page, so "Watch" always lands on the real provider rather than nothing.
    func testUnverifiableProviderDegradesToThatServicesOwnSearch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        StreamingStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            // The episode page cannot be verified (login wall, JS shell, 404 —
            // all routine on streaming sites).
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
            )
            return (response, Data())
        }
        defer { StreamingStubURLProtocol.requestHandler = nil }

        let netflix = provider(name: "Netflix", url: "https://www.netflix.com/watch/80057281")
        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: netflix,
            candidate: candidate(title: "The Rookie", season: 1, episode: 7, episodeTitle: "The Ride Along")
        )

        let resolved = try XCTUnwrap(destination)
        XCTAssertEqual(resolved.level, .search)
        XCTAssertEqual(resolved.primaryURL.host, "www.netflix.com")
        XCTAssertEqual(resolved.primaryURL.path, "/search")
        XCTAssertNil(resolved.webFallbackURL)
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

    func testHuluRootPlaceholderIsAcceptedForLocalResolution() throws {
        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "The Rookie", season: 1, episode: 7, episodeTitle: "The Ride Along"),
            supplied: [provider(name: "Hulu", url: "https://www.hulu.com/")]
        )

        XCTAssertEqual(providers.map(\.name), ["Hulu"])
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

    func testShowAndSearchPagesAreKeptWithHonestDestinationLevels() throws {
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

        XCTAssertEqual(
            providers.map { $0.destinationLevel },
            [.show, .show, .show, .show, .search, .search]
        )
    }

    func testNetflixDestinationOpensWhenPageMatchesIdentifiedTitle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        StreamingStubURLProtocol.requestHandler = { request in
            let html = Data(#"<html><head><meta property="og:title" content="The First Time - All American (Season 8, Episode 1) | Netflix"></head></html>"#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, html)
        }
        let netflix = provider(name: "Netflix", url: "https://www.netflix.com/watch/81012998")

        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: netflix,
            candidate: candidate(title: "All American", season: 8, episode: 1, episodeTitle: "The First Time")
        )

        XCTAssertEqual(destination?.primaryURL, netflix.episodeURL)
    }

    func testNetflixDestinationRejectsUnrelatedWatchID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        StreamingStubURLProtocol.requestHandler = { request in
            let html = Data(#"<html><head><meta property="og:title" content="Watch Random Comedy Special | Netflix"></head></html>"#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, html)
        }

        let unrelated = provider(name: "Netflix", url: "https://www.netflix.com/watch/99999999")
        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: unrelated,
            candidate: candidate(title: "All American", season: 8, episode: 1, episodeTitle: "The First Time")
        )

        // Verification failing no longer dead-ends: streaming sites are
        // login-walled single-page apps, so a rejected page used to leave the
        // user with nothing to tap. What must never happen is handing over the
        // wrong exact link, so the watch id is discarded and the destination
        // degrades to Netflix's own search.
        let resolved = try XCTUnwrap(destination)
        XCTAssertNotEqual(resolved.primaryURL, unrelated.episodeURL)
        XCTAssertFalse(resolved.primaryURL.path.contains("99999999"))
        XCTAssertEqual(resolved.level, .search)
        XCTAssertEqual(resolved.primaryURL.host, "www.netflix.com")
        XCTAssertEqual(resolved.primaryURL.path, "/search")
    }

    func testAppleTVDestinationRequiresMatchingEpisodeEvidence() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        StreamingStubURLProtocol.requestHandler = { request in
            let html = Data(#"<meta content="Wrong Turn - Any Show (Season 2, Episode 4) - Apple TV" property="og:title">"#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, html)
        }

        let wrongEpisode = provider(
            name: "Apple TV",
            url: "https://tv.apple.com/us/episode/the-episode/umc.cmc.wrong"
        )
        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: wrongEpisode,
            candidate: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode")
        )

        // The page is S2 E4, not the S2 E3 that was identified. Opening it would
        // spoil or mislead, so the exact route is dropped — but the row still
        // has to lead somewhere, so it becomes Apple TV's own search.
        let resolved = try XCTUnwrap(destination)
        XCTAssertNotEqual(resolved.primaryURL, wrongEpisode.episodeURL)
        XCTAssertFalse(resolved.primaryURL.path.contains("episode"))
        XCTAssertEqual(resolved.level, .search)
        XCTAssertEqual(resolved.primaryURL.host, "tv.apple.com")
        XCTAssertEqual(resolved.primaryURL.path, "/search")
    }

    func testAppleTVDestinationAcceptsMatchingEpisodePage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        StreamingStubURLProtocol.requestHandler = { request in
            let html = Data(#"<meta content="The Episode - Any Show (Season 2, Episode 3) - Apple TV" property="og:title">"#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, html)
        }
        let appleTV = provider(name: "Apple TV", url: "https://tv.apple.com/us/episode/the-episode/umc.cmc.id")

        let destination = await StreamingDestinationResolver(
            session: URLSession(configuration: configuration)
        ).destination(
            for: appleTV,
            candidate: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode")
        )

        XCTAssertEqual(destination?.primaryURL, appleTV.episodeURL)
    }

    func testProviderNameCannotDisguiseAnUntrustedHost() {
        let netflixProviders = StreamingProviderCatalog.providers(
            for: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode"),
            supplied: [provider(name: "Netflix", url: "https://example.com/watch/81234567")]
        )
        let huluProviders = StreamingProviderCatalog.providers(
            for: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode"),
            supplied: [provider(name: "Hulu", url: "https://example.com/")]
        )

        XCTAssertTrue(netflixProviders.isEmpty)
        XCTAssertTrue(huluProviders.isEmpty)
    }

    func testDifferentSupportedLongTailServicesAreNotCollapsed() {
        let supplied = [
            provider(name: "Tubi", url: "https://tubitv.com/tv-shows/123/example"),
            provider(name: "Crunchyroll", url: "https://www.crunchyroll.com/watch/ABC123/example")
        ]

        let providers = StreamingProviderCatalog.providers(
            for: candidate(title: "Any Show", season: 2, episode: 3, episodeTitle: "The Episode"),
            supplied: supplied
        )

        XCTAssertEqual(providers.map(\.name), ["Tubi", "Crunchyroll"])
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
