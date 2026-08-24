import Foundation

/// Finds the real "open in <service>" link for an episode or film, the same way
/// a search engine does.
///
/// Content ids like Apple TV's `umc.cmc.3151jcjocan3bys22epi0qeg6` or Peacock's
/// per-episode UUID cannot be derived from a title — but they are sitting in
/// public search results, because every provider publishes crawlable episode
/// pages. So SceneFind searches for the episode, pulls out any provider URLs,
/// and then **verifies each one by fetching it** and checking the page's own
/// `og:title` names the same show and season/episode. Verified live on
/// 2026-07-24 for *The Middle* S5E8, which returned a working Apple TV,
/// Peacock, and HBO Max episode URL.
///
/// The verification step is the point. It means a link is only ever offered when
/// the provider's own page confirms it, so a wrong or stale id is dropped rather
/// than handed to the viewer as a dead button.
struct EpisodeWatchLinkFinder {
    private let session: URLSession
    private let searchProvider: WebSearchProvider

    init(session: URLSession = .shared, searchProvider: WebSearchProvider? = nil) {
        self.session = session
        self.searchProvider = searchProvider ?? CompositeWebSearchProvider(session: session)
    }

    struct Found: Equatable, Codable {
        let url: URL
        let service: StreamingProviderKind
        let serviceName: String
    }

    /// Returns provider links whose own pages confirm they are this exact title.
    ///
    /// Verification is concurrent and the candidate list is capped. Checking one
    /// URL at a time until enough verified would, on a results page carrying
    /// twenty provider links, chain twenty eight-second fetches — slower than the
    /// video analysis this whole pipeline exists to avoid.
    func verifiedLinks(for candidate: SceneCandidate, limit: Int = 3) async -> [Found] {
        if let cached = await Self.cache.value(for: candidate) { return cached }

        let results = await searchProvider.search(query: Self.query(for: candidate))
        guard !results.isEmpty else { return [] }

        // One best URL per service, so a service with many indexed pages cannot
        // crowd out the others.
        var bestPerService: [(kind: StreamingProviderKind, url: URL)] = []
        for url in Self.rankedProviderURLs(in: results) {
            let kind = StreamingProviderKind(name: "", host: url.host)
            guard kind != .other, !bestPerService.contains(where: { $0.kind == kind }) else { continue }
            bestPerService.append((kind, url))
            if bestPerService.count >= Self.maximumServicesChecked { break }
        }
        guard !bestPerService.isEmpty else { return [] }

        let verified = await withTaskGroup(of: (Int, Found?).self) { group in
            for (index, entry) in bestPerService.enumerated() {
                group.addTask {
                    guard await self.pageConfirms(entry.url, candidate: candidate, kind: entry.kind) else {
                        return (index, nil)
                    }
                    return (index, Found(
                        url: WatchDestinationPolicy.normalized(entry.url),
                        service: entry.kind,
                        serviceName: OfficialWatchLinkService.displayName(for: entry.kind)
                    ))
                }
            }
            var found: [(Int, Found)] = []
            for await case let (index, link?) in group { found.append((index, link)) }
            // Restore search-rank order, which the group returns out of.
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let limited = Array(verified.prefix(limit))
        await Self.cache.store(limited, for: candidate)
        return limited
    }

    /// Five is enough to cover the services anyone actually subscribes to while
    /// keeping the concurrent fan-out small.
    private static let maximumServicesChecked = 5

    /// An episode's page URL never changes, so a repeat lookup should be free.
    /// Process-lifetime only, which is the right scope for a cache holding URLs
    /// that were verified against live pages.
    private static let cache = WatchLinkCache()

    /// Phrased the way a person would search for the episode, because that is
    /// what the provider pages are titled and indexed as.
    static func query(for candidate: SceneCandidate) -> String {
        var parts = [candidate.mediaTitle]
        if candidate.mediaType == .television,
           let season = candidate.seasonNumber, let episode = candidate.episodeNumber {
            parts.append("season \(season) episode \(episode)")
            if let episodeTitle = candidate.episodeTitle, !episodeTitle.isEmpty {
                parts.append(episodeTitle)
            }
        } else if candidate.mediaType == .movie {
            parts.append(String(candidate.releaseYear))
        }
        parts.append("watch")
        return parts.joined(separator: " ")
    }

    /// Prefers URLs that look episode-specific over a service's front page, and
    /// drops other countries' storefronts.
    ///
    /// Search happily returns a `paramountplus.com/ca/…` page for a US query, and
    /// a Canadian storefront will not play for a US viewer — the exact kind of
    /// link that looks right and then fails to open.
    static func rankedProviderURLs(in results: [URL]) -> [URL] {
        let markers = ["/episode", "/watch", "/video", "/movie", "/play", "/detail"]
        return results
            .filter { $0.scheme?.lowercased() == "https" && !isForeignStorefront($0) }
            .sorted { lhs, rhs in
                let l = markers.contains { lhs.path.lowercased().contains($0) }
                let r = markers.contains { rhs.path.lowercased().contains($0) }
                if l != r { return l }
                return lhs.path.count > rhs.path.count
            }
    }

    /// True when the path opens with a two-letter region that is not `us`.
    /// Providers use this shape (`/ca/`, `/au/`, `/gb/`) for regional catalogues.
    static func isForeignStorefront(_ url: URL) -> Bool {
        guard let first = url.pathComponents.first(where: { $0 != "/" })?.lowercased(),
              first.count == 2,
              first.allSatisfy(\.isLetter) else { return false }
        // `en` and `us` are language/region segments that still mean the US site.
        return !["us", "en"].contains(first)
    }

    private func pageConfirms(
        _ url: URL,
        candidate: SceneCandidate,
        kind: StreamingProviderKind
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(OEmbedSocialClipMetadataService.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return false }
        return StreamingPageParser.verification(
            in: data,
            candidate: candidate,
            kind: kind,
            url: response.url ?? url
        ) == .verified
    }
}

/// Caches verified links per title/season/episode, on disk.
///
/// This is load-bearing rather than an optimisation. SerpApi's free plan allows
/// 250 searches a month, and an episode's page URL never changes — so a lookup
/// should be paid for once, ever, not once per app launch. The file lives in the
/// App Group container so the share extension and the app share one cache.
private actor WatchLinkCache {
    private typealias Entries = [String: [EpisodeWatchLinkFinder.Found]]

    private var entries: Entries?

    private static let fileName = "watch-links.v1.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfiguration.identifier)?
            .appendingPathComponent(fileName)
    }

