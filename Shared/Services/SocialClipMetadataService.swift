import Foundation

struct SocialClipMetadata: Hashable {
    let title: String?
    let authorName: String?
    let thumbnailURL: URL?
    let videoURL: URL?
    let searchHints: [String]

    init(
        title: String?,
        authorName: String?,
        thumbnailURL: URL?,
        videoURL: URL? = nil,
        searchHints: [String] = []
    ) {
        self.title = title
        self.authorName = authorName
        self.thumbnailURL = thumbnailURL
        self.videoURL = videoURL
        self.searchHints = searchHints
    }
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

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(for url: URL) async throws -> SocialClipMetadata {
        guard let endpoint = endpoint(for: url) else {
            throw SceneFindError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.setValue("SceneFind/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SceneFindError.invalidURL
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let pageMetadata = SharedPlatform.detect(url: url) == .tiktok
            ? await tiktokPageMetadata(for: url)
            : nil
        return SocialClipMetadata(
            title: decoded.title,
            authorName: decoded.authorName,
            thumbnailURL: decoded.thumbnailURL ?? pageMetadata?.thumbnailURL,
            videoURL: pageMetadata?.videoURL,
            searchHints: pageMetadata?.searchHints ?? []
        )
    }

    private func tiktokPageMetadata(for url: URL) async -> TikTokPageMetadata? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return TikTokPageParser.metadata(from: data)
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

struct TikTokPageMetadata: Equatable {
    let videoURL: URL?
    let thumbnailURL: URL?
    let searchHints: [String]
}

enum TikTokPageParser {
    static func metadata(from data: Data) -> TikTokPageMetadata? {
        guard let html = String(data: data, encoding: .utf8),
              let scriptData = scriptJSON(in: html),
              let root = try? JSONSerialization.jsonObject(with: scriptData) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any],
              let detail = scope["webapp.video-detail"] as? [String: Any],
              let itemInfo = detail["itemInfo"] as? [String: Any],
              let item = itemInfo["itemStruct"] as? [String: Any] else { return nil }

        let video = item["video"] as? [String: Any]
        let videoURL = (video?["playAddr"] as? String).flatMap(URL.init(string:))
            ?? (((video?["PlayAddrStruct"] as? [String: Any])?["UrlList"] as? [String])?.first)
                .flatMap(URL.init(string:))
        let thumbnailURL = (video?["originCover"] as? String).flatMap(URL.init(string:))
            ?? (video?["cover"] as? String).flatMap(URL.init(string:))
        let hints = (item["suggestedWords"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard videoURL != nil || thumbnailURL != nil || !hints.isEmpty else { return nil }
        return TikTokPageMetadata(
            videoURL: videoURL,
            thumbnailURL: thumbnailURL,
            searchHints: Array(hints.prefix(12))
        )
    }

    private static func scriptJSON(in html: String) -> Data? {
        guard let idRange = html.range(of: "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\""),
              let openingTagEnd = html[idRange.upperBound...].firstIndex(of: ">"),
              let closingTag = html.range(of: "</script>", range: openingTagEnd..<html.endIndex) else {
            return nil
        }
        return String(html[html.index(after: openingTagEnd)..<closingTag.lowerBound]).data(using: .utf8)
    }
}

protocol TitleArtworkService {
    func artworkURL(
        for mediaTitle: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL?
}

final class PublicTitleArtworkService: TitleArtworkService {
    private struct TVMazeShow: Decodable {
        struct Image: Decodable {
            let medium: URL?
            let original: URL?
        }
        struct Embedded: Decodable {
            struct Episode: Decodable {
                let season: Int
                let number: Int
                let image: Image?
            }
            let episodes: [Episode]
        }

        let image: Image?
        let embedded: Embedded?

        enum CodingKeys: String, CodingKey {
            case image
            case embedded = "_embedded"
        }
    }

    private struct ITunesResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: URL?
        }
        let results: [Result]
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func artworkURL(
        for mediaTitle: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL? {
        switch mediaType {
        case .television:
            return await televisionArtwork(
                title: mediaTitle,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )
        case .movie:
            return await movieArtwork(title: mediaTitle)
        }
    }

    private func televisionArtwork(
        title: String,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL? {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")
        components?.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "embed", value: "episodes")
        ]
        guard let url = components?.url,
              let show: TVMazeShow = await decodedResponse(from: url) else { return nil }
        let episodeImage = show.embedded?.episodes.first {
            $0.season == seasonNumber && $0.number == episodeNumber
        }?.image
        return episodeImage?.original ?? episodeImage?.medium ?? show.image?.original ?? show.image?.medium
    }

    private func movieArtwork(title: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "media", value: "movie"),
            URLQueryItem(name: "entity", value: "movie"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url,
              let response: ITunesResponse = await decodedResponse(from: url),
              let artwork = response.results.first?.artworkUrl100 else { return nil }
        return URL(string: artwork.absoluteString.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
    }

    private func decodedResponse<T: Decodable>(from url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
