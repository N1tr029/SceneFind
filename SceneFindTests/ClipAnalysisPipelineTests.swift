import XCTest

final class ClipAnalysisPipelineTests: XCTestCase {
    func testPipelineProducesDeterministicStrongCandidateFromURLKeywords() async throws {
        let request = SharedClipRequest(
            sourceType: .url,
            sourcePlatform: .youtube,
            originalURL: URL(string: "https://youtube.com/shorts/space-mission-astronaut"),
            pageTitle: "Axiom Sunrise mission clip"
        )

        let result = try await ClipAnalysisPipeline().analyze(request: request)
        XCTAssertEqual(result.topCandidate.mediaTitle, "Axiom Sunrise")
        XCTAssertGreaterThan(result.topCandidate.confidence, 0.60)
        XCTAssertFalse(result.alternativeCandidates.isEmpty)
    }
}

