import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Shrinks a video until it fits the backend's upload limit.
///
/// Saved reels and screen recordings are routinely 10–40 MB and the backend
/// accepts 8 MB, so without this the "import the video" advice for Instagram
/// clips ended in "Clip too large" most of the time. Identification needs the
/// dialogue and a few frames, not HD, so a medium re-encode keeps everything
/// that matters. A clip too long to fit even at low quality keeps its opening,
/// which still carries the lines used to match an episode.
enum VideoCompressor {
    /// The backend rejects anything larger.
    static let backendLimitBytes = 8_000_000
    /// AVFoundation can overshoot `fileLengthLimit`, so aim below the real cap.
    private static let targetBytes: Int64 = 7_000_000

    /// Returns `source` when it can be uploaded as-is. Otherwise returns a new
    /// temporary MP4 the caller must delete.
    static func uploadableVideo(from source: URL) async throws -> URL {
        if fileSize(source) <= backendLimitBytes, isMPEG4(source) { return source }

        var attempts: [(preset: String, lengthLimit: Int64?)] = []
        // Already small enough: repackage as MP4 without re-encoding, which is
        // instant and keeps full quality.
        if fileSize(source) <= backendLimitBytes {
            attempts.append((AVAssetExportPresetPassthrough, nil))
        }
        attempts += [
            (AVAssetExportPresetMediumQuality, nil),
            (AVAssetExportPresetLowQuality, nil),
            (AVAssetExportPresetLowQuality, targetBytes),
        ]
        for attempt in attempts {
            guard let output = await export(source, preset: attempt.preset, lengthLimit: attempt.lengthLimit) else {
                continue
            }
            if fileSize(output) <= backendLimitBytes { return output }
            try? FileManager.default.removeItem(at: output)
        }
        // Nothing re-encoded. A small file in another container can still go
        // up untouched; a large one cannot.
        if fileSize(source) <= backendLimitBytes { return source }
        throw SceneFindError.mediaTooLarge
    }

    private static func export(_ source: URL, preset: String, lengthLimit: Int64?) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        let fileType: AVFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenefind-upload-\(UUID().uuidString)")
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let lengthLimit { session.fileLengthLimit = lengthLimit }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    }

    /// Groq's transcription endpoint takes MP4 but not QuickTime, and imports
    /// are saved as .mov, so anything that isn't already MP4 gets re-encoded.
    private static func isMPEG4(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .mpeg4Movie)
    }
}
