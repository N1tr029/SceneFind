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

            if requestCount == 1 {
                XCTAssertNil(json["tools"])
                let fileData = try XCTUnwrap(parts.first?["file_data"] as? [String: Any])
                XCTAssertEqual(
                    fileData["file_uri"] as? String,
                    "https://www.youtube.com/watch?v=abc123"
                )
                return try Self.geminiResponse(
                    text: "Dialogue: Nobody calls him that anymore. Two people are speaking in a kitchen."
                )
            }

            XCTAssertNil(json["tools"])
            XCTAssertNil(parts.first?["file_data"])
            let prompt = try XCTUnwrap(parts.first?["text"] as? String)
            XCTAssertTrue(prompt.contains("Nobody calls him that anymore"))
            let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
            XCTAssertNil(generationConfig["responseJsonSchema"])
            XCTAssertNil(generationConfig["responseMimeType"])

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
                    "scene_start_seconds": 732.0,
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
        XCTAssertEqual(requestCount, 2)
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
