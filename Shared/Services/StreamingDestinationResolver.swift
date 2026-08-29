import Foundation

enum StreamingProviderKind: String, Codable {
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
        self.init(
            name: provider.name,
            host: provider.episodeURL.host,
            scheme: provider.episodeURL.scheme
        )
    }

    init(name rawName: String, host rawHost: String? = nil, scheme rawScheme: String? = nil) {
        let name = rawName.lowercased()
        let host = rawHost?.lowercased() ?? ""
        let scheme = rawScheme?.lowercased() ?? ""
        if scheme == "hulu" || name.contains("hulu") || host.hasSuffix("hulu.com") {
            self = .hulu
        } else if scheme == "nflx" || name.contains("netflix") || host.hasSuffix("netflix.com") {
            self = .netflix
        } else if name.contains("apple") || host == "tv.apple.com" {
            self = .appleTV
        } else if name.contains("disney") || host.hasSuffix("disneyplus.com") {
            self = .disneyPlus
        } else if name.contains("prime") || name.contains("amazon") || host.hasSuffix("amazon.com")
            || host.hasSuffix("primevideo.com") {
            self = .primeVideo
        } else if name == "max" || name.contains("hbo") || host.hasSuffix("max.com")
            || host.hasSuffix("hbomax.com") {
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
    let level: StreamingDestinationLevel
    let diagnostic: String

    init(
        primaryURL: URL,
        webFallbackURL: URL?,
        level: StreamingDestinationLevel = .exactEpisode,
        diagnostic: String = "Exact route validated"
    ) {
        self.primaryURL = primaryURL
        self.webFallbackURL = webFallbackURL
        self.level = level
        self.diagnostic = diagnostic
    }
}

enum StreamingProviderCatalog {

    static func providers(for candidate: SceneCandidate, supplied: [WatchProvider]) -> [WatchProvider] {
        var seen = Set<String>()
        return supplied.compactMap { provider in
            let kind = StreamingProviderKind(provider: provider)
            guard let level = StreamingDestinationResolver.routeLevel(provider: provider, candidate: candidate) else {
                return nil
            }
            let key = kind == .other
                ? provider.episodeURL.host?.lowercased() ?? provider.name.lowercased()
                : kind.rawValue
            guard seen.insert(key).inserted else { return nil }
            return WatchProvider(
                id: provider.id,
                name: provider.name,
                offer: provider.offer,
                episodeURL: provider.episodeURL,
                sceneURL: provider.sceneURL,
                symbolName: provider.symbolName,
                brandColorHex: provider.brandColorHex,
                destinationLevel: level,
                destinationDiagnostic: level == .exactEpisode
                    ? "Route shape can represent exact content; the page is verified before opening."
                    : "The supplied official URL is not an exact episode route."
            )
        }
    }

    static func isHulu(_ provider: WatchProvider) -> Bool {
        provider.name.localizedCaseInsensitiveContains("hulu")
            || provider.episodeURL.host?.lowercased().hasSuffix("hulu.com") == true
    }

}

struct StreamingDestinationResolver {
    private let session: URLSession
    private static let cache = StreamingDestinationCache()

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func canResolve(provider: WatchProvider, candidate: SceneCandidate) -> Bool {
        routeLevel(provider: provider, candidate: candidate) != nil
    }

    static func routeLevel(
        provider: WatchProvider,
        candidate: SceneCandidate
    ) -> StreamingDestinationLevel? {
        if directDestination(for: provider, candidate: candidate) != nil { return .exactEpisode }
        let kind = StreamingProviderKind(provider: provider)
        guard provider.episodeURL.scheme?.lowercased() == "https",
              isTrustedHost(provider.episodeURL.host, for: kind) else { return nil }
        if kind == .hulu,
           candidate.seasonNumber != nil,
           candidate.episodeNumber != nil {
            return .exactEpisode
        }
        let path = provider.episodeURL.path.lowercased()
        let query = provider.episodeURL.query?.lowercased() ?? ""
        if path.contains("/search") || query.contains("search") || query.contains("query=")
            || query.contains("q=") || (kind == .primeVideo && query.contains("k=")) {
            return .search
        }
        return .show
    }

    func destination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) async -> ResolvedStreamingDestination? {
        let cacheKey = StreamingDestinationCache.Key(provider: provider, candidate: candidate)
        if let cached = await Self.cache.value(for: cacheKey) { return cached }

        let kind = StreamingProviderKind(provider: provider)
        var resolved: ResolvedStreamingDestination?
        if kind == .hulu {
            resolved = await huluDestination(for: provider, candidate: candidate)
        } else if Self.wasVerifiedByBackend(provider),
                  let direct = Self.directDestination(for: provider, candidate: candidate) {
            // Production analysis already fetched and verified this exact page.
            // Re-fetching it on the phone is actively harmful for Netflix: its
            // logged-out JS shell may omit title metadata, which used to turn a
            // valid /watch/<id> route into /search at the last second.
            resolved = direct
        } else if Self.routeLevel(provider: provider, candidate: candidate) != .exactEpisode {
            resolved = ResolvedStreamingDestination(
                primaryURL: provider.episodeURL,
                webFallbackURL: nil,
                level: Self.routeLevel(provider: provider, candidate: candidate) ?? .show,
                diagnostic: "Official URL accepted as a non-episode destination."
            )
        } else if let direct = Self.directDestination(for: provider, candidate: candidate),
                  await pageVerification(
                    provider.episodeURL,
                    candidate: candidate,
                    kind: kind
                  ) == .verified {
            resolved = direct
        } else {
            resolved = nil
        }
        // A destination that could not be verified used to surface as "SceneFind
        // rejected this destination" and left the user with nothing to tap.
        // Streaming sites are login-walled single-page apps, so verification
        // fails routinely on links that are perfectly fine. Degrade to the
        // service's own search instead of dead-ending.
        if resolved == nil {
            resolved = Self.fallbackDestination(for: provider, candidate: candidate)
        }
        if let resolved { await Self.cache.store(resolved, for: cacheKey) }
        return resolved
    }

    private static func wasVerifiedByBackend(_ provider: WatchProvider) -> Bool {
        guard provider.destinationLevel == .exactEpisode,
              let diagnostic = provider.destinationDiagnostic else { return false }
        return diagnostic.hasPrefix("Backend-verified exact provider page")
            || diagnostic == "The provider page confirmed this title."
    }

    /// Last resort that still lands somewhere real: the service's own search
    /// page, or a cross-service "where to watch" page when the service has none.
    static func fallbackDestination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) -> ResolvedStreamingDestination? {
        let kind = StreamingProviderKind(provider: provider)
        if let searchURL = WatchDestinationPolicy.searchURL(service: kind, title: candidate.mediaTitle) {
            return ResolvedStreamingDestination(
                primaryURL: searchURL,
                webFallbackURL: WatchDestinationPolicy.whereToWatchURL(title: candidate.mediaTitle),
                level: .search,
                diagnostic: "The exact page could not be confirmed, so this opens "
                    + "\(provider.name)'s search for \(candidate.mediaTitle)."
            )
        }
        guard let whereToWatch = WatchDestinationPolicy.whereToWatchURL(title: candidate.mediaTitle) else {
            return nil
        }
        return ResolvedStreamingDestination(
            primaryURL: whereToWatch,
            webFallbackURL: nil,
            level: .search,
            diagnostic: "\(provider.name) has no linkable search page, so this opens a "
                + "where-to-watch listing for \(candidate.mediaTitle)."
        )
    }

    /// Hulu is mid-migration into Disney+, which changes what can be checked.
    ///
    /// `www.hulu.com` now `302`s to the Disney+ home page, so the episode pages
    /// this used to scrape for a UUID are gone and the old verify-then-link flow
    /// can only ever fail — which is what silently killed previously-working
    /// saved links. But `dl.hulu.com` still publishes an AASA covering
    /// `/watch/*` for the Hulu app, and iOS resolves a Universal Link against
    /// that file without ever making the web request. So when an episode UUID is
    /// already in hand, hand it straight to `dl.hulu.com` and let the app open
    /// it; only fall back to search when there is no UUID to use.
    private func huluDestination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) async -> ResolvedStreamingDestination? {
        if provider.episodeURL.scheme?.lowercased() == "hulu" {
            return Self.directDestination(for: provider, candidate: candidate)
        }
        if let episodeID = Self.huluEpisodeID(in: provider.episodeURL) {
            return Self.huluEpisodeDestination(episodeID: episodeID)
        }
        return Self.fallbackDestination(for: provider, candidate: candidate)
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
        guard let universalLink = WatchDestinationPolicy.huluDeepLink(episodeID: episodeID),
              let nativeURL = URL(string: "hulu://watch/\(episodeID)") else { return nil }
        return ResolvedStreamingDestination(
            primaryURL: universalLink,
            webFallbackURL: nativeURL,
            level: .exactEpisode,
            diagnostic: "Opens this episode in the Hulu app. Hulu is moving to Disney+, "
                + "so without the app installed the web link lands on Disney+ instead."
        )
    }

    private static func huluFallbackDestination(
        for provider: WatchProvider,
        candidate: SceneCandidate
    ) -> ResolvedStreamingDestination? {
        if provider.episodeURL.path.lowercased().contains("/series/") {
            return ResolvedStreamingDestination(
                primaryURL: provider.episodeURL,
                webFallbackURL: nil,
                level: .show,
                diagnostic: "Hulu did not expose a matching episode UUID; downgraded to the supplied show page."
            )
        }
        var components = URLComponents(string: "https://www.hulu.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: candidate.mediaTitle)]
        guard let url = components?.url else { return nil }
        return ResolvedStreamingDestination(
            primaryURL: url,
            webFallbackURL: nil,
            level: .search,
            diagnostic: "Hulu did not expose a matching episode UUID; downgraded to an official title search."
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

        if candidate.mediaType != .television {
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

private actor StreamingDestinationCache {
    struct Key: Hashable {
        let provider: String
        let title: String
        let season: Int?
        let episode: Int?

        init(provider: WatchProvider, candidate: SceneCandidate) {
            self.provider = "\(StreamingProviderKind(provider: provider).rawValue)|\(provider.episodeURL.absoluteString)"
            title = candidate.mediaTitle.lowercased()
            season = candidate.seasonNumber
            episode = candidate.episodeNumber
        }
    }

    private var destinations: [Key: ResolvedStreamingDestination] = [:]

    func value(for key: Key) -> ResolvedStreamingDestination? {
        destinations[key]
    }

    func store(_ destination: ResolvedStreamingDestination, for key: Key) {
        destinations[key] = destination
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
