import AVFoundation
import Foundation
import UIKit

final class SharedContainerStore {
    static let shared = SharedContainerStore()

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var rootURL: URL {
        if let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfiguration.identifier) {
            return url
        }
        return fileManager.temporaryDirectory.appendingPathComponent("SceneFindAppGroup", isDirectory: true)
    }

    var requestsURL: URL { rootURL.appendingPathComponent("Requests", isDirectory: true) }
    var filesURL: URL { rootURL.appendingPathComponent("Files", isDirectory: true) }

    func prepare() throws {
        try fileManager.createDirectory(at: requestsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)
    }

    func saveRequest(_ request: SharedClipRequest) throws {
        try prepare()
        let data = try encoder.encode(request)
        try data.write(to: requestFileURL(id: request.id), options: [.atomic])
        saveRecentRequestID(request.id)
    }

    func loadRequest(id: UUID) throws -> SharedClipRequest {
        let url = requestFileURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { throw SceneFindError.requestNotFound }
        return try decoder.decode(SharedClipRequest.self, from: Data(contentsOf: url))
    }

    func deleteRequest(id: UUID) throws {
        let url = requestFileURL(id: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func listPendingRequests() throws -> [SharedClipRequest] {
        try prepare()
        return try fileManager.contentsOfDirectory(at: requestsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SharedClipRequest.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func copySharedFile(from sourceURL: URL, preferredExtension: String?) throws -> String {
        try prepare()
        let ext = preferredExtension ?? sourceURL.pathExtension
        let fileName = safeFileName(prefix: "shared", extension: ext.isEmpty ? "dat" : ext)
        let destination = filesURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return fileName
    }

    func saveImage(_ image: UIImage) throws -> String {
        try prepare()
        let fileName = safeFileName(prefix: "image", extension: "jpg")
        let destination = filesURL.appendingPathComponent(fileName)
        guard let data = image.jpegData(compressionQuality: 0.82) else { throw SceneFindError.thumbnailFailed }
        try data.write(to: destination, options: [.atomic])
        return fileName
    }

    func generateThumbnail(for videoURL: URL) throws -> String? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try generator.copyCGImage(at: CMTime(seconds: 0.6, preferredTimescale: 600), actualTime: nil)
        return try saveImage(UIImage(cgImage: cgImage))
    }

    func resolveFileURL(fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return filesURL.appendingPathComponent(fileName)
    }

    func saveRecentRequestID(_ id: UUID) {
        let defaults = UserDefaults(suiteName: AppGroupConfiguration.identifier) ?? .standard
        var ids = defaults.stringArray(forKey: "recentRequestIDs") ?? []
        ids.removeAll { $0 == id.uuidString }
        ids.insert(id.uuidString, at: 0)
        defaults.set(Array(ids.prefix(20)), forKey: "recentRequestIDs")
        defaults.set(id.uuidString, forKey: "pendingRequestID")
    }

    func consumePendingRequestID() -> UUID? {
        let defaults = UserDefaults(suiteName: AppGroupConfiguration.identifier) ?? .standard
        guard let value = defaults.string(forKey: "pendingRequestID"),
              let id = UUID(uuidString: value) else {
            return nil
        }
        defaults.removeObject(forKey: "pendingRequestID")
        return id
    }

    func cleanOldTemporaryFiles(olderThan days: Int = 7) throws {
        try prepare()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for url in try fileManager.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if (values.contentModificationDate ?? .distantFuture) < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func requestFileURL(id: UUID) -> URL {
        requestsURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func safeFileName(prefix: String, extension ext: String) -> String {
        "\(prefix)-\(UUID().uuidString).\(ext.lowercased())"
    }
}
