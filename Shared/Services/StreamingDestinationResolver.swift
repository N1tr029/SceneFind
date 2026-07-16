import Foundation

enum StreamingProviderKind: String {
    case hulu
    case netflix
    case appleTV
    case disneyPlus
    case primeVideo
    case max
    case peacock
    case paramountPlus
    case youtube
    case other

    init(provider: WatchProvider) {
        let name = provider.name.lowercased()
        let host = provider.episodeURL.host?.lowercased() ?? ""
        let scheme = provider.episodeURL.scheme?.lowercased() ?? ""
        if scheme == "hulu" || name.contains("hulu") || host.hasSuffix("hulu.com") {
            self = .hulu
        } else if scheme == "nflx" || name.contains("netflix") || host.hasSuffix("netflix.com") {
            self = .netflix
        } else if name.contains("apple") || host == "tv.apple.com" {
            self = .appleTV
        } else if name.contains("disney") || host.hasSuffix("disneyplus.com") {
            self = .disneyPlus
        } else if name.contains("prime") || name.contains("amazon") || host.hasSuffix("amazon.com") {
            self = .primeVideo
        } else if name == "max" || name.contains("hbo") || host.hasSuffix("max.com") {
            self = .max
        } else if name.contains("peacock") || host.hasSuffix("peacocktv.com") {
            self = .peacock
        } else if name.contains("paramount") || host.contains("paramountplus") {
            self = .paramountPlus
        } else if name.contains("youtube") || host.hasSuffix("youtube.com") || host == "youtu.be" {
            self = .youtube
        } else {
            self = .other
        }
    }
}

struct ResolvedStreamingDestination: Equatable {
    let primaryURL: URL
    let webFallbackURL: URL?
}

enum StreamingProviderCatalog {

    static func providers(for candidate: SceneCandidate, supplied: [WatchProvider]) -> [WatchProvider] {
        var seen = Set<String>()
        return supplied.filter { provider in
            let kind = StreamingProviderKind(provider: provider)
            guard StreamingDestinationResolver.canResolve(provider: provider, candidate: candidate) else {
                return false
            }
            return seen.insert(kind.rawValue).inserted
        }
    }

    static func isHulu(_ provider: WatchProvider) -> Bool {
        provider.name.localizedCaseInsensitiveContains("hulu")
            || provider.episodeURL.host?.lowercased().hasSuffix("hulu.com") == true
    }

}

struct StreamingDestinationResolver {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func canResolve(provider: WatchProvider, candidate: SceneCandidate) -> Bool {
        if directDestination(for: provider, candidate: candidate) != nil { return true }
        return StreamingProviderKind(provider: provider) == .hulu
            && isHuluSeriesURL(provider.episodeURL)
            && candidate.seasonNumber != nil
            && candidate.episodeNumber != nil
    }

    func destination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) async -> ResolvedStreamingDestination? {
        if let direct = Self.directDestination(for: provider, candidate: candidate) {
            return direct
        }
        guard StreamingProviderKind(provider: provider) == .hulu,
              Self.isHuluSeriesURL(provider.episodeURL),
              let season = candidate.seasonNumber,
              let episode = candidate.episodeNumber else { return nil }

        var request = URLRequest(url: provider.episodeURL)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 SceneFind/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let episodeID = HuluEpisodePageParser.episodeID(
                in: data,
                season: season,
                episode: episode,
                title: candidate.episodeTitle
              ) else { return nil }

        guard let nativeURL = URL(string: "hulu://watch/\(episodeID)") else { return nil }
        return ResolvedStreamingDestination(primaryURL: nativeURL, webFallbackURL: nil)
    }

    private static func directDestination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) -> ResolvedStreamingDestination? {
        let url = provider.episodeURL
        let path = url.path.lowercased()
        let kind = StreamingProviderKind(provider: provider)

        switch kind {
        case .hulu:
            guard let episodeID = huluEpisodeID(in: url),
                  let nativeURL = URL(string: "hulu://watch/\(episodeID)") else { return nil }
            let fallback = url.scheme?.lowercased().hasPrefix("http") == true ? url : nil
            return ResolvedStreamingDestination(primaryURL: nativeURL, webFallbackURL: fallback)
        case .netflix:
            guard url.scheme?.lowercased() == "nflx" || pathComponent(after: "watch", in: url) != nil else {
                return nil
            }
        case .appleTV:
            let isExact = candidate.mediaType == .movie
                ? path.contains("/movie/")
                : candidate.mediaType == .television && path.contains("/episode/")
            guard isExact else {
                return nil
            }
        case .disneyPlus:
            let isExact = path.contains("/video/")
                || (candidate.mediaType == .movie && path.contains("/browse/entity-"))
            guard isExact else { return nil }
        case .primeVideo:
            guard path.contains("/video/detail/") || path.contains("/gp/video/detail/") else { return nil }
        case .max:
            guard path.contains("/video/watch/") || path.contains("/episode/") else { return nil }
        case .peacock:
            guard path.contains("/episodes/") || path.contains("/watch/playback/") || path.contains("/deeplink") else {
                return nil
            }
        case .paramountPlus:
            guard url.host?.lowercased() == "link.us.paramountplus.com" || path.contains("/video/") else {
                return nil
            }
        case .youtube:
            guard path.contains("/watch") || url.host?.lowercased() == "youtu.be" else { return nil }
        case .other:
            guard path.contains("/episode/") || path.contains("/episodes/") || path.contains("/watch/") else {
                return nil
            }
        }
        return ResolvedStreamingDestination(primaryURL: url, webFallbackURL: nil)
    }

    private static func huluEpisodeID(in url: URL) -> String? {
        if url.scheme?.lowercased() == "hulu", url.host?.lowercased() == "watch" {
            return url.pathComponents.dropFirst().first
        }
        guard url.host?.lowercased().hasSuffix("hulu.com") == true else { return nil }
        return pathComponent(after: "watch", in: url)
    }

    private static func isHuluSeriesURL(_ url: URL) -> Bool {
        url.host?.lowercased().hasSuffix("hulu.com") == true && url.path.lowercased().contains("/series/")
    }

    private static func pathComponent(after marker: String, in url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let index = components.firstIndex(where: { $0.caseInsensitiveCompare(marker) == .orderedSame }),
              components.indices.contains(index + 1),
              !components[index + 1].isEmpty else { return nil }
        return components[index + 1]
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