    private func key(_ candidate: SceneCandidate) -> String {
        [
            candidate.mediaTitle.lowercased(),
            candidate.seasonNumber.map(String.init) ?? "-",
            candidate.episodeNumber.map(String.init) ?? "-",
            String(candidate.releaseYear)
        ].joined(separator: "|")
    }

    private func loaded() -> Entries {
        if let entries { return entries }
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Entries.self, from: data) else {
            entries = [:]
            return [:]
        }
        entries = decoded
        return decoded
    }

    func value(for candidate: SceneCandidate) -> [EpisodeWatchLinkFinder.Found]? {
        loaded()[key(candidate)]
    }

    func store(_ links: [EpisodeWatchLinkFinder.Found], for candidate: SceneCandidate) {
        // A miss is cached too. Without that, a title with no findable link would
        // spend a search on every single attempt.
        var current = loaded()
        current[key(candidate)] = links
        entries = current
        guard let url = Self.fileURL,
              let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Search

protocol WebSearchProvider {
    /// Result URLs for a query, best first. Empty when the search is unavailable.
    func search(query: String) async -> [URL]
}

/// The evidence-bearing form of a search result. Episode identification needs
/// the title and snippet as well as the URL: that is where an indexed transcript
/// exposes both a quoted line and its season/episode label without trusting a
/// social caption.
struct WebSearchResult: Equatable {
    let url: URL
    let title: String
    let snippet: String
}

/// Uses a configured search API when there is one, and otherwise makes a
/// best-effort keyless attempt.
///
/// The keyless path is genuinely unreliable: measured on 2026-07-24, DuckDuckGo's
/// HTML endpoint answered the first request with `200` and the next two with
/// `202` — its bot challenge. That is fine as an opportunistic bonus but it is
/// why a search API key is the supported configuration; see
/// `WebSearchConfiguration`.
struct CompositeWebSearchProvider: WebSearchProvider {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func search(query: String) async -> [URL] {
        await searchResults(query: query).map(\.url)
    }

    /// Detailed results for episode research. The public watch-link interface
    /// still consumes URLs only, while the episode resolver can corroborate
    /// dialogue against the indexed title/snippet.
    func searchResults(query: String) async -> [WebSearchResult] {
        for credentials in WebSearchConfiguration.credentialCandidates {
            let results: [WebSearchResult]?
            switch credentials.provider {
            case .brave:
                results = await braveSearch(query: query, apiKey: credentials.key)
            case .serpAPI:
                results = await serpAPISearch(query: query, apiKey: credentials.key)
            }
            if let results, !results.isEmpty { return results }
        }
        return (await duckDuckGoSearch(query: query) ?? []).map {
            WebSearchResult(url: $0, title: "", snippet: "")
        }
    }

    /// SerpApi returns Google's own results, which is exactly the index that
    /// carries provider episode pages.
    ///
    /// Its free plan allows 250 searches a month, so every result is cached by
    /// title/season/episode — an episode's page URL never changes, and without
    /// caching a handful of testers would exhaust the month in an afternoon.
    private func serpAPISearch(query: String, apiKey: String) async -> [WebSearchResult]? {
        var components = URLComponents(string: "https://serpapi.com/search.json")
        components?.queryItems = [
            URLQueryItem(name: "engine", value: "google"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: "20"),
            URLQueryItem(name: "gl", value: "us"),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let payload = try? JSONDecoder().decode(SerpAPIResponse.self, from: data) else { return nil }
        // Organic results first, then whatever Google surfaced in its own
        // watch-options block, which often names the providers directly.
        let organic = payload.organicResults?.compactMap { result -> WebSearchResult? in
            guard let url = URL(string: result.link) else { return nil }
            return WebSearchResult(
                url: url,
                title: result.title ?? "",
                snippet: result.snippet ?? ""
            )
        } ?? []
        let inline = payload.inlineVideos?.compactMap { result -> WebSearchResult? in
            guard let rawURL = result.link, let url = URL(string: rawURL) else { return nil }
            return WebSearchResult(
                url: url,
                title: result.title ?? "",
                snippet: result.snippet ?? ""
            )
        } ?? []
        return organic + inline
    }

    /// Brave's Search API is documented, keyed, and permits this use. It returns
    /// the same provider pages a browser search does.
    private func braveSearch(query: String, apiKey: String) async -> [WebSearchResult]? {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "20")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let payload = try? JSONDecoder().decode(BraveResponse.self, from: data) else { return nil }
        return payload.web?.results.compactMap { result -> WebSearchResult? in
            guard let url = URL(string: result.url) else { return nil }
            return WebSearchResult(
                url: url,
                title: result.title ?? "",
                snippet: result.description ?? ""
            )
        } ?? []
    }

    private func duckDuckGoSearch(query: String) async -> [URL]? {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(OEmbedSocialClipMetadataService.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return Self.absoluteURLs(in: html)
    }

    /// Pulls candidate result URLs out of a results page, unwrapping the
    /// redirector DuckDuckGo puts around outbound links.
    static func absoluteURLs(in html: String) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func append(_ text: String) {
            let cleaned = text
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>) "))
            guard let url = URL(string: cleaned), url.host != nil, seen.insert(cleaned).inserted else { return }
            found.append(url)
        }
        if let regex = try? NSRegularExpression(pattern: "uddg=([^&\"']+)") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                append(String(html[range]).removingPercentEncoding ?? String(html[range]))
            }
        }
        if let regex = try? NSRegularExpression(pattern: "https?://[^\"'<> )\\\\]+") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                append(String(html[range]))
            }
        }
        return found
    }

    private struct BraveResponse: Decodable {
        struct Web: Decodable {
            struct Result: Decodable {
                let url: String
                let title: String?
                let description: String?
            }
            let results: [Result]
        }
        let web: Web?
    }

    private struct SerpAPIResponse: Decodable {
        struct Organic: Decodable {
            let link: String
            let title: String?
            let snippet: String?
        }
        struct InlineVideo: Decodable {
            let link: String?
            let title: String?
            let snippet: String?
        }
        let organicResults: [Organic]?
        let inlineVideos: [InlineVideo]?

        enum CodingKeys: String, CodingKey {
            case organicResults = "organic_results"
            case inlineVideos = "inline_videos"
        }
    }
}
