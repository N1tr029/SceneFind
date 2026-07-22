import XCTest

final class LiveRegressionCorpusTests: XCTestCase {
    func testPublicClipRegressionCorpus() async throws {
        guard ProcessInfo.processInfo.environment["SCENEFIND_RUN_LIVE_CORPUS"] == "1" else {
            throw XCTSkip("Set SCENEFIND_RUN_LIVE_CORPUS=1 to run paid/free-tier API regression calls.")
        }
        guard GeminiConfiguration.isConfigured else {
            throw XCTSkip("The local Debug Gemini key is not configured.")
        }

        let urls = [
            "https://youtube.com/shorts/0SRUWOzWw8I",
            "https://www.tiktok.com/t/ZTSKqS1Mb/",
            "https://www.tiktok.com/t/ZTSKqKK8W/",
            "https://www.tiktok.com/t/ZTA1C7M9n/",
            "https://www.tiktok.com/t/ZTA1V97nG/",
            "https://www.tiktok.com/@mtyfvaqmyg8/video/7654576063070162207"
        ]
        let service = HybridClipIdentificationService()

        for rawURL in urls {
            let url = try XCTUnwrap(URL(string: rawURL))
            let started = Date()
            do {
                let result = try await service.identify(request: SharedClipRequest(
                    sourceType: .url,
                    sourcePlatform: SharedPlatform.detect(url: url),
                    originalURL: url,
                    pageTitle: "Live regression clip"
                ))
                let candidate = result.topCandidate
                print(
                    "LIVE_RESULT | \(url.host() ?? "unknown") | \(candidate.mediaTitle) | "
                    + "\(candidate.episodeLine) | \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
                )
            } catch {
                print(
                    "LIVE_RESULT | \(url.host() ?? "unknown") | ERROR | "
                    + "\(type(of: error)) | \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
                )
            }
        }
    }
}
