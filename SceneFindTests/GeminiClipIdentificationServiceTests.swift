import XCTest

final class GeminiClipIdentificationServiceTests: XCTestCase {
    func testMediaTypeClassifiesNativeOnlineMediaAsOther() {
        XCTAssertEqual(MediaType(apiValue: "movie"), .movie)
        XCTAssertEqual(MediaType(apiValue: "tv"), .television)
        XCTAssertEqual(MediaType(apiValue: "other"), .other)
        XCTAssertEqual(MediaType(apiValue: "youtube"), .other)
    }

    func testYouTubeVideoIDParsesWellFormedLinks() {
        func id(_ string: String) -> String? {
            URL(string: string).flatMap(GeminiClipIdentificationService.youTubeVideoID(from:))
        }
        XCTAssertEqual(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testYouTubeVideoIDRejectsMalformedOrNonVideoLinks() {
        func id(_ string: String) -> String? {
            URL(string: string).flatMap(GeminiClipIdentificationService.youTubeVideoID(from:))
        }
        // Missing/short/oversized ids — the class of hallucinated links that
        // used to become dead "watch" destinations.
        XCTAssertNil(id("https://www.youtube.com/watch?v="))
        XCTAssertNil(id("https://www.youtube.com/watch?v=short"))
        XCTAssertNil(id("https://www.youtube.com/watch?list=PL123"))
        // Search / channel / playlist pages are not a specific video.
        XCTAssertNil(id("https://www.youtube.com/results?search_query=dhar+mann"))
        XCTAssertNil(id("https://www.youtube.com/@DharMann"))
        XCTAssertNil(id("https://www.youtube.com/playlist?list=PL123"))
    }

    func testDeadYouTubeWatchLinkFallsBackToSearchForOnlineContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "www.youtube.com", url.path == "/oembed" {
                // Simulate a nonexistent/private video (well-formed id, dead link).
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
                return (response, Data())
            }
            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "You never know someone's story.",
                "candidates": [[
                    "media_title": "Dhar Mann",
                    "media_type": "other",
                    "release_year": 2021,
                    "confidence": 0.9,
                    "dialogue_score": 0.9,
                    "visual_score": 0.6,
                    "watch_providers": [[
                        "name": "YouTube",
                        "offer": "Free",
                        "url": "https://www.youtube.com/watch?v=abcdefghijk"
                    ]]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: resultJSON)
            return try Self.geminiResponse(text: String(data: data, encoding: .utf8)!)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://www.youtube.com/shorts/abcdefghijk")
        )

        let result = try await service.identify(request: request, metadata: nil)

        XCTAssertEqual(result.topCandidate.mediaType, .other)
        let providers = try XCTUnwrap(result.topCandidate.watchProviders)
        XCTAssertEqual(providers.count, 1)
        let destination = try XCTUnwrap(providers.first?.episodeURL)
        XCTAssertEqual(destination.host, "www.youtube.com")
        XCTAssertEqual(destination.path, "/results")
        XCTAssertTrue(destination.query?.contains("search_query=Dhar") == true)
        XCTAssertEqual(result.topCandidate.streamingURL, destination)
        // The dead watch link must not survive.
        XCTAssertFalse(providers.contains { $0.episodeURL.path == "/watch" })
    }

    func testLiveYouTubeWatchLinkIsKept() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "www.youtube.com", url.path == "/oembed" {
                let payload: [String: Any] = ["title": "A real video", "author_name": "Creator"]
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, try JSONSerialization.data(withJSONObject: payload))
            }
            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Line.",
                "candidates": [[
                    "media_title": "Some Channel",
                    "media_type": "other",
                    "release_year": 2023,
                    "confidence": 0.9,
                    "dialogue_score": 0.9,
                    "visual_score": 0.6,
                    "watch_providers": [[
                        "name": "YouTube",
                        "offer": "Free",
                        "url": "https://www.youtube.com/watch?v=abcdefghijk"
                    ]]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: resultJSON)
            return try Self.geminiResponse(text: String(data: data, encoding: .utf8)!)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://www.youtube.com/shorts/abcdefghijk")
        )

