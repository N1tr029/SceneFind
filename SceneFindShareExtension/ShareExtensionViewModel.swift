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
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        guard
              !attachments.isEmpty else {
            errorMessage = SceneFindError.unsupportedSharedItem.localizedDescription
            return
        }

        do {
            let attachmentText = try await sharedText(from: attachments)
            let itemText = items.compactMap { $0.attributedContentText?.string }.joined(separator: " ")
            let contextText = [attachmentText, itemText.isEmpty ? nil : itemText]
                .compactMap { $0 }
                .joined(separator: " ")

            if let request = try await loadFirst(attachments: attachments, type: .movie, contextText: contextText) {
                set(request)
            } else if let request = try await loadFirst(attachments: attachments, type: .url, contextText: contextText) {
                set(request)
            } else if let url = firstURL(in: contextText) {
                set(SharedClipRequest(
                    sourceType: .url,
                    sourcePlatform: SharedPlatform.detect(url: url),
                    originalURL: url,
                    sharedText: contextText,
                    pageTitle: "Shared from (SharedPlatform.detect(url: url).label)"
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
        summary = "\(request.sourcePlatform.label) \(request.sourceType.label)"
    }

    func appOpenFailed() {
        summary = "Saved. Open SceneFind to continue."
    }

    private func loadFirst(attachments: [NSItemProvider], type: UTType, contextText: String) async throws -> SharedClipRequest? {
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return nil }
        if type == .url {
            let value = try await provider.loadItem(forTypeIdentifier: type.identifier)
            let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
            guard let url else { throw SceneFindError.invalidURL }
            return SharedClipRequest(
                sourceType: .url,
                sourcePlatform: SharedPlatform.detect(url: url),
                originalURL: url,
                sharedText: contextText.isEmpty ? nil : contextText,
                pageTitle: provider.suggestedName
            )
        }

        if type == .plainText {
            let value = try await provider.loadItem(forTypeIdentifier: type.identifier)
            let text = value as? String
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

    private func sharedText(from attachments: [NSItemProvider]) async throws -> String? {
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else {
            return nil
        }
        let value = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
        return value as? String
    }

    private func firstURL(in text: String) -> URL? {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> URL? in
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>[](){}.,!\"'"))
                guard cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") else { return nil }
                return URL(string: cleaned)
            }
            .first
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
