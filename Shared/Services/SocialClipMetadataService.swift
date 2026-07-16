import Foundation

struct SocialClipMetadata: Hashable {
    let title: String?
    let authorName: String?
    let thumbnailURL: URL?
}

protocol SocialClipMetadataService {
    func metadata(for url: URL) async throws -> SocialClipMetadata
}

final class OEmbedSocialClipMetadataService: SocialClipMetadataService {
    private struct Response: Decodable {
        let title: String?
        let authorName: String?
        let thumbnailURL: URL?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    func metadata(for url: URL) async throws -> SocialClipMetadata {
        guard let endpoint = endpoint(for: url) else {
            throw SceneFindError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.setValue("SceneFind/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SceneFindError.invalidURL
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return SocialClipMetadata(
            title: decoded.title,
            authorName: decoded.authorName,
            thumbnailURL: decoded.thumbnailURL
        )
    }

    private func endpoint(for url: URL) -> URL? {
        let base: String
        switch SharedPlatform.detect(url: url) {
        case .youtube:
            base = "https://www.youtube.com/oembed"
        case .tiktok:
            base = "https://www.tiktok.com/oembed"
        default:
            return nil
        }

        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }
}
