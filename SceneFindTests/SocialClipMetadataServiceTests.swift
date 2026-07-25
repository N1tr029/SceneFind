import XCTest

final class SocialClipMetadataServiceTests: XCTestCase {
    override func tearDown() {
        SocialMetadataStubURLProtocol.handler = nil
        super.tearDown()
    }

    /// The gate that decides whether a clip gets the cheap text-only
    /// identification pass at all. Hashtags, @handles, and bare links are not
    /// evidence — counting them is how the pipeline used to talk itself into
    /// naming a title from "#fyp #viral" alone.
    func testTextIdentificationNeedsRealWordsNotHashtags() throws {
        XCTAssertFalse(metadata(title: "#fyp #viral #foryou #trending").supportsTextIdentification)
        XCTAssertFalse(metadata(title: "@dharmann https://example.com/x").supportsTextIdentification)
        XCTAssertFalse(metadata(title: "wait for it").supportsTextIdentification)
        XCTAssertTrue(metadata(title: "Ant-Man Baskin Robbins scene").supportsTextIdentification)
        XCTAssertTrue(metadata(caption: "The Rookie S2 E9 hospital").supportsTextIdentification)

        // A transcript is evidence in its own right, but only once there is
        // enough of it: a few words of music captions identify nothing.
        let elevenWords = transcript(words: 11)
        let twelveWords = transcript(words: 12)
        XCTAssertFalse(metadata(title: "#fyp", transcript: elevenWords).supportsTextIdentification)
        XCTAssertTrue(metadata(title: "#fyp", transcript: twelveWords).supportsTextIdentification)
    }

    private func metadata(
        title: String? = nil,
        caption: String? = nil,
        transcript: ClipTranscript? = nil
    ) -> SocialClipMetadata {
        SocialClipMetadata(
            title: title,
            authorName: nil,
            thumbnailURL: nil,
            caption: caption,
            transcript: transcript
        )
    }

    private func transcript(words: Int) -> ClipTranscript {
        ClipTranscript(
            cues: [ClipTranscript.Cue(
                startSeconds: 0,
                endSeconds: 3,
                text: (1...words).map { "word\($0)" }.joined(separator: " ")
            )],
            source: .tikTokASR
        )
    }

    func testTikTokPageEvidenceSurvivesOEmbedFailureAndKeepsCanonicalURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialMetadataStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let canonical = try XCTUnwrap(URL(string: "https://www.tiktok.com/@account/video/7654576063070162207"))
        let pageJSON: [String: Any] = [
            "__DEFAULT_SCOPE__": [
                "webapp.video-detail": [
                    "itemInfo": [
                        "itemStruct": [
                            "video": [
                                "playAddr": "https://cdn.example/clip.mp4",
                                "originCover": "https://cdn.example/cover.jpg"
                            ],
                            "suggestedWords": ["hospital dialogue"]
                        ]
                    ]
                ]
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: pageJSON)
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let html = Data("<script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\">\(jsonText)</script>".utf8)

        SocialMetadataStubURLProtocol.handler = { request in
            if request.url?.path == "/oembed" {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: canonical, statusCode: 200, httpVersion: nil, headerFields: nil)!, html)
        }

        let metadata = try await OEmbedSocialClipMetadataService(session: session).metadata(
            for: URL(string: "https://www.tiktok.com/t/short-link/")!
        )

        XCTAssertEqual(metadata.canonicalURL, canonical)
        XCTAssertEqual(metadata.videoURL?.absoluteString, "https://cdn.example/clip.mp4")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://cdn.example/cover.jpg")
        XCTAssertEqual(metadata.searchHints, ["hospital dialogue"])
    }

    func testTikTokOpenGraphEvidenceSurvivesStructuredPayloadChanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialMetadataStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let canonical = try XCTUnwrap(URL(string: "https://www.tiktok.com/@account/video/123456789"))
        let html = Data("""
        <html><head>
        <meta property="og:video:url" content="https://cdn.example/clip.mp4?token=one&amp;quality=high">
        <meta name="twitter:image" content="https://cdn.example/cover.jpg">
        </head></html>
        """.utf8)

        SocialMetadataStubURLProtocol.handler = { request in
            if request.url?.path == "/oembed" {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: canonical, statusCode: 200, httpVersion: nil, headerFields: nil)!, html)
        }

        let metadata = try await OEmbedSocialClipMetadataService(session: session).metadata(
            for: URL(string: "https://www.tiktok.com/t/short-link/")!
        )

        XCTAssertEqual(metadata.canonicalURL, canonical)
        XCTAssertEqual(metadata.videoURL?.absoluteString, "https://cdn.example/clip.mp4?token=one&quality=high")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://cdn.example/cover.jpg")
    }
}

private final class SocialMetadataStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
