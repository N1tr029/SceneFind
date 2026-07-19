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
            let key = kind == .other
                ? provider.episodeURL.host?.lowercased() ?? provider.name.lowercased()
                : kind.rawValue
            return seen.insert(key).inserted
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
            && isTrustedHuluURL(provider.episodeURL)
            && candidate.seasonNumber != nil
            && candidate.episodeNumber != nil
    }

    func destination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) async -> ResolvedStreamingDestination? {
        let kind = StreamingProviderKind(provider: provider)
        if kind == .hulu {
            return await huluDestination(for: provider, candidate: candidate)
        }

        guard let direct = Self.directDestination(for: provider, candidate: candidate),
              await pageVerification(
                provider.episodeURL,
                candidate: candidate,
                kind: kind
              ) == .verified else { return nil }
        return direct
    }

    private func huluDestination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) async -> ResolvedStreamingDestination? {
        if provider.episodeURL.scheme?.lowercased() == "hulu" {
            return Self.directDestination(for: provider, candidate: candidate)
        }

        if let episodeID = Self.huluEpisodeID(in: provider.episodeURL) {
            guard let (data, responseURL) = await huluPage(for: provider.episodeURL),
                  StreamingPageParser.matchesSeries(
                    in: data,
                    candidate: candidate,
                    url: responseURL
                  ) else { return nil }

            if candidate.mediaType == .television,
               let season = candidate.seasonNumber,
               let episode = candidate.episodeNumber {
                guard HuluEpisodePageParser.matchesEpisode(
                    in: data,
                    id: episodeID,
                    season: season,
                    episode: episode
                ) else { return nil }
            }
            return Self.huluEpisodeDestination(episodeID: episodeID)
        }

        guard Self.isTrustedHuluURL(provider.episodeURL),
              let season = candidate.seasonNumber,
              let episode = candidate.episodeNumber,
              let canonicalLookupURL = Self.huluSeriesLookupURL(title: candidate.mediaTitle) else {
            return nil
        }

        guard let (data, responseURL) = await huluPage(for: canonicalLookupURL),
              StreamingPageParser.matchesSeries(in: data, candidate: candidate, url: responseURL),
              let episodeID = HuluEpisodePageParser.episodeID(
                in: data,
                season: season,
                episode: episode,
                title: candidate.episodeTitle
              ) else { return nil }

        return Self.huluEpisodeDestination(episodeID: episodeID)
    }

    private func huluPage(for url: URL) async -> (Data, URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }
        return (data, httpResponse.url ?? url)
    }

    private func pageVerification(
        _ url: URL,
        candidate: SceneCandidate,
        kind: StreamingProviderKind
    ) async -> StreamingPageVerification {
        guard url.scheme?.lowercased() == "https" else { return .unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .unavailable }
        return StreamingPageParser.verification(
            in: data,
            candidate: candidate,
            kind: kind,
            url: response.url ?? url
        )
    }

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

    private static func directDestination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) -> ResolvedStreamingDestination? {
        let url = provider.episodeURL
        let path = url.path.lowercased()
        let kind = StreamingProviderKind(provider: provider)

        if url.scheme?.lowercased() != "hulu" {
            guard url.scheme?.lowercased() == "https",
                  isTrustedHost(url.host, for: kind) else { return nil }
        }

        switch kind {
        case .hulu:
            guard let episodeID = huluEpisodeID(in: url) else { return nil }
            return huluEpisodeDestination(episodeID: episodeID)
        case .netflix:
            guard pathComponent(after: "watch", in: url) != nil else {
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
            let contentMarkers = [
                "/episode/", "/episodes/", "/watch/", "/video/", "/detail/", "/details/",
                "/player/", "/on-demand/", "/tv-shows/", "/movies/"
            ]
            guard contentMarkers.contains(where: path.contains) else {
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
            ?? pathComponent(after: "videos", in: url)
    }

    private static func huluEpisodeDestination(episodeID: String) -> ResolvedStreamingDestination? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dl.hulu.com"
        components.path = "/watch/\(episodeID)"
        components.queryItems = [
            URLQueryItem(name: "source", value: "web_universal_deep_linking"),
            URLQueryItem(name: "play", value: "true")
        ]
        guard let universalLink = components.url,
              let nativeURL = URL(string: "hulu://watch/\(episodeID)") else { return nil }
        return ResolvedStreamingDestination(
            primaryURL: universalLink,
            webFallbackURL: nativeURL
        )
    }

    private static func isTrustedHuluURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && isTrustedHost(url.host, for: .hulu)
    }

    private static func huluSeriesLookupURL(title: String) -> URL? {
        let slug = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        guard !slug.isEmpty else { return nil }
        return URL(string: "https://www.hulu.com/series/\(slug)")
    }

    private static func isTrustedHost(_ rawHost: String?, for kind: StreamingProviderKind) -> Bool {
        guard let host = rawHost?.lowercased() else { return false }
        let domains: [String]
        switch kind {
        case .hulu: domains = ["hulu.com"]
        case .netflix: domains = ["netflix.com"]
        case .appleTV: domains = ["tv.apple.com"]
        case .disneyPlus: domains = ["disneyplus.com"]
        case .primeVideo: domains = ["amazon.com", "primevideo.com"]
        case .max: domains = ["max.com"]
        case .peacock: domains = ["peacocktv.com"]
        case .paramountPlus: domains = ["paramountplus.com"]
        case .youtube: domains = ["youtube.com", "youtu.be"]
        case .other:
            domains = [
                "tubitv.com", "pluto.tv", "roku.com", "fandango.com", "starz.com",
                "mgmplus.com", "amcplus.com", "britbox.com", "crunchyroll.com",
                "plex.tv", "philo.com", "sling.com"
            ]
        }
        return domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func pathComponent(after marker: String, in url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let index = components.firstIndex(where: { $0.caseInsensitiveCompare(marker) == .orderedSame }),
              components.indices.contains(index + 1),
              !components[index + 1].isEmpty else { return nil }
        return components[index + 1]
    }
}

enum StreamingPageVerification: Equatable {
    case verified
    case mismatch
    case unavailable
}

enum StreamingPageParser {
    static func verification(
        in data: Data,
        candidate: SceneCandidate,
        kind: StreamingProviderKind,
        url: URL
    ) -> StreamingPageVerification {
        guard let html = String(data: data, encoding: .utf8) else { return .unavailable }
        let titles = pageTitles(in: html)
        guard !titles.isEmpty else { return .unavailable }

        let showMatch = titles.contains { containsPhrase(candidate.mediaTitle, in: $0) }
        let episodeMatch = candidate.episodeTitle.map { episodeTitle in
            titles.contains { containsPhrase(episodeTitle, in: $0) }
        } ?? false
        let numberMatch = matchesEpisodeNumber(in: titles, candidate: candidate)
        let routeShowMatch = containsPhrase(candidate.mediaTitle, in: url.path)

        if candidate.mediaType != .television || kind == .netflix {
            return showMatch ? .verified : .mismatch
        }
        if episodeMatch && (showMatch || routeShowMatch) {
            return .verified
        }
        if showMatch && numberMatch {
            return .verified
        }
        return .mismatch
    }

    static func matchesSeries(in data: Data, candidate: SceneCandidate, url: URL) -> Bool {
        guard let html = String(data: data, encoding: .utf8) else { return false }
        return pageTitles(in: html).contains { containsPhrase(candidate.mediaTitle, in: $0) }
            || containsPhrase(candidate.mediaTitle, in: url.path)
    }

    private static func pageTitles(in html: String) -> [String] {
        var values: [String] = []
        if let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..., in: html)
            for match in metaRegex.matches(in: html, range: range) {
                guard let tagRange = Range(match.range, in: html) else { continue }
                let attributes = metaAttributes(in: String(html[tagRange]))
                let key = (attributes["property"] ?? attributes["name"])?.lowercased()
                if ["og:title", "twitter:title"].contains(key), let content = attributes["content"] {
                    values.append(decoded(content))
                }
            }
        }
        if let titleRegex = try? NSRegularExpression(
            pattern: #"<title[^>]*>([^<]+)</title>"#,
            options: [.caseInsensitive]
        ), let match = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            values.append(decoded(String(html[range])))
        }
        return Array(Set(values)).filter { !$0.isEmpty }
    }

    private static func metaAttributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z:-]+)\s*=\s*[\"']([^\"']*)[\"']"#
        ) else { return [:] }
        return regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).reduce(into: [:]) { values, match in
            guard let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 2), in: tag) else { return }
            values[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
        }
    }

    private static func containsPhrase(_ phrase: String, in value: String) -> Bool {
        let expected = normalized(phrase)
        let haystack = normalized(value)
        guard !expected.isEmpty else { return false }
        return " \(haystack) ".contains(" \(expected) ")
    }

    private static func matchesEpisodeNumber(in titles: [String], candidate: SceneCandidate) -> Bool {
        guard let season = candidate.seasonNumber, let episode = candidate.episodeNumber else { return false }
        let value = normalized(titles.joined(separator: " "))
        let patterns = [
            "s\(season) e\(episode)",
            "\(season)x\(episode)",
            "season \(season) episode \(episode)"
        ]
        return patterns.contains(where: value.contains)
    }

    private static func decoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum HuluEpisodePageParser {
    static func episodeID(in data: Data, season: Int, episode: Int, title _: String?) -> String? {
        guard let root = rootObject(in: data) else { return nil }
        return episodeID(in: root, season: season, episode: episode)
    }

    static func matchesEpisode(in data: Data, id: String, season: Int, episode: Int) -> Bool {
        guard let root = rootObject(in: data) else { return false }
        return containsEpisode(in: root, id: id, season: season, episode: episode)
    }

    private static func rootObject(in data: Data) -> Any? {
        guard let html = String(data: data, encoding: .utf8),
              let jsonData = nextDataJSON(in: html) else { return nil }
        return try? JSONSerialization.jsonObject(with: jsonData)
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

    private static func containsEpisode(
        in value: Any,
        id: String,
        season: Int,
        episode: Int
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            if (dictionary["type"] as? String)?.lowercased() == "episode",
               dictionary["id"] as? String == id,
               integer(dictionary["season"]) == season,
               integer(dictionary["number"]) == episode {
                return true
            }
            return dictionary.values.contains {
                containsEpisode(in: $0, id: id, season: season, episode: episode)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsEpisode(in: $0, id: id, season: season, episode: episode)
            }
        }
        return false
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

}
