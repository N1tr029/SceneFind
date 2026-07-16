import XCTest

final class KnownClipCatalogTests: XCTestCase {
    func testKnownYouTubeShortResolvesToVerifiedModernFamilyScene() async throws {
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://www.youtube.com/shorts/QD4bDD7L66M")
        )

        let result = try await HybridClipIdentificationService().identify(request: request)

        XCTAssertEqual(result.topCandidate.mediaTitle, "Modern Family")
        XCTAssertEqual(result.topCandidate.seasonNumber, 4)
        XCTAssertEqual(result.topCandidate.episodeNumber, 4)
        XCTAssertEqual(result.topCandidate.episodeTitle, "The Butler's Escape")
        XCTAssertEqual(result.topCandidate.sceneTimestampSeconds, 606)
        XCTAssertEqual(result.topCandidate.clipEndTimestampSeconds, 625)
        XCTAssertEqual(result.topCandidate.watchProviders?.count, 8)
        XCTAssertEqual(
            result.topCandidate.watchProviders?.first?.episodeURL.absoluteString,
            "https://www.hulu.com/series/modern-family-883c414c-34a3-4fcc-b50a-0ad5a184c977?entity_id=008ab86a-f287-4275-83d2-d2d7aa605bb5"
        )
        XCTAssertGreaterThan(result.topCandidate.confidence, 0.95)
    }

    func testTikTokCaptionCanResolveKnownRepost() {
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/@example/video/123"),
            sharedText: "how many times has she done this??? #ModernFamily"
        )

        let result = KnownClipCatalog.result(for: request)

        XCTAssertEqual(result?.topCandidate.episodeTitle, "The Butler's Escape")
    }
}
