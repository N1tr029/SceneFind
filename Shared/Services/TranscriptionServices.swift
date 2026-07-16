import Foundation

protocol SpeechTranscriptionService {
    func transcribe(request: SharedClipRequest, videoURL: URL?) async throws -> TranscriptionResult
}

final class MockSpeechTranscriptionService: SpeechTranscriptionService {
    func transcribe(request: SharedClipRequest, videoURL: URL?) async throws -> TranscriptionResult {
        let haystack = [
            request.originalURL?.absoluteString,
            request.sharedText,
            request.pageTitle,
            request.localFileName,
            videoURL?.lastPathComponent
        ].compactMap { $0?.lowercased() }.joined(separator: " ")

        let pairs: [(String, String)] = [
            ("office paper scranton", "That is not a meeting, it is a room full of panic."),
            ("space mission astronaut mars", "We have one sunrise left before the orbit closes."),
            ("harbor lighthouse fog", "The lighthouse blinked twice before the phone rang."),
            ("train aurora snow", "Aurora is not a city, it is our last chance."),
            ("umbrella heist vault", "When the blue umbrella opens, everyone changes partners."),
            ("garden glass flower", "Every glass flower blooms for a memory you refuse to name."),
            ("classroom school chalk", "Put the answer down, then tell me why it scares you."),
            ("no match unknown static", "A sentence that does not belong to the local demo set.")
        ]

        for pair in pairs where pair.0.split(separator: " ").contains(where: { haystack.contains($0) }) {
            return TranscriptionResult(text: pair.1, confidence: 0.91)
        }

        if let text = request.sharedText, text.split(separator: " ").count > 3 {
            return TranscriptionResult(text: text, confidence: 0.76)
        }

        let index = abs(request.id.uuidString.hashValue) % MockMediaLibrary.titles.count
        let title = MockMediaLibrary.titles[index]
        let segments = title.episodes.first?.subtitleSegments ?? []
        let segmentIndex = segments.isEmpty ? 0 : abs(request.id.uuidString.hashValue / 7) % segments.count
        let segment = segments.isEmpty ? "The clip is quiet, but the scene has a familiar shape." : segments[segmentIndex].text
        return TranscriptionResult(text: segment, confidence: 0.68)
    }
}

final class SystemSpeechTranscriptionService: SpeechTranscriptionService {
    func transcribe(request: SharedClipRequest, videoURL: URL?) async throws -> TranscriptionResult {
        // Experimental placeholder for a future Apple Speech + AVFoundation implementation.
        throw SceneFindError.permissionDenied
    }
}
