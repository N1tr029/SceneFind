import AVFoundation
import Foundation
import UIKit

final class VideoFrameExtractionService {
    private let store: SharedContainerStore

    init(store: SharedContainerStore = .shared) {
        self.store = store
    }

    func extractFrames(from videoURL: URL) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var frames: [ExtractedFrame] = []

        for percent in [0.10, 0.30, 0.50, 0.70, 0.90] {
            let timestamp = duration * percent
            do {
                let cgImage = try generator.copyCGImage(at: CMTime(seconds: timestamp, preferredTimescale: 600), actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                let fileName = try store.saveImage(image)
                if let url = store.resolveFileURL(fileName: fileName) {
                    frames.append(ExtractedFrame(id: UUID(), timestamp: timestamp, imageURL: url))
                }
            } catch {
                continue
            }
        }
        return frames
    }
}

protocol VisualMatchingService {
    func compare(requestID: UUID, frames: [ExtractedFrame], candidates: [SceneCandidate]) async throws -> [VisualMatchScore]
}

final class MockVisualMatchingService: VisualMatchingService {
    func compare(requestID: UUID, frames: [ExtractedFrame], candidates: [SceneCandidate]) async throws -> [VisualMatchScore] {
        candidates.map { candidate in
            let seed = "\(requestID.uuidString)-\(candidate.id.uuidString)-\(frames.count)"
            let value = abs(seed.hashValue % 38)
            return VisualMatchScore(candidateID: candidate.id, score: 0.42 + Double(value) / 100.0)
        }
    }
}