        let result = try await service.identify(request: request, metadata: nil)

        let providers = try XCTUnwrap(result.topCandidate.watchProviders)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?.episodeURL.absoluteString, "https://www.youtube.com/watch?v=abcdefghijk")
    }

    func testInstagramWithoutFetchableMediaRefusesToGuess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var generateCallCount = 0

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "www.instagram.com" || url.host == "instagram.com" {
                // A login-walled page with no og:image (typical for scrapers).
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, Data("<html><head><title>Instagram</title></head></html>".utf8))
            }
            if url.host?.contains("generativelanguage") == true {
                generateCallCount += 1
            }
            return try Self.geminiResponse(text: "{\"match_found\":false,\"candidates\":[]}")
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .instagram,
            originalURL: URL(string: "https://www.instagram.com/reel/CxAbCdEf123/")
        )

        do {
            _ = try await service.identify(request: request, metadata: nil)
            XCTFail("Expected SceneFind to stop instead of guessing with no media")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "Video unavailable")
        }
        // The whole point: with no media, we must NOT call the model at all.
        XCTAssertEqual(generateCallCount, 0)
    }

    func testInstagramPreviewImageProducesCappedConfidence() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "www.instagram.com" {
                let html = "<html><head><meta property=\"og:image\" content=\"https://cdn.ig.example/frame.jpg\"></head></html>"
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, Data(html.utf8))
            }
            if url.host == "cdn.ig.example" {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"]
                ))
                return (response, Data(repeating: 9, count: 2_048))
            }
            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "We need to talk about Iran.",
                "candidates": [[
                    "media_title": "Euphoria",
                    "media_type": "tv",
                    "release_year": 2019,
                    "season_number": 1,
                    "episode_number": 3,
                    "confidence": 0.95,
                    "dialogue_score": 0.9,
                    "visual_score": 0.8,
                    "watch_providers": []
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: resultJSON)
            return try Self.geminiResponse(text: String(data: data, encoding: .utf8)!)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .instagram,
            originalURL: URL(string: "https://www.instagram.com/reel/CxAbCdEf123/")
        )

        let result = try await service.identify(request: request, metadata: nil)

        // Only a still frame was available (no audio/dialogue), so a self-reported
        // 0.95 must be capped — not presented as near-certain.
        XCTAssertLessThanOrEqual(result.topCandidate.confidence, 0.65)
        XCTAssertEqual(result.analysisDetails.directMediaAnalyzed, true)
    }

    func testRetiredModelIsMigrated() {
        XCTAssertEqual(
            GeminiConfiguration.supportedModel("gemini-2.5-flash-lite"),
            "gemini-3.5-flash"
        )
        XCTAssertEqual(GeminiConfiguration.supportedModel("gemini-2.5-flash"), "gemini-3.5-flash")
    }

    override func tearDown() {
        GeminiStubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testYouTubeShortIsSentAsVideoAndMapsStructuredResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var requestCount = 0
        GeminiStubURLProtocol.requestHandler = { request in
            requestCount += 1
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-test-key")

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

            XCTAssertNil(json["tools"])
            let fileData = try XCTUnwrap(parts.first?["file_data"] as? [String: Any])
            XCTAssertEqual(
                fileData["file_uri"] as? String,
                "https://www.youtube.com/watch?v=abc123"
            )
            let prompt = try XCTUnwrap(parts.last?["text"] as? String)
            XCTAssertTrue(prompt.contains("Social reposts may splice scenes out of order"))
            let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
            let systemParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
            let instructions = try XCTUnwrap(systemParts.first?["text"] as? String)
            XCTAssertTrue(instructions.contains("Analyze evidence before choosing a title"))
            XCTAssertTrue(instructions.contains("captions, hashtags, usernames"))
            let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
            let thinkingConfig = try XCTUnwrap(generationConfig["thinkingConfig"] as? [String: Any])
            XCTAssertEqual(thinkingConfig["thinkingLevel"] as? String, "LOW")
            XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 4_096)
            let responseFormat = try XCTUnwrap(generationConfig["responseFormat"] as? [String: Any])
            let textFormat = try XCTUnwrap(responseFormat["text"] as? [String: Any])
            XCTAssertEqual(textFormat["mimeType"] as? String, "APPLICATION_JSON")
            let schema = try XCTUnwrap(textFormat["schema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")

            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Nobody calls him that anymore.",
                "visual_evidence": ["Two characters argue in a hospital corridor."],
                "candidates": [[
                    "media_title": "Example Show",
                    "media_type": "tv",
                    "release_year": 2022,
                    "season_number": 3,
                    "episode_number": 7,
                    "episode_title": "Old Names",
                    "clip_start_seconds": 732.0,
                    "clip_end_seconds": 748.0,
                    "matching_subtitle": "Nobody calls him that anymore.",
                    "confidence": 0.92,
                    "dialogue_score": 0.91,
                    "visual_score": 0.84,
                    "metadata_score": 0.18,
                    "hero_image_url": NSNull(),
                    "watch_providers": [[
                        "name": "Hulu",
                        "offer": "Subscription",
                        "url": "https://www.hulu.com/example"
                    ]]
                ]]
            ]
            let resultData = try JSONSerialization.data(withJSONObject: resultJSON)
            let resultText = try XCTUnwrap(String(data: resultData, encoding: .utf8))
            let outputText = "Research complete.\n```json\n\(resultText)\n```"
            return try Self.geminiResponse(text: outputText)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://www.youtube.com/shorts/abc123")
        )
        let metadata = SocialClipMetadata(
            title: "A scene from a show",
            authorName: "Clip account",
            thumbnailURL: URL(string: "https://i.ytimg.com/example.jpg")
        )

        let result = try await service.identify(request: request, metadata: metadata)

        XCTAssertEqual(result.topCandidate.mediaTitle, "Example Show")
        XCTAssertEqual(result.topCandidate.episodeLine, "S3 E7")
        XCTAssertEqual(result.topCandidate.sceneTimestampSeconds, 732)
        XCTAssertEqual(result.topCandidate.clipEndTimestampSeconds, 748)
        XCTAssertEqual(result.topCandidate.watchProviders?.first?.name, "Hulu")
        XCTAssertEqual(
            result.topCandidate.watchProviders?.first?.episodeURL.absoluteString,
            "https://www.hulu.com/"
        )
        XCTAssertEqual(result.topCandidate.heroImageURL, metadata.thumbnailURL)
        XCTAssertEqual(result.topCandidate.subtitleScore, 0.91)
        XCTAssertEqual(result.topCandidate.visualScore, 0.84)
        XCTAssertEqual(result.topCandidate.metadataScore, 0.18)
        XCTAssertEqual(result.analysisDetails.visualEvidence, ["Two characters argue in a hospital corridor."])
        XCTAssertEqual(result.analysisDetails.directMediaAnalyzed, true)
        XCTAssertEqual(requestCount, 1)
    }

    func testEmptyGeminiResponseDoesNotRepeatExpensiveRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0

        GeminiStubURLProtocol.requestHandler = { request in
            requestCount += 1
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(#"{"candidates":[{"content":{"parts":[]}}]}"#.utf8))
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        do {
            _ = try await service.identify(
                request: SharedClipRequest(
                    sourceType: .url,
                    sourcePlatform: .youtube,
                    originalURL: URL(string: "https://www.youtube.com/shorts/example")
                ),
                metadata: nil
            )
            XCTFail("Expected an invalid structured response")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "Couldn't read the result")
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testTikTokUploadLimitCoversLargePublicClips() {
        XCTAssertGreaterThanOrEqual(
            GeminiClipIdentificationService.maximumUploadSizeBytes,
            35 * 1_024 * 1_024
        )
    }

    func testCommonJSONTypeVariationsAreRecovered() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
            XCTAssertNotNil(generationConfig["responseFormat"])

            return try Self.geminiResponse(text: """
                {
                  "match_found": "true",
                  "candidates": [{
                    "media_title": "Example Show",
                    "media_type": "tv",
                    "release_year": "2022",
                    "season_number": "3",
                    "episode_number": 7,
                    "clip_start_seconds": "732.5",
                    "confidence": "92%"
                  }]
                }
                """)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://www.youtube.com/shorts/example")
        )

        let result = try await service.identify(request: request, metadata: nil)

        XCTAssertEqual(result.topCandidate.releaseYear, 2022)
        XCTAssertEqual(result.topCandidate.seasonNumber, 3)
        XCTAssertEqual(result.topCandidate.sceneTimestampSeconds, 732.5)
        XCTAssertEqual(result.topCandidate.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(result.detectedDialogue, "")
        XCTAssertEqual(result.topCandidate.watchProviders, [])
    }

    func testTikTokPageParserFindsPublicVideoThumbnailAndSearchHints() throws {
        let payload: [String: Any] = [
            "__DEFAULT_SCOPE__": [
                "webapp.video-detail": [
                    "itemInfo": [
                        "itemStruct": [
                            "video": [
                                "playAddr": "https://cdn.example/clip.mp4",
                                "originCover": "https://cdn.example/cover.jpg"
                            ],
                            "suggestedWords": ["bull tv series", "bull immigration episode"]
                        ]
                    ]
                ]
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let html = Data("<script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">\(jsonText)</script>".utf8)

        let metadata = try XCTUnwrap(TikTokPageParser.metadata(from: html))

        XCTAssertEqual(metadata.videoURL?.absoluteString, "https://cdn.example/clip.mp4")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://cdn.example/cover.jpg")
        XCTAssertEqual(metadata.searchHints, ["bull tv series", "bull immigration episode"])
    }

    func testTikTokEmbedParserFindsSignedVideoThumbnailAndHashtags() throws {
        let payload: [String: Any] = [
            "source": [
                "data": [
                    "/embed/v2/7655625118344957214": [
                        "videoData": [
                            "itemInfos": [
                                "video": ["urls": ["https://cdn.example/signed-video.mp4"]],
                                "coversOrigin": ["https://cdn.example/embed-cover.jpg"],
                                "challengeInfoList": [
                                    ["challengeName": "dacademy"],
                                    ["challengeName": "thegoldbergs"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let html = Data("<script id=\"__FRONTITY_CONNECT_STATE__\" type=\"application/json\">\(jsonText)</script>".utf8)

        let metadata = try XCTUnwrap(TikTokPageParser.metadata(from: html))

        XCTAssertEqual(metadata.videoURL?.absoluteString, "https://cdn.example/signed-video.mp4")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://cdn.example/embed-cover.jpg")
        XCTAssertEqual(metadata.searchHints, ["dacademy", "thegoldbergs"])
    }

    func testTikTokOEmbedVideoIDLoadsPublicEmbedMedia() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestedEmbed = false

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/oembed" {
                let payload: [String: Any] = [
                    "title": "#dacademy",
                    "author_name": "repost",
                    "html": "<blockquote data-video-id=\"7655625118344957214\"></blockquote>"
                ]
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, try JSONSerialization.data(withJSONObject: payload))
            }
            if url.path.contains("/t/") {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, Data("<html></html>".utf8))
            }
            XCTAssertEqual(url.absoluteString, "https://www.tiktok.com/embed/v2/7655625118344957214")
            requestedEmbed = true
            let state: [String: Any] = [
                "source": ["data": ["page": ["videoData": ["itemInfos": [
                    "video": ["urls": ["https://cdn.example/goldbergs.mp4"]],
                    "covers": ["https://cdn.example/goldbergs.jpg"]
                ]]]]]
            ]
            let json = try JSONSerialization.data(withJSONObject: state)
            let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
            let html = Data("<script id=\"__FRONTITY_CONNECT_STATE__\">\(jsonText)</script>".utf8)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, html)
        }

        let service = OEmbedSocialClipMetadataService(session: session)
        let metadata = try await service.metadata(
            for: XCTUnwrap(URL(string: "https://www.tiktok.com/t/ZTA1C7M9n/"))
        )

        XCTAssertTrue(requestedEmbed)
        XCTAssertEqual(metadata.title, "#dacademy")
        XCTAssertEqual(metadata.videoURL?.absoluteString, "https://cdn.example/goldbergs.mp4")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://cdn.example/goldbergs.jpg")
    }

    func testTVArtworkPrefersShowCoverOverEpisodeStill() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let payload: [String: Any] = [
                "image": [
                    "medium": "https://images.example/show-medium.jpg",
                    "original": "https://images.example/show-cover.jpg"
                ],
                "_embedded": ["episodes": [[
                    "season": 4,
                    "number": 18,
                    "image": [
                        "medium": "https://images.example/episode-medium.jpg",
                        "original": "https://images.example/episode-still.jpg"
                    ]
                ]]]
            ]
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        let artwork = await PublicTitleArtworkService(session: session).artworkURL(
            for: "The Rookie",
            mediaType: .television,
            seasonNumber: 4,
            episodeNumber: 18
        )

        XCTAssertEqual(artwork?.absoluteString, "https://images.example/show-cover.jpg")
    }

    func testTikTokVideoIsAttachedInlineAndEpisodeIsVerifiedAgainstGuide() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var generateCallCount = 0
        var verificationCallCount = 0

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "cdn.example" {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "video/mp4"]
                ))
                return (response, Data(repeating: 7, count: 1_024))
            }
            if url.path == "/upload/v1beta/files" {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Goog-Upload-URL": "https://upload.example/finalize"]
                ))
                return (response, Data())
            }
            if url.host == "upload.example" {
                let file = [
                    "file": [
                        "name": "files/tiktok-test",
                        "uri": "https://generativelanguage.googleapis.com/v1beta/files/tiktok-test",
                        "mimeType": "video/mp4",
                        "state": "ACTIVE"
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: file)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ))
                return (response, data)
            }
            if request.httpMethod == "DELETE" {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (response, Data())
            }
            if url.host == "api.tvmaze.com" {
                let guide: [String: Any] = ["_embedded": ["episodes": [
                    [
                        "season": 2,
                        "number": 2,
                        "name": "Mama Drama",
                        "summary": "Murray leaves a Flyers game early because of traffic and misses an unprecedented event."
                    ],
                    [
                        "season": 4,
                        "number": 16,
                        "name": "The Dynamic Duo",
                        "summary": "Barry tries to reinvent himself."
                    ]
                ]]]
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, try JSONSerialization.data(withJSONObject: guide))
            }
            if url.host == "api.groq.com" {
                verificationCallCount += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer groq-test-key")
                let body = try XCTUnwrap(Self.bodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["model"] as? String, "openai/gpt-oss-120b")
                XCTAssertEqual(json["reasoning_effort"] as? String, "low")
                let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
                XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
                let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
                XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
                XCTAssertNotNil(jsonSchema["schema"])
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertTrue((messages.last?["content"] as? String)?.contains("Episode guide entries:") == true)

                let verification: [String: Any] = [
                    "match_verified": true,
                    "season_number": 2,
                    "episode_number": 2,
                    "episode_title": "Mama Drama",
                    "clip_start_seconds": NSNull(),
                    "clip_end_seconds": NSNull(),
                    "matching_subtitle": "Ron Hextall scores the final goal!",
                    "verification_evidence": "The Flyers, traffic, and unprecedented goal match the Mama Drama guide summary."
                ]
                let verificationData = try JSONSerialization.data(withJSONObject: verification)
                let content = try XCTUnwrap(String(data: verificationData, encoding: .utf8))
                let envelope: [String: Any] = [
                    "choices": [["message": ["content": content]]]
                ]
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ))
                return (response, try JSONSerialization.data(withJSONObject: envelope))
            }

            let requestBody = try XCTUnwrap(Self.bodyData(from: request))
            let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let requestContents = try XCTUnwrap(requestJSON["contents"] as? [[String: Any]])
            let requestParts = try XCTUnwrap(requestContents.first?["parts"] as? [[String: Any]])
            if (requestParts.first?["text"] as? String)?.contains("Episode guide entries:") == true {
                verificationCallCount += 1
                XCTAssertNil(requestJSON["tools"])
                let generationConfig = try XCTUnwrap(requestJSON["generationConfig"] as? [String: Any])
                XCTAssertNotNil(generationConfig["responseFormat"])
                let verification: [String: Any] = [
                    "match_verified": true,
                    "season_number": 2,
                    "episode_number": 2,
                    "episode_title": "Mama Drama",
                    "clip_start_seconds": NSNull(),
                    "clip_end_seconds": NSNull(),
                    "matching_subtitle": "Ron Hextall scores the final goal!",
                    "verification_evidence": "The Flyers, traffic, and unprecedented goal match the Mama Drama guide summary."
                ]
                let data = try JSONSerialization.data(withJSONObject: verification)
                return try Self.geminiResponse(text: String(data: data, encoding: .utf8)!)
            }

            generateCallCount += 1
            let json = requestJSON
            let parts = requestParts
            let inlineData = try XCTUnwrap(parts.first?["inline_data"] as? [String: Any])
            XCTAssertEqual(inlineData["mime_type"] as? String, "video/mp4")
            XCTAssertNotNil(inlineData["data"] as? String)
            XCTAssertTrue((parts.last?["text"] as? String)?.contains("dacademy") == true)
            let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
            let systemParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
            let instructions = try XCTUnwrap(systemParts.first?["text"] as? String)
            XCTAssertTrue(instructions.contains("Never let metadata override what is visible or spoken"))

            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Ron Hextall scores the final goal! Goalies can't score.",
                "visual_evidence": [
                    "Barry Goldberg wears a Philadelphia Flyers jacket.",
                    "Murray Goldberg wears a Flyers scarf in the arena.",
                    "Pops watches a hockey broadcast in the Goldberg living room."
                ],
                "candidates": [[
                    "media_title": "The Goldbergs",
                    "media_type": "tv",
                    "release_year": 2013,
                    "season_number": 4,
                    "episode_number": 16,
                    "episode_title": "The Dynamic Duo",
                    "clip_start_seconds": 630,
                    "clip_end_seconds": 750,
                    "matching_subtitle": "Ron Hextall scores the final goal!",
                    "confidence": 0.80,
                    "dialogue_score": 0.80,
                    "visual_score": 0.80,
                    "metadata_score": 0.30,
                    "hero_image_url": "https://wrong.example/guessed.jpg",
                    "watch_providers": []
                ]]
            ]
            let resultData = try JSONSerialization.data(withJSONObject: resultJSON)
            return try Self.geminiResponse(text: String(data: resultData, encoding: .utf8)!)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { "groq-test-key" }
        )
        let clipThumbnail = try XCTUnwrap(URL(string: "https://cdn.example/tiktok-thumbnail.jpg"))
        let metadata = SocialClipMetadata(
            title: "#dacademy",
            authorName: "Clip account",
            thumbnailURL: clipThumbnail,
            videoURL: URL(string: "https://cdn.example/clip.mp4"),
            searchHints: ["dacademy"]
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/t/example")
        )

        let result = try await service.identify(request: request, metadata: metadata)

        XCTAssertEqual(result.topCandidate.mediaTitle, "The Goldbergs")
        XCTAssertEqual(result.topCandidate.episodeLine, "S2 E2")
        XCTAssertEqual(result.topCandidate.episodeTitle, "Mama Drama")
        XCTAssertNil(result.topCandidate.sceneTimestampSeconds)
        XCTAssertNil(result.topCandidate.clipEndTimestampSeconds)
        XCTAssertEqual(result.topCandidate.heroImageURL, clipThumbnail)
        XCTAssertEqual(result.topCandidate.subtitleScore, 0.80)
        XCTAssertEqual(result.topCandidate.visualScore, 0.80)
        XCTAssertEqual(result.topCandidate.metadataScore, 0.30)
        XCTAssertEqual(result.analysisDetails.visualEvidence?.count, 3)
        XCTAssertEqual(result.analysisDetails.directMediaAnalyzed, true)
        XCTAssertEqual(
            result.analysisDetails.episodeVerificationEvidence,
            "The Flyers, traffic, and unprecedented goal match the Mama Drama guide summary."
        )
        XCTAssertEqual(generateCallCount, 1)
        XCTAssertEqual(verificationCallCount, 1)
    }

    func testTikTokWithoutDirectVideoRefusesMetadataOnlyGuess() async {
        let service = GeminiClipIdentificationService(apiKeyProvider: { "gemini-test-key" })
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/t/example")
        )
        let metadata = SocialClipMetadata(
            title: "#dacademy",
            authorName: "Repost account",
            thumbnailURL: nil,
            searchHints: ["dacademy"]
        )

        do {
            _ = try await service.identify(request: request, metadata: metadata)
            XCTFail("Expected SceneFind to reject metadata-only TikTok identification")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "Video unavailable")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImportedVideoIsUploadedBeforeIdentification() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        try SharedContainerStore.shared.prepare()
        let fileName = "import-test-\(UUID().uuidString).mov"
        let fileURL = SharedContainerStore.shared.filesURL.appendingPathComponent(fileName)
        try Data(repeating: 4, count: 2_048).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var generatedWithFile = false
        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/upload/v1beta/files" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"), "2048")
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Goog-Upload-URL": "https://upload.example/imported"]
                ))
                return (response, Data())
            }
            if url.host == "upload.example" {
                let envelope: [String: Any] = ["file": [
                    "name": "files/imported-test",
                    "uri": "https://generativelanguage.googleapis.com/v1beta/files/imported-test",
                    "mimeType": "video/quicktime",
                    "state": "ACTIVE"
                ]]
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, try JSONSerialization.data(withJSONObject: envelope))
            }
            if request.httpMethod == "DELETE" {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, Data())
            }

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            let inlineData = try XCTUnwrap(parts.first?["inline_data"] as? [String: Any])
            XCTAssertEqual(inlineData["mime_type"] as? String, "video/quicktime")
            XCTAssertNotNil(inlineData["data"] as? String)
            generatedWithFile = true

            let result: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Imported clip dialogue",
                "candidates": [[
                    "media_title": "Imported Show",
                    "media_type": "tv",
                    "release_year": 2024,
                    "season_number": 1,
                    "episode_number": 2,
                    "episode_title": "The Import",
                    "clip_start_seconds": 120,
                    "clip_end_seconds": 135,
                    "matching_subtitle": "Imported clip dialogue",
                    "confidence": 0.9,
                    "hero_image_url": NSNull(),
                    "watch_providers": []
                ]]
            ]
            let resultData = try JSONSerialization.data(withJSONObject: result)
            return try Self.geminiResponse(text: String(data: resultData, encoding: .utf8)!)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-test" },
            artworkService: NoArtworkService(),
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .video,
            sourcePlatform: .photos,
            localFileName: fileName
        )

        let result = try await service.identify(request: request, metadata: nil)

        XCTAssertTrue(generatedWithFile)
        XCTAssertEqual(result.topCandidate.mediaTitle, "Imported Show")
        XCTAssertEqual(result.analysisDetails.extractedFrameCount, 1)
    }

    func testMissingGeminiKeyFailsBeforeNetworkRequest() async {
        let service = GeminiClipIdentificationService(apiKeyProvider: { nil })
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://youtube.com/shorts/example")
        )

        do {
            _ = try await service.identify(request: request, metadata: nil)
            XCTFail("Expected a missing-key error")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "Setup needed")
            XCTAssertEqual(error.localizedDescription, "Add your free Gemini API key in Settings to identify new links.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFreeTierRateLimitGetsSpecificError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "error": ["message": "Resource exhausted", "status": "RESOURCE_EXHAUSTED"]
            ])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, data)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://youtube.com/shorts/example")
        )

        do {
            _ = try await service.identify(request: request, metadata: nil)
            XCTFail("Expected a free-tier limit error")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "Free-tier limit reached")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBusyPreferredModelRetriesThenUsesFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestedModels: [String] = []

        GeminiStubURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let model = try XCTUnwrap(
                url.pathComponents.first(where: { $0.hasPrefix("gemini-") })?
                    .replacingOccurrences(of: ":generateContent", with: "")
            )
            requestedModels.append(model)

            if model == "gemini-primary" {
                let data = try JSONSerialization.data(withJSONObject: [
                    "error": [
                        "message": "This model is currently experiencing high demand.",
                        "status": "UNAVAILABLE"
                    ]
                ])
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (response, data)
            }

            let result: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Fallback dialogue",
                "candidates": [[
                    "media_title": "Fallback Show",
                    "media_type": "tv",
                    "release_year": 2026,
                    "season_number": 1,
                    "episode_number": 4,
                    "episode_title": "Capacity",
                    "clip_start_seconds": 240,
                    "clip_end_seconds": 255,
                    "matching_subtitle": "Fallback dialogue",
                    "confidence": 0.91,
                    "hero_image_url": NSNull(),
                    "watch_providers": []
                ]]
            ]
            let resultData = try JSONSerialization.data(withJSONObject: result)
            return try Self.geminiResponse(text: String(data: resultData, encoding: .utf8)!)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" },
            modelProvider: { "gemini-primary" },
            artworkService: NoArtworkService(),
            fallbackModels: ["gemini-backup"],
            retryDelayNanoseconds: 0,
            groqAPIKeyProvider: { nil }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://www.youtube.com/shorts/example")
        )

        let result = try await service.identify(request: request, metadata: nil)

        XCTAssertEqual(result.topCandidate.mediaTitle, "Fallback Show")
        XCTAssertEqual(requestedModels, ["gemini-primary", "gemini-backup"])
    }

    func testDepletedPrepaidProjectGetsSpecificError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        GeminiStubURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "error": [
                    "message": "Your prepayment credits are depleted.",
                    "status": "RESOURCE_EXHAUSTED"
                ]
            ])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, data)
        }

        let service = GeminiClipIdentificationService(
            session: session,
            apiKeyProvider: { "gemini-test-key" }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://youtube.com/shorts/example")
        )

        do {
            _ = try await service.identify(request: request, metadata: nil)
            XCTFail("Expected a depleted-credit error")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "Gemini project needs credits")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func geminiResponse(text: String) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "https://generativelanguage.googleapis.com/test"))
        let envelope: [String: Any] = [
            "candidates": [["content": ["parts": [["text": text]]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, data)
    }
}

private struct NoArtworkService: TitleArtworkService {
    func artworkURL(
        for mediaTitle: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL? {
        nil
    }
}

private final class GeminiStubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("GeminiStubURLProtocol received a request without a handler")
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
