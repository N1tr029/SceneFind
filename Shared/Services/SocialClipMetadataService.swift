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
        let html: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
            case html
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
            ? await tiktokPageMetadata(for: url, oEmbedHTML: decoded.html)
            : nil
        return SocialClipMetadata(
            title: decoded.title,
            authorName: decoded.authorName,
            thumbnailURL: decoded.thumbnailURL ?? pageMetadata?.thumbnailURL,
            videoURL: pageMetadata?.videoURL,
            searchHints: pageMetadata?.searchHints ?? []
        )
    }

    private func tiktokPageMetadata(for url: URL, oEmbedHTML: String?) async -> TikTokPageMetadata? {
        if let videoID = oEmbedHTML.flatMap({ Self.tiktokVideoID(in: $0) })
            ?? Self.tiktokVideoID(in: url.absoluteString),
           let embedURL = URL(string: "https://www.tiktok.com/embed/v2/\(videoID)"),
           let metadata = await tiktokPageMetadata(at: embedURL) {
            return metadata
        }
        return await tiktokPageMetadata(at: url)
    }

    private func tiktokPageMetadata(at url: URL) async -> TikTokPageMetadata? {
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

    private static func tiktokVideoID(in value: String) -> String? {
        let patterns = [#"data-video-id=[\"'](\d+)[\"']"#, #"/video/(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { continue }
            return String(value[range])
        }
        return nil
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
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        if let item = universalItem(in: html) {
            return metadata(from: item)
        }
        if let item = embedItem(in: html) {
            return metadata(from: item)
        }
        return nil
    }

    private static func metadata(from item: [String: Any]) -> TikTokPageMetadata? {
        let video = item["video"] as? [String: Any]
        let videoURL = ((video?["urls"] as? [String])?.first).flatMap(URL.init(string:))
            ?? (video?["playAddr"] as? String).flatMap(URL.init(string:))
            ?? (((video?["PlayAddrStruct"] as? [String: Any])?["UrlList"] as? [String])?.first)
                .flatMap(URL.init(string:))
        let thumbnailURL = ((item["coversOrigin"] as? [String])?.first).flatMap(URL.init(string:))
            ?? ((item["covers"] as? [String])?.first).flatMap(URL.init(string:))
            ?? (video?["originCover"] as? String).flatMap(URL.init(string:))
            ?? (video?["cover"] as? String).flatMap(URL.init(string:))
        let challengeHints = (item["challengeInfoList"] as? [[String: Any]] ?? [])
            .compactMap { $0["challengeName"] as? String }
        let hints = ((item["suggestedWords"] as? [String] ?? []) + challengeHints)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard videoURL != nil || thumbnailURL != nil || !hints.isEmpty else { return nil }
        return TikTokPageMetadata(
            videoURL: videoURL,
            thumbnailURL: thumbnailURL,
            searchHints: Array(hints.prefix(12))
        )
    }

    private static func universalItem(in html: String) -> [String: Any]? {
        guard let scriptData = scriptJSON(id: "__UNIVERSAL_DATA_FOR_REHYDRATION__", in: html),
              let root = try? JSONSerialization.jsonObject(with: scriptData) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any],
              let detail = scope["webapp.video-detail"] as? [String: Any],
              let itemInfo = detail["itemInfo"] as? [String: Any] else { return nil }
        return itemInfo["itemStruct"] as? [String: Any]
    }

    private static func embedItem(in html: String) -> [String: Any]? {
        guard let scriptData = scriptJSON(id: "__FRONTITY_CONNECT_STATE__", in: html),
              let root = try? JSONSerialization.jsonObject(with: scriptData) as? [String: Any],
              let source = root["source"] as? [String: Any],
              let data = source["data"] as? [String: Any] else { return nil }
        for value in data.values {
            guard let page = value as? [String: Any],
                  let videoData = page["videoData"] as? [String: Any],
                  let item = videoData["itemInfos"] as? [String: Any] else { continue }
            return item
        }
        return nil
    }

    private static func scriptJSON(id: String, in html: String) -> Data? {
        guard let idRange = html.range(of: "id=\"\(id)\""),
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
        case .other:
            return nil
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
        return show.image?.original ?? show.image?.medium ?? episodeImage?.original ?? episodeImage?.medium
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
