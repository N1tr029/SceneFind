import Foundation

enum StreamingProviderCatalog {
    private static let huluSeriesURLs: [String: URL] = [
        "modern family": URL(string: "https://www.hulu.com/series/modern-family-883c414c-34a3-4fcc-b50a-0ad5a184c977")!,
        "the rookie": URL(string: "https://www.hulu.com/series/the-rookie-1138ee62-b9d9-4561-8094-3f7cda4bbd22")!
    ]

    private static let verifiedHuluEpisodes: [String: URL] = [
        "modern family|4|4": URL(string: "https://www.hulu.com/series/modern-family-883c414c-34a3-4fcc-b50a-0ad5a184c977?entity_id=008ab86a-f287-4275-83d2-d2d7aa605bb5")!
    ]

    static func providers(for candidate: SceneCandidate, supplied: [WatchProvider]) -> [WatchProvider] {
        var providers = supplied.map { provider in
            guard isHulu(provider) else { return provider }
            return huluProvider(for: candidate)
        }

        if huluSeriesURL(for: candidate.mediaTitle) != nil,
           !providers.contains(where: isHulu) {
            providers.insert(huluProvider(for: candidate), at: 0)
        }

        var seen = Set<String>()
        return providers.filter { seen.insert($0.id.lowercased()).inserted }
    }

    static func huluSeriesURL(for mediaTitle: String) -> URL? {
        huluSeriesURLs[normalized(mediaTitle)]
    }

    static func verifiedHuluEpisodeURL(for candidate: SceneCandidate) -> URL? {
        guard let season = candidate.seasonNumber, let episode = candidate.episodeNumber else { return nil }
        return verifiedHuluEpisodes["\(normalized(candidate.mediaTitle))|\(season)|\(episode)"]
    }

    static func isHulu(_ provider: WatchProvider) -> Bool {
        provider.name.localizedCaseInsensitiveContains("hulu")
            || provider.episodeURL.host?.lowercased().hasSuffix("hulu.com") == true
    }

    static func huluSearchURL(for candidate: SceneCandidate) -> URL {
        var components = URLComponents(string: "https://www.hulu.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: searchTitle(for: candidate))]
        return components.url!
    }

    private static func huluProvider(for candidate: SceneCandidate) -> WatchProvider {
        let destination = verifiedHuluEpisodeURL(for: candidate)
            ?? huluSeriesURL(for: candidate.mediaTitle)
            ?? huluSearchURL(for: candidate)
        return WatchProvider(
            id: "hulu",
            name: "Hulu",
            offer: "Subscription",
            episodeURL: destination,
            sceneURL: nil,
            symbolName: "play.tv.fill",
            brandColorHex: "1CE783"
        )
    }

    private static func searchTitle(for candidate: SceneCandidate) -> String {
        [
            candidate.mediaTitle,
            candidate.seasonNumber.map { "Season \($0)" },
            candidate.episodeNumber.map { "Episode \($0)" },
            candidate.episodeTitle
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct StreamingDestinationResolver {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func destination(for provider: WatchProvider, candidate: SceneCandidate) async -> URL {
        guard StreamingProviderCatalog.isHulu(provider) else { return provider.episodeURL }
        if let verified = StreamingProviderCatalog.verifiedHuluEpisodeURL(for: candidate) {
            return verified
        }
        guard let seriesURL = StreamingProviderCatalog.huluSeriesURL(for: candidate.mediaTitle),
              let season = candidate.seasonNumber,
              let episode = candidate.episodeNumber else {
            return StreamingProviderCatalog.huluSeriesURL(for: candidate.mediaTitle)
                ?? StreamingProviderCatalog.huluSearchURL(for: candidate)
        }

        var request = URLRequest(url: seriesURL)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 SceneFind/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let episodeID = HuluEpisodePageParser.episodeID(
                in: data,
                season: season,
                episode: episode,
                title: candidate.episodeTitle
              ) else {
            return seriesURL
        }

        var components = URLComponents(url: seriesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "entity_id", value: episodeID)]
        return components.url ?? seriesURL
    }
}

enum HuluEpisodePageParser {
    static func episodeID(in data: Data, season: Int, episode: Int, title _: String?) -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let jsonData = nextDataJSON(in: html),
              let root = try? JSONSerialization.jsonObject(with: jsonData) else {
            return nil
        }
        return episodeID(in: root, season: season, episode: episode)
    }

    private static func nextDataJSON(in html: String) -> Data? {
        guard let scriptStart = html.range(of: "<script id=\"__NEXT_DATA__\""),
              let openingTagEnd = html[scriptStart.lowerBound...].firstIndex(of: ">"),
              let scriptEnd = html.range(of: "</script>", range: openingTagEnd..<html.endIndex) else {
            return nil
        }
        return String(html[html.index(after: openingTagEnd)..<scriptEnd.lowerBound]).data(using: .utf8)
    }

    private static func episodeID(in value: Any, season: Int, episode: Int) -> String? {
        if let dictionary = value as? [String: Any] {
            if (dictionary["type"] as? String)?.lowercased() == "episode",
               integer(dictionary["season"]) == season,
               integer(dictionary["number"]) == episode,
               let id = dictionary["id"] as? String,
               !id.isEmpty {
                return id
            }
            for child in dictionary.values {
                if let id = episodeID(in: child, season: season, episode: episode) {
                    return id
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let id = episodeID(in: child, season: season, episode: episode) {
                    return id
                }
            }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

}
