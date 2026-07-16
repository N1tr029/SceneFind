import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    @Published var request: SharedClipRequest?
    @Published var summary = "Reading shared content..."
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var openURL: URL?

    private let store = SharedContainerStore.shared

    func load(from context: NSExtensionContext?) async {
        isLoading = true
        defer { isLoading = false }
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        guard
              !attachments.isEmpty else {
            errorMessage = SceneFindError.unsupportedSharedItem.localizedDescription
            return
        }

        do {
            let attachmentText = await sharedText(from: attachments)
            let itemText = items.compactMap { $0.attributedContentText?.string }.joined(separator: " ")
            let contextText = [attachmentText, itemText.isEmpty ? nil : itemText]
                .compactMap { $0 }
                .joined(separator: " ")

            if let request = try await loadFirst(attachments: attachments, type: .movie, contextText: contextText) {
                set(request)
            } else if let request = await loadURL(attachments: attachments, contextText: contextText) {
                set(request)
            } else if let url = SharedURLExtractor.firstURL(in: contextText) {
                set(SharedClipRequest(
                    sourceType: .url,
                    sourcePlatform: SharedPlatform.detect(url: url),
                    originalURL: url,
                    sharedText: contextText,
                    pageTitle: "Shared from \(SharedPlatform.detect(url: url).label)"
                ))
            } else if let request = try await loadFirst(attachments: attachments, type: .image, contextText: contextText) {
                set(request)
            } else if let request = try await loadFirst(attachments: attachments, type: .plainText, contextText: contextText) {
                set(request)
            } else {
                throw SceneFindError.unsupportedSharedItem
            }
        } catch {
            errorMessage = error.localizedDescription
            summary = "Unsupported item"
        }
    }

    @discardableResult
    func save() async -> URL? {
        guard let request else { return nil }
        isLoading = true
        do {
            try store.saveRequest(request)
            openURL = URL(string: "scenefind://analyze?requestID=\(request.id.uuidString)")
            summary = "Opening SceneFind..."
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        return openURL
    }

    private func set(_ request: SharedClipRequest) {
        self.request = request
        summary = request.originalURL?.absoluteString ?? "\(request.sourcePlatform.label) \(request.sourceType.label)"
    }

    func appOpenFailed() {
        summary = "Saved. Open SceneFind to continue."
    }

    private func loadFirst(attachments: [NSItemProvider], type: UTType, contextText: String) async throws -> SharedClipRequest? {
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return nil }
        if type == .plainText {
            let value = try await provider.loadItem(forTypeIdentifier: type.identifier)
            let text = value as? String
            if let text, let url = SharedURLExtractor.firstURL(in: text) {
                return urlRequest(url: url, contextText: contextText, suggestedName: provider.suggestedName)
            }
            return SharedClipRequest(sourceType: .plainText, sourcePlatform: .unknown, sharedText: text, pageTitle: provider.suggestedName)
        }

        if type == .image {
            let value = try await provider.loadItem(forTypeIdentifier: type.identifier)
            if let image = value as? UIImage {
                let fileName = try store.saveImage(image)
                return SharedClipRequest(sourceType: .image, sourcePlatform: .photos, localFileName: fileName, pageTitle: provider.suggestedName, thumbnailFileName: fileName)
            }
            if let url = value as? URL {
                let fileName = try store.copySharedFile(from: url, preferredExtension: url.pathExtension)
                return SharedClipRequest(sourceType: .image, sourcePlatform: .files, localFileName: fileName, pageTitle: provider.suggestedName, thumbnailFileName: fileName)
            }
        }

        if type == .movie {
            let value = try await provider.loadItem(forTypeIdentifier: type.identifier)
            guard let url = value as? URL else { throw SceneFindError.sharedFileMissing }
            let fileName = try store.copySharedFile(from: url, preferredExtension: url.pathExtension)
            let thumbnail = try? store.generateThumbnail(for: store.resolveFileURL(fileName: fileName) ?? url)
            return SharedClipRequest(sourceType: .video, sourcePlatform: .files, localFileName: fileName, pageTitle: provider.suggestedName, thumbnailFileName: thumbnail ?? nil)
        }

        return nil
    }

    private func loadURL(attachments: [NSItemProvider], contextText: String) async -> SharedClipRequest? {
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) else { continue }
            let url = value as? URL
                ?? (value as? NSURL).map { $0 as URL }
                ?? (value as? String).flatMap(SharedURLExtractor.firstURL(in:))
            if let url, SharedURLExtractor.isWebURL(url) {
                return urlRequest(url: url, contextText: contextText, suggestedName: provider.suggestedName)
            }
        }
        return nil
    }

    private func urlRequest(url: URL, contextText: String, suggestedName: String?) -> SharedClipRequest {
        SharedClipRequest(
            sourceType: .url,
            sourcePlatform: SharedPlatform.detect(url: url),
            originalURL: url,
            sharedText: contextText.isEmpty ? nil : contextText,
            pageTitle: suggestedName ?? "Shared from \(SharedPlatform.detect(url: url).label)"
        )
    }

    private func sharedText(from attachments: [NSItemProvider]) async -> String? {
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
               let text = value as? String,
               !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

extension NSItemProvider {
    func loadItem(forTypeIdentifier identifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }
}
