import PhotosUI
import SwiftUI

/// Turns a Photos pick into a pending clip request.
///
/// Home and the Instagram notice on a result both offer to import a video, and
/// both must store the file, thumbnail and request the same way or the analysis
/// screen cannot find the clip. Compression happens later, at upload.
@MainActor
enum VideoImport {
    static func pendingRequest(
        from item: PhotosPickerItem,
        store: SharedContainerStore
    ) async throws -> SharedClipRequest {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw SceneFindError.sharedFileMissing
        }
        try store.prepare()
        let fileName = "imported-\(UUID().uuidString).mov"
        let destination = store.filesURL.appendingPathComponent(fileName)
        try data.write(to: destination, options: [.atomic])
        let thumbnail = try? store.generateThumbnail(for: destination)
        let request = SharedClipRequest(
            sourceType: .video,
            sourcePlatform: .photos,
            localFileName: fileName,
            pageTitle: item.itemIdentifier,
            thumbnailFileName: thumbnail ?? nil
        )
        try store.saveRequest(request)
        _ = store.consumePendingRequestID()
        return request
    }
}

extension SharedPlatform {
    /// Instagram hands other apps a reel's cover image and caption but never
    /// the video, so a link can name the show but not the episode or moment.
    static let instagramLinkLimit =
        "Instagram only shares a reel's cover and caption with other apps, so SceneFind can name the show but can't hear the dialogue that pins down the episode."
}
