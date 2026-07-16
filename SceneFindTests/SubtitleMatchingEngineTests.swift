import XCTest

final class SubtitleMatchingEngineTests: XCTestCase {
    private var engine: SubtitleMatchingEngine!
    private var library: [MediaTitle]!

    override func setUp() {
        super.setUp()
        engine = SubtitleMatchingEngine()
        library = MockMediaLibrary.titles
    }

    func testExactDialogueMatchRanksHigh() {
        let matches = engine.rankedMatches(query: "We have one sunrise left before the orbit closes.", library: library)
        XCTAssertEqual(topTitle(matches), "Axiom Sunrise")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.85)
    }

    func testMinorTranscriptionMistakesStillMatch() {
        let matches = engine.rankedMatches(query: "we have one sun rise left before orbit closes", library: library)
        XCTAssertEqual(topTitle(matches), "Axiom Sunrise")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.55)
    }

    func testMissingWordsStillMatch() {
        let matches = engine.rankedMatches(query: "blue umbrella opens everyone changes", library: library)
        XCTAssertEqual(topTitle(matches), "The Blue Umbrella Job")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.45)
    }

    func testExtraWordsStillMatch() {
        let matches = engine.rankedMatches(query: "funny clip where the lighthouse blinked twice before the phone rang wow", library: library)
        XCTAssertEqual(topTitle(matches), "Harbor After Midnight")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.45)
    }

    func testNoMatchReturnsEmptyForUnrelatedText() {
        let matches = engine.rankedMatches(query: "purple toaster calendar engine with no useful scene words", library: library)
        XCTAssertTrue(matches.isEmpty)
    }

    func testMultiplePossibleMatchesAreRanked() {
        let matches = engine.rankedMatches(query: "signal truth static broadcast", library: library)
        XCTAssertGreaterThanOrEqual(matches.count, 2)
        XCTAssertGreaterThanOrEqual(matches[0].score, matches[1].score)
    }

    private func topTitle(_ matches: [SubtitleMatch]) -> String? {
        guard let match = matches.first else { return nil }
        return library.first { $0.id == match.mediaID }?.title
    }
}

