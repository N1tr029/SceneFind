import XCTest
@testable import SceneFind

final class SharedURLExtractorTests: XCTestCase {
    func testFindsTikTokURLInsideSharedCaption() {
        let text = "Watch this clip on TikTok https://www.tiktok.com/t/ZT8example/ more text"

        XCTAssertEqual(
            SharedURLExtractor.firstURL(in: text)?.absoluteString,
            "https://www.tiktok.com/t/ZT8example/"
        )
    }

    func testTrimsPunctuationAroundURL() {
        XCTAssertEqual(
            SharedURLExtractor.firstURL(in: "(https://youtube.com/shorts/abc123).")?.absoluteString,
            "https://youtube.com/shorts/abc123"
        )
    }

    func testRejectsNonWebURL() {
        XCTAssertNil(SharedURLExtractor.firstURL(in: "scenefind://analyze?requestID=123"))
    }
}
