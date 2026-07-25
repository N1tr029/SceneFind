import XCTest

final class LiveRegressionCorpusTests: XCTestCase {
    func testPublicClipRegressionCorpus() async throws {
        guard ProcessInfo.processInfo.environment["SCENEFIND_RUN_LIVE_CORPUS"] == "1" else {
            throw XCTSkip("Set SCENEFIND_RUN_LIVE_CORPUS=1 to run paid/free-tier API regression calls.")
        }
        guard GeminiConfiguration.isConfigured else {
            throw XCTSkip("The local Debug Gemini key is not configured.")
        }

        // The first three are the clips the evidence-first pipeline was built
        // against, one per platform, and each exercises a different path:
        //   Instagram — the answer is in the Reel's og:description caption
        //               ("Ant-Man (2015)"), with no fetchable video at all.
        //   TikTok    — the caption is just "#fyp"; the identification comes
        //               from TikTok's free ASR caption track, which also gives
        //               the dialogue that locates the scene in the runtime.
        //   YouTube   — oEmbed answers 401 for this video because embedding is
        //               disabled, so the title and episode have to come from the
        //               watch page's own description.
        let urls = [
            "https://www.instagram.com/reel/DUnCvbnif6s/",
            "https://www.tiktok.com/t/ZTAY2LwFE/",
            "https://youtube.com/shorts/N4UpQBoE9Ak",
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
                let timestamp = candidate.sceneTimestampSeconds
                    .map { "\($0.timestampString) (\(candidate.timestampAccuracy?.label ?? "unlabelled"))" }
                    ?? "no timestamp"
                print(
                    "LIVE_RESULT | \(url.host() ?? "unknown") | \(candidate.mediaTitle) | "
                    + "\(candidate.episodeLine) | \(timestamp) | "
                    + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s"
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
