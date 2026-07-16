import XCTest

final class OpenAIClipIdentificationServiceTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testURLResearchResponseMapsIntoSceneFindResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "gpt-test")
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.first?["type"] as? String, "web_search")

            let resultJSON: [String: Any] = [
                "match_found": true,
                "detected_dialogue": "Every boat in this harbor has a secret name.",
                "candidates": [[
                    "media_title": "Harbor Show",
                    "media_type": "tv",
                    "release_year": 2024,
                    "season_number": 2,
                    "episode_number": 3,
                    "episode_title": "Secret Names",
                    "clip_start_seconds": 441.0,
                    "clip_end_seconds": 459.0,
                    "matching_subtitle": "Every boat in this harbor has a secret name.",
                    "confidence": 0.91,
                    "hero_image_url": NSNull(),
                    "watch_providers": [[
                        "name": "Apple TV",
                        "offer": "$2.99",
                        "url": "https://tv.apple.com/example"
                    ]]
                ]]
            ]
            let resultData = try JSONSerialization.data(withJSONObject: resultJSON)
            let outputText = try XCTUnwrap(String(data: resultData, encoding: .utf8))
            let envelope: [String: Any] = [
                "output": [[
                    "content": [["type": "output_text", "text": outputText]]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, data)
        }

        let service = OpenAIClipIdentificationService(
            session: session,
            apiKeyProvider: { "test-key" },
            modelProvider: { "gpt-test" }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://youtube.com/shorts/example")
        )
        let metadata = SocialClipMetadata(
            title: "A mysterious harbor scene",
            authorName: "Clip account",
            thumbnailURL: URL(string: "https://i.ytimg.com/example.jpg")
        )

        let result = try await service.identify(request: request, metadata: metadata)

        XCTAssertEqual(result.topCandidate.mediaTitle, "Harbor Show")
        XCTAssertEqual(result.topCandidate.mediaType, .television)
        XCTAssertEqual(result.topCandidate.episodeLine, "S2 E3")
        XCTAssertEqual(result.topCandidate.sceneTimestampSeconds, 441)
        XCTAssertEqual(result.topCandidate.clipEndTimestampSeconds, 459)
        XCTAssertEqual(result.topCandidate.watchProviders?.first?.name, "Apple TV")
        XCTAssertEqual(result.topCandidate.heroImageURL, metadata.thumbnailURL)
    }

    func testMissingKeyFailsBeforeNetworkRequest() async {
        let service = OpenAIClipIdentificationService(apiKeyProvider: { nil })
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/@example/video/123")
        )

        do {
            _ = try await service.identify(request: request, metadata: nil)
            XCTFail("Expected a missing-key error")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.localizedDescription, "Add your OpenAI API key in Settings to identify new links.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQuotaErrorIsReportedAsBillingProblem() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.requestHandler = { request in
            let envelope: [String: Any] = [
                "error": [
                    "message": "You exceeded your current quota.",
                    "type": "insufficient_quota",
                    "code": "insufficient_quota"
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, data)
        }

        let service = OpenAIClipIdentificationService(
            session: session,
            apiKeyProvider: { "test-key" }
        )
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://youtube.com/shorts/example")
        )

        do {
            _ = try await service.identify(request: request, metadata: nil)
            XCTFail("Expected a quota error")
        } catch let error as SceneFindError {
            XCTAssertEqual(error.failureTitle, "API billing required")
            XCTAssertEqual(error.localizedDescription, "This OpenAI API account has no available quota. Add API billing or credits, then try again.")
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
}

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("StubURLProtocol received a request without a handler")
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
