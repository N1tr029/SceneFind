import XCTest

final class GeminiClipIdentificationServiceTests: XCTestCase {
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
            let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
            let responseFormat = try XCTUnwrap(generationConfig["responseFormat"] as? [String: Any])
            let textFormat = try XCTUnwrap(responseFormat["text"] as? [String: Any])
            XCTAssertEqual(textFormat["mimeType"] as? String, "APPLICATION_JSON")
            let schema = try XCTUnwrap(textFormat["schema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")

            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Nobody calls him that anymore.",
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
            modelProvider: { "gemini-test" }
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
        XCTAssertEqual(result.topCandidate.heroImageURL, metadata.thumbnailURL)
        XCTAssertEqual(requestCount, 1)
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
            artworkService: NoArtworkService()
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/example")
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

    func testTikTokVideoIsUploadedAndIdentifiedInOneGenerateCall() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var generateCallCount = 0

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

            generateCallCount += 1
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            let fileData = try XCTUnwrap(parts.first?["file_data"] as? [String: Any])
            XCTAssertEqual(
                fileData["file_uri"] as? String,
                "https://generativelanguage.googleapis.com/v1beta/files/tiktok-test"
            )
            XCTAssertEqual(fileData["mime_type"] as? String, "video/mp4")
            XCTAssertTrue((parts.last?["text"] as? String)?.contains("bull tv series") == true)

            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "You had dinner at Della Nicci last week?",
                "candidates": [[
                    "media_title": "Bull",
                    "media_type": "tv",
                    "release_year": 2016,
                    "season_number": 3,
                    "episode_number": 9,
                    "episode_title": "Separation",
                    "clip_start_seconds": 1_417,
                    "clip_end_seconds": 434,
                    "matching_subtitle": "You had dinner at Della Nicci last week?",
                    "confidence": 0.97,
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
            artworkService: NoArtworkService()
        )
        let clipThumbnail = try XCTUnwrap(URL(string: "https://cdn.example/tiktok-thumbnail.jpg"))
        let metadata = SocialClipMetadata(
            title: "#fyp",
            authorName: "Clip account",
            thumbnailURL: clipThumbnail,
            videoURL: URL(string: "https://cdn.example/clip.mp4"),
            searchHints: ["bull tv series", "bull immigration episode"]
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/t/example")
        )

        let result = try await service.identify(request: request, metadata: metadata)

        XCTAssertEqual(result.topCandidate.mediaTitle, "Bull")
        XCTAssertEqual(result.topCandidate.episodeLine, "S3 E9")
        XCTAssertEqual(result.topCandidate.sceneTimestampSeconds, 1_417)
        XCTAssertEqual(result.topCandidate.clipEndTimestampSeconds, 434)
        XCTAssertEqual(result.topCandidate.heroImageURL, clipThumbnail)
        XCTAssertEqual(generateCallCount, 1)
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
            let fileData = try XCTUnwrap(parts.first?["file_data"] as? [String: Any])
            XCTAssertEqual(
                fileData["file_uri"] as? String,
                "https://generativelanguage.googleapis.com/v1beta/files/imported-test"
            )
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
            artworkService: NoArtworkService()
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
